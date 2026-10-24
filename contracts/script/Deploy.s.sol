// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GridSignal} from "../src/GridSignal.sol";

/// @notice Deploys GridSignal and opens a funded epoch with an uneven bounty
///         layout so the swarm-vs-spread effect is visible immediately.
///
/// Bounties are scaled by chain: 7 ETH of funding is fine on a local node but
/// unreachable from a testnet faucet, so Base Sepolia uses the same ratios at
/// 1/1000 the size.
contract Deploy is Script {
    uint8 internal constant HOT = 12;
    uint8 internal constant COOL = 7;

    function run() external {
        uint256 stake = vm.envOr("STAKE_WEI", uint256(0.001 ether));
        // Anvil account #4 — the lane that owns the Advance Phase button.
        address operator = vm.envOr("OPERATOR_ADDRESS", address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65));

        bool local = block.chainid == 31337;
        uint256 hotBounty = local ? 5 ether : 0.005 ether;
        uint256 coolBounty = local ? 2 ether : 0.002 ether;

        uint256[25] memory bounties;
        bounties[HOT] = hotBounty;
        bounties[COOL] = coolBounty;
        uint256 total = hotBounty + coolBounty;

        vm.startBroadcast();
        GridSignal grid = new GridSignal(stake, operator);
        uint256 epochId = grid.createEpoch{value: total}(bounties, 1 hours, 1 hours, 1 hours);
        vm.stopBroadcast();

        console.log("GridSignal:", address(grid));
        console.log("operator:  ", operator);
        console.log("stake wei: ", stake);
        console.log("epochId:   ", epochId);
        console.log("hot sector 12:", hotBounty);
        console.log("cool sector 7:", coolBounty);
    }
}
