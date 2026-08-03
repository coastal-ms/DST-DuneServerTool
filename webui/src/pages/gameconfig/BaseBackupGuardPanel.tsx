import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getBaseBackupGuard, saveBaseBackupGuard } from '../../api/gameconfig'
import type { BaseBackupGuardState } from '../../api/types'

type Props = { vmRunning: boolean }

// Rendered inside the BaseBackUp category card, below its INI fields.
//
// Unlike everything else in that category this is not an INI setting: Funcom's
// season-end cleanup deletes every actor left on the Deep Desert except those in
// transit or backed-up vehicles, and a stored base backup is not on that list.
// So after a reset it can only be recycled, never placed. Turning this on adds
// stored bases to the protected set. It belongs next to the map restriction
// because enabling the tool in the Deep Desert without it produces exactly that
// surprise.
export function BaseBackupGuardPanel({ vmRunning }: Props) {
  const [state, setState] = useState<BaseBackupGuardState | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true); setErr(null)
    try {
      setState(await getBaseBackupGuard())
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
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
    <div className="mt-5 pt-4 border-t border-border">
      <label className="flex items-center gap-2 text-sm cursor-pointer">
        <input
          type="checkbox"
          checked={enabled}
          disabled={!vmRunning || saving || loading}
          onChange={e => void toggle(e.target.checked)}
          className="accent-ibad"
        />
        <span className="font-medium text-text">Keep stored base backups through the Deep Desert reset</span>
        {(saving || loading) && <Icon name="Loader2" size={13} className="animate-spin text-text-dim" />}
      </label>

      <p className="mt-1 text-xs text-text-muted">
        The end-of-season cleanup removes everything left on the Deep Desert except things in
        transit and backed-up vehicles. Stored bases aren&apos;t on that list, so after a reset they
        can only be recycled. This adds them to it. Not an INI setting — it changes how the
        server&apos;s own cleanup behaves, and switching it off restores the original exactly.
      </p>

      {!vmRunning || state?.available === false ? (
        <div className="mt-2 text-xs text-warning">
          {state?.message ?? 'Start the battlegroup to read or change this.'}
        </div>
      ) : state?.functionFound === false ? (
        <div className="mt-2 text-xs text-warning">
          This server build doesn&apos;t have the cleanup routine DST adjusts, so there&apos;s nothing to
          change here.
        </div>
      ) : (
        <div className="mt-2 text-[11px] font-mono text-text-dim">
          status: {applied ? 'protected' : 'stock Funcom behaviour'}
        </div>
      )}

      {err && <div className="mt-2 px-3 py-2 rounded border border-danger/40 bg-danger/10 text-danger text-xs">{err}</div>}
      {ok && <div className="mt-2 px-3 py-2 rounded border border-success/40 bg-success/10 text-success text-xs">{ok}</div>}

      {drifted && (
        <div className="mt-2 px-3 py-2 rounded border border-warning/40 bg-warning/10 text-warning text-xs">
          A game update has replaced the cleanup routine and removed the protection. DST puts it
          back automatically within ~10 minutes, or untick and re-tick to do it now.
        </div>
      )}
    </div>
  )
}
