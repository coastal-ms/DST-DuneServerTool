// ServerNameCard — rename the server (battlegroup spec.title) shown in the
// in-game server browser and on status pages (e.g. dunestatus).
//
// This is NOT an INI setting: it patches the battlegroup CRD directly. Applying
// the new title forces the operator to recreate the battlegroup pods, so it is a
// RESTART-class action — players disconnect briefly and the server blips out of
// the browser before returning under the new name. No data is touched. Hence the
// typed "RESTART" confirmation and the prominent warning below.
import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ApiError } from '../../api/client'
import { renameServer } from '../../api/server'

const CONFIRM_PHRASE = 'RESTART'
const MAX_LEN = 64

type Props = {
  vmRunning: boolean
  currentName: string
  onRenamed: () => void
}

export function ServerNameCard({ vmRunning, currentName, onRenamed }: Props) {
  const [editing, setEditing] = useState(false)
  const [name, setName] = useState(currentName)
  const [confirm, setConfirm] = useState('')
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  // Keep the input seeded with the live name whenever it changes (status poll)
  // and the editor isn't open.
  useEffect(() => {
    if (!editing) setName(currentName)
  }, [currentName, editing])

  const trimmed = name.trim()
  const changed = trimmed.length > 0 && trimmed !== currentName.trim()
  const tooLong = trimmed.length > MAX_LEN
  const confirmed = confirm.trim().toUpperCase() === CONFIRM_PHRASE
  const canSave = vmRunning && changed && !tooLong && confirmed && !saving

  function openEditor() {
    setEditing(true)
    setName(currentName)
    setConfirm('')
    setErr(null)
    setOk(null)
  }

  function cancel() {
    setEditing(false)
    setConfirm('')
    setErr(null)
  }

  async function save() {
    if (!canSave) return
    setSaving(true); setErr(null); setOk(null)
    try {
      const r = await renameServer(trimmed)
      setOk(r.message ?? `Server renamed to "${r.newName ?? trimmed}".`)
      setEditing(false)
      setConfirm('')
      onRenamed()
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="card p-4 mb-4 border-border">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="Server" size={16} className="shrink-0 text-accent" />
          <div className="min-w-0">
            <div className="text-sm font-semibold text-text">Server name</div>
            <div className="text-xs text-text-muted">
              Shown in the in-game server browser and on status pages.
            </div>
          </div>
        </div>
        {!editing && (
          <button
            type="button"
            className="btn-secondary shrink-0"
            onClick={openEditor}
            disabled={!vmRunning}
            title={vmRunning ? 'Rename the server' : 'Start the VM first'}
          >
            <Icon name="Pencil" size={14} /> Rename
          </button>
        )}
      </div>

      {!editing && (
        <div className="mt-3 flex items-center gap-2">
          <span className="text-lg font-semibold text-text truncate" title={currentName || undefined}>
            {currentName || <span className="text-text-dim italic text-base font-normal">Unknown</span>}
          </span>
        </div>
      )}

      {editing && (
        <div className="mt-3 space-y-3">
          <div>
            <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">New name</label>
            <input
              type="text"
              value={name}
              maxLength={MAX_LEN + 8}
              onChange={e => setName(e.target.value)}
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-accent focus:border-accent/50"
              autoFocus
              placeholder="My Dune server"
            />
            <div className="mt-1 flex items-center justify-between text-xs">
              <span className={tooLong ? 'text-danger' : 'text-text-dim'}>
                {trimmed.length}/{MAX_LEN}
              </span>
            </div>
          </div>

          <div className="card p-3 border-warning/40 bg-warning/5 text-sm flex items-start gap-2">
            <Icon name="AlertTriangle" size={16} className="mt-0.5 shrink-0 text-warning" />
            <div className="text-xs text-text leading-relaxed">
              Renaming <span className="font-medium">restarts your battlegroup</span>. All connected
              players are disconnected, and the server briefly disappears from the in-game browser
              before returning under the new name. Your world and player data are not affected.
            </div>
          </div>

          <div>
            <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">
              Type <span className="font-mono text-warning">{CONFIRM_PHRASE}</span> to confirm the restart
            </label>
            <input
              type="text"
              value={confirm}
              onChange={e => setConfirm(e.target.value)}
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono focus:outline-none focus:ring-2 focus:ring-warning focus:border-warning/50"
              placeholder={CONFIRM_PHRASE}
            />
          </div>

          <div className="flex items-center gap-2">
            <button type="button" className="btn-primary" onClick={() => void save()} disabled={!canSave}>
              <Icon name={saving ? 'Loader2' : 'Check'} size={14} className={saving ? 'animate-spin' : ''} />
              {saving ? 'Renaming…' : 'Rename & restart'}
            </button>
            <button type="button" className="btn-secondary" onClick={cancel} disabled={saving}>
              <Icon name="X" size={14} /> Cancel
            </button>
          </div>
        </div>
      )}

      {err && (
        <div className="mt-3 text-sm text-danger flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {err}
        </div>
      )}
      {ok && (
        <div className="mt-3 text-sm text-success flex items-center gap-2">
          <Icon name="ShieldCheck" size={14} /> {ok}
        </div>
      )}
    </div>
  )
}
