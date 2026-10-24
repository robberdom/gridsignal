# GridSignal Hackathon Project

## Build & Test Commands
- **Smart Contract Build:** `cd contracts && forge build` (Must run `$env:PATH = "$env:USERPROFILE\.foundry\bin;$env:PATH"` first in new terminals).
- **Smart Contract Test:** `cd contracts && forge test -vvv`
- **Frontend Dev:** `cd web && npm run dev`
- **Frontend Build:** `cd web && npm run build` (Use full npm path on this machine: `& "C:\Program Files\nodejs\npm.cmd" run build`).

## Core Architecture
- **Backend:** Solidity ^0.8.24, 25-cell grid (S0-S24). 
- **Phases:** Commit -> Reveal -> Claim. 
- **Frontend:** React + Tailwind + viem v2. 
- **Wallets:** We sign directly with viem `privateKeyToAccount` using Anvil accounts #1, #2, #3 for boats, and #4 for the Operator. NO wallet popups.

## AI Rules (Strict)
1. **Never output full files** if modifying existing code. Output only the modified functions or specific JSX blocks.
2. **Never hallucinate Web3 libraries.** Use exactly `viem` v2. No ethers, no wagmi.
3. Check `CLAUDE.md` before making architectural changes.