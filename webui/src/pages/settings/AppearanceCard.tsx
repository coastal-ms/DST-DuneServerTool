import { useRef, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  PRESETS,
  useTheme,
  getPreset,
  DEFAULT_PRESET_ID,
  THEME_SCHEMA_VERSION,
} from '../../theme/ThemeContext'
import { TOKENS, CATEGORY_LABELS, CATEGORY_ORDER, type TokenCategory } from '../../theme/tokens'

// Group tokens by category once at module load.
const TOKENS_BY_CATEGORY: Record<TokenCategory, typeof TOKENS> = {
  surface: [], text: [], accent: [], ibad: [], status: [],
}
for (const t of TOKENS) TOKENS_BY_CATEGORY[t.category].push(t)

export function AppearanceCard() {
  const t = useTheme()
  const [expanded, setExpanded] = useState(false)
  const [customizeOpen, setCustomizeOpen] = useState(false)
  const [importMsg, setImportMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const fileInputRef = useRef<HTMLInputElement | null>(null)

  const currentPreset = getPreset(t.presetId) ?? getPreset(DEFAULT_PRESET_ID)!
  const overrideCount = Object.keys(t.overrides).length
  const isCustomized = overrideCount > 0

  const onExport = () => {
    const json = t.exportJson()
    const blob = new Blob([json], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const slug = t.presetId + (isCustomized ? '-custom' : '')
    const a = document.createElement('a')
    a.href = url
    a.download = `dune-theme-${slug}.json`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }

  const onPickFile = () => fileInputRef.current?.click()

  const onFileChosen = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = '' // allow re-import of same file
    if (!file) return
    try {
      const raw = await file.text()
      const result = t.importJson(raw)
      setImportMsg({ ok: result.ok, text: result.message })
    } catch (err) {
      setImportMsg({ ok: false, text: err instanceof Error ? err.message : String(err) })
    }
    window.setTimeout(() => setImportMsg(null), 6000)
  }

  return (
    <div className="card mb-4">
      <button
        type="button"
        onClick={() => setExpanded(v => !v)}
        className="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-surface-2/40 rounded-lg transition-colors"
        aria-expanded={expanded}
      >
        <div className="flex items-center gap-3">
          <Icon name={expanded ? 'ChevronDown' : 'ChevronRight'} size={16} className="text-text-dim" />
          <Icon name="Palette" size={18} className="text-text-muted" />
          <h2 className="text-lg font-semibold">Appearance</h2>
        </div>
        <div className="flex items-center gap-2">
          <span className="pill-muted text-xs">{currentPreset.name}</span>
          {isCustomized && (
            <span className="pill-info text-xs">
              {overrideCount} custom color{overrideCount === 1 ? '' : 's'}
            </span>
          )}
        </div>
      </button>

      {expanded && (
        <div className="px-6 pb-5 space-y-5">
          <div className="flex items-start justify-between gap-3 border-t border-border pt-4">
            <p className="text-sm text-text-dim">
              Pick a preset, tweak any color, or import a theme JSON. Saved locally in your browser; xterm in the Terminal page recolors live.
            </p>
            <button
              type="button"
              onClick={t.resetToDefault}
              className="btn-secondary shrink-0"
              title="Restore Eyes of Ibad with no customizations"
            >
              <Icon name="RotateCcw" size={14} />
              Reset to default
            </button>
          </div>

          {/* --- Preset grid ------------------------------------------------ */}
          <div>
            <div className="text-xs font-semibold tracking-wider uppercase text-text-dim mb-2">Presets</div>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              {PRESETS.map(p => {
                const active = p.id === t.presetId
                return (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => t.setPreset(p.id)}
                    className={[
                      'card card-hover p-3 text-left transition-all',
                      active ? 'border-accent ring-2 ring-accent/40' : '',
                    ].join(' ')}
                    aria-pressed={active}
                  >
                    <div className="flex items-center gap-2 mb-2">
                      <div className="flex -space-x-1">
                        {p.preview.map((c, i) => (
                          <span
                            key={i}
                            className="w-5 h-5 rounded-full border border-border"
                            style={{ background: c }}
                          />
                        ))}
                      </div>
                      <div className="flex-1 font-medium text-sm">{p.name}</div>
                      {active && <Icon name="Check" size={14} className="text-accent" />}
                    </div>
                    <p className="text-xs text-text-dim leading-snug">{p.description}</p>
                  </button>
                )
              })}
            </div>
          </div>

          {/* --- Custom color overrides ------------------------------------ */}
          <div>
            <button
              type="button"
              onClick={() => setCustomizeOpen(v => !v)}
              className="w-full flex items-center justify-between text-left text-xs font-semibold tracking-wider uppercase text-text-dim hover:text-text-muted transition-colors"
              aria-expanded={customizeOpen}
            >
              <span className="flex items-center gap-2">
                <Icon name={customizeOpen ? 'ChevronDown' : 'ChevronRight'} size={12} />
                Customize colors
                {isCustomized && (
                  <span className="pill-info text-[10px]">
                    {overrideCount} edited
                  </span>
                )}
              </span>
              {isCustomized && (
                <button
                  type="button"
                  onClick={(e) => { e.stopPropagation(); t.resetAllOverrides() }}
                  className="text-xs text-text-dim hover:text-text underline normal-case font-normal tracking-normal"
                >
                  Revert all overrides
                </button>
              )}
            </button>

            {customizeOpen && (
              <div className="mt-3 space-y-4">
                {CATEGORY_ORDER.map((cat: TokenCategory) => (
                  <div key={cat}>
                    <div className="text-[11px] font-semibold uppercase tracking-wider text-text-dim mb-2">
                      {CATEGORY_LABELS[cat]}
                    </div>
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
                      {TOKENS_BY_CATEGORY[cat].map((tok: typeof TOKENS[number]) => {
                        const value = t.resolved[tok.key] ?? '#000000'
                        const isOverridden = tok.key in t.overrides
                        return (
                          <div
                            key={tok.key}
                            className={[
                              'flex items-center gap-2 p-2 rounded-lg border',
                              isOverridden ? 'border-ibad/40 bg-ibad/5' : 'border-border bg-surface-2/30',
                            ].join(' ')}
                          >
                            <input
                              type="color"
                              value={value}
                              onChange={(e) => t.setOverride(tok.key, e.target.value)}
                              className="w-9 h-9 rounded-md border border-border cursor-pointer shrink-0"
                              aria-label={tok.label}
                            />
                            <div className="flex-1 min-w-0">
                              <div className="text-sm font-medium truncate" title={tok.label}>{tok.label}</div>
                              <div className="text-[10px] font-mono text-text-dim truncate" title={tok.key}>{tok.key}</div>
                            </div>
                            <input
                              type="text"
                              value={value}
                              onChange={(e) => {
                                const v = e.target.value.trim()
                                if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(v)) t.setOverride(tok.key, v)
                              }}
                              spellCheck={false}
                              className="w-20 text-xs font-mono px-1.5 py-1 bg-base border border-border rounded text-text-muted"
                            />
                            {isOverridden && (
                              <button
                                type="button"
                                onClick={() => t.resetOverride(tok.key)}
                                title="Revert to preset value"
                                className="text-text-dim hover:text-text shrink-0"
                              >
                                <Icon name="RotateCcw" size={13} />
                              </button>
                            )}
                          </div>
                        )
                      })}
                    </div>
                  </div>
                ))}
                {tok_hint()}
              </div>
            )}
          </div>

          {/* --- Import / export -------------------------------------------- */}
          <div className="flex flex-wrap items-center gap-2 border-t border-border pt-4">
            <button type="button" onClick={onExport} className="btn-secondary">
              <Icon name="Download" size={14} />
              Export theme JSON
            </button>
            <button type="button" onClick={onPickFile} className="btn-secondary">
              <Icon name="Upload" size={14} />
              Import theme JSON
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept="application/json,.json"
              onChange={onFileChosen}
              className="hidden"
            />
            <span className="text-[10px] font-mono text-text-dim ml-auto">
              schema v{THEME_SCHEMA_VERSION}
            </span>
          </div>

          {importMsg && (
            <div className={[
              'text-sm border rounded-lg px-3 py-2 flex items-center gap-2',
              importMsg.ok ? 'border-success/40 bg-success/10 text-success' : 'border-danger/40 bg-danger/10 text-danger',
            ].join(' ')}>
              <Icon name={importMsg.ok ? 'CheckCircle2' : 'AlertCircle'} size={14} />
              {importMsg.text}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// Inline helper: small advisory under the color grid.
function tok_hint() {
  return (
    <p className="text-[11px] text-text-dim leading-snug border-t border-border pt-2">
      Tip: <span className="text-text-muted">Accent foreground</span> controls text color on primary buttons. Pick something with strong contrast against your <span className="text-text-muted">Accent</span> color.
    </p>
  )
}
