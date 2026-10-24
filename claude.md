# GridSignal Hackathon Project

## Build & Test Commands
- **Smart Contract Build:** `cd contracts && forge build` (Must run `$env:PATH = "$env:USERPROFILE\.foundry\bin;$env:PATH"` first in new terminals).
- **Smart Contract Test:** `cd contracts && forge test -vvv`
- **Frontend Dev:** `cd web && npm run dev`
- **Frontend Build:** `cd web && npm run build` (Use full npm path on this machine: `& "C:\Program Files\nodejs\npm.cmd" run build`).
- **Full rerun:** Kill anvil.exe and node.exe, start Anvil (`$USERPROFILE/.foundry/bin/anvil --silent &`), deploy (`forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`), then `npm run dev`.

## Core Architecture
- **Backend:** Solidity ^0.8.24, 25-cell grid (S0-S24).
- **Phases:** Commit -> Reveal -> Claim.
- **Frontend:** React + Tailwind + viem v2.
- **Wallets:** We sign directly with viem `privateKeyToAccount` using Anvil accounts #1, #2, #3 for boats, and #4 for the Operator. NO wallet popups.

## Bounty Layout
- Full 25-cell gradient: S12 = 5 ETH (center/hot), cross ring ~2 ETH, inner diagonal ~1.5 ETH, mid-edges 1 ETH, corners 0.5 ETH.
- Same layout used in both the deploy script and the UI Create Epoch button.
- Total bounty pool = 29 ETH per epoch on local Anvil.

## UI Behaviour
- Each boat has its own sector picker (arrows) — they can each target different sectors independently.
- Clicking a grid cell sets all uncommitted boats to that sector at once.
- Advance Phase is blocked until: all 3 boats have committed (Commit phase), all committed boats have revealed (Reveal phase), all revealed boats have claimed (Claim phase).
- Create Epoch button appears only after loaded=true and phase is None or Closed.
- Epoch counter increments with each createEpoch call and does not reset on redeploy — expected.

## AI Rules (Strict)
1. **Never output full files** if modifying existing code. Output only the modified functions or specific JSX blocks.
2. **Never hallucinate Web3 libraries.** Use exactly `viem` v2. No ethers, no wagmi.
3. Check `CLAUDE.md` before making architectural changes.
