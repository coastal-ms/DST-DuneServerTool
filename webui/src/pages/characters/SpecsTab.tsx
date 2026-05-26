// Specs tab — per-track level/xp + Unlock Keystones button.
import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ConfirmDialog, NumberField, SectionCard, Toast } from './Shared'
import { saveSpec, unlockKeystones } from '../../api/characters'
import type { CharacterDetail, CharacterDefs } from '../../api/types'

type Props = {
  charId: number
  charName: string
  detail: CharacterDetail
  defs: CharacterDefs
  onSaved?: () => void
}

type RowState = { xp: string; level: string; busy: boolean }

export function SpecsTab({ charId, charName, detail, defs, onSaved }: Props) {
  const [rows, setRows] = useState<Record<string, RowState>>({})
  const [pendingPrefix, setPendingPrefix] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    const next: Record<string, RowState> = {}
    for (const t of defs.specTracks) {
      const existing = detail.specializations.tracks.find(r => r.trackType === t)
      next[t] = {
        xp:    existing ? String(existing.xp ?? 0)    : '0',
        level: existing ? String(existing.level ?? 0) : '0',
        busy:  false,
      }
    }
    setRows(next)
  }, [detail, defs])

  function setRow(track: string, patch: Partial<RowState>) {
    setRows(prev => ({ ...prev, [track]: { ...prev[track], ...patch } }))
  }

  async function onSet(track: string) {
    setErr(null); setOk(null); setRow(track, { busy: true })
    try {
      const r = rows[track]
      await saveSpec(charId, track, Math.max(0, Math.floor(Number(r.xp) || 0)), Number(r.level) || 0)
      setOk(`${track}: saved.`)
      onSaved?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setRow(track, { busy: false })
    }
  }

  async function onUnlockKeystones() {
    if (!pendingPrefix) return
    const prefix = pendingPrefix
    setPendingPrefix(null); setErr(null); setOk(null)
    try {
      await unlockKeystones(charId, prefix)
      setOk(`Keystones unlocked for ${prefix.replace('_', '')}.`)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    }
  }

  return (
    <SectionCard title="Specializations" icon="Sparkles">
      <Toast kind="error" message={err} onClear={() => setErr(null)} />
      <Toast kind="success" message={ok} onClear={() => setOk(null)} />
      <div className="space-y-3">
        {defs.specTracks.map(track => {
          const r = rows[track] ?? { xp: '0', level: '0', busy: false }
          const prefix = `${track}_`
          const hasKeystones = defs.specKeystonePrefixes.includes(prefix)
          return (
            <div key={track} className="border border-border rounded-lg p-3 bg-surface-2/40">
              <div className="flex items-center justify-between mb-3">
                <h4 className="font-medium text-text">{track}</h4>
                {hasKeystones && (
                  <button type="button" className="btn-secondary text-xs px-2 py-1"
                          onClick={() => setPendingPrefix(prefix)}>
                    <Icon name="Key" size={13} /> Unlock Keystones
                  </button>
                )}
              </div>
              <div className="grid grid-cols-2 md:grid-cols-[1fr_1fr_auto] gap-3 items-end">
                <NumberField label="Level" value={r.level} min={0} step={1}
                             onChange={v => setRow(track, { level: v })} />
                <NumberField label="XP"    value={r.xp}    min={0} step={1}
                             onChange={v => setRow(track, { xp: v })} />
                <button type="button" className="btn-primary py-2" disabled={r.busy} onClick={() => onSet(track)}>
                  <Icon name={r.busy ? 'Loader2' : 'Save'} size={14} className={r.busy ? 'animate-spin' : ''} />
                  Set
                </button>
              </div>
            </div>
          )
        })}
      </div>
      <ConfirmDialog
        open={!!pendingPrefix}
        title="Unlock keystones?"
        message={<>Grant every keystone for <strong>{pendingPrefix?.replace('_', '')}</strong> on
                  <strong> {charName || `character #${charId}`}</strong>?</>}
        confirmLabel="Unlock"
        confirmIcon="Key"
        onCancel={() => setPendingPrefix(null)}
        onConfirm={onUnlockKeystones}
      />
    </SectionCard>
  )
}
