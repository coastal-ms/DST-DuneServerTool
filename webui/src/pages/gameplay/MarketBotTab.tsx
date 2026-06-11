import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getBotStatus, getBotConfig, saveBotConfig,
  type BotStatus, type BotConfig,
} from '../../api/gameplay'
import { fmtSolari, fmtNum, fmtUptime, SourceBadge } from './shared'

export function MarketBotTab() {
  const [status, setStatus] = useState<BotStatus | null>(null)
  const [config, setConfig] = useState<BotConfig | null>(null)
  const [draft, setDraft] = useState<BotConfig | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saveMsg, setSaveMsg] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [s, c] = await Promise.all([getBotStatus(), getBotConfig()])
      setStatus(s)
      setConfig(c)
      setDraft(structuredClone(c))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  // Poll status while the tab is open (config is left untouched).
  useEffect(() => {
    const id = window.setInterval(() => {
      getBotStatus().then(setStatus).catch(() => {})
    }, 10000)
    return () => window.clearInterval(id)
  }, [])

  const configured = config?.configured !== false && status?.configured !== false
  const dirty = JSON.stringify(config) !== JSON.stringify(draft)

  const save = async () => {
    if (!draft) return
    setSaving(true)
    setSaveMsg(null)
    setError(null)
    try {
      const saved = await saveBotConfig(draft)
      setConfig(saved)
      setDraft(structuredClone(saved))
      setSaveMsg('Configuration saved to the bot.')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  if (loading && !status) {
    return <div className="text-text-dim py-8 text-center"><Icon name="Loader2" size={20} className="animate-spin inline" /> Loading bot…</div>
  }

  return (
    <div>
      {!configured && (
        <div className="card p-3 mb-4 text-xs text-text-muted border-l-2 border-accent flex items-start gap-2">
          <Icon name="Info" size={14} className="text-accent shrink-0 mt-0.5" />
          <span>
            No market bot is configured. Set <span className="font-mono text-accent">MarketBotAddr</span> and{' '}
            <span className="font-mono text-accent">MarketBotToken</span> in your config to manage a live Revy bot.
            The values below are a sample configuration.
          </span>
        </div>
      )}

      {/* Status */}
      <section className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        <div className="card p-3">
          <div className="flex items-center justify-between">
            <span className="text-xs uppercase tracking-wider text-text-dim">Bot state</span>
            <Icon name="Bot" size={15} className={status?.running ? 'text-success' : 'text-text-muted'} />
          </div>
          <div className={`mt-1 text-xl font-semibold ${status?.running ? 'text-success' : 'text-text-muted'}`}>
            {status?.running ? 'Running' : 'Stopped'}
          </div>
          {status?.uptime ? <div className="text-[11px] text-text-dim">up {fmtUptime(status.uptime)}</div> : null}
        </div>
        <StatCard label="Listings" value={fmtNum(status?.listing_count)} icon="Tags" />
        <StatCard label="Balance" value={status?.balance !== undefined ? fmtSolari(status.balance) : '—'} icon="Coins" />
        <StatCard label="Errors" value={fmtNum(status?.error_count ?? 0)} icon="TriangleAlert"
          tone={status?.error_count ? 'text-danger' : 'text-text'} />
      </section>

      {status?.error && (
        <div className="card p-3 mb-4 text-sm text-danger break-words">
          <span className="font-semibold">Bot error:</span> {status.error}
        </div>
      )}

      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
          <Icon name="Sliders" size={14} className="text-accent" /> Pricing &amp; tuning
        </h3>
        <div className="flex items-center gap-2">
          <SourceBadge source={config?.source} />
          <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
            <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        </div>
      </div>

      {draft && (
        <div className="space-y-4">
          {/* Core toggles + intervals */}
          <div className="card p-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            <Toggle label="Bot enabled" checked={draft.enabled}
              onChange={v => setDraft({ ...draft, enabled: v })} disabled={!configured} />
            <NumField label="List tick (s)" value={draft.list_tick_interval}
              onChange={v => setDraft({ ...draft, list_tick_interval: v })} disabled={!configured} />
            <NumField label="Buy tick (s)" value={draft.buy_tick_interval}
              onChange={v => setDraft({ ...draft, buy_tick_interval: v })} disabled={!configured} />
            <NumField label="Buy threshold" step={0.01} value={draft.buy_threshold}
              onChange={v => setDraft({ ...draft, buy_threshold: v })} disabled={!configured} />
            <NumField label="Max buys / tick" value={draft.max_buys_per_tick}
              onChange={v => setDraft({ ...draft, max_buys_per_tick: v })} disabled={!configured} />
            <NumField label="Listings / grade" value={draft.listings_per_grade}
              onChange={v => setDraft({ ...draft, listings_per_grade: v })} disabled={!configured} />
          </div>

          {/* Rarity multipliers */}
          <div className="card p-4">
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-3">Rarity price multipliers</h4>
            <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
              {Object.entries(draft.rarity_multipliers ?? {}).map(([rarity, mult]) => (
                <NumField key={rarity} label={rarity} step={0.05} value={mult} disabled={!configured}
                  onChange={v => setDraft({ ...draft, rarity_multipliers: { ...draft.rarity_multipliers, [rarity]: v } })} />
              ))}
            </div>
          </div>

          {/* Grade multipliers */}
          <div className="card p-4">
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1">Grade multipliers</h4>
            <p className="text-[11px] text-text-dim mb-2">Comma-separated, one per item grade (low → high).</p>
            <input type="text" disabled={!configured}
              value={(draft.grade_multipliers ?? []).join(', ')}
              onChange={e => {
                const arr = e.target.value.split(',').map(s => parseFloat(s.trim())).filter(n => !Number.isNaN(n))
                setDraft({ ...draft, grade_multipliers: arr })
              }}
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad disabled:opacity-50" />
          </div>

          {/* Disabled items */}
          <div className="card p-4">
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1">Disabled items</h4>
            <p className="text-[11px] text-text-dim mb-2">Template IDs the bot will never list or buy. One per line.</p>
            <textarea rows={4} disabled={!configured}
              value={(draft.disabled_items ?? []).join('\n')}
              onChange={e => setDraft({ ...draft, disabled_items: e.target.value.split('\n').map(s => s.trim()).filter(Boolean) })}
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad disabled:opacity-50" />
          </div>

          {/* Actions */}
          <div className="flex items-center gap-3">
            <button className="btn-primary" disabled={!configured || !dirty || saving} onClick={() => { void save() }}>
              <Icon name={saving ? 'Loader2' : 'Save'} size={15} className={saving ? 'animate-spin' : ''} /> Save config
            </button>
            <button className="btn-secondary" disabled={!dirty || saving} onClick={() => setDraft(structuredClone(config))}>
              Reset
            </button>
            {saveMsg && <span className="text-xs text-success">{saveMsg}</span>}
            {error && <span className="text-xs text-danger break-words">{error}</span>}
          </div>

          <p className="text-[11px] text-text-dim flex items-center gap-1.5">
            <Icon name="Info" size={12} />
            Lifecycle control (start / stop / restart) isn't wired in this build — manage the bot service directly for now.
          </p>
        </div>
      )}
    </div>
  )
}

function StatCard({ label, value, icon, tone }: { label: string; value: string; icon: string; tone?: string }) {
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between">
        <span className="text-xs uppercase tracking-wider text-text-dim">{label}</span>
        <Icon name={icon} size={15} className="text-accent" />
      </div>
      <div className={`mt-1 text-xl font-semibold truncate ${tone ?? 'text-text'}`}>{value}</div>
    </div>
  )
}

function NumField({ label, value, onChange, step, disabled }: {
  label: string; value: number; onChange: (v: number) => void; step?: number; disabled?: boolean
}) {
  return (
    <label className="block">
      <span className="block text-[11px] uppercase tracking-wider text-text-dim mb-1 capitalize">{label}</span>
      <input type="number" value={value} step={step ?? 1} disabled={disabled}
        onChange={e => onChange(parseFloat(e.target.value))}
        className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad disabled:opacity-50" />
    </label>
  )
}

function Toggle({ label, checked, onChange, disabled }: {
  label: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean
}) {
  return (
    <label className="flex items-center justify-between gap-3 cursor-pointer">
      <span className="text-sm text-text">{label}</span>
      <button type="button" role="switch" aria-checked={checked} disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative w-10 h-6 rounded-full transition-colors disabled:opacity-50 ${checked ? 'bg-accent' : 'bg-surface-3'}`}>
        <span className={`absolute top-0.5 left-0.5 w-5 h-5 rounded-full bg-text transition-transform ${checked ? 'translate-x-4' : ''}`} />
      </button>
    </label>
  )
}
