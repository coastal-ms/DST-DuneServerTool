// Stats tab — 8 numeric inputs, batched PUT save.
import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { NumberField, SectionCard, Toast } from './Shared'
import { saveStats } from '../../api/characters'
import type { CharacterDetail, CharacterDefs } from '../../api/types'

type Props = {
  charId: number
  detail: CharacterDetail
  defs: CharacterDefs
  onSaved?: () => void
}

export function StatsTab({ charId, detail, defs, onSaved }: Props) {
  const [values, setValues] = useState<Record<string, string>>({})
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk]   = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)

  useEffect(() => {
    const v: Record<string, string> = {}
    for (const def of defs.stats) {
      const raw = detail.stats[def.key]
      v[def.key] = raw === '' || raw === null || raw === undefined ? '' : String(raw)
    }
    setValues(v)
    setDirty(false)
  }, [detail, defs])

  function setField(k: string, v: string) {
    setValues(prev => ({ ...prev, [k]: v }))
    setDirty(true)
  }

  async function onSave() {
    setSaving(true); setErr(null); setOk(null)
    try {
      const payload: Record<string, number> = {}
      for (const def of defs.stats) {
        const raw = values[def.key]
        if (raw === '' || raw === undefined) continue
        const n = Number(raw)
        if (!Number.isFinite(n)) continue
        payload[def.key] = n
      }
      const out = await saveStats(charId, payload)
      setOk(`Saved ${out.updated} stat${out.updated === 1 ? '' : 's'}.`)
      setDirty(false)
      onSaved?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <SectionCard title="Player Stats" icon="HeartPulse" actions={
      <button type="button" className="btn-primary" disabled={saving || !dirty} onClick={onSave}>
        <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
        {saving ? 'Saving…' : 'Save changes'}
      </button>
    }>
      <Toast kind="error" message={err} onClear={() => setErr(null)} />
      <Toast kind="success" message={ok} onClear={() => setOk(null)} />
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {defs.stats.map(def => (
          <NumberField
            key={def.key}
            label={def.label}
            value={values[def.key] ?? ''}
            min={def.min}
            max={def.max}
            step={def.step}
            onChange={v => setField(def.key, v)}
          />
        ))}
      </div>
      <p className="text-xs text-text-dim mt-4">
        Each field maps to a JSONB path in <code className="font-mono">actors.properties</code> or
        <code className="font-mono"> actors.gas_attributes</code>. Changes take effect on next world reload for the player.
      </p>
    </SectionCard>
  )
}
