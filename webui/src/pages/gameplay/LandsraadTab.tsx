// Landsraad Houses — view/edit the reward tiers (thresholds + items) for each
// house in the current Landsraad term. Allows bulk threshold adjustment (the
// Discord "5k task goal" pattern) and per-tier item/amount edits.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getLandsraadRewards, setLandsraadThresholds, setLandsraadRewardTier,
  type LandsraadRewardHouse, type LandsraadRewardTier, type DataSource,
} from '../../api/gameplay'
import { SourceBadge, DemoNotice, fmtNum } from './shared'

// Default Funcom thresholds and example "5k goal" replacements.
const DEFAULT_THRESHOLDS = [700, 3500, 7000, 10500, 14000]
const PRESET_5K: { old: number; new: number }[] = [
  { old: 700, new: 250 },
  { old: 3500, new: 1250 },
  { old: 7000, new: 2500 },
  { old: 10500, new: 3750 },
  { old: 14000, new: 5000 },
]

export function LandsraadTab() {
  const [houses, setHouses] = useState<LandsraadRewardHouse[]>([])
  const [termId, setTermId] = useState(0)
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Bulk threshold editor state.
  const [showBulk, setShowBulk] = useState(false)
  const [bulkMappings, setBulkMappings] = useState<{ old: string; new: string }[]>(
    DEFAULT_THRESHOLDS.map(t => ({ old: String(t), new: '' }))
  )

  // Per-tier inline editor state.
  const [editKey, setEditKey] = useState<string | null>(null) // "taskId-threshold"
  const [editTemplate, setEditTemplate] = useState('')
  const [editAmount, setEditAmount] = useState('')

  // Expanded house cards.
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set())

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getLandsraadRewards()
      setHouses(r.houses); setTermId(r.term_id); setSource(r.source); setLiveError(r.liveError)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  // Derive current distinct thresholds across all houses for display.
  const currentThresholds = useMemo(() => {
    const set = new Set<number>()
    for (const h of houses) for (const t of h.tiers) set.add(t.threshold)
    return [...set].sort((a, b) => a - b)
  }, [houses])

  // Apply bulk threshold mappings.
  const applyBulk = async () => {
    const mappings = bulkMappings
      .map(m => ({ old: parseInt(m.old, 10), new: parseInt(m.new, 10) }))
      .filter(m => m.old > 0 && m.new > 0 && m.old !== m.new)
    if (mappings.length === 0) { setError('Enter at least one valid old→new mapping.'); return }
    setBusy(true); setError(null); setFlash(null)
    try {
      const r = await setLandsraadThresholds(mappings)
      setFlash(r.message)
      void load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  // Load preset into bulk editor.
  const loadPreset5k = () => {
    setBulkMappings(PRESET_5K.map(p => ({ old: String(p.old), new: String(p.new) })))
  }
  const loadPresetReset = () => {
    // Reverse: current -> default (assumes current are the 5k ones).
    setBulkMappings(PRESET_5K.map(p => ({ old: String(p.new), new: String(p.old) })))
  }

  // Start editing a tier.
  const beginEdit = (h: LandsraadRewardHouse, t: LandsraadRewardTier) => {
    setEditKey(`${h.task_id}-${t.threshold}`)
    setEditTemplate(t.template_id)
    setEditAmount(String(t.amount))
  }
  const cancelEdit = () => { setEditKey(null); setEditTemplate(''); setEditAmount('') }
  const saveEdit = async (taskId: number, threshold: number) => {
    const tmpl = editTemplate.trim() || undefined
    const amt = parseInt(editAmount, 10) || undefined
    if (!tmpl && !amt) { setError('Provide template_id and/or amount.'); return }
    setBusy(true); setError(null); setFlash(null)
    try {
      const r = await setLandsraadRewardTier(taskId, threshold, tmpl, amt)
      setFlash(r.message)
      cancelEdit()
      void load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const toggleHouse = (taskId: number) => {
    setExpanded(prev => {
      const next = new Set(prev)
      if (next.has(taskId)) next.delete(taskId); else next.add(taskId)
      return next
    })
  }

  const canWrite = source === 'live'

  return (
    <div>
      {/* Header info */}
      <div className="card p-4 mb-4">
        <div className="flex items-center justify-between flex-wrap gap-2 mb-2">
          <div className="flex items-center gap-2">
            <Icon name="Landmark" size={18} className="text-accent" />
            <span className="font-semibold text-text">Landsraad Houses</span>
            <SourceBadge source={source} />
          </div>
          <button className="btn-secondary" onClick={() => void load()} disabled={loading || busy}>
            <Icon name="RefreshCw" size={14} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        </div>
        <p className="text-xs text-text-muted leading-relaxed">
          Each Landsraad house (task) has <strong>5 reward tiers</strong> — milestones players unlock by contributing points.
          <strong> Threshold</strong> is the point target for that tier; <strong>template_id</strong> is the item rewarded; <strong>amount</strong> is how many.
          Use <em>Bulk Threshold Edit</em> to rescale all thresholds at once (e.g. when you lower the task goal from 15k to 5k),
          or expand a house and click a tier to change its item/amount individually.
        </p>
        {termId > 0 && (
          <div className="mt-2 text-xs text-text-dim">
            Current term: <span className="font-mono text-text">{termId}</span> • Thresholds in use: <span className="font-mono text-text">{currentThresholds.join(', ') || '—'}</span>
          </div>
        )}
      </div>

      {source === 'demo' && <DemoNotice liveError={liveError} what="Landsraad reward data" />}
      {flash && <div className="card p-3 mb-4 text-sm text-success flex items-center gap-2"><Icon name="CheckCircle2" size={15} /> {flash}</div>}
      {error && <div className="card p-3 mb-4 text-sm text-danger">{error}</div>}

      {/* Bulk threshold editor */}
      <div className="card mb-4">
        <button
          type="button"
          className="w-full flex items-center justify-between px-4 py-3 text-left"
          onClick={() => setShowBulk(b => !b)}
        >
          <span className="font-medium text-text flex items-center gap-2">
            <Icon name="Settings2" size={15} className="text-accent" />
            Bulk Threshold Edit
          </span>
          <Icon name={showBulk ? 'ChevronUp' : 'ChevronDown'} size={15} className="text-text-dim" />
        </button>
        {showBulk && (
          <div className="px-4 pb-4 border-t border-border pt-3">
            <p className="text-xs text-text-muted mb-3">
              Map each <strong>old threshold</strong> to a <strong>new threshold</strong>. Leave "new" blank to skip that row.
              This updates <em>every</em> reward row across all houses in the current term where the threshold matches.
            </p>
            <div className="flex flex-wrap gap-2 mb-3">
              <button type="button" className="btn-secondary text-xs" onClick={loadPreset5k} disabled={busy}>
                <Icon name="Zap" size={12} /> Load 5k-goal preset (700→250, etc.)
              </button>
              <button type="button" className="btn-secondary text-xs" onClick={loadPresetReset} disabled={busy}>
                <Icon name="RotateCcw" size={12} /> Load reverse (back to Funcom defaults)
              </button>
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-5 gap-2 mb-3">
              {bulkMappings.map((m, i) => (
                <div key={i} className="flex flex-col gap-1">
                  <label className="text-[10px] uppercase tracking-wider text-text-dim">Old</label>
                  <input
                    type="number"
                    className="input-field text-sm font-mono"
                    value={m.old}
                    onChange={e => {
                      const next = [...bulkMappings]
                      next[i] = { ...next[i], old: e.target.value }
                      setBulkMappings(next)
                    }}
                    disabled={busy}
                  />
                  <label className="text-[10px] uppercase tracking-wider text-text-dim">New</label>
                  <input
                    type="number"
                    className="input-field text-sm font-mono"
                    placeholder="—"
                    value={m.new}
                    onChange={e => {
                      const next = [...bulkMappings]
                      next[i] = { ...next[i], new: e.target.value }
                      setBulkMappings(next)
                    }}
                    disabled={busy}
                  />
                </div>
              ))}
            </div>
            <button
              type="button"
              className="btn-primary"
              onClick={() => void applyBulk()}
              disabled={busy || !canWrite}
              title={canWrite ? 'Apply the threshold mappings' : 'Start the battlegroup to enable writes'}
            >
              {busy ? <Icon name="Loader2" size={14} className="animate-spin" /> : <Icon name="Save" size={14} />}
              Apply Threshold Changes
            </button>
            {!canWrite && <span className="ml-2 text-xs text-text-dim">(requires live DB)</span>}
          </div>
        )}
      </div>

      {/* Houses list */}
      {loading && houses.length === 0 && (
        <div className="card p-8 text-center text-text-dim">
          <Icon name="Loader2" size={20} className="animate-spin inline" /> Loading Landsraad houses…
        </div>
      )}
      {!loading && termId === 0 && (
        <div className="card p-8 text-center text-text-dim">No active Landsraad term on this server.</div>
      )}
      {houses.length > 0 && (
        <div className="space-y-2">
          {houses.map(h => {
            const open = expanded.has(h.task_id)
            return (
              <div key={h.task_id} className="card overflow-hidden">
                <button
                  type="button"
                  className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-surface-2 transition-colors"
                  onClick={() => toggleHouse(h.task_id)}
                >
                  <span className="font-medium text-text">
                    <Icon name="Home" size={14} className="inline mr-2 text-accent" />
                    {h.display_name}
                    <span className="ml-2 text-xs text-text-dim font-normal">({h.tiers.length} tiers)</span>
                  </span>
                  <Icon name={open ? 'ChevronUp' : 'ChevronDown'} size={15} className="text-text-dim" />
                </button>
                {open && (
                  <div className="border-t border-border">
                    <table className="w-full text-sm">
                      <thead>
                        <tr className="text-left text-[11px] uppercase tracking-wider text-text-dim border-b border-border/50">
                          <th className="px-4 py-2 font-medium">Threshold</th>
                          <th className="px-4 py-2 font-medium">Item (template_id)</th>
                          <th className="px-4 py-2 font-medium text-right">Amount</th>
                          <th className="px-4 py-2 font-medium text-right">Actions</th>
                        </tr>
                      </thead>
                      <tbody>
                        {h.tiers.map(t => {
                          const key = `${h.task_id}-${t.threshold}`
                          const editing = editKey === key
                          return (
                            <tr key={t.threshold} className="border-b border-border/30 hover:bg-surface-2">
                              <td className="px-4 py-2 font-mono text-accent">{fmtNum(t.threshold)}</td>
                              {editing ? (
                                <>
                                  <td className="px-4 py-2">
                                    <input
                                      type="text"
                                      className="input-field text-xs font-mono w-full"
                                      value={editTemplate}
                                      onChange={e => setEditTemplate(e.target.value)}
                                      placeholder="template_id"
                                      disabled={busy}
                                    />
                                  </td>
                                  <td className="px-4 py-2 text-right">
                                    <input
                                      type="number"
                                      className="input-field text-xs font-mono w-20 text-right"
                                      value={editAmount}
                                      onChange={e => setEditAmount(e.target.value)}
                                      placeholder="qty"
                                      disabled={busy}
                                    />
                                  </td>
                                  <td className="px-4 py-2 text-right flex items-center justify-end gap-1">
                                    <button
                                      type="button"
                                      className="btn-primary py-1 px-2 text-xs"
                                      onClick={() => void saveEdit(h.task_id, t.threshold)}
                                      disabled={busy}
                                    >
                                      {busy ? <Icon name="Loader2" size={12} className="animate-spin" /> : <Icon name="Check" size={12} />} Save
                                    </button>
                                    <button type="button" className="btn-secondary py-1 px-2 text-xs" onClick={cancelEdit} disabled={busy}>
                                      <Icon name="X" size={12} />
                                    </button>
                                  </td>
                                </>
                              ) : (
                                <>
                                  <td className="px-4 py-2 font-mono text-text-muted truncate max-w-[260px]" title={t.template_id}>
                                    {t.template_id}
                                  </td>
                                  <td className="px-4 py-2 text-right font-mono">{fmtNum(t.amount)}</td>
                                  <td className="px-4 py-2 text-right">
                                    <button
                                      type="button"
                                      className="btn-secondary py-1 px-2 text-xs"
                                      onClick={() => beginEdit(h, t)}
                                      disabled={busy || !canWrite}
                                      title={canWrite ? 'Edit this tier' : 'Start the battlegroup to enable writes'}
                                    >
                                      <Icon name="Pencil" size={12} /> Edit
                                    </button>
                                  </td>
                                </>
                              )}
                            </tr>
                          )
                        })}
                      </tbody>
                    </table>
                    <div className="px-4 py-2 text-[11px] text-text-dim bg-surface-2/50">
                      <strong>task_id:</strong> {h.task_id} • <strong>house_name:</strong> {h.house_name}
                    </div>
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
