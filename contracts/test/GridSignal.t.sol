// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GridSignal} from "../src/GridSignal.sol";

contract GridSignalTest is Test {
    GridSignal internal grid;

    uint256 internal constant STAKE = 0.001 ether;

    address internal operator = address(0xBEEF);
    address internal deployer = address(this);

    // Swarm sector is richer than the spread sector, so piling on still loses.
    uint8 internal constant HOT = 12;
    uint8 internal constant COOL = 7;
    uint256 internal constant HOT_BOUNTY = 5 ether;
    uint256 internal constant COOL_BOUNTY = 2 ether;

    uint64 internal constant COMMIT_DUR = 1 hours;
    uint64 internal constant REVEAL_DUR = 1 hours;
    uint64 internal constant CLAIM_DUR = 1 hours;

    function setUp() public {
        grid = new GridSignal(STAKE, operator);
        vm.warp(1_700_000_000);
    }

    // ---------------------------------------------------------------- helpers

    function _emptyBounties() internal pure returns (uint256[25] memory b) {}

    function _createEpoch(uint256[25] memory bounties) internal returns (uint256 epochId) {
        uint256 total;
        for (uint256 i = 0; i < 25; ++i) {
            total += bounties[i];
        }
        vm.deal(deployer, total);
        epochId = grid.createEpoch{value: total}(bounties, COMMIT_DUR, REVEAL_DUR, CLAIM_DUR);
    }

    function _defaultEpoch() internal returns (uint256) {
        uint256[25] memory b = _emptyBounties();
        b[HOT] = HOT_BOUNTY;
        b[COOL] = COOL_BOUNTY;
        return _createEpoch(b);
    }

    function _commitmentOf(address who, uint256 epochId, uint8 sectorId, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(who, epochId, sectorId, salt));
    }

    function _commit(address who, uint256 epochId, uint8 sectorId, bytes32 salt) internal {
        vm.deal(who, who.balance + STAKE);
        vm.prank(who);
        grid.commit{value: STAKE}(_commitmentOf(who, epochId, sectorId, salt));
    }

    function _advance(uint256 epochId) internal {
        vm.prank(operator);
        grid.advancePhaseForDemo(epochId);
    }

    function _phase(uint256 epochId) internal view returns (GridSignal.Phase p) {
        (,, p) = grid.getEpochGridState(epochId);
    }

    function _counts(uint256 epochId) internal view returns (uint32[25] memory c) {
        (, c,) = grid.getEpochGridState(epochId);
    }

    // ------------------------------------------------------------------ tests

    /// Five responders swarm the rich sector and each take a fifth of it; one
    /// responder alone on the poorer sector out-earns every one of them.
    function test_SwarmVsSpread() public {
        uint256 epochId = _defaultEpoch();

        address[5] memory swarm = [address(0xA1), address(0xA2), address(0xA3), address(0xA4), address(0xA5)];
        address spread = address(0xB1);

        for (uint256 i = 0; i < swarm.length; ++i) {
            _commit(swarm[i], epochId, HOT, bytes32(uint256(0x1000 + i)));
        }
        _commit(spread, epochId, COOL, bytes32(uint256(0x2000)));

        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Reveal), "should be in Reveal");

        for (uint256 i = 0; i < swarm.length; ++i) {
            vm.prank(swarm[i]);
            grid.reveal(epochId, HOT, bytes32(uint256(0x1000 + i)));
        }
        vm.prank(spread);
        grid.reveal(epochId, COOL, bytes32(uint256(0x2000)));

        uint32[25] memory counts = _counts(epochId);
        assertEq(counts[HOT], 5, "hot sector count");
        assertEq(counts[COOL], 1, "cool sector count");

        // Stake came back on reveal, so every balance is level again.
        for (uint256 i = 0; i < swarm.length; ++i) {
            assertEq(swarm[i].balance, STAKE, "swarm stake refunded");
        }
        assertEq(spread.balance, STAKE, "spread stake refunded");

        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Claim), "should be in Claim");

        uint256 swarmPayout;
        for (uint256 i = 0; i < swarm.length; ++i) {
            uint256 before = swarm[i].balance;
            vm.prank(swarm[i]);
            uint256 paid = grid.claim(epochId);
            assertEq(swarm[i].balance - before, paid, "swarm balance matches payout");
            if (i == 0) {
                swarmPayout = paid;
            } else {
                assertEq(paid, swarmPayout, "swarm payouts equal");
            }
        }

        uint256 spreadBefore = spread.balance;
        vm.prank(spread);
        uint256 spreadPayout = grid.claim(epochId);
        assertEq(spread.balance - spreadBefore, spreadPayout, "spread balance matches payout");

        assertEq(swarmPayout, HOT_BOUNTY / 5, "swarm gets a fifth of the hot sector");
        assertEq(spreadPayout, COOL_BOUNTY, "spread takes the whole cool sector");
        assertGt(spreadPayout, swarmPayout, "spreading out must beat swarming");
        assertEq(spreadPayout, 2 * swarmPayout, "spread is 2x the swarm payout");
    }

    /// A reveal that does not match the commitment is rejected, whether the
    /// salt or the sector is wrong, and leaves the grid untouched.
    function test_BadRevealReverts() public {
        uint256 epochId = _defaultEpoch();

        address boat = address(0xA1);
        bytes32 salt = bytes32(uint256(0xCAFE));
        _commit(boat, epochId, HOT, salt);

        _advance(epochId);

        vm.prank(boat);
        vm.expectRevert(GridSignal.BadReveal.selector);
        grid.reveal(epochId, HOT, bytes32(uint256(0xDEAD)));

        vm.prank(boat);
        vm.expectRevert(GridSignal.BadReveal.selector);
        grid.reveal(epochId, COOL, salt);

        uint32[25] memory counts = _counts(epochId);
        assertEq(counts[HOT], 0, "hot count untouched");
        assertEq(counts[COOL], 0, "cool count untouched");

        // The correct reveal still works afterwards.
        vm.prank(boat);
        grid.reveal(epochId, HOT, salt);
        assertEq(_counts(epochId)[HOT], 1, "valid reveal counted");
    }

    /// The demo helper walks Commit -> Reveal -> Claim -> Closed and closes
    /// each phase's actions as it goes.
    function test_AdvancePhaseForDemo() public {
        uint256 epochId = _defaultEpoch();

        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Commit), "starts in Commit");

        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Reveal), "Commit -> Reveal");

        // Committing is closed once the phase has moved on.
        address late = address(0xC1);
        vm.deal(late, STAKE);
        vm.prank(late);
        vm.expectRevert(
            abi.encodeWithSelector(GridSignal.InvalidPhase.selector, GridSignal.Phase.Reveal, GridSignal.Phase.Commit)
        );
        grid.commit{value: STAKE}(bytes32(uint256(1)));

        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Claim), "Reveal -> Claim");

        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Closed), "Claim -> Closed");

        // Closed is terminal.
        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Closed), "Closed stays Closed");
    }

    /// A responder who has committed but not revealed reports no pending payout
    /// and never reverts, even when sector 0 (the default) has real reveals.
    function test_PendingPayoutZeroBeforeReveal() public {
        uint256[25] memory b = _emptyBounties();
        b[0] = 3 ether;
        uint256 epochId = _createEpoch(b);

        address quiet = address(0xA1);
        address loud = address(0xA2);

        _commit(quiet, epochId, 0, bytes32(uint256(0x11)));
        _commit(loud, epochId, 0, bytes32(uint256(0x22)));

        _advance(epochId);

        vm.prank(loud);
        grid.reveal(epochId, 0, bytes32(uint256(0x22)));

        // Committed, not revealed: sector defaults to 0, which now has a count,
        // so an unguarded view would hand back sector 0's payout.
        (bool committed, bool revealed,, uint8 sector, uint256 pending) = grid.getResponderState(epochId, quiet);
        assertTrue(committed, "quiet boat committed");
        assertFalse(revealed, "quiet boat did not reveal");
        assertEq(sector, 0, "default sector is 0");
        assertEq(pending, 0, "no payout before revealing");

        (,,,, uint256 loudPending) = grid.getResponderState(epochId, loud);
        assertEq(loudPending, 3 ether, "revealer sees the full sector bounty");

        // Addresses and epochs we know nothing about also stay callable.
        (bool c2,,,, uint256 p2) = grid.getResponderState(epochId, address(0xDEAD));
        assertFalse(c2, "stranger has not committed");
        assertEq(p2, 0, "stranger has no payout");
        (,,,, uint256 p3) = grid.getResponderState(999, quiet);
        assertEq(p3, 0, "unknown epoch has no payout");

        // Claiming without revealing is refused outright.
        _advance(epochId);
        vm.prank(quiet);
        vm.expectRevert(GridSignal.NotRevealed.selector);
        grid.claim(epochId);
    }

    /// Only the operator can move the clock; anyone else is refused and the
    /// phase holds.
    function test_AdvancePhaseUnauthorizedReverts() public {
        uint256 epochId = _defaultEpoch();

        address boat = address(0xA1);
        vm.prank(boat);
        vm.expectRevert(GridSignal.Unauthorized.selector);
        grid.advancePhaseForDemo(epochId);

        // The deployer is not the operator either.
        vm.expectRevert(GridSignal.Unauthorized.selector);
        grid.advancePhaseForDemo(epochId);

        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Commit), "phase unchanged");

        _advance(epochId);
        assertEq(uint8(_phase(epochId)), uint8(GridSignal.Phase.Reveal), "operator may advance");
    }
}
