// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GridSignal
/// @notice Commit-reveal bounty grid for distributed emergency response.
///         Responders stake to commit to a hidden 5x5 sector, reveal it, then
///         split that sector's bounty with everyone else who revealed there.
///         Piling onto one rich sector ("swarm") pays less per responder than
///         spreading out across the grid.
contract GridSignal {
    /// @dev 5x5 grid, sectorId 0..24.
    uint256 public constant GRID = 25;

    enum Phase {
        None,
        Commit,
        Reveal,
        Claim,
        Closed
    }

    struct Epoch {
        uint64 commitEnd;
        uint64 revealEnd;
        uint64 claimEnd;
        uint256[25] bounties;
        uint32[25] counts;
        bool exists;
    }

    struct Responder {
        bytes32 commitment;
        uint8 sector;
        bool revealed;
        bool claimed;
    }

    /// @notice Stake locked by commit(), refunded on a valid reveal and
    ///         forfeited otherwise. Immutable so one contract serves both a
    ///         local chain and a faucet-constrained testnet.
    uint256 public immutable COMMIT_STAKE;

    /// @notice Only address allowed to call advancePhaseForDemo.
    address public immutable operator;

    uint256 public currentEpochId;

    mapping(uint256 => Epoch) private epochs;
    mapping(uint256 => mapping(address => Responder)) private responders;

    event EpochCreated(uint256 indexed epochId, uint64 commitEnd, uint64 revealEnd, uint64 claimEnd, uint256 totalBounty);
    event Committed(uint256 indexed epochId, address indexed responder, bytes32 commitment);
    event Revealed(uint256 indexed epochId, address indexed responder, uint8 sectorId, uint32 newCount);
    event Claimed(uint256 indexed epochId, address indexed responder, uint8 sectorId, uint256 payout);
    event PhaseAdvanced(uint256 indexed epochId, Phase newPhase);

    error Unauthorized();
    error InvalidPhase(Phase current, Phase required);
    error WrongStake(uint256 sent, uint256 required);
    error AlreadyCommitted();
    error NoCommitment();
    error NotRevealed();
    error BadReveal();
    error AlreadyRevealed();
    error AlreadyClaimed();
    error InvalidSector(uint8 sectorId);
    error BountyFundingMismatch(uint256 sent, uint256 required);
    error EpochNotFound(uint256 epochId);
    error ZeroOperator();
    error ZeroDuration();
    error TransferFailed();

    constructor(uint256 _commitStake, address _operator) {
        // A zero operator would permanently disable phase advancement with no
        // way to recover, bricking the demo.
        if (_operator == address(0)) revert ZeroOperator();
        COMMIT_STAKE = _commitStake;
        operator = _operator;
    }

    /// @notice Create a funded epoch. msg.value must equal the sum of bounties
    ///         so every claim() is backed by real ETH held here.
    function createEpoch(
        uint256[25] calldata bounties,
        uint64 commitDuration,
        uint64 revealDuration,
        uint64 claimDuration
    ) external payable returns (uint256 epochId) {
        if (commitDuration == 0 || revealDuration == 0 || claimDuration == 0) revert ZeroDuration();

        uint256 total;
        for (uint256 i = 0; i < GRID; ++i) {
            total += bounties[i];
        }
        if (msg.value != total) revert BountyFundingMismatch(msg.value, total);

        epochId = ++currentEpochId;

        Epoch storage ep = epochs[epochId];
        ep.commitEnd = uint64(block.timestamp) + commitDuration;
        ep.revealEnd = ep.commitEnd + revealDuration;
        ep.claimEnd = ep.revealEnd + claimDuration;
        ep.bounties = bounties;
        ep.exists = true;

        emit EpochCreated(epochId, ep.commitEnd, ep.revealEnd, ep.claimEnd, total);
    }

    /// @notice Commit to a hidden sector in the current epoch.
    /// @param commitment keccak256(abi.encodePacked(msg.sender, epochId, sectorId, salt))
    function commit(bytes32 commitment) external payable {
        uint256 epochId = currentEpochId;
        Epoch storage ep = epochs[epochId];
        if (!ep.exists) revert EpochNotFound(epochId);

        Phase phase = _phaseOf(ep);
        if (phase != Phase.Commit) revert InvalidPhase(phase, Phase.Commit);
        if (msg.value != COMMIT_STAKE) revert WrongStake(msg.value, COMMIT_STAKE);

        Responder storage r = responders[epochId][msg.sender];
        if (r.commitment != bytes32(0)) revert AlreadyCommitted();

        r.commitment = commitment;

        emit Committed(epochId, msg.sender, commitment);
    }

    /// @notice Reveal the committed sector and recover the stake.
    /// @dev Binding msg.sender and epochId into the hash blocks both
    ///      commitment copying and cross-epoch replay.
    function reveal(uint256 epochId, uint8 sectorId, bytes32 salt) external {
        Epoch storage ep = epochs[epochId];
        if (!ep.exists) revert EpochNotFound(epochId);

        Phase phase = _phaseOf(ep);
        if (phase != Phase.Reveal) revert InvalidPhase(phase, Phase.Reveal);
        if (sectorId >= GRID) revert InvalidSector(sectorId);

        Responder storage r = responders[epochId][msg.sender];
        if (r.commitment == bytes32(0)) revert NoCommitment();
        if (r.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encodePacked(msg.sender, epochId, sectorId, salt));
        if (expected != r.commitment) revert BadReveal();

        r.sector = sectorId;
        r.revealed = true;

        uint32 newCount = ep.counts[sectorId] + 1;
        ep.counts[sectorId] = newCount;

        emit Revealed(epochId, msg.sender, sectorId, newCount);

        _send(msg.sender, COMMIT_STAKE);
    }

    /// @notice Claim an equal share of the revealed sector's bounty.
    function claim(uint256 epochId) external returns (uint256 payout) {
        Epoch storage ep = epochs[epochId];
        if (!ep.exists) revert EpochNotFound(epochId);

        Phase phase = _phaseOf(ep);
        if (phase != Phase.Claim) revert InvalidPhase(phase, Phase.Claim);

        Responder storage r = responders[epochId][msg.sender];
        // revealed implies a non-zero commitment, so this subsumes the commit check.
        if (!r.revealed) revert NotRevealed();
        if (r.claimed) revert AlreadyClaimed();

        uint8 sector = r.sector;
        // Reaching here requires r.revealed, so counts[sector] >= 1.
        payout = ep.bounties[sector] / ep.counts[sector];

        r.claimed = true;

        emit Claimed(epochId, msg.sender, sector, payout);

        if (payout > 0) {
            _send(msg.sender, payout);
        }
    }

    /// @notice Step the epoch to its next phase immediately so judges can walk
    ///         through the lifecycle without waiting on wall-clock time.
    /// @dev Operator-only: an open version lets anyone snap the phase forward
    ///      mid-commit and brick another participant's transaction.
    function advancePhaseForDemo(uint256 epochId) external returns (Phase newPhase) {
        if (msg.sender != operator) revert Unauthorized();

        Epoch storage ep = epochs[epochId];
        if (!ep.exists) revert EpochNotFound(epochId);

        uint64 now_ = uint64(block.timestamp);
        Phase phase = _phaseOf(ep);

        // Snap the active boundary to now and drag the later boundaries along,
        // preserving each remaining phase's duration.
        if (phase == Phase.Commit) {
            uint64 shift = ep.commitEnd - now_;
            ep.commitEnd = now_;
            ep.revealEnd -= shift;
            ep.claimEnd -= shift;
            newPhase = Phase.Reveal;
        } else if (phase == Phase.Reveal) {
            uint64 shift = ep.revealEnd - now_;
            ep.revealEnd = now_;
            ep.claimEnd -= shift;
            newPhase = Phase.Claim;
        } else if (phase == Phase.Claim) {
            ep.claimEnd = now_;
            newPhase = Phase.Closed;
        } else {
            newPhase = Phase.Closed;
        }

        emit PhaseAdvanced(epochId, newPhase);
    }

    /// @notice Full grid snapshot: 25 bounties, 25 revealed counts, and the phase.
    function getEpochGridState(uint256 epochId)
        external
        view
        returns (uint256[25] memory bounties, uint32[25] memory counts, Phase phase)
    {
        Epoch storage ep = epochs[epochId];
        bounties = ep.bounties;
        counts = ep.counts;
        phase = ep.exists ? _phaseOf(ep) : Phase.None;
    }

    /// @notice Per-responder view driving the frontend status line.
    /// @dev Total for every input: unknown epochs and unknown addresses return
    ///      zeros rather than reverting, so the UI poll can never break.
    function getResponderState(uint256 epochId, address responder)
        external
        view
        returns (bool committed, bool revealed, bool claimed, uint8 sector, uint256 pendingPayout)
    {
        Epoch storage ep = epochs[epochId];
        Responder storage r = responders[epochId][responder];

        committed = r.commitment != bytes32(0);
        revealed = r.revealed;
        claimed = r.claimed;
        sector = r.sector;

        // Guarded on both counts: a zero count would panic on division, and an
        // unrevealed responder defaults to sector 0, which would otherwise
        // report sector 0's payout as its own.
        uint256 count = ep.counts[sector];
        pendingPayout = (revealed && count > 0) ? ep.bounties[sector] / count : 0;
    }

    /// @notice Phase boundaries for an epoch.
    function getEpochTimes(uint256 epochId)
        external
        view
        returns (uint64 commitEnd, uint64 revealEnd, uint64 claimEnd)
    {
        Epoch storage ep = epochs[epochId];
        return (ep.commitEnd, ep.revealEnd, ep.claimEnd);
    }

    /// @dev Phase is derived from timestamps, never stored, so there is exactly
    ///      one source of truth and advancing only has to move boundaries.
    function _phaseOf(Epoch storage ep) private view returns (Phase) {
        uint256 t = block.timestamp;
        if (t < ep.commitEnd) return Phase.Commit;
        if (t < ep.revealEnd) return Phase.Reveal;
        if (t < ep.claimEnd) return Phase.Claim;
        return Phase.Closed;
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
