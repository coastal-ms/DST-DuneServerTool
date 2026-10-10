import { useState } from 'react'

export type SoloFactionAction = 'ch3_start' | 'rank19_eligible' | 'add-reputation' | 'set-reputation'

export function SoloFactionProgression({ disabled, onRun }: {
  disabled: boolean
  onRun: (faction: string, action: SoloFactionAction, amount: number) => void
}) {
  const [faction, setFaction] = useState('atreides')
  const [stage, setStage] = useState<SoloFactionAction>('rank19_eligible')
  const [amount, setAmount] = useState('100')
  const value = Number(amount)
  const invalid = amount.trim() === '' || !Number.isSafeInteger(value) || value < 0 || value > 12474
  const inputClass = 'input w-full'
  return <div className="card p-5">
    <h3 className="font-semibold mb-2">Faction progression</h3>
    <p className="text-sm text-text-muted mb-3">Close the game first. Each change keeps a backup and takes effect on your next login.</p>
    <div className="grid gap-3 sm:grid-cols-2">
      <label className="text-sm">Faction
        <select className={inputClass} value={faction} disabled={disabled} onChange={e => setFaction(e.target.value)}>
          <option value="atreides">Atreides</option><option value="harkonnen">Harkonnen</option>
        </select>
      </label>
      <label className="text-sm">Progression stage
        <select className={inputClass} value={stage} disabled={disabled} onChange={e => setStage(e.target.value as SoloFactionAction)}>
          <option value="ch3_start">Chapter 3 start · Rank 5</option><option value="rank19_eligible">Rank 19 Eligible</option>
        </select>
      </label>
    </div>
    <p className="text-sm text-text-muted my-3">Progression Unlock joins the selected faction, completes its recruitment journey, and sets at least the selected rank. Rank 19 also unlocks Landsraad onboarding.</p>
    <button className="btn-primary" disabled={disabled} onClick={() => {
      if (window.confirm(`Apply ${stage === 'rank19_eligible' ? 'Rank 19 eligibility' : 'Chapter 3 progression'} for ${faction === 'atreides' ? 'Atreides' : 'Harkonnen'}? This changes your faction allegiance and completes the matching journey nodes.`)) onRun(faction, stage, 0)
    }}>Apply Progression Unlock</button>
    <div className="mt-5">
      <label className="text-sm">Faction reputation amount (0–12,474)
        <input type="number" className={inputClass} min={0} max={12474} step={1} value={amount} disabled={disabled} onChange={e => setAmount(e.target.value)} />
      </label>
      <p className="text-sm text-text-muted my-3">Add to or set standing with the selected faction. Reputation edits preserve your current allegiance.</p>
      <div className="flex gap-2 flex-wrap">
        <button className="btn-primary" disabled={disabled || invalid} onClick={() => onRun(faction, 'add-reputation', value)}>Add reputation</button>
        <button className="btn btn-secondary" disabled={disabled || invalid} onClick={() => {
          if (window.confirm(`Set ${faction} reputation to ${value}? This replaces its current amount.`)) onRun(faction, 'set-reputation', value)
        }}>Set reputation</button>
      </div>
    </div>
  </div>
}
