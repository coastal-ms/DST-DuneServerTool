import { useState } from 'react'

export function SoloCharacterXp({ disabled, currentXp, onRun }: {
  disabled: boolean
  currentXp?: number | null
  onRun: (action: 'add' | 'set', amount: number) => void
}) {
  const [amount, setAmount] = useState('5000')
  const value = Number(amount)
  const invalid = amount.trim() === '' || !Number.isSafeInteger(value) || value < 0 || value > 344440
  return <div className="card p-5">
    <h3 className="font-semibold mb-2">Character XP</h3>
    {currentXp != null && <p className="text-sm mb-2">Saved character XP: {currentXp.toLocaleString()}</p>}
    <p className="text-sm text-text-muted mb-3">Change total character XP, separately from faction reputation and specializations. Close the game first; each change retains a backup.</p>
    <label className="text-sm">Character XP amount (0–344,440)
      <input type="number" className="input w-full" min={0} max={344440} step={1} value={amount} disabled={disabled} onChange={event => setAmount(event.target.value)} />
    </label>
    <p className="text-sm text-text-muted my-3">Level changes adjust available skill points and award newly earned Intel. Existing skill allocations, bonus points and research stay intact. Respec first if lowering XP would remove allocated points.</p>
    <div className="flex gap-2 flex-wrap">
      <button className="btn-primary" disabled={disabled || invalid} onClick={() => onRun('add', value)}>Add character XP</button>
      <button className="btn btn-secondary" disabled={disabled || invalid} onClick={() => {
        if (window.confirm(`Set total character XP to ${value}? This replaces the current XP and adjusts available skill points.`)) onRun('set', value)
      }}>Set character XP</button>
    </div>
  </div>
}
