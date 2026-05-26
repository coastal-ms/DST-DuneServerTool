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
  GameConfigSection,
  GameConfigField,
  GameConfigResponse,
} from '../api/types'

type LoadState = 'idle' | 'loading' | 'ready' | 'error' | 'unavailable'

export function GameConfig() {
  const { status } = useStatus()
  const vmRunning = status?.vm?.running === true

  const [schema, setSchema] = useState<GameConfigSection[] | null>(null)
  const [cfg, setCfg] = useState<GameConfigResponse | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [originals, setOriginals] = useState<Record<string, string>>({})
  const [loadState, setLoadState] = useState<LoadState>('idle')
  const [loadError, setLoadError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [savedMsg, setSavedMsg] = useState<string | null>(null)

  // Compute combined values + originals from the fetched config + schema.
  const seedValues = useCallback((sections: GameConfigSection[], data: GameConfigResponse) => {
    const out: Record<string, string> = {}
    for (const sec of sections) {
      for (const f of sec.fields) {
        const bucket = f.file === 'game' ? data.game.values : data.engine.values
        out[f.key] = bucket?.[f.key] ?? ''
      }
    }
    return out
  }, [])

  const loadAll = useCallback(async () => {
    setLoadState('loading')
    setLoadError(null)
    setSavedMsg(null)
    try {
      // Schema is always available (no SSH). Fetch it once.
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
      // Detect 503 (VM not running etc.) vs hard failure
      setLoadState(/\b503\b/.test(msg) ? 'unavailable' : 'error')
    }
  }, [schema, seedValues])

  // Initial mount: fetch schema even if VM is offline so the form can render
  // with all fields disabled. Only fetch live values when VM is running.
  useEffect(() => {
    void (async () => {
      if (!schema) {
        try {
          const s = await getGameConfigSchema()
          setSchema(s.schema)
        } catch (e) {
          setLoadError(e instanceof Error ? e.message : String(e))
          setLoadState('error')
          return
        }
      }
      if (vmRunning) {
        void loadAll()
      } else {
        setLoadState('unavailable')
        setLoadError('VM is not running. Start the battlegroup to load live values.')
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
      setCfg({ available: true, source: out.source, game: out.game, engine: out.engine })
      const seeded = seedValues(schema ?? [], { available: true, source: out.source, game: out.game, engine: out.engine })
      setValues(seeded)
      setOriginals(seeded)
      const n = (out.applied?.game ?? 0) + (out.applied?.engine ?? 0)
      setSavedMsg(`Saved ${n} change${n === 1 ? '' : 's'}.`)
      window.setTimeout(() => setSavedMsg(null), 4000)
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
        description="UserGame.ini + UserEngine.ini editor — writes back to the live BG PVC."
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

      {/* Status / error banners */}
      {loadState === 'unavailable' && (
        <div className="card p-4 mb-4 border-warning/40 bg-warning/10 text-warning text-sm flex items-start gap-2">
          <Icon name="AlertTriangle" size={16} className="mt-0.5 shrink-0" />
          <div>
            <div className="font-medium">{loadError ?? 'Game config unavailable.'}</div>
            <div className="text-xs text-text-muted mt-0.5">Form is read-only until the VM is up.</div>
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

      {/* Form */}
      {!schema && loadState === 'loading' && (
        <div className="card p-8 text-text-muted flex items-center gap-2">
          <Icon name="Loader2" size={14} className="animate-spin" /> Loading schema…
        </div>
      )}
      {schema && (
        <form onSubmit={onSubmit}>
          <div className="space-y-5">
            {schema.map(sec => (
              <SectionCard key={sec.section} section={sec}>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-4">
                  {sec.fields.map(f => (
                    <FieldRow
                      key={f.key}
                      field={f}
                      value={values[f.key] ?? ''}
                      onChange={v => setValues(prev => ({ ...prev, [f.key]: v }))}
                      disabled={loadState !== 'ready' || saving}
                      isDirty={(values[f.key] ?? '') !== (originals[f.key] ?? '')}
                    />
                  ))}
                </div>
              </SectionCard>
            ))}
          </div>

          <div className="sticky bottom-0 mt-6 -mx-6 px-6 py-3 bg-surface/95 border-t border-border backdrop-blur-sm flex items-center justify-between">
            <div className="text-xs text-text-muted flex items-center gap-4">
              {cfg && (
                <>
                  <span className="font-mono truncate max-w-md" title={cfg.game.path}>game: {cfg.game.path}</span>
                  <span className="font-mono truncate max-w-md" title={cfg.engine.path}>engine: {cfg.engine.path}</span>
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
    </>
  )
}

// -----------------------------------------------------------------------------
// Section card + field row
// -----------------------------------------------------------------------------

function SectionCard({ section, children }: { section: GameConfigSection; children: React.ReactNode }) {
  return (
    <div className="card p-5">
      <h2 className="text-sm font-semibold uppercase tracking-wider text-accent-bright mb-4 flex items-center gap-2">
        <Icon name="ChevronRight" size={14} /> {section.section}
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
}

function FieldRow({ field, value, onChange, disabled, isDirty }: FieldRowProps) {
  const inputBase =
    'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm ' +
    'placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 ' +
    'disabled:opacity-50 disabled:cursor-not-allowed'

  const wide = field.wide

  return (
    <div className={wide ? 'md:col-span-2' : ''}>
      <label className="flex items-center justify-between text-sm font-medium mb-1.5">
        <span className="flex items-center gap-2">
          {field.label}
          {isDirty && <span className="w-1.5 h-1.5 rounded-full bg-ibad" title="Modified" />}
        </span>
        <span className="text-[10px] font-mono text-text-dim uppercase tracking-wider">
          {field.file}
        </span>
      </label>

      {field.type === 'select' && field.options ? (
        <select
          value={value}
          disabled={disabled}
          onChange={e => onChange(e.target.value)}
          className={inputBase}
        >
          <option value="">(unset)</option>
          {field.options.map(o => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      ) : field.type === 'number' ? (
        <div className="flex items-center gap-2">
          <input
            type="number"
            value={value}
            disabled={disabled}
            placeholder={field.placeholder ?? ''}
            step={field.step ?? undefined}
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
        {field.hint && <p className="text-xs text-text-dim">{field.hint}</p>}
        <span className="text-[10px] font-mono text-text-dim ml-auto truncate">{field.key}</span>
      </div>
    </div>
  )
}
