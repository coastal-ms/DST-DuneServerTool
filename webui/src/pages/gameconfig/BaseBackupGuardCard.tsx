import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { getBaseBackupGuard, saveBaseBackupGuard } from '../../api/gameconfig'
import type { BaseBackupGuardState } from '../../api/types'

type Props = { vmRunning: boolean }

// Deep Desert base backups vs the weekly Coriolis wipe.
//
// Funcom's season-end cleanup deletes every actor on a map outside the
// shieldwall except those held in the Travel / VehicleBackup / VehicleRecovery
// states. A stored base backup lives in the BaseBackup state, which is not on
// that list — so on a server that has allowed the base backup tool in the Deep
// Desert, the reset deletes the actors behind a stored base and the tool is
// left able to recycle it but never place it.
export function BaseBackupGuardCard({ vmRunning }: Props) {
  const [state, setState] = useState<BaseBackupGuardState | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const load = useCallback(async (silent = false) => {
    if (!silent) { setLoading(true); setErr(null) }
    try {
      setState(await getBaseBackupGuard())
    } catch (e) {
      if (!silent) setErr(e instanceof Error ? e.message : String(e))
    } finally {
      if (!silent) setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  async function toggle(next: boolean) {
    setSaving(true); setErr(null); setOk(null)
    try {
      const res = await saveBaseBackupGuard(next)
      setState(res)
      if (!res.ok) setErr(res.message ?? 'The change could not be applied.')
      else setOk(res.message ?? (next ? 'Applied.' : 'Reverted.'))
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  const applied = state?.applied === true
  const enabled = state?.enabled === true
  // Opted in but the predicate is gone: a game update replaced the function.
  // The scheduler re-applies within ~10 minutes; surface it meanwhile.
  const drifted = enabled && state?.available === true && state?.functionFound === true && !applied

  return (
    <CollapsibleCard
      id="gameconfig.baseBackupGuard"
      icon="Archive"
      iconClassName="text-ibad shrink-0"
      title="Deep Desert base backups"
      titleClassName="text-sm font-semibold uppercase tracking-wider text-ibad"
      subtitle={
        <span className="text-xs text-text-muted">
          Keep stored base backups alive through the weekly Deep Desert reset.
        </span>
      }
      headerClassName="px-5 pt-5 pb-2"
      bodyClassName="px-5 pb-5"
      headerRight={
        <button type="button" className="btn-secondary" disabled={loading || saving}
                onClick={() => void load()}>
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14}
                className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      }
    >
      {err && <div className="mb-3 px-3 py-2 rounded border border-danger/40 bg-danger/10 text-danger text-xs">{err}</div>}
      {ok && <div className="mb-3 px-3 py-2 rounded border border-success/40 bg-success/10 text-success text-xs">{ok}</div>}

      <p className="text-xs text-text-muted mb-3">
        Funcom&apos;s season-end cleanup deletes everything left on the Deep Desert except
        actors in transit and backed-up vehicles. A stored base backup is not on that
        list, so after a reset it can only be recycled, never placed. Turning this on
        adds base backups to the same protected set.
      </p>

      {!vmRunning || state?.available === false ? (
        <div className="text-xs text-warning">
          {state?.message ?? 'Start the battlegroup to read or change this.'}
        </div>
      ) : state?.functionFound === false ? (
        <div className="text-xs text-warning">
          This server build does not have the cleanup function DST patches, so there is
          nothing to change here.
        </div>
      ) : (
        <>
          <label className="flex items-center gap-2 text-sm mb-3 cursor-pointer">
            <input type="checkbox" checked={enabled} disabled={saving || loading}
                   onChange={e => void toggle(e.target.checked)} className="accent-ibad" />
            <span className="font-medium text-text">Protect stored base backups from the reset</span>
          </label>

          <div className="text-[11px] font-mono text-text-dim">
            status: {applied ? 'protected' : 'stock Funcom behaviour'}
          </div>

          {drifted && (
            <div className="mt-3 px-3 py-2 rounded border border-warning/40 bg-warning/10 text-warning text-xs">
              A game update has replaced the cleanup function and removed the protection.
              DST re-applies it automatically within ~10 minutes, or use the checkbox to
              do it now.
            </div>
          )}

          <p className="mt-3 text-[11px] text-text-dim">
            This edits a Funcom-owned database function. Turning it off restores the
            original exactly. It only matters if you have also added
            <code className="mx-1">DeepDesert</code>
            to the base backup tool&apos;s allowed maps.
          </p>
        </>
      )}
    </CollapsibleCard>
  )
}
