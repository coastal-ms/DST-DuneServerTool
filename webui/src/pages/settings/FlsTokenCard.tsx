import { useEffect, useRef, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ApiError } from '../../api/client'
import {
  getFlsWorld,
  getFlsRotateStatus,
  rotateFlsToken,
  type FlsWorld,
  type FlsStep,
} from '../../api/flsToken'

const INPUT_CLASS =
  'flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'

function stepClass(status: FlsStep['status']): string {
  if (status === 'done') return 'text-success'
  if (status === 'failed') return 'text-danger'
  if (status === 'running') return 'text-warning'
  return 'text-text-dim'
}

function stepIcon(status: FlsStep['status']): string {
  if (status === 'done') return 'CircleCheck'
  if (status === 'failed') return 'CircleX'
  if (status === 'running') return 'LoaderCircle'
  return 'Circle'
}

export function FlsTokenCard() {
  const [open, setOpen] = useState(false)
  const [world, setWorld] = useState<FlsWorld | null>(null)
  const [worldLoading, setWorldLoading] = useState(false)
  const [token, setToken] = useState('')
  const [ack, setAck] = useState(false)
  const [steps, setSteps] = useState<FlsStep[]>([])
  const [running, setRunning] = useState(false)
  const [phase, setPhase] = useState<string>('idle')
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const pollRef = useRef<number | null>(null)

  function stopPolling() {
    if (pollRef.current !== null) {
      window.clearInterval(pollRef.current)
      pollRef.current = null
    }
  }

  async function loadWorld() {
    setWorldLoading(true)
    try {
      setWorld(await getFlsWorld())
    } catch {
      setWorld({ ok: false, reachable: false, error: 'Could not reach the server.' })
    } finally {
      setWorldLoading(false)
    }
  }

  async function refreshStatus(): Promise<boolean> {
    try {
      const s = await getFlsRotateStatus()
      if (s.steps && s.steps.length) setSteps(s.steps)
      setPhase(s.phase ?? 'idle')
      if (s.phase === 'done') {
        setRunning(false)
        setError(null)
        setMessage('New token applied. Give the servers a few minutes to come back, then check the in-game server browser.')
        void loadWorld()
        return false
      }
      if (s.phase === 'error') {
        setRunning(false)
        setError(s.error || 'Token rotation failed. Your backup is on the server, so nothing was lost.')
        return false
      }
      setRunning(Boolean(s.running))
      return Boolean(s.running)
    } catch {
      // Server is likely mid-restart - keep polling.
      return true
    }
  }

  function startPolling() {
    stopPolling()
    pollRef.current = window.setInterval(() => {
      void (async () => {
        const more = await refreshStatus()
        if (!more) stopPolling()
      })()
    }, 2500)
  }

  // On first expand: load the world context and pick up any in-flight rotation.
  useEffect(() => {
    if (!open) return
    void loadWorld()
    void (async () => {
      const more = await refreshStatus()
      if (more) startPolling()
    })()
    return () => stopPolling()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  useEffect(() => stopPolling, [])

  async function onRotate() {
    setError(null)
    setMessage(null)
    setSteps([])
    try {
      await rotateFlsToken(token.trim())
      setRunning(true)
      setPhase('starting')
      setToken('')
      setAck(false)
      startPolling()
    } catch (e) {
      const msg = e instanceof ApiError ? e.message : 'Could not start the rotation.'
      setError(msg)
    }
  }

  const canRotate = ack && token.trim().length > 0 && !running

  return (
    <div className="card mb-4">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between gap-3 p-6 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="KeyRound" size={18} className="text-text-muted shrink-0" />
          <div className="min-w-0">
            <div className="font-medium">Server authorization token (403002 recovery)</div>
            <div className="text-sm text-text-muted truncate">
              Fix a server that vanished from the in-game browser with a Funcom authorization error.
            </div>
          </div>
        </div>
        <Icon name={open ? 'ChevronUp' : 'ChevronDown'} size={18} className="text-text-muted shrink-0" />
      </button>

      {open && (
        <div className="px-6 pb-6 space-y-4">
          <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-text space-y-2">
            <div className="flex items-center gap-2 font-medium text-warning">
              <Icon name="TriangleAlert" size={16} />
              When to use this
            </div>
            <p className="text-text-muted">
              Only if your self-hosted server suddenly disappeared from the in-game server browser and your
              logs show <span className="font-mono">403002</span> /{' '}
              <span className="font-mono">ACCESS_DENIED</span> ("Could not find service authorization
              information for Battlegroup"). This is a Funcom-side authorization issue, not a DST bug.
            </p>
            <p className="text-text-muted">
              First, regenerate your self-hosting token on the{' '}
              <a
                href="https://account.duneawakening.com/"
                target="_blank"
                rel="noreferrer"
                className="text-ibad hover:underline"
              >
                Dune account page
              </a>{' '}
              while signed into the <span className="font-medium">same account</span> this server was created
              with, then paste the new token below. DST replaces it everywhere on the server and restarts the
              battlegroup.
            </p>
            <p className="text-text-dim text-xs">
              This is the community-reported recovery, validated by DST on a live server. A full backup of your
              server config is taken before anything changes, and DST refuses any token from a different account
              (so your characters can't be orphaned).
            </p>
          </div>

          <div className="text-sm">
            {worldLoading ? (
              <span className="text-text-muted">Reading your battlegroup…</span>
            ) : world && world.ok ? (
              <div className="text-text-muted">
                Battlegroup <span className="font-mono text-text">{world.world}</span>
                {world.phase ? <> · phase <span className="font-mono">{world.phase}</span></> : null}
              </div>
            ) : world ? (
              <span className="text-danger">{world.error || 'No battlegroup found on the server.'}</span>
            ) : null}
          </div>

          <div className="space-y-2">
            <label className="block text-sm font-medium">New self-hosting token</label>
            <input
              type="password"
              autoComplete="off"
              value={token}
              placeholder="Paste your regenerated token (JWT)"
              onChange={e => setToken(e.target.value)}
              disabled={running}
              className={INPUT_CLASS}
            />
          </div>

          <label className="flex items-start gap-2 text-sm text-text-muted">
            <input
              type="checkbox"
              checked={ack}
              onChange={e => setAck(e.target.checked)}
              disabled={running}
              className="mt-0.5"
            />
            <span>
              I understand this restarts my battlegroup — any players currently online will be disconnected for
              a few minutes.
            </span>
          </label>

          <div>
            <button
              type="button"
              onClick={() => void onRotate()}
              disabled={!canRotate}
              className="btn-danger"
            >
              {running ? 'Rotating…' : 'Apply new token & restart'}
            </button>
          </div>

          {steps.length > 0 && (
            <div className="rounded-lg border border-border bg-surface-2 p-3 space-y-1.5">
              {steps.map(s => (
                <div key={s.id} className="flex items-start gap-2 text-sm">
                  <Icon
                    name={stepIcon(s.status)}
                    size={15}
                    className={`mt-0.5 shrink-0 ${stepClass(s.status)} ${s.status === 'running' ? 'animate-spin' : ''}`}
                  />
                  <div className="min-w-0">
                    <span className={stepClass(s.status)}>{s.label}</span>
                    {s.detail ? <span className="text-text-dim"> — {s.detail}</span> : null}
                  </div>
                </div>
              ))}
            </div>
          )}

          {message && (
            <div className="rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success flex items-start gap-2">
              <Icon name="CircleCheck" size={16} className="mt-0.5 shrink-0" />
              <span>{message}</span>
            </div>
          )}
          {error && (
            <div className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger flex items-start gap-2">
              <Icon name="CircleX" size={16} className="mt-0.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}
          {phase === 'starting' || (running && steps.length === 0) ? (
            <div className="text-sm text-text-muted">Starting…</div>
          ) : null}
        </div>
      )}
    </div>
  )
}
