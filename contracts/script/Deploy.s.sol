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
    function run() external {
        uint256 stake = vm.envOr("STAKE_WEI", uint256(0.001 ether));
        // Anvil account #4 — the lane that owns the Advance Phase button.
        address operator = vm.envOr("OPERATOR_ADDRESS", address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65));

        bool local = block.chainid == 31337;
        // Scale factor: 1 ether on local, 0.001 ether on testnet.
        uint256 u = local ? 1 ether : 0.001 ether;

        // 5x5 grid layout (row-major, S0=top-left, S24=bottom-right):
        //   0.5  0.5  1.0  0.5  0.5
        //   0.5  1.5  2.0  1.5  0.5
        //   1.0  2.0  5.0  2.0  1.0
        //   0.5  1.5  2.0  1.5  0.5
        //   0.5  0.5  1.0  0.5  0.5
        uint256[25] memory b;
        b[0]=u/2; b[1]=u/2; b[2]=u;   b[3]=u/2; b[4]=u/2;
        b[5]=u/2; b[6]=u*3/2; b[7]=u*2; b[8]=u*3/2; b[9]=u/2;
        b[10]=u;  b[11]=u*2; b[12]=u*5; b[13]=u*2; b[14]=u;
        b[15]=u/2; b[16]=u*3/2; b[17]=u*2; b[18]=u*3/2; b[19]=u/2;
        b[20]=u/2; b[21]=u/2; b[22]=u;   b[23]=u/2; b[24]=u/2;

        uint256[25] memory bounties = b;
        uint256 total;
        for (uint256 i = 0; i < 25; ++i) total += bounties[i];

        vm.startBroadcast();
        GridSignal grid = new GridSignal(stake, operator);
        uint256 epochId = grid.createEpoch{value: total}(bounties, 1 hours, 1 hours, 1 hours);
        vm.stopBroadcast();

        console.log("GridSignal:", address(grid));
        console.log("operator:  ", operator);
        console.log("stake wei: ", stake);
        console.log("epochId:   ", epochId);
        console.log("total bounty:", total);
    }
}
