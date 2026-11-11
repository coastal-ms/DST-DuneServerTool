import { useEffect, useMemo, useRef, useState } from 'react'
import { api, withOnlinePlayerGuard } from '../../api/client'
import type { RetailServerSetting } from '../../api/types'
import { RetailServerSettingsRows, RETAIL_SETTING_GUIDANCE } from './OfficialRetailServerSettingsCard'

type Field = RetailServerSetting & { id: string }
type Snapshot = { targets: { id: string; label: string }[]; target: string; file: string; revision: string; raw: string; overridden: boolean; canSave: boolean; pendingRestart?: boolean; saveDisabledReason?: string; fields: Field[] }
const valuesFrom = (s: Snapshot) => Object.fromEntries(s.fields.map(f => [f.id, f.value]))
const messageOf = (e: unknown) => e instanceof Error ? e.message : String(e)
const draftKey = (target: string, file: string) => `dst.windows.map-settings.${target}.${file}`

export function WindowsPerMapSettings({ target: selectedTarget, onTargetChange, globalFile = 'server', onGlobalFileChange, disabled = false }: {
  target?: string; onTargetChange?: (target: string) => void; globalFile?: 'server' | 'game' | 'engine';
  onGlobalFileChange?: (file: 'server' | 'game' | 'engine') => void; disabled?: boolean
} = {}) {
  const [targets, setTargets] = useState<Snapshot['targets']>([])
  const [localTarget, setLocalTarget] = useState('global')
  const target = selectedTarget ?? localTarget
  const setTarget = (value: string) => { setLocalTarget(value); onTargetChange?.(value) }
  const file = 'server'
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [query, setQuery] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const sequence = useRef(0)
  const matches = snapshot?.target === target && snapshot?.file === file
  const fields = matches ? snapshot.fields : []
  const changes = useMemo(() => Object.fromEntries(fields.filter(f => f.editable && (values[f.id] ?? '') !== f.value).map(f => [f.id, values[f.id] ?? ''])), [fields, values])
  const dirty = Object.keys(changes).length > 0
  const load = async () => {
    const request = ++sequence.current; setError(''); setSnapshot(null)
    if (target === 'global') { setBusy(false); return }
    setBusy(true)
    try {
      const result = await api<Snapshot>(`/api/map-settings?target=${encodeURIComponent(target)}&file=${file}`)
      if (request !== sequence.current) return
      let draft: { snapshot?: Snapshot; values?: Record<string, string> } | null = null
      try { draft = JSON.parse(sessionStorage.getItem(draftKey(target, file)) ?? 'null') } catch { /* Storage is optional. */ }
      if (draft?.snapshot?.target === target && draft.snapshot.file === file && draft.values) {
        setSnapshot(draft.snapshot); setValues(draft.values)
        if (draft.snapshot.revision !== result.revision) setError('The saved settings changed. Your draft is retained; discard it and Refresh before saving.')
      } else { setSnapshot(result); setValues(valuesFrom(result)) }
    } catch (e) { if (request === sequence.current) setError(messageOf(e)) }
    finally { if (request === sequence.current) setBusy(false) }
  }
  useEffect(() => {
    let cancelled = false
    void api<Pick<Snapshot, 'targets'>>('/api/map-settings').then(catalog => { if (!cancelled) setTargets(catalog.targets ?? []) }).catch(e => { if (!cancelled) setError(messageOf(e)) })
    return () => { cancelled = true }
  }, [])
  useEffect(() => { void load(); return () => { sequence.current++ } }, [target, file])
  useEffect(() => {
    if (!matches) return
    try { if (dirty) sessionStorage.setItem(draftKey(target, file), JSON.stringify({ snapshot, values })); else sessionStorage.removeItem(draftKey(target, file)) } catch { /* In-memory edits remain available. */ }
  }, [target, file, matches, snapshot, values, dirty])
  const save = async (inherit: boolean) => {
    if (!matches || busy) return
    setBusy(true); setError(''); setMessage('')
    try {
      const result = await withOnlinePlayerGuard(force => api<Snapshot>(`/api/map-settings${force ? '?force=true' : ''}`, { method: 'PUT', body: JSON.stringify({ target, file, revision: snapshot.revision, updates: changes, inherit }) }))
      setSnapshot(result); setValues(valuesFrom(result)); setMessage(inherit ? 'This map now uses Global Custom Server Settings.' : 'Map settings saved on the VM. Pending the next battlegroup restart or scheduled maintenance through DST.')
      try { sessionStorage.removeItem(draftKey(target, file)) } catch { /* Optional storage. */ }
    } catch (e) { setError(messageOf(e)) }
    finally { setBusy(false) }
  }
  return <section className="card mb-4 space-y-4 p-5" aria-label="Server settings scope">
    <div className="flex flex-wrap gap-3">
      <label className="min-w-0 flex-[2_1_18rem]">Map<select className="block w-full min-w-0 rounded border border-border bg-surface px-3 py-2" aria-label="Map settings target" value={target} disabled={busy || disabled} onChange={e => { setTarget(e.target.value); setMessage('') }}><option value="global">Global</option>{targets.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}</select></label>
      {target === 'global' ? <label className="min-w-0 flex-[1_1_12rem]">Settings file<select aria-label="Global settings file" className="block w-full rounded border border-border bg-surface px-3 py-2" value={globalFile} disabled={disabled} onChange={e => onGlobalFileChange?.(e.target.value as 'server' | 'game' | 'engine')}><option value="server">Custom Server Settings</option><option value="game">Game.ini</option><option value="engine">Engine.ini</option></select></label> : <label className="min-w-0 flex-[1_1_12rem]">Search<input aria-label="Search map settings" className="block w-full rounded border border-border bg-surface px-3 py-2" value={query} onChange={e => setQuery(e.target.value)} /></label>}
    </div>
    {target !== 'global' && <h2 className="text-lg font-semibold">Custom Server Settings</h2>}
    {busy && <p role="status">Loading or saving map settings…</p>}
    {error && <p role="alert" className="text-danger">{error}</p>}
    {message && <p role="status" className="text-success">{message}</p>}
    {matches && <>
      {snapshot.pendingRestart && <p role="status" className="text-warning">Saved on VM · pending next DST battlegroup restart or scheduled maintenance.</p>}
      <p>{snapshot.overridden ? 'This map has its own saved file.' : 'Using inherited settings.'} {!snapshot.canSave && snapshot.saveDisabledReason}</p>
      <RetailServerSettingsRows settings={fields.filter(f => `${f.label} ${f.key} ${f.group}`.toLowerCase().includes(query.toLowerCase()))} values={values} disabled={busy || disabled}
        onChange={(key, value) => setValues(previous => ({ ...previous, [key]: value }))} />
      <p className="text-sm text-text-muted" role="status">{!snapshot.canSave ? snapshot.saveDisabledReason : dirty ? 'Save stores this map’s settings without starting or restarting the battlegroup. They apply on the next battlegroup restart or scheduled maintenance through DST.' : 'No unsaved changes.'}</p>
      <div className="flex flex-wrap gap-2">
        <button className="btn-secondary" disabled={busy || disabled} onClick={() => setValues(previous => ({ ...previous, ...Object.fromEntries(fields.filter(f => f.editable && (f.key !== 'PVPMode' || f.present === false) && RETAIL_SETTING_GUIDANCE[f.key]).map(f => [f.key, RETAIL_SETTING_GUIDANCE[f.key].defaultValue])) }))}>Default Settings</button>
        <button className="btn-primary" disabled={busy || !dirty || !snapshot.canSave} onClick={() => void save(false)}>Save map overrides{dirty ? ` (${Object.keys(changes).length})` : ''}</button>
        <button className="btn-secondary" disabled={busy || !dirty} onClick={() => { setValues(valuesFrom(snapshot)); setError('') }}>Discard changes</button>
        <button className="btn-secondary" disabled={busy || dirty} onClick={() => void load()}>Refresh</button>
        <button className="btn-secondary" disabled={busy || dirty || !snapshot.overridden || !snapshot.canSave} onClick={() => { if (window.confirm('Remove this map’s override for the selected file and inherit inherited settings?')) void save(true) }}>Use Global settings</button>
      </div>
      <details><summary>View saved map INI</summary><textarea aria-label="Saved map INI" readOnly className="min-w-0 max-w-full rounded border border-border bg-surface px-3 py-2 text-text focus:outline-none focus:ring-2 focus:ring-accent h-48 w-full font-mono" value={snapshot.raw} /></details>
    </>}
    {target !== 'global' && !busy && !targets.length && !error && <p>No supported Hagga or Deep Desert maps were found.</p>}
  </section>
}
