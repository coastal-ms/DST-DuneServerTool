import { useCallback, useEffect, useState } from 'react'
import { ApiError } from '../../../api/client'
import {
  getDungeonDifficultySummary,
  normalizeDungeonDifficulty,
  type DungeonDifficultySummary,
} from '../../../api/gameplay'
import { ConfirmationModal } from '../../../components/ConfirmationModal'
import { Icon } from '../../../components/Icon'
import { fmtNum } from '../shared'

const CONFIRMATION = 'NORMALIZE DUNGEONS'

type Flash = (msg: string, kind?: 'ok' | 'err') => void

export function DungeonDifficultyAdmin({
  canWrite,
  demo,
  flash,
}: {
  canWrite: boolean
  demo: boolean
  flash: Flash
}) {
  const [summary, setSummary] = useState<DungeonDifficultySummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [backupPath, setBackupPath] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [typed, setTyped] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setSummary(await getDungeonDifficultySummary(demo))
    } catch (e) {
      setSummary(null)
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [demo])

  useEffect(() => { void load() }, [load])

  const run = async () => {
    if (typed !== CONFIRMATION) return
    setBusy(true)
    setError(null)
    try {
      const result = await normalizeDungeonDifficulty(typed)
      setBackupPath(result.backupPath || '')
      setConfirming(false)
      setTyped('')
      flash(result.message)
      await load()
    } catch (e) {
      const body = e instanceof ApiError && e.body && typeof e.body === 'object'
        ? e.body as { backupPath?: unknown }
        : null
      const path = typeof body?.backupPath === 'string' ? body.backupPath : ''
      setBackupPath(path)
      setError(e instanceof Error ? e.message : String(e))
      setConfirming(false)
      setTyped('')
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  const affected = summary?.aboveTarget ?? 0
  const available = summary !== null && summary.source === 'live'
  const canNormalize = canWrite && available && affected > 0 && !busy

  return (
    <div className="card p-4 space-y-3">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 text-xs uppercase tracking-wider text-text-dim">
          <Icon name="Gauge" size={13} /> Normalize Dungeon Difficulty
        </div>
        <button type="button" className="btn-secondary" onClick={() => { void load() }} disabled={loading || busy}>
          <Icon name="RefreshCw" size={13} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
      </div>

      <p className="text-xs text-text-dim">
        Lower historical dungeon completion difficulty values above 50 to exactly 50 across the server.
        Values at or below 50 are never changed or raised.
      </p>

      {summary && (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-5" aria-label="Dungeon difficulty summary">
          <Metric label="Completions" value={summary.total} />
          <Metric label="Above 50" value={summary.aboveTarget} warning={summary.aboveTarget > 0} />
          <Metric label="Maximum" value={summary.maximum} />
          <Metric label="Participants" value={summary.affectedPlayers} />
          <Metric label="Fixed target" value={summary.target} />
        </div>
      )}

      <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs space-y-1.5">
        <div className="flex items-center gap-2 font-semibold text-warning">
          <Icon name="TriangleAlert" size={14} /> Server-wide historical change
        </div>
        <p className="text-text-dim">
          DST verifies a pre-stop backup, stops the battlegroup, then verifies the definitive rollback backup
          before updating only completion rows above 50. It verifies the result and starts the battlegroup.
          All connected players are disconnected during the stop.
        </p>
      </div>

      {demo && <div className="text-xs text-text-dim">Demo mode is read-only; no server data can be changed.</div>}
      {error && <div role="alert" className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-xs text-danger break-words">{error}</div>}
      {backupPath && (
        <div className="text-xs text-text-dim break-all">
          Rollback backup: <span className="font-mono text-text">{backupPath}</span>
        </div>
      )}
      {summary && affected === 0 && !loading && (
        <div className="text-xs text-success">No dungeon completion rows are above 50. Nothing needs changing.</div>
      )}

      <button
        type="button"
        className="btn-danger"
        disabled={!canNormalize}
        onClick={() => setConfirming(true)}
      >
        <Icon name={busy ? 'Loader2' : 'Gauge'} size={13} className={busy ? 'animate-spin' : ''} />
        {busy ? 'Backing up, normalizing, and restarting...' : `Normalize ${fmtNum(affected)} completion row${affected === 1 ? '' : 's'}`}
      </button>

      {confirming && summary && (
        <ConfirmationModal
          title="Normalize dungeon difficulty server-wide?"
          description={`This will lower ${fmtNum(summary.aboveTarget)} historical completion row${summary.aboveTarget === 1 ? '' : 's'} to difficulty 50 and disconnect connected players during the battlegroup stop.`}
          confirmLabel="Back up and normalize"
          confirmDisabled={typed !== CONFIRMATION || busy}
          onConfirm={() => { void run() }}
          onCancel={() => { if (!busy) { setConfirming(false); setTyped('') } }}
        >
          <div className="space-y-3 text-sm">
            <p className="text-text-muted">
              A verified safety backup is required before the battlegroup stops, and a definitive rollback
              backup is verified while it is stopped before any write. No completion is deleted, and no value
              at or below 50 is changed.
            </p>
            <label className="block">
              <span className="block text-xs text-text-dim mb-1">
                Type <span className="font-mono text-warning">{CONFIRMATION}</span> to continue
              </span>
              <input
                autoFocus
                aria-label="Dungeon normalization confirmation"
                value={typed}
                onChange={event => setTyped(event.target.value)}
                className="w-full rounded-lg border border-border bg-surface-2 px-3 py-2 font-mono text-sm text-text"
              />
            </label>
          </div>
        </ConfirmationModal>
      )}
    </div>
  )
}

function Metric({ label, value, warning = false }: { label: string; value: number | null; warning?: boolean }) {
  return (
    <div className="rounded-lg border border-border bg-surface-2 p-2">
      <div className="text-[10px] uppercase tracking-wide text-text-dim">{label}</div>
      <div className={`mt-1 font-mono text-base ${warning ? 'text-warning' : 'text-text'}`}>
        {value === null ? '-' : fmtNum(value)}
      </div>
    </div>
  )
}
