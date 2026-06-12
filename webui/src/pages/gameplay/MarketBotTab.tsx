import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getBotStatus, getBotConfig, saveBotConfig, runBotTick, runBotListTick, botExec,
  setBotBalance, clearBotListings, clearBotLegacyListings, getBotVendorSnapshot,
  type BotStatus, type BotConfig, type BotTickResult, type BotListTickResult,
  type BotVendorCandidate,
} from '../../api/gameplay'
import { fmtSolari, fmtNum, SourceBadge } from './shared'

type SubTab = 'buy' | 'list' | 'pricing'

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
  const [listTick, setListTick] = useState<BotListTickResult | null>(null)
  const [listTicking, setListTicking] = useState(false)
  const [balanceBusy, setBalanceBusy] = useState(false)
  const [clearing, setClearing] = useState(false)
  const [clearingLegacy, setClearingLegacy] = useState(false)
  const [snapshot, setSnapshot] = useState<BotVendorCandidate[] | null>(null)
  const [snapshotLoading, setSnapshotLoading] = useState(false)
  const [sub, setSub] = useState<SubTab>('buy')

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

  useEffect(() => {
    const id = window.setInterval(() => {
      getBotStatus().then(setStatus).catch(() => {})
    }, 10000)
    return () => window.clearInterval(id)
  }, [])

  const dirty = JSON.stringify(config) !== JSON.stringify(draft)

  const save = async () => {
    if (!draft) return
    setSaving(true); setSaveMsg(null); setError(null)
    try {
      const saved = await saveBotConfig(draft)
      setConfig(saved); setDraft(structuredClone(saved))
      setSaveMsg('Configuration saved.')
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally { setSaving(false) }
  }

  const toggleEnabled = async (v: boolean) => {
    setError(null)
    // When the operator enables Duke and the live DB still has NPC orders
    // from a previous bot (Revy from the upstream Go bot, or anything else
    // that isn't a clean Duke actor), offer to wipe them right now. Two
    // bots fighting over the same exchange is the #1 source of mislabeled
    // listings in-game, so we make this front-and-center on enable.
    if (v) {
      const refreshed = await getBotStatus().catch(() => null)
      if (refreshed) setStatus(refreshed)
      const legacy = refreshed?.legacy_listings_count ?? status?.legacy_listings_count ?? 0
      if (legacy > 0) {
        const breakdown = (refreshed?.listings_by_class ?? status?.listings_by_class ?? [])
          .filter(b => b.class !== 'Duke')
          .map(b => `  • ${b.class}: ${fmtNum(b.count)}`)
          .join('\n')
        const msg = `Heads up — the live exchange already has ${fmtNum(legacy)} NPC listings from a previous bot:\n\n${breakdown}\n\nThese will keep showing up in-game alongside Duke's listings unless they're removed. Wipe them now before starting Duke?\n\n(Player listings and Duke's own listings are NOT affected. This cannot be undone.)`
        if (window.confirm(msg)) {
          setClearingLegacy(true)
          try {
            const r = await clearBotLegacyListings()
            setSaveMsg(r.message ?? `Cleared ${fmtNum(r.cleared)} legacy NPC listings.`)
          } catch (e) {
            setError(e instanceof Error ? e.message : String(e))
            setClearingLegacy(false)
            return
          }
          setClearingLegacy(false)
        }
      }
    }
    try {
      await botExec(v ? 'start' : 'stop')
      if (draft) setDraft({ ...draft, enabled: v })
      if (config) setConfig({ ...config, enabled: v })
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
  }

  const doTick = async (dry: boolean) => {
    setTicking(true); setTick(null); setError(null)
    try {
      const r = await runBotTick(dry)
      setTick(r)
      if (!dry) getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setTicking(false) }
  }

  const doListTick = async (dry: boolean) => {
    setListTicking(true); setListTick(null); setError(null)
    try {
      const r = await runBotListTick(dry)
      setListTick(r)
      if (!dry) getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setListTicking(false) }
  }

  const maintainBalance = async () => {
    if (!draft) return
    setBalanceBusy(true); setError(null); setSaveMsg(null)
    try {
      const r = await setBotBalance(draft.target_balance)
      setSaveMsg(`Balance set to ${fmtSolari(r.after)} (Δ ${fmtSolari(r.delta)}).`)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBalanceBusy(false) }
  }

  const clearListings = async () => {
    if (!window.confirm("Delete ALL of Duke's market listings? Player listings are not affected. This cannot be undone.")) return
    setClearing(true); setError(null); setSaveMsg(null)
    try {
      const r = await clearBotListings()
      setSaveMsg(r.message ?? `Cleared ${fmtNum(r.cleared)} of Duke's listings.`)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setClearing(false) }
  }

  const clearLegacy = async () => {
    const n = status?.legacy_listings_count ?? 0
    if (n <= 0) { setSaveMsg('No legacy (non-Duke) NPC listings to clear.'); return }
    if (!window.confirm(`Permanently delete ${fmtNum(n)} legacy NPC market listings (any actor whose class is NOT Duke — e.g. leftover Revy orders from the old external bot)?\n\nPlayer listings and Duke's own listings are NOT affected. This cannot be undone.`)) return
    setClearingLegacy(true); setError(null); setSaveMsg(null)
    try {
      const r = await clearBotLegacyListings()
      setSaveMsg(r.message ?? `Cleared ${fmtNum(r.cleared)} legacy NPC listings.`)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setClearingLegacy(false) }
  }

  const loadSnapshot = async () => {
    setSnapshotLoading(true); setError(null)
    try {
      const r = await getBotVendorSnapshot()
      setSnapshot(r.candidates ?? [])
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setSnapshotLoading(false) }
  }

  if (loading && !status) {
    return <div className="text-text-dim py-8 text-center"><Icon name="Loader2" size={20} className="animate-spin inline" /> Loading bot…</div>
  }

  const legacyCount = status?.legacy_listings_count ?? 0

  return (
    <div>
      {/* Persistent warning: bot is running but the exchange still has
          listings from another bot. Stays visible until legacy_count is 0. */}
      {status?.enabled && legacyCount > 0 && (
        <div className="card p-3 mb-4 border-l-4 border-warning bg-warning/10 flex items-start gap-3">
          <Icon name="TriangleAlert" size={18} className="text-warning shrink-0 mt-0.5" />
          <div className="flex-1 min-w-0">
            <div className="text-sm font-semibold text-warning">
              Duke is running alongside {fmtNum(legacyCount)} legacy NPC listings from a previous bot.
            </div>
            <div className="text-xs text-text-muted mt-1">
              Players will see both sets in-game until these are cleared. Wipe them so Duke owns the exchange cleanly.
              {(() => {
                const others = (status.listings_by_class ?? []).filter(b => b.class !== 'Duke')
                if (others.length === 0) return null
                return (
                  <span className="ml-1">
                    Affected actor{others.length > 1 ? 's' : ''}: {others.map(b => `${b.class} (${fmtNum(b.count)})`).join(', ')}.
                  </span>
                )
              })()}
            </div>
          </div>
          <button className="btn-primary text-xs shrink-0" disabled={clearingLegacy} onClick={() => { void clearLegacy() }}>
            <Icon name={clearingLegacy ? 'Loader2' : 'Trash2'} size={13} className={clearingLegacy ? 'animate-spin' : ''} />
            {' '}Wipe legacy ({fmtNum(legacyCount)})
          </button>
        </div>
      )}

      <div className="card p-3 mb-4 text-xs text-text-muted border-l-2 border-accent flex items-start gap-2">
        <Icon name="Info" size={14} className="text-accent shrink-0 mt-0.5" />
        <span>
          <span className="font-semibold text-text">Duke</span> runs natively inside this server — no external bot process.
          On each <span className="text-text">buy tick</span> every player listing rolls a
          {' '}<span className="font-mono text-accent">d{draft?.die_size ?? 12}</span>; only a roll of
          {' '}<span className="font-mono text-accent">{draft?.die_target ?? 5}</span> buys the item.
          On each <span className="text-text">list tick</span> Duke tops up its own NPC sell orders for items already on
          the live vendor inventory, priced via the sane-pricing rules (100 k Solari hard cap).
          Writes go straight to the live game DB — dry-run first.
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
        <StatCard label="Duke listings" value={fmtNum(status?.listing_count)} icon="Tags"
          sub={status?.listings_npc_total != null ? `${fmtNum(status.listings_npc_total)} NPC total` : undefined} />
        <StatCard label="Balance" value={status?.balance != null ? fmtSolari(status.balance) : '—'} icon="Coins" />
        <StatCard label="Legacy listings" value={fmtNum(legacyCount)} icon="TriangleAlert"
          tone={legacyCount > 0 ? 'text-warning' : 'text-text-dim'}
          sub={legacyCount > 0 ? 'non-Duke NPC orders' : 'all NPC orders are Duke'} />
      </section>

      {/* Last tick timestamps */}
      {(status?.last_buy_tick || status?.last_list_tick) && (
        <div className="card p-3 mb-4 text-xs text-text-muted grid grid-cols-1 sm:grid-cols-2 gap-2">
          <div><span className="text-text-dim">Last buy tick:</span> {status?.last_buy_tick ? new Date(status.last_buy_tick).toLocaleString() : '—'}</div>
          <div><span className="text-text-dim">Last list tick:</span> {status?.last_list_tick ? new Date(status.last_list_tick).toLocaleString() : '—'}</div>
        </div>
      )}

      {/* NPC class breakdown */}
      {status?.listings_by_class && status.listings_by_class.length > 0 && (
        <div className="card p-3 mb-4">
          <div className="flex items-center justify-between mb-2">
            <span className="text-xs uppercase tracking-wider text-text-dim">NPC listings by actor class</span>
            {legacyCount > 0 && (
              <button className="btn-secondary text-xs" disabled={clearingLegacy} onClick={() => { void clearLegacy() }}
                title="Permanently delete NPC orders whose actor class is not Duke (e.g. legacy Revy orphans).">
                <Icon name={clearingLegacy ? 'Loader2' : 'Trash2'} size={13} className={clearingLegacy ? 'animate-spin' : ''} />
                {' '}Wipe legacy ({fmtNum(legacyCount)})
              </button>
            )}
          </div>
          <div className="flex flex-wrap gap-2">
            {status.listings_by_class.map(b => (
              <span key={b.class} className={`text-xs px-2 py-1 rounded border ${b.class === 'Duke' ? 'border-accent/40 bg-accent/10 text-accent-bright' : 'border-warning/40 bg-warning/10 text-warning'}`}>
                <span className="font-mono">{b.class}</span>: {fmtNum(b.count)}
              </span>
            ))}
          </div>
        </div>
      )}

      {status?.error && (
        <div className="card p-3 mb-4 text-sm text-danger break-words">
          <span className="font-semibold">Bot error:</span> {status.error}
        </div>
      )}

      {/* Subtab nav for the tick + config sections */}
      <div className="flex gap-1 mb-3 border-b border-border">
        {([['buy', 'Buy side', 'Dices'], ['list', 'List side', 'Tags'], ['pricing', 'Pricing rules', 'Sliders']] as [SubTab, string, string][]).map(([id, label, icon]) => (
          <button key={id} onClick={() => setSub(id)}
            className={`px-3 py-2 text-sm flex items-center gap-1.5 border-b-2 -mb-px ${sub === id ? 'border-accent text-text' : 'border-transparent text-text-muted hover:text-text'}`}>
            <Icon name={icon} size={14} /> {label}
          </button>
        ))}
        <div className="ml-auto flex items-center gap-2">
          <SourceBadge source={config?.source} />
          <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
            <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        </div>
      </div>

      {draft && sub === 'buy' && (
        <BuySection draft={draft} setDraft={setDraft} status={status} tick={tick} ticking={ticking}
          clearing={clearing} balanceBusy={balanceBusy}
          onTick={doTick} onClear={clearListings} onMaintainBalance={maintainBalance}
          onToggleEnabled={toggleEnabled} />
      )}

      {draft && sub === 'list' && (
        <ListSection draft={draft} setDraft={setDraft} listTick={listTick} listTicking={listTicking}
          snapshot={snapshot} snapshotLoading={snapshotLoading}
          onListTick={doListTick} onLoadSnapshot={loadSnapshot} />
      )}

      {draft && sub === 'pricing' && (
        <PricingSection draft={draft} setDraft={setDraft} />
      )}

      {/* Save bar (shared across all subtabs) */}
      {draft && (
        <div className="flex items-center gap-3 mt-4 sticky bottom-0 bg-bg/80 backdrop-blur py-2">
          <button className="btn-primary" disabled={!dirty || saving} onClick={() => { void save() }}>
            <Icon name={saving ? 'Loader2' : 'Save'} size={15} className={saving ? 'animate-spin' : ''} /> Save config
          </button>
          <button className="btn-secondary" disabled={!dirty || saving} onClick={() => setDraft(structuredClone(config))}>
            Reset
          </button>
          {saveMsg && <span className="text-xs text-success">{saveMsg}</span>}
          {error && <span className="text-xs text-danger break-words">{error}</span>}
          {dirty && <span className="text-xs text-warning ml-auto">Unsaved changes</span>}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Buy section — existing dice-roll buy tuning + clear-listings.
// ---------------------------------------------------------------------------
function BuySection({ draft, setDraft, status, tick, ticking, clearing, balanceBusy,
  onTick, onClear, onMaintainBalance, onToggleEnabled }: {
    draft: BotConfig; setDraft: (c: BotConfig) => void; status: BotStatus | null;
    tick: BotTickResult | null; ticking: boolean; clearing: boolean; balanceBusy: boolean;
    onTick: (dry: boolean) => void; onClear: () => void; onMaintainBalance: () => void;
    onToggleEnabled: (v: boolean) => void;
  }) {
  return (
    <div className="space-y-4">
      <div className="card p-4">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
            <Icon name="Dices" size={14} className="text-accent" /> Run a buy tick
          </h4>
          <div className="flex items-center gap-2">
            <button className="btn-secondary" disabled={clearing} onClick={onClear}
              title="Delete all of Duke's own market listings.">
              <Icon name={clearing ? 'Loader2' : 'Trash2'} size={15} className={clearing ? 'animate-spin' : ''} /> Clear Duke listings
            </button>
            <button className="btn-secondary" disabled={ticking} onClick={() => onTick(true)}>
              <Icon name={ticking ? 'Loader2' : 'FlaskConical'} size={15} className={ticking ? 'animate-spin' : ''} /> Dry run
            </button>
            <button className="btn-primary" disabled={ticking} onClick={() => onTick(false)}>
              <Icon name={ticking ? 'Loader2' : 'Play'} size={15} className={ticking ? 'animate-spin' : ''} /> Run now
            </button>
          </div>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Dry run rolls the dice and reports what it <em>would</em> buy without touching the database.
        </p>
        {tick && <BuyTickResultView tick={tick} />}
      </div>

      <div className="card p-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <Toggle label="Bot enabled" checked={draft.enabled} onChange={v => onToggleEnabled(v)} />
        <NumField label="Buy tick (s)" value={draft.buy_tick_interval}
          onChange={v => setDraft({ ...draft, buy_tick_interval: v })} />
        <NumField label="Max buys / tick" value={draft.max_buys_per_tick}
          onChange={v => setDraft({ ...draft, max_buys_per_tick: v })} />
      </div>

      <div className="card p-4">
        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1 flex items-center gap-2">
          <Icon name="Dices" size={14} className="text-accent" /> Dice roll buy
        </h4>
        <p className="text-[11px] text-text-dim mb-3">
          Each candidate rolls 1–<span className="font-mono">{draft.die_size}</span>; only the winning number buys.
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <NumField label="Die size" value={draft.die_size}
            onChange={v => setDraft({ ...draft, die_size: v })} />
          <NumField label="Winning number" value={draft.die_target}
            onChange={v => setDraft({ ...draft, die_target: v })} />
        </div>
      </div>

      <div className="card p-4">
        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1 flex items-center gap-2">
          <Icon name="Coins" size={14} className="text-accent" /> Solari balance
        </h4>
        <p className="text-[11px] text-text-dim mb-3">
          Current: <span className="font-mono text-text">{status?.balance != null ? fmtSolari(status.balance) : '—'}</span>.
          With auto-maintain on, Duke tops back up to target at tick start when below half.
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 items-end">
          <Toggle label="Auto-maintain" checked={draft.maintain_balance}
            onChange={v => setDraft({ ...draft, maintain_balance: v })} />
          <NumField label="Target balance" value={draft.target_balance}
            onChange={v => setDraft({ ...draft, target_balance: v })} />
          <button className="btn-secondary" disabled={balanceBusy} onClick={onMaintainBalance}>
            <Icon name={balanceBusy ? 'Loader2' : 'Wallet'} size={15} className={balanceBusy ? 'animate-spin' : ''} /> Set to target
          </button>
        </div>
      </div>

      <div className="card p-4">
        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-1">Disabled items</h4>
        <p className="text-[11px] text-text-dim mb-2">Template IDs Duke will never buy <em>or</em> list. One per line.</p>
        <textarea rows={4}
          value={(draft.disabled_items ?? []).join('\n')}
          onChange={e => setDraft({ ...draft, disabled_items: e.target.value.split('\n').map(s => s.trim()).filter(Boolean) })}
          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad" />
      </div>
    </div>
  )
}

function BuyTickResultView({ tick }: { tick: BotTickResult }) {
  return (
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
  )
}

// ---------------------------------------------------------------------------
// List section — sell-side scheduler + listing tuning + vendor snapshot preview.
// ---------------------------------------------------------------------------
function ListSection({ draft, setDraft, listTick, listTicking, snapshot, snapshotLoading,
  onListTick, onLoadSnapshot }: {
    draft: BotConfig; setDraft: (c: BotConfig) => void;
    listTick: BotListTickResult | null; listTicking: boolean;
    snapshot: BotVendorCandidate[] | null; snapshotLoading: boolean;
    onListTick: (dry: boolean) => void; onLoadSnapshot: () => void;
  }) {
  return (
    <div className="space-y-4">
      <div className="card p-4">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
            <Icon name="Tags" size={14} className="text-accent" /> Run a list tick
          </h4>
          <div className="flex items-center gap-2">
            <button className="btn-secondary" disabled={listTicking} onClick={() => onListTick(true)}>
              <Icon name={listTicking ? 'Loader2' : 'FlaskConical'} size={15} className={listTicking ? 'animate-spin' : ''} /> Dry run
            </button>
            <button className="btn-primary" disabled={listTicking} onClick={() => onListTick(false)}>
              <Icon name={listTicking ? 'Loader2' : 'Play'} size={15} className={listTicking ? 'animate-spin' : ''} /> Run now
            </button>
          </div>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Snapshots live NPC vendor inventory, applies sane-pricing rules, and tops up Duke's own listings to
          <span className="font-mono"> {draft.listings_per_grade}</span> per (item, grade).
          Dry run shows the planned actions without writing.
        </p>
        {listTick && <ListTickResultView tick={listTick} />}
      </div>

      <div className="card p-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <NumField label="List tick (s)" value={draft.list_tick_interval}
          onChange={v => setDraft({ ...draft, list_tick_interval: v })} />
        <NumField label="Listings / grade" value={draft.listings_per_grade}
          onChange={v => setDraft({ ...draft, listings_per_grade: v })} />
        <Toggle label="Stackables only (v11.5.2)" checked={draft.stackables_only}
          onChange={v => setDraft({ ...draft, stackables_only: v })} />
      </div>

      <div className="card p-4">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
            <Icon name="Eye" size={14} className="text-accent" /> Vendor snapshot preview
          </h4>
          <button className="btn-secondary" disabled={snapshotLoading} onClick={onLoadSnapshot}>
            <Icon name={snapshotLoading ? 'Loader2' : 'RefreshCw'} size={15} className={snapshotLoading ? 'animate-spin' : ''} /> Refresh snapshot
          </button>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Items the bot would list (derived from the live NPC vendor inventory + current pricing rules).
        </p>
        {snapshot == null ? (
          <div className="text-text-dim text-sm">No snapshot loaded. Click <em>Refresh snapshot</em>.</div>
        ) : snapshot.length === 0 ? (
          <div className="text-text-dim text-sm">No eligible items in the snapshot (try toggling <em>Stackables only</em> off, or seed NPC vendors first).</div>
        ) : (
          <div className="max-h-72 overflow-auto rounded-lg border border-border">
            <table className="w-full text-xs">
              <thead className="text-text-dim bg-surface-2 sticky top-0">
                <tr>
                  <th className="text-left px-2 py-1">Template</th>
                  <th className="text-center px-2 py-1">Tier</th>
                  <th className="text-left px-2 py-1">Rarity</th>
                  <th className="text-right px-2 py-1">Stack</th>
                  <th className="text-right px-2 py-1">Vendor price</th>
                  <th className="text-right px-2 py-1">Target list</th>
                </tr>
              </thead>
              <tbody>
                {snapshot.slice(0, 500).map(c => (
                  <tr key={c.template_id} className="border-t border-border">
                    <td className="px-2 py-1 font-mono text-text truncate max-w-[280px]">{c.template_id}</td>
                    <td className="px-2 py-1 text-center text-text-muted">{c.tier || '—'}</td>
                    <td className="px-2 py-1 text-text-muted">{c.rarity}</td>
                    <td className="px-2 py-1 text-right">{fmtNum(c.stack_max)}</td>
                    <td className="px-2 py-1 text-right text-text-muted">{fmtSolari(c.vendor_price)}</td>
                    <td className="px-2 py-1 text-right font-mono text-accent-bright">{fmtSolari(c.target_price)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {snapshot.length > 500 && (
              <div className="px-2 py-1 text-[11px] text-text-dim border-t border-border">
                Showing first 500 of {fmtNum(snapshot.length)} candidates.
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

function ListTickResultView({ tick }: { tick: BotListTickResult }) {
  return (
    <div className="text-sm">
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-text-muted">
        <span><span className="text-text-dim">considered:</span> {fmtNum(tick.considered)}</span>
        <span><span className="text-text-dim">eligible:</span> {fmtNum(tick.eligible)}</span>
        <span><span className="text-text-dim">listed before:</span> {fmtNum(tick.listed_before)}</span>
        <span className={tick.dryRun ? 'text-accent' : 'text-success'}>
          <span className="text-text-dim">listed after:</span> {fmtNum(tick.listed_after)}
        </span>
        <span><span className="text-text-dim">inserted:</span> {fmtNum(tick.inserted)}</span>
        <span><span className="text-text-dim">deleted:</span> {fmtNum(tick.deleted)}</span>
        {tick.errors > 0 && <span className="text-danger"><span className="text-text-dim">errors:</span> {fmtNum(tick.errors)}</span>}
      </div>
      {tick.dryRun && <div className="mt-1 text-[11px] text-accent">Dry run — nothing was written.</div>}
      {tick.message && <div className="mt-1 text-[11px] text-danger break-words">{tick.message}</div>}
      {tick.planned?.length > 0 && (
        <div className="mt-2 max-h-48 overflow-auto rounded-lg border border-border">
          <table className="w-full text-xs">
            <thead className="text-text-dim bg-surface-2 sticky top-0">
              <tr>
                <th className="text-left px-2 py-1">Template</th>
                <th className="text-right px-2 py-1">Target</th>
                <th className="text-right px-2 py-1">Stack</th>
                <th className="text-right px-2 py-1">Existing</th>
                <th className="text-right px-2 py-1">Stale</th>
                <th className="text-right px-2 py-1">To insert</th>
              </tr>
            </thead>
            <tbody>
              {tick.planned.slice(0, 200).map((p, i) => (
                <tr key={`${p.template_id}-${i}`} className="border-t border-border">
                  <td className="px-2 py-1 font-mono text-text truncate max-w-[260px]">{p.template_id}</td>
                  <td className="px-2 py-1 text-right font-mono text-accent-bright">{fmtSolari(p.target_price)}</td>
                  <td className="px-2 py-1 text-right">{fmtNum(p.stack_max)}</td>
                  <td className="px-2 py-1 text-right text-text-muted">{p.existing}{p.aligned !== p.existing && <span className="text-text-dim"> ({p.aligned} ok)</span>}</td>
                  <td className="px-2 py-1 text-right text-warning">{p.stale}</td>
                  <td className="px-2 py-1 text-right text-success">{p.to_insert}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {tick.planned.length > 200 && (
            <div className="px-2 py-1 text-[11px] text-text-dim border-t border-border">
              Showing first 200 of {fmtNum(tick.planned.length)} planned actions.
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Pricing section — the sane-pricing knobs (100 k cap, tier base prices,
// rarity / vendor / grade multipliers, per-template overrides).
// ---------------------------------------------------------------------------
function PricingSection({ draft, setDraft }: { draft: BotConfig; setDraft: (c: BotConfig) => void }) {
  const tbp = draft.tier_base_prices ?? {}
  const sup = draft.stack_unit_prices ?? {}
  const cf  = draft.category_factors ?? {}
  const rm  = draft.rarity_multipliers ?? {}
  const vm  = draft.vendor_multipliers ?? {}
  const gm  = draft.grade_multipliers ?? []
  const overrides = draft.price_overrides ?? {}
  const overrideRows = Object.entries(overrides)

  const setMap = (key: 'tier_base_prices' | 'stack_unit_prices' | 'category_factors' | 'rarity_multipliers' | 'vendor_multipliers',
                  next: Record<string, number>) => {
    setDraft({ ...draft, [key]: next })
  }

  const tierKeys = ['0', '1', '2', '3', '4', '5', '6']

  return (
    <div className="space-y-4">
      <div className="card p-3 text-xs text-text-muted border-l-2 border-warning flex items-start gap-2">
        <Icon name="TriangleAlert" size={14} className="text-warning shrink-0 mt-0.5" />
        <span>
          Sane-pricing defaults (100 k Solari hard cap, tier base prices, category factors, rarity multipliers,
          and 95 % vendor floor) are ported from the dune-admin patch. Touch with care — these directly drive
          every listing the bot writes.
        </span>
      </div>

      <div className="card p-4 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <NumField label="Price cap (Solari)" value={draft.price_cap ?? 100000}
          onChange={v => setDraft({ ...draft, price_cap: v })} />
        <NumField label="Default unit price (fallback)" value={draft.default_unit_price ?? 50}
          onChange={v => setDraft({ ...draft, default_unit_price: v })} />
      </div>

      <div className="card p-4">
        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Tier base prices (non-stackable)</h4>
        <div className="grid grid-cols-7 gap-2">
          {tierKeys.map(t => (
            <NumField key={`tbp-${t}`} label={`T${t}`} value={tbp[t] ?? 0}
              onChange={v => setMap('tier_base_prices', { ...tbp, [t]: v })} />
          ))}
        </div>
        <h4 className="text-xs uppercase tracking-wider text-text-dim mt-4 mb-2">Stack unit prices (stackable, per unit)</h4>
        <div className="grid grid-cols-7 gap-2">
          {tierKeys.map(t => (
            <NumField key={`sup-${t}`} label={`T${t}`} value={sup[t] ?? 0}
              onChange={v => setMap('stack_unit_prices', { ...sup, [t]: v })} />
          ))}
        </div>
      </div>

      <div className="card p-4 grid grid-cols-1 sm:grid-cols-3 gap-4">
        <FloatField label="Augment factor" value={cf['augment'] ?? 0}
          onChange={v => setMap('category_factors', { ...cf, augment: v })} />
        <FloatField label="Schematic factor" value={cf['schematic'] ?? 0}
          onChange={v => setMap('category_factors', { ...cf, schematic: v })} />
        <FloatField label="Gear factor" value={cf['gear'] ?? 0}
          onChange={v => setMap('category_factors', { ...cf, gear: v })} />
      </div>

      <div className="card p-4">
        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Rarity multipliers</h4>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          {['common', 'rare', 'unique', 'memento'].map(r => (
            <FloatField key={r} label={r} value={rm[r] ?? 1.0}
              onChange={v => setMap('rarity_multipliers', { ...rm, [r]: v })} />
          ))}
        </div>
        <h4 className="text-xs uppercase tracking-wider text-text-dim mt-4 mb-2">Vendor multiplier</h4>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <FloatField label="all" value={vm['all'] ?? 0.95}
            onChange={v => setMap('vendor_multipliers', { ...vm, all: v })} />
        </div>
        <h4 className="text-xs uppercase tracking-wider text-text-dim mt-4 mb-2">Grade multipliers (T0–T5 grade)</h4>
        <div className="grid grid-cols-3 sm:grid-cols-6 gap-2">
          {gm.map((g, i) => (
            <FloatField key={`gm-${i}`} label={`G${i}`} value={g}
              onChange={v => {
                const next = [...gm]; next[i] = v
                setDraft({ ...draft, grade_multipliers: next })
              }} />
          ))}
        </div>
      </div>

      <div className="card p-4">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim">Per-template price overrides</h4>
          <button className="btn-secondary text-xs" onClick={() => {
            const tmpl = window.prompt('Template ID to override:')?.trim()
            if (!tmpl) return
            const v = window.prompt(`Override price for ${tmpl} (Solari, integer):`)?.trim()
            const n = v != null ? parseInt(v, 10) : NaN
            if (!Number.isFinite(n) || n < 0) return
            setDraft({ ...draft, price_overrides: { ...overrides, [tmpl]: n } })
          }}>
            <Icon name="Plus" size={13} /> Add override
          </button>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Manual price (Solari, integer) for specific template IDs. Overrides win over the formula, then the 100 k cap applies.
        </p>
        {overrideRows.length === 0 ? (
          <div className="text-text-dim text-sm">No overrides.</div>
        ) : (
          <div className="space-y-1">
            {overrideRows.map(([tmpl, price]) => (
              <div key={tmpl} className="flex items-center gap-2 text-sm">
                <span className="font-mono text-text flex-1 truncate">{tmpl}</span>
                <input type="number" value={price} min={0}
                  onChange={e => {
                    const next = { ...overrides, [tmpl]: parseInt(e.target.value, 10) || 0 }
                    setDraft({ ...draft, price_overrides: next })
                  }}
                  className="w-32 px-2 py-1 rounded bg-surface-2 border border-border text-text font-mono text-sm" />
                <button className="text-text-dim hover:text-danger" title="Remove override"
                  onClick={() => {
                    const next = { ...overrides }; delete next[tmpl]
                    setDraft({ ...draft, price_overrides: next })
                  }}>
                  <Icon name="X" size={14} />
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Shared small UI helpers.
// ---------------------------------------------------------------------------
function StatCard({ label, value, icon, tone, sub }: { label: string; value: string; icon: string; tone?: string; sub?: string }) {
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between">
        <span className="text-xs uppercase tracking-wider text-text-dim">{label}</span>
        <Icon name={icon} size={15} className="text-accent" />
      </div>
      <div className={`mt-1 text-xl font-semibold truncate ${tone ?? 'text-text'}`}>{value}</div>
      {sub && <div className="text-[11px] text-text-dim truncate">{sub}</div>}
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

function FloatField({ label, value, onChange, disabled }: {
  label: string; value: number; onChange: (v: number) => void; disabled?: boolean
}) {
  return (
    <label className="block">
      <span className="block text-[11px] uppercase tracking-wider text-text-dim mb-1 capitalize">{label}</span>
      <input type="number" value={value} step={0.05} min={0} disabled={disabled}
        onChange={e => onChange(parseFloat(e.target.value) || 0)}
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
