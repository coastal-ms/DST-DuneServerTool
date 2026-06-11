import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getBotStatus, getBotConfig, saveBotConfig, runBotTick, botExec, setBotBalance, clearBotListings,
  type BotStatus, type BotConfig, type BotTickResult,
} from '../../api/gameplay'
import { fmtSolari, fmtNum, SourceBadge } from './shared'

export function MarketBotTab() {
  const [status, setStatus] = useState<BotStatus | null>(null)
  const [config, setConfig] = useState<BotConfig | null>(null)
  const [draft, setDraft] = useState<BotConfig | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saveMsg, setSaveMsg] = useState<string | null>(null)
  const [tick, setTick] = useState<BotTickResult | null>(null)
  const [ticking, setTicking] = useState(false)
  const [balanceBusy, setBalanceBusy] = useState(false)
  const [clearing, setClearing] = useState(false)

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

  // Poll status while the tab is open (config draft is left untouched).
  useEffect(() => {
    const id = window.setInterval(() => {
      getBotStatus().then(setStatus).catch(() => {})
    }, 10000)
    return () => window.clearInterval(id)
  }, [])

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
      setSaveMsg('Configuration saved.')
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  const toggleEnabled = async (v: boolean) => {
    setError(null)
    try {
      await botExec(v ? 'start' : 'stop')
      if (draft) setDraft({ ...draft, enabled: v })
      if (config) setConfig({ ...config, enabled: v })
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const doTick = async (dry: boolean) => {
    setTicking(true)
    setTick(null)
    setError(null)
    try {
      const r = await runBotTick(dry)
      setTick(r)
      if (!dry) getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setTicking(false)
    }
  }

  const maintainBalance = async () => {
    if (!draft) return
    setBalanceBusy(true)
    setError(null)
    setSaveMsg(null)
    try {
      const r = await setBotBalance(draft.target_balance)
      setSaveMsg(`Balance set to ${fmtSolari(r.after)} (Δ ${fmtSolari(r.delta)}).`)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBalanceBusy(false)
    }
  }

  const clearListings = async () => {
    if (!window.confirm("Delete ALL of Duke's market listings? Player listings are not affected. This cannot be undone.")) return
    setClearing(true)
    setError(null)
    setSaveMsg(null)
    try {
      const r = await clearBotListings()
      setSaveMsg(r.message ?? `Cleared ${fmtNum(r.cleared)} of Duke's listings.`)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setClearing(false)
    }
  }

  if (loading && !status) {
    return <div className="text-text-dim py-8 text-center"><Icon name="Loader2" size={20} className="animate-spin inline" /> Loading bot…</div>
  }

  return (
    <div>
      <div className="card p-3 mb-4 text-xs text-text-muted border-l-2 border-accent flex items-start gap-2">
        <Icon name="Info" size={14} className="text-accent shrink-0 mt-0.5" />
        <span>
          <span className="font-semibold text-text">Duke</span> runs natively inside this server — no external bot process.
          On each buy tick every player listing rolls a <span className="font-mono text-accent">d{draft?.die_size ?? 12}</span>;
          only a roll of <span className="font-mono text-accent">{draft?.die_target ?? 5}</span> buys the item, regardless of price.
          Writes go straight to the live game database, so keep the bot disabled until you've dry-run a tick.
        </span>
      </div>

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
          <div className="text-[11px] text-text-dim">{status?.provisioned ? 'provisioned' : 'not provisioned'}</div>
        </div>
        <StatCard label="NPC listings" value={fmtNum(status?.listing_count)} icon="Tags" />
        <StatCard label="Balance" value={status?.balance != null ? fmtSolari(status.balance) : '—'} icon="Coins" />
        <StatCard label="Errors" value={fmtNum(status?.error_count ?? 0)} icon="TriangleAlert"
          tone={status?.error_count ? 'text-danger' : 'text-text'} />
      </section>

      {status?.error && (
        <div className="card p-3 mb-4 text-sm text-danger break-words">
          <span className="font-semibold">Bot error:</span> {status.error}
        </div>
      )}

      {/* Run a buy tick */}
      <div className="card p-4 mb-4">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
            <Icon name="Dices" size={14} className="text-accent" /> Run a buy tick
          </h4>
          <div className="flex items-center gap-2">
            <button className="btn-secondary" disabled={clearing} onClick={() => { void clearListings() }}
              title="Delete all of Duke's own market listings (player listings are untouched)">
              <Icon name={clearing ? 'Loader2' : 'Trash2'} size={15} className={clearing ? 'animate-spin' : ''} /> Clear listings
            </button>
            <button className="btn-secondary" disabled={ticking} onClick={() => { void doTick(true) }}>
              <Icon name={ticking ? 'Loader2' : 'FlaskConical'} size={15} className={ticking ? 'animate-spin' : ''} /> Dry run
            </button>
            <button className="btn-primary" disabled={ticking} onClick={() => { void doTick(false) }}>
              <Icon name={ticking ? 'Loader2' : 'Play'} size={15} className={ticking ? 'animate-spin' : ''} /> Run now
            </button>
          </div>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Dry run rolls the dice and reports what it <em>would</em> buy without touching the database. Run now executes the purchases.
        </p>
        {tick && (
          <div className="text-sm">
            <div className="flex flex-wrap gap-x-4 gap-y-1 text-text-muted">
              <span><span className="text-text-dim">die:</span> <span className="font-mono">{tick.die}</span></span>
              <span><span className="text-text-dim">candidates:</span> {fmtNum(tick.candidates)}</span>
              <span><span className="text-text-dim">rolled:</span> {fmtNum(tick.rolled)}</span>
              <span><span className="text-text-dim">won:</span> {fmtNum(tick.won)}</span>
              <span className={tick.dryRun ? 'text-accent' : 'text-success'}>
                <span className="text-text-dim">{tick.dryRun ? 'would buy:' : 'purchased:'}</span> {fmtNum(tick.purchased)}
              </span>
              {tick.errors > 0 && <span className="text-danger"><span className="text-text-dim">errors:</span> {fmtNum(tick.errors)}</span>}
            </div>
            {tick.dryRun && <div className="mt-1 text-[11px] text-accent">Dry run — nothing was written.</div>}
            {tick.message && <div className="mt-1 text-[11px] text-danger break-words">{tick.message}</div>}
            {tick.winners?.length > 0 && (
              <div className="mt-2 max-h-40 overflow-auto rounded-lg border border-border">
                <table className="w-full text-xs">
                  <thead className="text-text-dim bg-surface-2 sticky top-0">
                    <tr><th className="text-left px-2 py-1">Item</th><th className="text-right px-2 py-1">Price</th><th className="text-right px-2 py-1">Qty</th><th className="text-right px-2 py-1">Roll</th></tr>
                  </thead>
                  <tbody>
                    {tick.winners.map((w, i) => (
                      <tr key={`${w.order_id}-${i}`} className="border-t border-border">
                        <td className="px-2 py-1 font-mono text-text">{w.template_id}</td>
                        <td className="px-2 py-1 text-right">{fmtSolari(w.price)}</td>
                        <td className="px-2 py-1 text-right">{fmtNum(w.stack)}</td>
                        <td className="px-2 py-1 text-right font-mono text-accent">{w.roll}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
          <Icon name="Sliders" size={14} className="text-accent" /> Buy tuning
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
            <Toggle label="Bot enabled" checked={draft.enabled} onChange={v => { void toggleEnabled(v) }} />
            <NumField label="Buy tick (s)" value={draft.buy_tick_interval}
              onChange={v => setDraft({ ...draft, buy_tick_interval: v })} />
            <NumField label="Max buys / tick" value={draft.max_buys_per_tick}
              onChange={v => setDraft({ ...draft, max_buys_per_tick: v })} />
          </div>

          {/* Dice roll buy */}
          <div className="card p-4">
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1 flex items-center gap-2">
              <Icon name="Dices" size={14} className="text-accent" /> Dice roll buy
            </h4>
            <p className="text-[11px] text-text-dim mb-3">
              Each candidate listing rolls 1–<span className="font-mono">{draft.die_size}</span>; a roll equal to the winning number buys it.
              A larger die buys less often; the winning number is clamped to the die size.
            </p>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
              <NumField label="Die size" value={draft.die_size}
                onChange={v => setDraft({ ...draft, die_size: v })} />
              <NumField label="Winning number" value={draft.die_target}
                onChange={v => setDraft({ ...draft, die_target: v })} />
            </div>
          </div>

          {/* Solari balance maintenance */}
          <div className="card p-4">
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1 flex items-center gap-2">
              <Icon name="Coins" size={14} className="text-accent" /> Solari balance
            </h4>
            <p className="text-[11px] text-text-dim mb-3">
              Current balance: <span className="font-mono text-text">{status?.balance != null ? fmtSolari(status.balance) : '—'}</span>.
              When auto-maintain is on, Duke tops back up to the target at the start of a tick if it drops below half.
            </p>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 items-end">
              <Toggle label="Auto-maintain balance" checked={draft.maintain_balance}
                onChange={v => setDraft({ ...draft, maintain_balance: v })} />
              <NumField label="Target balance" value={draft.target_balance}
                onChange={v => setDraft({ ...draft, target_balance: v })} />
              <button className="btn-secondary" disabled={balanceBusy} onClick={() => { void maintainBalance() }}>
                <Icon name={balanceBusy ? 'Loader2' : 'Wallet'} size={15} className={balanceBusy ? 'animate-spin' : ''} /> Set balance to target
              </button>
            </div>
          </div>

          {/* Disabled items */}
          <div className="card p-4">
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1">Disabled items</h4>
            <p className="text-[11px] text-text-dim mb-2">Template IDs Duke will never buy. One per line.</p>
            <textarea rows={4}
              value={(draft.disabled_items ?? []).join('\n')}
              onChange={e => setDraft({ ...draft, disabled_items: e.target.value.split('\n').map(s => s.trim()).filter(Boolean) })}
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad" />
          </div>

          {/* Actions */}
          <div className="flex items-center gap-3">
            <button className="btn-primary" disabled={!dirty || saving} onClick={() => { void save() }}>
              <Icon name={saving ? 'Loader2' : 'Save'} size={15} className={saving ? 'animate-spin' : ''} /> Save config
            </button>
            <button className="btn-secondary" disabled={!dirty || saving} onClick={() => setDraft(structuredClone(config))}>
              Reset
            </button>
            {saveMsg && <span className="text-xs text-success">{saveMsg}</span>}
            {error && <span className="text-xs text-danger break-words">{error}</span>}
          </div>
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
