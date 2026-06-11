import { useState, useEffect, useMemo, useCallback, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import {
  getGameConfigSchema,
  getGameConfig,
  saveGameConfig,
} from '../api/gameconfig'
import type {
  GameConfigCategory,
  GameConfigField,
  GameConfigResponse,
  GameConfigFileBundle,
  GameConfigIniSection,
} from '../api/types'
import { SpicefieldsCard } from './gameconfig/SpicefieldsCard'

type LoadState = 'idle' | 'loading' | 'ready' | 'error' | 'unavailable'

const SANDWORM_ENABLED_KEY = 'sandworm.dune.Enabled'

// Bool literal pairs per type so toggles emit exactly what UE expects.
function boolPair(type: GameConfigField['type']): { on: string; off: string } | null {
  if (type === 'bool') return { on: 'True', off: 'False' }
  if (type === 'boolLower') return { on: 'true', off: 'false' }
  if (type === 'bool01') return { on: '1', off: '0' }
  return null
}

function bundleFor(data: GameConfigResponse, file: 'game' | 'engine'): GameConfigFileBundle {
  return file === 'game' ? data.game : data.engine
}

function fieldDefault(field: GameConfigField): string {
  return field.default ?? ''
}

// Live value written in the battlegroup's INI for this field ('' when unset or VM down).
function liveValue(data: GameConfigResponse | null, field: GameConfigField): string {
  if (!data) return ''
  return bundleFor(data, field.file).effective?.[`${field.section}||${field.key}`] ?? ''
}

// A field is "customized" when the live file overrides it with a value other than the default.
function isCustomized(data: GameConfigResponse | null, field: GameConfigField): boolean {
  const lv = liveValue(data, field)
  return lv !== '' && lv !== fieldDefault(field)
}

// The value an input should hold: the live override when present, otherwise the default.
function currentValue(data: GameConfigResponse | null, field: GameConfigField): string {
  const lv = liveValue(data, field)
  return lv !== '' ? lv : fieldDefault(field)
}

function sectionIsManaged(data: GameConfigResponse, field: GameConfigField): boolean {
  return bundleFor(data, field.file).managedSections?.includes(field.section) ?? false
}

export function GameConfig() {
  const { status } = useStatus()
  const vmRunning = status?.vm?.running === true

  const [schema, setSchema] = useState<GameConfigCategory[] | null>(null)
  const [cfg, setCfg] = useState<GameConfigResponse | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [originals, setOriginals] = useState<Record<string, string>>({})
  const [loadState, setLoadState] = useState<LoadState>('idle')
  const [loadError, setLoadError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [savedMsg, setSavedMsg] = useState<string | null>(null)
  const [sandwormModalOpen, setSandwormModalOpen] = useState(false)
  const [search, setSearch] = useState('')

  const handleFieldChange = useCallback((key: string, newVal: string) => {
    if (
      key === SANDWORM_ENABLED_KEY &&
      newVal === '1' &&
      (values[key] ?? '') !== '1'
    ) {
      setSandwormModalOpen(true)
      return
    }
    setValues(prev => ({ ...prev, [key]: newVal }))
  }, [values])

  const confirmSandwormEnable = useCallback(() => {
    setValues(prev => ({ ...prev, [SANDWORM_ENABLED_KEY]: '1' }))
    setSandwormModalOpen(false)
  }, [])

  // Seed editable values: live override when present, otherwise the funcom default,
  // so every field is populated even before (or without) a live battlegroup.
  const seedValues = useCallback((cats: GameConfigCategory[], data: GameConfigResponse | null) => {
    const out: Record<string, string> = {}
    for (const cat of cats) {
      for (const f of cat.fields) out[f.key] = currentValue(data, f)
    }
    return out
  }, [])

  const loadAll = useCallback(async () => {
    setLoadState('loading')
    setLoadError(null)
    setSavedMsg(null)
    try {
      const sch = schema ?? (await getGameConfigSchema()).schema
      if (!schema) setSchema(sch)
      const data = await getGameConfig()
      setCfg(data)
      const seeded = seedValues(sch, data)
      setValues(seeded)
      setOriginals(seeded)
      setLoadState('ready')
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      setLoadError(msg)
      setLoadState(/\b503\b/.test(msg) ? 'unavailable' : 'error')
    }
  }, [schema, seedValues])

  useEffect(() => {
    void (async () => {
      let s = schema
      if (!s) {
        try {
          const resp = await getGameConfigSchema()
          s = resp.schema
          setSchema(s)
        } catch (e) {
          setLoadError(e instanceof Error ? e.message : String(e))
          setLoadState('error')
          return
        }
      }
      if (vmRunning) {
        void loadAll()
      } else {
        // No live battlegroup: populate every field with its funcom default so the
        // form is readable. Editing/saving is gated until the VM is up.
        const seeded = seedValues(s, null)
        setValues(seeded)
        setOriginals(seeded)
        setCfg(null)
        setLoadState('unavailable')
        setLoadError('Showing Funcom defaults — start the battlegroup to load live values and edit.')
      }
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vmRunning])

  const dirtyKeys = useMemo(() => {
    const keys: string[] = []
    for (const k of Object.keys(values)) {
      if ((values[k] ?? '') !== (originals[k] ?? '')) keys.push(k)
    }
    return keys
  }, [values, originals])

  const filteredSchema = useMemo(() => {
    if (!schema) return null
    const q = search.trim().toLowerCase()
    if (!q) return schema
    return schema
      .map(cat => ({
        category: cat.category,
        fields: cat.fields.filter(
          f =>
            f.label.toLowerCase().includes(q) ||
            f.key.toLowerCase().includes(q) ||
            (f.help ?? '').toLowerCase().includes(q) ||
            cat.category.toLowerCase().includes(q),
        ),
      }))
      .filter(cat => cat.fields.length > 0)
  }, [schema, search])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (dirtyKeys.length === 0) return
    setSaving(true)
    setSaveError(null)
    setSavedMsg(null)
    try {
      const updates: Record<string, string> = {}
      for (const k of dirtyKeys) updates[k] = values[k] ?? ''
      const out = await saveGameConfig(updates)
      const next: GameConfigResponse = { available: true, source: out.source, game: out.game, engine: out.engine }
      setCfg(next)
      const seeded = seedValues(schema ?? [], next)
      setValues(seeded)
      setOriginals(seeded)
      const n = out.applied ?? dirtyKeys.length
      setSavedMsg(`Saved ${n} change${n === 1 ? '' : 's'} into the DST-managed block.`)
      window.setTimeout(() => setSavedMsg(null), 5000)
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : String(err))
    } finally {
      setSaving(false)
    }
  }

  function resetDirty() {
    setValues(originals)
    setSaveError(null)
    setSavedMsg(null)
  }

  const sourcePill = cfg && (
    <span
      className={
        cfg.source === 'live' ? 'pill-success' :
        cfg.source === 'cache' ? 'pill-info' : 'pill-warning'
      }
      title={cfg.source === 'template'
        ? 'No live BG yet — values from setup templates.'
        : cfg.source === 'cache'
          ? 'Paths cached from a prior request this session.'
          : 'Values from the live BG PVC.'}
    >
      <Icon
        name={cfg.source === 'live' ? 'CircleCheck' : cfg.source === 'cache' ? 'Info' : 'AlertTriangle'}
        size={12}
      />
      {cfg.source === 'live' ? 'Live' : cfg.source === 'cache' ? 'Cached' : 'Template'}
    </span>
  )

  return (
    <>
      <PageHeader
        title="Game Config"
        icon="Sliders"
        description="UserGame.ini + UserEngine.ini editor. Edits are tracked in a DST-managed block written to the live battlegroup."
        actions={
          <div className="flex items-center gap-2">
            {sourcePill}
            <button
              type="button"
              onClick={() => void loadAll()}
              disabled={!vmRunning || loadState === 'loading' || saving}
              className="btn-secondary"
              title="Re-fetch values from the VM"
            >
              <Icon name={loadState === 'loading' ? 'Loader2' : 'RefreshCw'} size={14} className={loadState === 'loading' ? 'animate-spin' : ''} />
              Refresh
            </button>
          </div>
        }
      />

      {/* How-it-works note */}
      <div className="card p-3 mb-4 border-border bg-surface-2/40 text-xs text-text-muted flex items-start gap-2">
        <Icon name="Info" size={14} className="mt-0.5 shrink-0 text-accent-bright" />
        <div>
          When you change a setting, DST relocates that setting&apos;s entire section into a managed block at the
          bottom of the file and becomes its owner — keeping one clean copy, preserving structure, and migrating
          any existing dune-admin block. The original file is backed up on the server before every write.
        </div>
      </div>

      {/* Status / error banners */}
      {loadState === 'unavailable' && (
        <div className="card p-4 mb-4 border-accent/30 bg-accent/5 text-text-muted text-sm flex items-start gap-2">
          <Icon name="Info" size={16} className="mt-0.5 shrink-0 text-accent-bright" />
          <div>
            <div className="font-medium text-text">{loadError ?? 'Showing Funcom defaults.'}</div>
            <div className="text-xs text-text-muted mt-0.5">Every setting below shows its default value. Editing and saving are enabled once the battlegroup is running.</div>
          </div>
        </div>
      )}
      {loadState === 'error' && loadError && (
        <div className="card p-4 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {loadError}
        </div>
      )}
      {saveError && (
        <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {saveError}
        </div>
      )}
      {savedMsg && (
        <div className="card p-3 mb-4 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
          <Icon name="CheckCircle2" size={14} /> {savedMsg}
        </div>
      )}

      {!schema && loadState === 'loading' && (
        <div className="card p-8 text-text-muted flex items-center gap-2">
          <Icon name="Loader2" size={14} className="animate-spin" /> Loading schema…
        </div>
      )}

      {schema && (
        <form onSubmit={onSubmit}>
          {/* Search */}
          <div className="relative mb-4">
            <Icon name="Search" size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim" />
            <input
              type="text"
              value={search}
              onChange={e => setSearch(e.target.value)}
              placeholder="Filter settings…"
              className="w-full pl-9 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
          </div>

          <div className="space-y-5">
            {(filteredSchema ?? []).map(cat => (
              <CategoryCard key={cat.category} category={cat.category} count={cat.fields.length}>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-4">
                  {cat.fields.map(f => (
                    <FieldRow
                      key={`${f.section}||${f.key}`}
                      field={f}
                      value={values[f.key] ?? ''}
                      onChange={v => handleFieldChange(f.key, v)}
                      disabled={loadState !== 'ready' || saving}
                      isDirty={(values[f.key] ?? '') !== (originals[f.key] ?? '')}
                      isSet={liveValue(cfg, f) !== ''}
                      isCustom={isCustomized(cfg, f)}
                      defaultValue={fieldDefault(f)}
                      managed={cfg ? sectionIsManaged(cfg, f) : false}
                    />
                  ))}
                </div>
              </CategoryCard>
            ))}
            {filteredSchema && filteredSchema.length === 0 && (
              <div className="card p-6 text-text-muted text-sm">No settings match “{search}”.</div>
            )}

            <SpicefieldsCard vmRunning={vmRunning} />

            {cfg && <AdvancedIniBrowser cfg={cfg} />}
          </div>

          <div className="sticky bottom-0 mt-6 -mx-6 px-6 py-3 bg-surface/95 border-t border-border backdrop-blur-sm flex items-center justify-between">
            <div className="text-xs text-text-muted flex items-center gap-4">
              {cfg && (
                <>
                  <span className="font-mono truncate max-w-xs" title={cfg.game.path}>game: {cfg.game.path}</span>
                  <span className="font-mono truncate max-w-xs" title={cfg.engine.path}>engine: {cfg.engine.path}</span>
                </>
              )}
            </div>
            <div className="flex items-center gap-2">
              <span className="text-xs text-text-muted">
                {dirtyKeys.length === 0 ? 'No changes' : `${dirtyKeys.length} change${dirtyKeys.length === 1 ? '' : 's'}`}
              </span>
              <button
                type="button"
                onClick={resetDirty}
                disabled={dirtyKeys.length === 0 || saving}
                className="btn-secondary"
              >
                <Icon name="Undo2" size={14} /> Discard
              </button>
              <button
                type="submit"
                disabled={dirtyKeys.length === 0 || saving || loadState !== 'ready'}
                className="btn-primary"
              >
                <Icon name={saving ? 'Loader2' : 'Save'} size={15} className={saving ? 'animate-spin' : ''} />
                {saving ? 'Saving…' : 'Save'}
              </button>
            </div>
          </div>
        </form>
      )}

      <SandwormConfirmModal
        open={sandwormModalOpen}
        onCancel={() => setSandwormModalOpen(false)}
        onConfirm={confirmSandwormEnable}
      />
    </>
  )
}

// -----------------------------------------------------------------------------
// Category card + field row
// -----------------------------------------------------------------------------

function CategoryCard({ category, count, children }: { category: string; count: number; children: React.ReactNode }) {
  return (
    <div className="card p-5">
      <h2 className="text-sm font-semibold uppercase tracking-wider text-accent-bright mb-4 flex items-center gap-2">
        <Icon name="ChevronRight" size={14} /> {category}
        <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">({count})</span>
      </h2>
      {children}
    </div>
  )
}

type FieldRowProps = {
  field: GameConfigField
  value: string
  onChange: (v: string) => void
  disabled: boolean
  isDirty: boolean
  isSet: boolean
  isCustom: boolean
  defaultValue: string
  managed: boolean
}

// Human-friendly rendering of a raw default value for the grayed "Default:" line.
function formatDefaultDisplay(field: GameConfigField, def: string): string {
  if (def === '') return '(unset)'
  if (field.type === 'select' && field.options) {
    const opt = field.options.find(o => o.value === def)
    return opt ? opt.label : def
  }
  const pair = boolPair(field.type)
  if (pair) return def === pair.on ? 'On' : def === pair.off ? 'Off' : def
  return def
}

function FieldRow({ field, value, onChange, disabled, isDirty, isSet, isCustom, defaultValue, managed }: FieldRowProps) {
  const inputBase =
    'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm ' +
    'placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 ' +
    'disabled:opacity-50 disabled:cursor-not-allowed'

  const pair = boolPair(field.type)
  const isNumber = field.type === 'int' || field.type === 'float'
  const wide = field.wide

  return (
    <div className={wide ? 'md:col-span-2' : ''}>
      <label className="flex items-center justify-between text-sm font-medium mb-1.5 gap-2">
        <span className="flex items-center gap-2 min-w-0">
          <span className="truncate">{field.label}</span>
          {isDirty && <span className="w-1.5 h-1.5 rounded-full bg-ibad shrink-0" title="Modified" />}
        </span>
        <span className="flex items-center gap-1 shrink-0">
          {managed && (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/15 text-accent-bright" title="DST owns this section in the managed block">
              DST
            </span>
          )}
          {isCustom ? (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-ibad/15 text-ibad" title="This value overrides the Funcom default">
              Custom
            </span>
          ) : isSet && !managed ? (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-muted" title="Currently set in the file (matches default)">
              Set
            </span>
          ) : (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-dim" title="Using the Funcom default value">
              Default
            </span>
          )}
          <span className="text-[10px] font-mono text-text-dim uppercase tracking-wider">{field.file}</span>
        </span>
      </label>

      {/* When this field overrides the default, show the uneditable default beneath the name. */}
      {isCustom && (
        <div className="mb-1.5 text-[11px] text-text-dim flex items-center gap-1.5" title="Funcom default — read-only">
          <Icon name="CornerDownRight" size={11} className="shrink-0 opacity-60" />
          <span>Default:</span>
          <span className="font-mono">{formatDefaultDisplay(field, defaultValue)}</span>
        </div>
      )}

      {field.type === 'select' && field.options ? (
        <select value={value} disabled={disabled} onChange={e => onChange(e.target.value)} className={inputBase}>
          <option value="">(unset)</option>
          {field.options.map(o => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      ) : pair ? (
        <BoolToggle on={pair.on} off={pair.off} value={value} disabled={disabled} onChange={onChange} />
      ) : isNumber ? (
        <div className="flex items-center gap-2">
          <input
            type="number"
            value={value}
            disabled={disabled}
            placeholder={field.placeholder ?? ''}
            step={field.type === 'float' ? 'any' : 1}
            min={field.min ?? undefined}
            max={field.max ?? undefined}
            onChange={e => onChange(e.target.value)}
            className={inputBase + ' font-mono'}
          />
          {field.unit && <span className="text-xs text-text-muted shrink-0">{field.unit}</span>}
        </div>
      ) : (
        <input
          type="text"
          value={value}
          disabled={disabled}
          placeholder={field.placeholder ?? ''}
          onChange={e => onChange(e.target.value)}
          className={inputBase + ' font-mono'}
        />
      )}

      <div className="mt-1 flex items-center justify-between gap-2">
        {field.help && <p className="text-xs text-text-dim">{field.help}</p>}
        <span className="text-[10px] font-mono text-text-dim ml-auto truncate" title={`${field.section} / ${field.key}`}>{field.key}</span>
      </div>
    </div>
  )
}

function BoolToggle({ on, off, value, disabled, onChange }: { on: string; off: string; value: string; disabled: boolean; onChange: (v: string) => void }) {
  const isOn = value === on
  const isOff = value === off
  const btn = 'flex-1 px-3 py-2 text-sm font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed'
  return (
    <div className="flex items-center gap-2">
      <button
        type="button"
        disabled={disabled}
        onClick={() => onChange(off)}
        className={btn + ' ' + (isOff ? 'bg-danger/20 text-danger border border-danger/40' : 'bg-surface-2 border border-border text-text-muted')}
      >
        Off
      </button>
      <button
        type="button"
        disabled={disabled}
        onClick={() => onChange(on)}
        className={btn + ' ' + (isOn ? 'bg-success/20 text-success border border-success/40' : 'bg-surface-2 border border-border text-text-muted')}
      >
        On
      </button>
    </div>
  )
}

// -----------------------------------------------------------------------------
// Advanced / raw INI browser (read-only) — shows everything in both files,
// including keys DST has no curated control for, with managed-block badges.
// -----------------------------------------------------------------------------

function AdvancedIniBrowser({ cfg }: { cfg: GameConfigResponse }) {
  const [open, setOpen] = useState(false)
  const [file, setFile] = useState<'game' | 'engine'>('game')
  const [showRaw, setShowRaw] = useState(false)

  const bundle = file === 'game' ? cfg.game : cfg.engine

  return (
    <div className="card p-5">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between text-sm font-semibold uppercase tracking-wider text-accent-bright"
      >
        <span className="flex items-center gap-2">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} /> Advanced — full INI contents
        </span>
        <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">read-only</span>
      </button>

      {open && (
        <div className="mt-4">
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-1 bg-surface-2 rounded-lg p-0.5">
              {(['game', 'engine'] as const).map(f => (
                <button
                  key={f}
                  type="button"
                  onClick={() => setFile(f)}
                  className={'px-3 py-1.5 text-xs font-medium rounded-md ' + (file === f ? 'bg-accent/20 text-accent-bright' : 'text-text-muted')}
                >
                  {f === 'game' ? 'UserGame.ini' : 'UserEngine.ini'}
                </button>
              ))}
            </div>
            <button type="button" onClick={() => setShowRaw(r => !r)} className="btn-ghost px-2 py-1 text-xs">
              <Icon name="Code" size={13} /> {showRaw ? 'Sections' : 'Raw text'}
            </button>
          </div>

          {showRaw ? (
            <pre className="text-[11px] font-mono text-text-muted bg-surface-2 rounded-lg p-3 overflow-x-auto max-h-[28rem] overflow-y-auto whitespace-pre">
              {bundle.raw}
            </pre>
          ) : (
            <div className="space-y-3 max-h-[28rem] overflow-y-auto pr-1">
              {bundle.sections.map((s, i) => (
                <IniSectionBlock key={`${s.name}-${i}`} section={s} />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function IniSectionBlock({ section }: { section: GameConfigIniSection }) {
  return (
    <div className="border border-border rounded-lg overflow-hidden">
      <div className="flex items-center justify-between px-3 py-2 bg-surface-2">
        <span className="font-mono text-xs text-text truncate" title={section.name}>[{section.name}]</span>
        {section.managed && (
          <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/15 text-accent-bright shrink-0">
            DST-managed
          </span>
        )}
      </div>
      <div className="divide-y divide-border/60">
        {section.keys.length === 0 && (
          <div className="px-3 py-1.5 text-[11px] text-text-dim">(no keys)</div>
        )}
        {section.keys.map((k, i) => (
          <div key={`${k.key}-${i}`} className="px-3 py-1.5 flex items-start gap-2 text-[11px] font-mono">
            <span className="text-text-muted shrink-0">
              {k.isArray && <span className="text-warning mr-1" title="Array entry (+/-)">[]</span>}
              {k.key}
            </span>
            <span className="text-text-dim">=</span>
            <span className="text-text break-all">{k.value}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

// -----------------------------------------------------------------------------
// Sandworm-enable confirmation modal
// -----------------------------------------------------------------------------

function SandwormConfirmModal({
  open, onCancel, onConfirm,
}: {
  open: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  const [text, setText] = useState('')

  useEffect(() => { if (!open) setText('') }, [open])

  if (!open) return null

  const ok = text.trim().toLowerCase() === 'i confirm'

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={onCancel}
    >
      <div
        className="card p-0 max-w-md w-full"
        onClick={e => e.stopPropagation()}
      >
        <div className="px-5 py-4 border-b border-border flex items-center justify-between">
          <h3 className="font-semibold text-text flex items-center gap-2">
            <Icon name="AlertTriangle" size={16} className="text-warning" />
            Enable Sandworms?
          </h3>
          <button type="button" className="btn-ghost px-2 py-1" onClick={onCancel}>
            <Icon name="X" size={16} />
          </button>
        </div>

        <div className="px-5 py-4 space-y-4">
          <div className="text-sm text-text leading-relaxed">
            When this is enabled, all sandworm areas should be clear of items
            you want to keep.{' '}
            <span className="font-semibold text-danger">Irreversible.</span>
          </div>

          <div>
            <label className="block text-xs uppercase tracking-wider text-text-muted mb-1.5">
              Type <span className="font-mono text-text">i confirm</span> to proceed
            </label>
            <input
              type="text"
              autoFocus
              value={text}
              onChange={e => setText(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter' && ok) { e.preventDefault(); onConfirm() }
                if (e.key === 'Escape') { e.preventDefault(); onCancel() }
              }}
              placeholder="i confirm"
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm
                         font-mono placeholder:text-text-dim focus:outline-none focus:ring-2
                         focus:ring-warning focus:border-warning/50"
            />
          </div>
        </div>

        <div className="px-5 py-3 border-t border-border flex items-center justify-end gap-2">
          <button type="button" className="btn-secondary" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            disabled={!ok}
            onClick={onConfirm}
            className="btn-primary"
          >
            <Icon name="AlertTriangle" size={14} />
            Enable Sandworms
          </button>
        </div>
      </div>
    </div>
  )
}
