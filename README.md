# GridSignal

GridSignal is a full-stack decentralized coordination protocol built on Ethereum. Network participants deploy to a 25-cell geographic grid containing variable bounties, utilizing a secure cryptographic commit-reveal scheme to prevent front-running and optimize strategic positioning.

## Core Architecture
* **Epoch-Based Lifecycle:** The protocol cycles through distinct operational phases (Commit, Reveal, Claim, Closed) managed by an Operator address.
* **Cryptographic Commit-Reveal:** Actors lock in their sector choice using a salted hash on-chain, keeping their positional data private until the network enters the Reveal phase.
* **Dynamic Bounties:** Each grid sector is allocated a specific ETH distribution. Participants who successfully validate their committed sector claim a portion of that sector's yield.

## Tech Stack
* **Smart Contracts:** Solidity, Foundry 
* **Frontend:** React, Vite, `viem`
* **Network:** Ethereum Sepolia Testnet
* **Hosting:** Vercel

## Network & Deployment
* **Live Contract (Sepolia):** `0x5cBcFE5eA980585270eAB78eDf4Be1a6eeffE946`
* **RPC Endpoint:** `https://sepolia.drpc.org`
* **EVM Target:** `paris` (for broad testnet node compatibility)

## Local Development

### Smart Contracts (Foundry)
Navigate to the `contracts` directory to work with the smart contracts.

1. **Install dependencies and compile:**
   ```bash
   forge build
