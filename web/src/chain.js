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
  'function createEpoch(uint256[25] bounties, uint64 commitDuration, uint64 revealDuration, uint64 claimDuration) payable returns (uint256)',
])

export const PHASE_LABELS = ['Not created', 'Commit', 'Reveal', 'Claim', 'Closed']

export const contractAddress = '0x5cBcFE5eA980585270eAB78eDf4Be1a6eeffE946'
const rpcUrl = 'https://sepolia.drpc.org'
const chainId = 11155111

export const chain = defineChain({
  id: chainId,
  name: 'Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
})

export const publicClient = createPublicClient({ chain, transport: http(rpcUrl) })

function wallet(key) {
  const account = privateKeyToAccount(key)
  return { account, client: createWalletClient({ account, chain, transport: http(rpcUrl) }) }
}

export const BOATS = [
  { id: 'A', label: 'Boat A', ...wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80') },
  { id: 'B', label: 'Boat B', ...wallet('0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d') },
  { id: 'C', label: 'Boat C', ...wallet('0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a') },
]

export const operatorWallet = wallet('0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6')