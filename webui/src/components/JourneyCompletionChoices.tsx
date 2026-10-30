import { Icon } from './Icon'
import { useEffect, useState } from 'react'
import { getMainQuestCatalog, getProgressionPresets } from '../api/gameplay'

type Choice = { id: string; label: string; description?: string; kind: 'preset' | 'quest' }
const tutorials = new Set(['skip_npe', 'a_new_beginning', 'vermillius_intro', 'deep_desert_intro', 'taxation_intro', 'overland_intro'])
const completeLabel = (name: string) => name.startsWith('Complete ') ? name : `Complete ${name.replace(/^(Complete:|Skip:)\s*/, '')}`

export function JourneyCompletionChoices({ category, busy, onPreset, onQuest }: {
  category: 'story' | 'tutorial'
  busy: boolean
  onPreset: (id: string) => unknown
  onQuest: (id: string) => unknown
}) {
  const [choices, setChoices] = useState<Choice[]>([])
  const [selected, setSelected] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    let alive = true
    Promise.all([getProgressionPresets(), getMainQuestCatalog()]).then(([presets, catalog]) => {
      if (!alive) return
      const entries = presets.presets ?? []
      const list: Choice[] = entries.filter(p => !p.id.startsWith('faction_') && p.id !== 'unlock_all_lore' && p.id !== 'a_new_beginning' && tutorials.has(p.id) === (category === 'tutorial')).map(p => ({
        id: p.id, label: p.id === 'skip_npe' ? 'Complete Full Tutorial' : completeLabel(p.name), description: p.description, kind: 'preset',
      }))
      if (category === 'story') {
        const covered = new Set(entries.flatMap(p => p.nodes))
        covered.add('DA_MQ_NPEAutocompleted')
        for (const q of catalog.main_quests ?? []) if (!covered.has(q.id)) list.push({ id: q.id, label: completeLabel(q.name), kind: 'quest' })
        const order = ['act1_complete', 'act2_complete', 'act3_complete', 'act4_complete', 'lost_harvest_complete']
        list.sort((a, b) => (order.includes(a.id) ? order.indexOf(a.id) : 99) - (order.includes(b.id) ? order.indexOf(b.id) : 99))
      }
      setChoices(list); setSelected(list[0]?.id ?? '')
    }).catch(e => { if (alive) setError(e instanceof Error ? e.message : String(e)) }).finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [category])
  if (loading) return <p role="status">Loading completion choices…</p>
  if (error) return <p className="text-danger">{error}</p>
  const chosen = choices.find(c => c.id === selected)
  return <div className="space-y-3">
    <label className="block">{category === 'story' ? 'Story' : 'Tutorial'}
      <span className="relative block mt-2">
      <select className="w-full min-h-12 appearance-none rounded-lg border border-border bg-surface-2 py-3 pl-4 pr-12 text-text text-sm shadow-sm cursor-pointer hover:border-ibad focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad disabled:cursor-not-allowed disabled:opacity-50" value={selected} disabled={busy} onChange={e => setSelected(e.target.value)}>
        {choices.map(c => <option key={c.id} value={c.id}>{c.label}</option>)}
      </select>
      <Icon name="ChevronDown" size={20} className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 text-text" />
      </span>
    </label>
    {chosen?.description && <p className="text-sm text-text-muted">{chosen.description}</p>}
    <p className="text-xs text-text-dim">Player must be offline. Takes effect on next login.</p>
    <button className="btn-primary w-full" disabled={busy || !chosen} onClick={() => { if (chosen) (chosen.kind === 'preset' ? onPreset : onQuest)(chosen.id) }}>{busy ? 'Completing…' : chosen?.label ?? 'No completion choices available'}</button>
  </div>
}
