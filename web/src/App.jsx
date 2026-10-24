import { useCallback, useEffect, useState } from 'react'
import { encodePacked, formatEther, keccak256, parseEther, toHex } from 'viem'
import {
  BOATS,
  GRID_SIZE,
  PHASE_LABELS,
  chain,
  contractAddress,
  gridSignalAbi,
  operatorWallet,
  publicClient,
} from './chain'

const PHASE = { None: 0, Commit: 1, Reveal: 2, Claim: 3, Closed: 4 }

function randomSalt() {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  return toHex(bytes)
}

function saltKey(epochId, boatId) {
  return `gridsignal:${chain.id}:${epochId}:${boatId}`
}

function loadSalt(epochId, boatId) {
  try {
    const raw = localStorage.getItem(saltKey(epochId, boatId))
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

function saveSalt(epochId, boatId, entry) {
  localStorage.setItem(saltKey(epochId, boatId), JSON.stringify(entry))
}

// Must match keccak256(abi.encodePacked(msg.sender, epochId, sectorId, salt)).
function commitmentFor(address, epochId, sectorId, salt) {
  return keccak256(
    encodePacked(
      ['address', 'uint256', 'uint8', 'bytes32'],
      [address, BigInt(epochId), sectorId, salt],
    ),
  )
}

function errText(err) {
  return err?.shortMessage ?? err?.details ?? err?.message ?? String(err)
}

export default function App() {
  const [epochId, setEpochId] = useState(0n)
  const [phase, setPhase] = useState(PHASE.None)
  const [bounties, setBounties] = useState(Array(GRID_SIZE).fill(0n))
  const [counts, setCounts] = useState(Array(GRID_SIZE).fill(0))
  const [stake, setStake] = useState(null)
  // Pre-spread defaults so it's obvious each boat has its own selector.
  const [selected, setSelected] = useState(() => ({ A: 11, B: 12, C: 13 }))
  const [boatState, setBoatState] = useState({})
  const [busy, setBusy] = useState({})
  const [message, setMessage] = useState('')
  const [loaded, setLoaded] = useState(false)

  const refresh = useCallback(async () => {
    try {
      const id = await publicClient.readContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'currentEpochId',
      })
      setEpochId(id)

      const [grid, stakeWei] = await Promise.all([
        publicClient.readContract({
          address: contractAddress,
          abi: gridSignalAbi,
          functionName: 'getEpochGridState',
          args: [id],
        }),
        publicClient.readContract({
          address: contractAddress,
          abi: gridSignalAbi,
          functionName: 'COMMIT_STAKE',
        }),
      ])
      setBounties(grid[0])
      setCounts(grid[1])
      setPhase(Number(grid[2]))
      setStake(stakeWei)

      const states = await Promise.all(
        BOATS.map((boat) =>
          publicClient.readContract({
            address: contractAddress,
            abi: gridSignalAbi,
            functionName: 'getResponderState',
            args: [id, boat.account.address],
          }),
        ),
      )
      const next = {}
      BOATS.forEach((boat, i) => {
        const [committed, revealed, claimed, sector, pendingPayout] = states[i]
        next[boat.id] = { committed, revealed, claimed, sector: Number(sector), pendingPayout }
      })
      setBoatState(next)
      setLoaded(true)
    } catch (err) {
      setMessage(`Read failed: ${errText(err)}`)
    }
  }, [])

  useEffect(() => {
    refresh()
    const t = setInterval(refresh, 2000)
    return () => clearInterval(t)
  }, [refresh])

  // Locks per lane, so a second click on one boat cannot reuse its nonce while
  // leaving the other boats free to act.
  const run = useCallback(
    async (lane, label, send) => {
      if (busy[lane]) return
      setBusy((b) => ({ ...b, [lane]: true }))
      setMessage(`${label}...`)
      try {
        const hash = await send()
        await publicClient.waitForTransactionReceipt({ hash })
        setMessage(`${label} confirmed`)
        await refresh()
      } catch (err) {
        setMessage(`${label} failed: ${errText(err)}`)
      } finally {
        setBusy((b) => ({ ...b, [lane]: false }))
      }
    },
    [busy, refresh],
  )

  const onCommit = (boat) =>
    run(boat.id, `${boat.label} commit S${selected[boat.id]}`, async () => {
      // Read epochId fresh to avoid a stale-state mismatch: the contract binds
      // the commitment to currentEpochId at call time, not the React state copy.
      const id = await publicClient.readContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'currentEpochId',
      })

      // Never overwrite an existing salt entry. If a previous commit tx landed
      // but the UI state was stale, overwriting the salt would make the on-chain
      // commitment unrevealable and forfeit the stake permanently.
      const existing = loadSalt(id.toString(), boat.id)
      if (existing) {
        // Stale entry guard: if the chain says not committed (e.g. Anvil restarted
        // and redeployed with the same epochId), clear it and proceed.
        const onChain = await publicClient.readContract({
          address: contractAddress,
          abi: gridSignalAbi,
          functionName: 'getResponderState',
          args: [id, boat.account.address],
        })
        if (onChain[0]) throw new Error(`${boat.label} already committed this epoch`)
      }

      const salt = randomSalt()
      // Stored before sending: a lost receipt must not lose the salt, or the
      // stake can never be revealed and is forfeit.
      saveSalt(id.toString(), boat.id, { epochId: id.toString(), sector: selected[boat.id], salt })
      return boat.client.writeContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'commit',
        args: [commitmentFor(boat.account.address, id, selected[boat.id], salt)],
        value: stake,
      })
    })

  const onReveal = (boat) =>
    run(boat.id, `${boat.label} reveal`, async () => {
      const entry = loadSalt(epochId.toString(), boat.id)
      if (!entry) throw new Error('no stored commitment for this epoch')
      return boat.client.writeContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'reveal',
        args: [BigInt(entry.epochId), entry.sector, entry.salt],
      })
    })

  const onClaim = (boat) =>
    run(boat.id, `${boat.label} claim`, () =>
      boat.client.writeContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'claim',
        args: [epochId],
      }),
    )

  const onCreateEpoch = () =>
    run('operator', 'Create epoch', async () => {
      // Same gradient as the deploy script: hot center, medium ring, low outer ring.
      const u = parseEther('1')
      const half = u / 2n
      const bounties = [
        half,   half,   u,    half,   half,
        half,   u*3n/2n, u*2n, u*3n/2n, half,
        u,      u*2n,   u*5n, u*2n,   u,
        half,   u*3n/2n, u*2n, u*3n/2n, half,
        half,   half,   u,    half,   half,
      ]
      const total = bounties.reduce((a, b) => a + b, 0n)
      return operatorWallet.client.writeContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'createEpoch',
        args: [bounties, 3600n, 3600n, 3600n],
        value: total,
      })
    })

  const onAdvance = () =>
    run('operator', 'Advance phase', () =>
      operatorWallet.client.writeContract({
        address: contractAddress,
        abi: gridSignalAbi,
        functionName: 'advancePhaseForDemo',
        args: [epochId],
      }),
    )

  const committed = BOATS.filter((b) => boatState[b.id]?.committed)
  const revealed = BOATS.filter((b) => boatState[b.id]?.revealed)
  const allCommittedBoatsRevealed =
    committed.length === 0 || committed.every((b) => boatState[b.id]?.revealed)
  const allClaimedOrNoneRevealed =
    revealed.length === 0 || revealed.every((b) => boatState[b.id]?.claimed)

  return (
    <div className="min-h-screen p-6 max-w-5xl mx-auto">
      <header className="mb-5">
        <h1 className="text-2xl font-semibold">GridSignal</h1>
        <p className="text-sm text-slate-400">
          Epoch {epochId.toString()} &middot; Phase{' '}
          <span className="text-slate-100 font-medium">{PHASE_LABELS[phase]}</span> &middot; Stake{' '}
          {stake === null ? '…' : `${formatEther(stake)} ETH`}
        </p>
      </header>

      {loaded && (phase === PHASE.None || phase === PHASE.Closed) && (
        <button
          onClick={onCreateEpoch}
          disabled={!!busy.operator}
          className="mb-6 w-full rounded bg-green-600 px-4 py-3 text-lg font-semibold disabled:bg-slate-700 disabled:text-slate-500"
        >
          Create Epoch (Operator)
        </button>
      )}

      <div className="grid grid-cols-5 gap-2 mb-6">
        {Array.from({ length: GRID_SIZE }, (_, i) => {
          const here = BOATS.filter((b) => {
            const s = boatState[b.id]
            return s?.revealed && s.sector === i
          })
          return (
            <button
              key={i}
              onClick={() => {
                // Clicking a grid cell sets all uncommitted boats to that sector.
                setSelected((prev) => {
                  const next = { ...prev }
                  BOATS.forEach((b) => { if (!boatState[b.id]?.committed) next[b.id] = i })
                  return next
                })
              }}
              className={`rounded border p-3 text-left transition ${
                BOATS.some((b) => !boatState[b.id]?.committed && selected[b.id] === i)
                  ? 'border-sky-400 bg-sky-950'
                  : 'border-slate-700 bg-slate-900 hover:border-slate-500'
              }`}
            >
              <div className="text-xs text-slate-400">S{i}</div>
              <div className="text-sm font-medium">{formatEther(bounties[i] ?? 0n)} ETH</div>
              <div className="text-xs text-slate-400">
                revealed: {Number(counts[i] ?? 0)}
                {here.length > 0 && (
                  <span className="text-sky-300"> ({here.map((b) => b.id).join(',')})</span>
                )}
              </div>
            </button>
          )
        })}
      </div>

      <div className="mb-6 space-y-2">
        {BOATS.map((boat) => {
          const s = boatState[boat.id]
          const locked = !!busy[boat.id]
          const boatSector = selected[boat.id]
          return (
            <div key={boat.id} className="flex items-center gap-3">
              <span className="w-20 text-sm font-medium">{boat.label}</span>
              {phase === PHASE.Commit && !s?.committed && (
                <div className="flex items-center gap-1">
                  <button
                    onClick={() => setSelected((p) => ({ ...p, [boat.id]: (boatSector + GRID_SIZE - 1) % GRID_SIZE }))}
                    className="rounded bg-slate-600 px-2 py-1 text-sm font-bold hover:bg-slate-500"
                  >‹</button>
                  <span className="w-10 text-center text-sm font-bold text-sky-300">S{boatSector}</span>
                  <button
                    onClick={() => setSelected((p) => ({ ...p, [boat.id]: (boatSector + 1) % GRID_SIZE }))}
                    className="rounded bg-slate-600 px-2 py-1 text-sm font-bold hover:bg-slate-500"
                  >›</button>
                </div>
              )}
              <button
                onClick={() => onCommit(boat)}
                disabled={!loaded || locked || phase !== PHASE.Commit || s?.committed || stake === null}
                className="rounded bg-sky-600 px-3 py-1.5 text-sm font-medium disabled:bg-slate-700 disabled:text-slate-500"
              >
                Commit S{boatSector}
              </button>
              <button
                onClick={() => onReveal(boat)}
                disabled={!loaded || locked || phase !== PHASE.Reveal || !s?.committed || s?.revealed}
                className="rounded bg-emerald-600 px-3 py-1.5 text-sm font-medium disabled:bg-slate-700 disabled:text-slate-500"
              >
                Reveal
              </button>
              <button
                onClick={() => onClaim(boat)}
                disabled={!loaded || locked || phase !== PHASE.Claim || !s?.revealed || s?.claimed}
                className="rounded bg-violet-600 px-3 py-1.5 text-sm font-medium disabled:bg-slate-700 disabled:text-slate-500"
              >
                Claim
              </button>
              <span className="text-xs text-slate-400">
                {!s?.committed
                  ? 'idle'
                  : s.claimed
                    ? `claimed S${s.sector}`
                    : s.revealed
                      ? `revealed S${s.sector}`
                      : 'committed (hidden)'}
              </span>
            </div>
          )
        })}
      </div>

      <button
        onClick={onAdvance}
        disabled={
          !!busy.operator ||
          phase === PHASE.None ||
          phase === PHASE.Closed ||
          (phase === PHASE.Commit && committed.length < BOATS.length) ||
          (phase === PHASE.Reveal && !allCommittedBoatsRevealed) ||
          (phase === PHASE.Claim && !allClaimedOrNoneRevealed)
        }
        title={
          phase === PHASE.Commit && committed.length < BOATS.length
            ? `Waiting for all boats to commit (${committed.length}/${BOATS.length})`
            : phase === PHASE.Reveal && !allCommittedBoatsRevealed
              ? 'All committed boats must reveal first'
              : phase === PHASE.Claim && !allClaimedOrNoneRevealed
                ? 'All revealed boats must claim before closing'
                : undefined
        }
        className="mb-6 w-full rounded bg-amber-600 px-4 py-3 text-lg font-semibold disabled:bg-slate-700 disabled:text-slate-500"
      >
        {phase === PHASE.Commit && committed.length < BOATS.length
          ? `Advance Phase (${committed.length}/${BOATS.length} committed)`
          : phase === PHASE.Reveal && !allCommittedBoatsRevealed
            ? 'Advance Phase (waiting for reveals)'
            : phase === PHASE.Claim && !allClaimedOrNoneRevealed
              ? 'Advance Phase (waiting for claims)'
              : 'Advance Phase'}
      </button>

      <div className="rounded border border-slate-700 bg-slate-900 p-4 text-sm">
        <p className="mb-2">
          Phase: <span className="font-medium">{PHASE_LABELS[phase]}</span>
        </p>
        {revealed.length === 0 ? (
          <p className="text-slate-400">No boats have revealed yet.</p>
        ) : (
          revealed.map((boat) => {
            const s = boatState[boat.id]
            return (
              <p key={boat.id} className="text-slate-300">
                {boat.label} on S{s.sector} ({Number(counts[s.sector] ?? 0)} there) would receive{' '}
                <span className="font-medium text-slate-100">
                  {formatEther(s.pendingPayout)} ETH
                </span>
                {s.claimed && <span className="text-slate-400"> (claimed)</span>}
              </p>
            )
          })
        )}
        {message && <p className="mt-2 text-xs text-slate-400">{message}</p>}
      </div>
    </div>
  )
}

