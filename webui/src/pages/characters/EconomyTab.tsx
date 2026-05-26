// Economy tab — currencies (Solari, House Scrip) + faction reputation rows.
import { useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import { NumberField, SectionCard, Toast } from './Shared'
import { saveCurrency, saveFactionRep } from '../../api/characters'
import type { CharacterDetail, CharacterDefs } from '../../api/types'

type Props = {
  charId: number
  detail: CharacterDetail
  defs: CharacterDefs
  onSaved?: () => void
}

export function EconomyTab({ charId, detail, defs, onSaved }: Props) {
  const [curValues, setCurValues] = useState<Record<number, string>>({})
  const [facValues, setFacValues] = useState<Record<number, string>>({})
  const [busyCur,   setBusyCur]   = useState<number | null>(null)
  const [busyFac,   setBusyFac]   = useState<number | null>(null)
  const [ok, setOk]   = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  // Build the master faction list — union of `factions` table + any rep rows that
  // reference a faction not in the table (defensive).
  const factions = useMemo(() => {
    const map = new Map<number, string>()
    for (const f of detail.economy.factions)   map.set(f.id, f.name)
    for (const r of detail.economy.factionRep) if (!map.has(r.factionId)) map.set(r.factionId, r.factionName)
    return Array.from(map.entries()).map(([id, name]) => ({ id, name })).sort((a, b) => a.id - b.id)
  }, [detail])

  useEffect(() => {
    const c: Record<number, string> = {}
    for (const def of defs.currencies) {
      const row = detail.economy.currency.find(r => r.currencyId === def.id)
      c[def.id] = row ? String(row.balance) : '0'
    }
    setCurValues(c)
    const f: Record<number, string> = {}
    for (const fac of factions) {
      const row = detail.economy.factionRep.find(r => r.factionId === fac.id)
      f[fac.id] = row ? String(row.reputation) : '0'
    }
    setFacValues(f)
  }, [detail, defs, factions])

  async function onSaveCurrency(id: number) {
    setErr(null); setOk(null); setBusyCur(id)
    try {
      const bal = Math.max(0, Math.floor(Number(curValues[id]) || 0))
      await saveCurrency(charId, id, bal)
      setOk(`${defs.currencies.find(c => c.id === id)?.label ?? 'Currency'}: saved.`)
      onSaved?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyCur(null)
    }
  }

  async function onSaveFaction(id: number) {
    setErr(null); setOk(null); setBusyFac(id)
    try {
      const amt = Math.floor(Number(facValues[id]) || 0)
      await saveFactionRep(charId, id, amt)
      setOk(`${factions.find(f => f.id === id)?.name ?? 'Faction'}: saved.`)
      onSaved?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyFac(null)
    }
  }

  return (
    <>
      <SectionCard title="Currencies" icon="Coins" actions={
        <span className="text-xs text-text-dim">
          Controller&nbsp;ID&nbsp;<code className="font-mono">{detail.economy.controllerId || '—'}</code>
        </span>
      }>
        <Toast kind="error"   message={err} onClear={() => setErr(null)} />
        <Toast kind="success" message={ok}  onClear={() => setOk(null)} />
        <div className="space-y-3">
          {defs.currencies.map(def => (
            <div key={def.id} className="grid grid-cols-[1fr_auto] gap-3 items-end">
              <NumberField label={def.label} value={curValues[def.id] ?? '0'} min={0} step={1}
                           onChange={v => setCurValues(prev => ({ ...prev, [def.id]: v }))} />
              <button type="button" className="btn-primary py-2" disabled={busyCur === def.id}
                      onClick={() => onSaveCurrency(def.id)}>
                <Icon name={busyCur === def.id ? 'Loader2' : 'Save'} size={14}
                      className={busyCur === def.id ? 'animate-spin' : ''} />
                Set
              </button>
            </div>
          ))}
        </div>
        {!detail.economy.controllerId && (
          <p className="text-xs text-warning mt-3">
            <Icon name="AlertTriangle" size={12} className="inline mr-1" />
            No player_controller_id resolved — saves will fail until this character has been online once.
          </p>
        )}
      </SectionCard>

      <SectionCard title="Faction Reputation" icon="Flag">
        {factions.length === 0 ? (
          <div className="text-sm text-text-muted py-2">
            <Icon name="Info" size={14} className="inline mr-1.5" />
            No factions returned by the DB yet.
          </div>
        ) : (
          <div className="space-y-2">
            {factions.map(fac => (
              <div key={fac.id} className="grid grid-cols-[1fr_auto] gap-3 items-end">
                <NumberField label={`${fac.name} (id ${fac.id})`} value={facValues[fac.id] ?? '0'}
                             step={1} onChange={v => setFacValues(prev => ({ ...prev, [fac.id]: v }))} />
                <button type="button" className="btn-primary py-2" disabled={busyFac === fac.id}
                        onClick={() => onSaveFaction(fac.id)}>
                  <Icon name={busyFac === fac.id ? 'Loader2' : 'Save'} size={14}
                        className={busyFac === fac.id ? 'animate-spin' : ''} />
                  Set
                </button>
              </div>
            ))}
          </div>
        )}
      </SectionCard>
    </>
  )
}
