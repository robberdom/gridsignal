import { createPublicClient, createWalletClient, defineChain, http, parseAbi } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

export const GRID_SIZE = 25

export const gridSignalAbi = parseAbi([
  'function COMMIT_STAKE() view returns (uint256)',
  'function operator() view returns (address)',
  'function currentEpochId() view returns (uint256)',
  'function commit(bytes32 commitment) payable',
  'function reveal(uint256 epochId, uint8 sectorId, bytes32 salt)',
  'function claim(uint256 epochId) returns (uint256)',
  'function advancePhaseForDemo(uint256 epochId) returns (uint8)',
  'function getEpochGridState(uint256 epochId) view returns (uint256[25] bounties, uint32[25] counts, uint8 phase)',
  'function getResponderState(uint256 epochId, address responder) view returns (bool committed, bool revealed, bool claimed, uint8 sector, uint256 pendingPayout)',
])

export const PHASE_LABELS = ['Not created', 'Commit', 'Reveal', 'Claim', 'Closed']

export const contractAddress = import.meta.env.VITE_CONTRACT_ADDRESS
const rpcUrl = import.meta.env.VITE_RPC_URL ?? 'http://127.0.0.1:8545'
const chainId = Number(import.meta.env.VITE_CHAIN_ID ?? 31337)

export const chain = defineChain({
  id: chainId,
  name: chainId === 31337 ? 'Anvil' : `Chain ${chainId}`,
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
})

export const publicClient = createPublicClient({ chain, transport: http(rpcUrl) })

function wallet(key) {
  const account = privateKeyToAccount(key)
  return { account, client: createWalletClient({ account, chain, transport: http(rpcUrl) }) }
}

// Each boat is its own account, so their nonces are independent and the payout
// arithmetic for each one stays legible. The operator lane exists only to sign
// advancePhaseForDemo, which the contract restricts to that address.
export const BOATS = [
  { id: 'A', label: 'Boat A', ...wallet(import.meta.env.VITE_BOAT_A_KEY) },
  { id: 'B', label: 'Boat B', ...wallet(import.meta.env.VITE_BOAT_B_KEY) },
  { id: 'C', label: 'Boat C', ...wallet(import.meta.env.VITE_BOAT_C_KEY) },
]

export const operatorWallet = wallet(import.meta.env.VITE_OPERATOR_KEY)
