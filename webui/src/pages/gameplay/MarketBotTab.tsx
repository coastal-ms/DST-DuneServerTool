import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ItemPicker } from '../../components/ItemPicker'
import {
  getBotStatus, getBotConfig, saveBotConfig, runBotTick, runBotListTick,
  startBotSeedMarket, abortBotSeedMarket, botExec,
  setBotBalance, clearBotListings, clearBotError, getBotVendorSnapshot,
  type BotStatus, type BotConfig, type BotTickResult, type BotListTickResult,
  type BotSeedProgress,
  type BotVendorCandidate,
} from '../../api/gameplay'
import { fmtSolari, fmtNum, SourceBadge } from './shared'

type SubTab = 'buy' | 'list' | 'pricing'

// Keep the seed-progress banner visible for ~30s after a seed finishes so the
// user gets a chance to read the final counters even if they navigated to
// another subtab during the run.
function isRecentSeedFinish(p: BotSeedProgress | null | undefined): boolean {
  if (!p || p.running) return false
  const ts = p.finished ?? p.updated
  if (!ts) return false
  const t = Date.parse(ts)
  if (Number.isNaN(t)) return false
  return Date.now() - t < 30_000
}

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
  const [seedLaunchError, setSeedLaunchError] = useState<string | null>(null)
  const [balanceBusy, setBalanceBusy] = useState(false)
  const [clearing, setClearing] = useState(false)
  const [togglingPricing, setTogglingPricing] = useState(false)
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

  const doListTick = async () => {
    setListTicking(true); setListTick(null); setError(null)
    try {
      const r = await runBotListTick(false)
      if (!r.ok && !r.running) {
        setError(r.error ?? 'Failed to start list tick.')
        return
      }
      // Live tick is async server-side — refresh status so the button stays
      // disabled while list_tick_progress.running is true, and let the
      // existing 10s status poll pick up the completion.
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setListTicking(false) }
  }

  const seedProgress: BotSeedProgress | null = status?.seed_progress ?? null
  const seeding = !!seedProgress?.running
  const listTickRunningServer = !!status?.list_tick_progress?.running
  const listTickBusy = listTicking || listTickRunningServer
  const [dismissingError, setDismissingError] = useState(false)

  const dismissError = async () => {
    setDismissingError(true)
    try {
      await clearBotError()
      const s = await getBotStatus().catch(() => null)
      if (s) setStatus(s)
    } catch { /* swallow — banner stays */ }
    finally { setDismissingError(false) }
  }

  const doSeedMarket = async () => {
    const perGrade = draft?.listings_per_grade ?? 5
    const ok = window.confirm(
      `Bulk-seed the market: insert up to ${perGrade} NPC listings per catalogued template (~1000–1400 templates depending on the Stackables-only toggle). This bypasses the live vendor snapshot and writes straight to the DB.\n\nThe seed runs in the background — you can leave this page open and watch the progress bar, or come back later. The button reactivates once it finishes.\n\nProceed?`,
    )
    if (!ok) return
    setSeedLaunchError(null); setError(null)
    try {
      const r = await startBotSeedMarket()
      if (!r.ok && !r.running) {
        setSeedLaunchError(r.error ?? 'Failed to start seed market.')
        return
      }
      // Refresh status immediately so the progress bar appears without
      // waiting for the next 10s poll interval.
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setSeedLaunchError(e instanceof Error ? e.message : String(e))
    }
  }

  const [aborting, setAborting] = useState(false)
  const doAbortSeed = async () => {
    if (aborting) return
    setAborting(true)
    try {
      await abortBotSeedMarket()
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) {
      setSeedLaunchError(e instanceof Error ? e.message : String(e))
    } finally {
      setAborting(false)
    }
  }

  // While a seed OR list tick is running, poll status every 2s instead of
  // 10s so the progress bar / button state updates promptly. Reverts to
  // normal cadence once both finish.
  useEffect(() => {
    if (!seeding && !listTickRunningServer) return
    const id = window.setInterval(() => {
      getBotStatus().then(setStatus).catch(() => {})
    }, 2000)
    return () => window.clearInterval(id)
  }, [seeding, listTickRunningServer])

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
    if (!window.confirm("Delete ALL of Duke's market listings AND wipe his entire NPC inventory (including any orphan items left behind by previous runs)? Player listings are not affected. This cannot be undone.")) return
    setClearing(true); setError(null); setSaveMsg(null)
    try {
      const r = await clearBotListings()
      let msg = r.message ?? `Cleared ${fmtNum(r.cleared)} of Duke's listings.`
      if (r.orphans && r.orphans > 0) {
        msg = `${msg} (Removed ${fmtNum(r.orphans)} orphan item(s) from inventory ${r.inventory_id ?? '?'}.)`
      }
      setSaveMsg(msg)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setClearing(false) }
  }

  // Switch between sane-pricing (100k cap, tier×category×rarity) and upstream
  // Funcom-style pricing (vendor×rarity up to 5×, uncapped). Either direction
  // wipes Duke's current listings so the new prices replace them on the next
  // list tick instead of triggering a thrash where every listing is flagged as
  // "wrong price" and recreated piecemeal.
  const togglePricingMode = async (toUpstream: boolean) => {
    if (!draft) return
    const msg = toUpstream
      ? "Switch Duke to UPSTREAM Funcom pricing?\n\nThis pricing uses vendor_price × rarity (up to 5× for rare/unique) plus the original equipment/schematic/stack tier tables — UNCAPPED. A T6 schematic Flawless can list for hundreds of thousands of Solari.\n\nAll of Duke's current listings will be WIPED so the new prices replace them on the next list tick. This cannot be undone.\n\nProceed?"
      : "Switch Duke back to SANE pricing (100,000 Solari hard cap)?\n\nAll of Duke's current listings will be WIPED so the new prices replace them on the next list tick. This cannot be undone.\n\nProceed?"
    if (!window.confirm(msg)) return
    setTogglingPricing(true); setError(null); setSaveMsg(null)
    try {
      const next = { ...draft, upstream_pricing: toUpstream }
      const saved = await saveBotConfig(next)
      setConfig(saved); setDraft(structuredClone(saved))
      const r = await clearBotListings()
      let cleared = `Switched to ${toUpstream ? 'upstream' : 'sane'} pricing — cleared ${fmtNum(r.cleared)} of Duke's listings.`
      if (r.orphans && r.orphans > 0) {
        cleared = `${cleared} (Removed ${fmtNum(r.orphans)} orphan item(s) from inventory ${r.inventory_id ?? '?'}.)`
      }
      setSaveMsg(`${cleared} Duke will repopulate on the next list tick.`)
      getBotStatus().then(setStatus).catch(() => {})
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setTogglingPricing(false) }
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

  const upstreamPricing = !!draft?.upstream_pricing

  return (
    <div>
      <div className="card p-3 mb-4 text-xs text-text-muted border-l-2 border-accent flex items-start gap-2">
        <Icon name="Info" size={14} className="text-accent shrink-0 mt-0.5" />
        <span>
          <span className="font-semibold text-text">Duke</span> runs natively inside this server — no external bot process.
          On each <span className="text-text">buy tick</span> every player listing rolls a
          {' '}<span className="font-mono text-accent">d{draft?.die_size ?? 12}</span>; only a roll of
          {' '}<span className="font-mono text-accent">{draft?.die_target ?? 5}</span> buys the item.
          On each <span className="text-text">list tick</span> Duke tops up its own NPC sell orders for items already on
          the live vendor inventory, priced via the
          {' '}<span className={`font-semibold ${upstreamPricing ? 'text-warning' : 'text-success'}`}>
            {upstreamPricing ? 'upstream Funcom (uncapped)' : 'sane-pricing (100 k Solari cap)'}
          </span> rules.
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
        {/* Pricing-mode toggle card. Replaces the legacy-listings stat tile.
            Click cycles between sane and upstream after a confirm + wipe. */}
        <div className="card p-3 flex flex-col">
          <div className="flex items-center justify-between">
            <span className="text-xs uppercase tracking-wider text-text-dim">Pricing mode</span>
            <Icon name={upstreamPricing ? 'TriangleAlert' : 'ShieldCheck'} size={15}
              className={upstreamPricing ? 'text-warning' : 'text-success'} />
          </div>
          <div className={`mt-1 text-xl font-semibold ${upstreamPricing ? 'text-warning' : 'text-success'}`}>
            {upstreamPricing ? 'Upstream' : 'Sane'}
          </div>
          <div className="text-[11px] text-text-dim mb-2">
            {upstreamPricing ? 'vendor × rarity, uncapped' : '100 k Solari cap'}
          </div>
          <button className="btn-secondary text-[11px] self-start" disabled={togglingPricing || !draft}
            onClick={() => { void togglePricingMode(!upstreamPricing) }}
            title="Wipes Duke's listings and switches the pricing formula. The new prices take effect on the next list tick.">
            <Icon name={togglingPricing ? 'Loader2' : 'ArrowLeftRight'} size={12}
              className={togglingPricing ? 'animate-spin' : ''} />
            {' '}{togglingPricing ? 'Switching…' : (upstreamPricing ? 'Switch to sane' : 'Switch to upstream')}
          </button>
        </div>
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
        <div className="card p-3 mb-4 text-sm text-danger break-words flex items-start gap-3">
          <div className="flex-1">
            <span className="font-semibold">Bot error:</span> {status.error}
          </div>
          <button
            className="btn-secondary text-xs shrink-0"
            disabled={dismissingError}
            onClick={dismissError}
            title="Dismiss this stale error message">
            <Icon name={dismissingError ? 'Loader2' : 'X'} size={13} className={dismissingError ? 'animate-spin' : ''} />
            Dismiss
          </button>
        </div>
      )}

      {/* Seed market progress — surfaced ABOVE the subtab nav so it's visible
          from any subtab. Only renders while a seed is running, or for ~30s
          after one completes so the user can see the final state. */}
      {seedProgress && (seeding || isRecentSeedFinish(seedProgress)) && (
        <div className="card p-3 mb-4 border-l-2 border-l-accent">
          <div className="text-xs uppercase tracking-wider text-text-dim mb-2 flex items-center gap-2">
            <Icon name={seeding ? 'Loader2' : (seedProgress.phase === 'error' ? 'AlertCircle' : (seedProgress.phase === 'aborted' ? 'XCircle' : 'CheckCircle2'))}
                  size={14}
                  className={seeding ? 'animate-spin text-accent' : (seedProgress.phase === 'error' ? 'text-danger' : (seedProgress.phase === 'aborted' ? 'text-warning' : 'text-success'))} />
            Seed market — {seeding ? 'in progress' : (seedProgress.phase === 'error' ? 'failed' : (seedProgress.phase === 'aborted' ? 'aborted' : 'done'))}
            {seeding && (
              <button className="btn-secondary ml-auto text-xs" disabled={aborting} onClick={() => { void doAbortSeed() }}>
                <Icon name={aborting ? 'Loader2' : 'X'} size={13} className={aborting ? 'animate-spin' : ''} />
                {aborting ? 'Aborting…' : 'Abort'}
              </button>
            )}
          </div>
          <SeedProgressView progress={seedProgress} />
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
          balanceBusy={balanceBusy}
          onTick={doTick} onMaintainBalance={maintainBalance}
          onToggleEnabled={toggleEnabled} />
      )}

      {draft && sub === 'list' && (
        <ListSection draft={draft} setDraft={setDraft} listTick={listTick} listTicking={listTickBusy}
          snapshot={snapshot} snapshotLoading={snapshotLoading}
          seeding={seeding} seedLaunchError={seedLaunchError}
          clearing={clearing}
          onListTick={doListTick} onLoadSnapshot={loadSnapshot} onSeedMarket={doSeedMarket}
          onClear={clearListings} />
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
function BuySection({ draft, setDraft, status, tick, ticking, balanceBusy,
  onTick, onMaintainBalance, onToggleEnabled }: {
    draft: BotConfig; setDraft: (c: BotConfig) => void; status: BotStatus | null;
    tick: BotTickResult | null; ticking: boolean; balanceBusy: boolean;
    onTick: (dry: boolean) => void; onMaintainBalance: () => void;
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
        <div className="mt-4 pt-3 border-t border-border">
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 items-end">
            <Toggle label="Over-market guard" checked={draft.over_market_guard ?? false}
              onChange={v => setDraft({ ...draft, over_market_guard: v })} />
            <NumField label="Max over market (%)" value={draft.over_market_pct ?? 5}
              onChange={v => setDraft({ ...draft, over_market_pct: v })}
              disabled={!(draft.over_market_guard ?? false)} />
            <NumField label="No-price baseline" value={draft.over_market_baseline ?? 100}
              onChange={v => setDraft({ ...draft, over_market_baseline: v })}
              disabled={!(draft.over_market_guard ?? false) || (draft.over_market_allow_unpriced ?? false)} />
          </div>
          <div className="mt-3">
            <Toggle label="Allow items with no market price"
              checked={draft.over_market_allow_unpriced ?? false}
              onChange={v => setDraft({ ...draft, over_market_allow_unpriced: v })}
              disabled={!(draft.over_market_guard ?? false)} />
          </div>
          <p className="text-[11px] text-text-dim mt-2">
            When on, a winning roll only buys if the seller's price is within this percentage of Duke's
            reference (market) price for the item. A roll that wins but is over the window is skipped and
            the reason is logged to the console.
          </p>
          <p className="text-[11px] text-text-dim mt-1">
            For items Duke has no market price for: leave <em>Allow…</em> off to judge them against the
            editable <em>No-price baseline</em>, or turn it on to buy them anyway (no reference → can't judge).
          </p>
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
        {(tick.blocked ?? 0) > 0 && <span className="text-warning"><span className="text-text-dim">over-market:</span> {fmtNum(tick.blocked ?? 0)}</span>}
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
  seeding, seedLaunchError, clearing,
  onListTick, onLoadSnapshot, onSeedMarket, onClear }: {
    draft: BotConfig; setDraft: (c: BotConfig) => void;
    listTick: BotListTickResult | null; listTicking: boolean;
    snapshot: BotVendorCandidate[] | null; snapshotLoading: boolean;
    seeding: boolean; seedLaunchError: string | null;
    clearing: boolean;
    onListTick: () => void; onLoadSnapshot: () => void;
    onSeedMarket: () => void; onClear: () => void;
  }) {
  return (
    <div className="space-y-4">
      <div className="card p-4 border-l-2 border-l-accent">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
            <Icon name="Sparkles" size={14} className="text-accent" /> Seed market (immediate bulk-list)
          </h4>
          <button className="btn-primary" disabled={seeding} onClick={onSeedMarket}>
            <Icon name={seeding ? 'Loader2' : 'Zap'} size={15} className={seeding ? 'animate-spin' : ''} /> {seeding ? 'Seeding…' : 'Seed market'}
          </button>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Bypasses the live NPC vendor snapshot (which depends on the in-game market already having activity)
          and the mask-cache SSH refresh. Walks the bundled item catalog intersected with the persistent mask cache
          and tops Duke up to <span className="font-mono">{draft.listings_per_grade}</span> per template in one
          batched transaction per ~100 templates. Runs in the background — the button reactivates when it finishes.
        </p>
        {seedLaunchError && (
          <div className="text-danger text-xs mb-2">Launch failed: {seedLaunchError}</div>
        )}
        {seeding && (
          <div className="text-[11px] text-accent">Seed running — see progress banner above.</div>
        )}
      </div>

      <div className="card p-4">
        <div className="flex items-center justify-between mb-2">
          <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
            <Icon name="Tags" size={14} className="text-accent" /> Run a list tick
          </h4>
          <div className="flex items-center gap-2">
            <button className="btn-secondary" disabled={clearing} onClick={onClear}
              title="Delete all of Duke's own market listings.">
              <Icon name={clearing ? 'Loader2' : 'Trash2'} size={15} className={clearing ? 'animate-spin' : ''} /> Clear Duke listings
            </button>
            <button className="btn-primary" disabled={listTicking} onClick={onListTick}>
              <Icon name={listTicking ? 'Loader2' : 'Play'} size={15} className={listTicking ? 'animate-spin' : ''} /> Run now
            </button>
          </div>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Snapshots live NPC vendor inventory, applies sane-pricing rules, and tops up Duke's own listings to
          <span className="font-mono"> {draft.listings_per_grade}</span> per (item, grade).
        </p>
        {listTick && <ListTickResultView tick={listTick} />}
      </div>

      <div className="card p-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <NumField label="List tick (s)" value={draft.list_tick_interval}
          onChange={v => setDraft({ ...draft, list_tick_interval: v })} />
        <NumField label="Listings / grade" value={draft.listings_per_grade}
          onChange={v => setDraft({ ...draft, listings_per_grade: v })} />
        <Toggle label="Stackables only" checked={draft.stackables_only}
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

function SeedProgressView({ progress }: { progress: BotSeedProgress }) {
  const running = !!progress.running
  const done = progress.chunks_done ?? 0
  const total = progress.chunks_total ?? 0
  const pct = total > 0 ? Math.min(100, Math.round((done / total) * 100)) : (running ? 0 : 100)
  const isError = progress.phase === 'error'
  const isDone  = progress.phase === 'done'
  const barClass = isError ? 'bg-danger' : isDone ? 'bg-success' : 'bg-accent'
  const label = running
    ? (progress.phase === 'starting' ? 'Starting…'
      : progress.phase === 'reading-listings' ? "Reading Duke's current listings…"
      : progress.phase === 'writing' ? `Writing chunk ${fmtNum(done)} of ${fmtNum(total || done)}`
      : `Phase: ${progress.phase ?? '?'}`)
    : isError ? 'Failed'
    : isDone ? 'Done'
    : (progress.phase ?? 'idle')

  return (
    <div className="text-sm space-y-2">
      <div className="flex items-center gap-2">
        <div className="flex-1 h-2 rounded-full bg-surface-2 overflow-hidden">
          <div className={`h-full ${barClass} transition-all duration-300`} style={{ width: `${pct}%` }} />
        </div>
        <span className="font-mono text-xs text-text-dim w-12 text-right">{pct}%</span>
      </div>
      <div className="text-xs text-text-muted">{label}</div>
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-text-muted text-xs">
        {progress.masks_known != null && (
          <span><span className="text-text-dim">masks known:</span> {fmtNum(progress.masks_known)}</span>
        )}
        {progress.considered != null && (
          <span><span className="text-text-dim">considered:</span> {fmtNum(progress.considered)}</span>
        )}
        {progress.eligible != null && (
          <span><span className="text-text-dim">eligible:</span> {fmtNum(progress.eligible)}</span>
        )}
        {progress.inserted != null && (
          <span className="text-success"><span className="text-text-dim">inserted:</span> {fmtNum(progress.inserted)}</span>
        )}
        {total > 0 && (
          <span><span className="text-text-dim">chunks:</span> {fmtNum(done)} / {fmtNum(total)}</span>
        )}
        {progress.errors != null && progress.errors > 0 && (
          <span className="text-danger"><span className="text-text-dim">errors:</span> {fmtNum(progress.errors)}</span>
        )}
        {progress.listed_after != null && (
          <span><span className="text-text-dim">listed after:</span> {fmtNum(progress.listed_after)}</span>
        )}
        {progress.last_chunk_ms != null && progress.last_chunk_ms > 0 && (
          <span><span className="text-text-dim">last chunk:</span> {(progress.last_chunk_ms / 1000).toFixed(1)}s</span>
        )}
      </div>
      {progress.message && (
        <div className={`text-[11px] break-words ${isError ? 'text-danger' : 'text-text-dim'}`}>{progress.message}</div>
      )}
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
        {(tick.market_medians ?? 0) > 0 && <span className="text-accent"><span className="text-text-dim">market medians:</span> {fmtNum(tick.market_medians ?? 0)}</span>}
        {tick.wiped && <span className="text-warning"><span className="text-text-dim">listings:</span> wiped & rebuilding</span>}
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
// Market-follow pricing card. Lists at the median of competing player sell
// orders + a markup, instead of the formula. All-or-nothing; toggling wipes &
// rebuilds Duke's listings on the next list tick (server flags relist_pending
// in Save-DuneBotConfig). Includes a collapsible explainer + per-control
// tooltips so operators understand each knob.
// ---------------------------------------------------------------------------
function MarketFollowCard({ draft, setDraft }: { draft: BotConfig; setDraft: (c: BotConfig) => void }) {
  const on = draft.market_follow_enabled ?? false
  const noMarket = draft.market_follow_no_market ?? 'formula'
  const noMarketOpts: [string, string, string][] = [
    ['formula', 'Formula', 'List at the normal tier/rarity/vendor price'],
    ['skip', 'Skip', "Don't list items with no competing market"],
    ['baseline', 'Baseline', 'List at a fixed baseline price you set'],
  ]
  const toggleFollow = (next: boolean) => {
    const msg = next
      ? "Turn ON market-follow pricing?\n\nDuke will price EVERY listing from the live market — the median of other players' sell orders for each item, plus your markup. This is all-or-nothing: it replaces the formula/upstream pricing entirely.\n\nDuke's current listings will be WIPED and rebuilt at the new prices on the next list tick. This cannot be undone.\n\nProceed?"
      : "Turn OFF market-follow pricing?\n\nDuke will go back to formula/upstream pricing for every listing.\n\nDuke's current listings will be WIPED and rebuilt on the next list tick. This cannot be undone.\n\nProceed?"
    if (!window.confirm(msg)) return
    setDraft({ ...draft, market_follow_enabled: next })
  }
  return (
    <div className="card p-4 space-y-3 border-l-2 border-accent">
      <div className="flex items-center justify-between gap-3">
        <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-2">
          <Icon name="TrendingUp" size={14} className="text-accent" /> Market-follow pricing
        </h4>
        <span className={`text-[11px] px-2 py-0.5 rounded-full ${on ? 'bg-accent/20 text-accent' : 'bg-surface-3 text-text-dim'}`}>
          {on ? 'ON — following market' : 'OFF — using formula'}
        </span>
      </div>

      <Toggle label="Follow market price (median + %)" checked={on} onChange={toggleFollow} />

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 items-end">
        <div title="Duke lists at the market median for an item, multiplied by (1 + this %). Start at 10%.">
          <NumField label="Market markup (%)" value={draft.market_follow_pct ?? 10}
            onChange={v => setDraft({ ...draft, market_follow_pct: v })} disabled={!on} />
        </div>
        <div title="Minimum number of competing sell orders before Duke trusts a median. Below this, the no-market rule applies.">
          <NumField label="Min competing orders" value={draft.market_follow_min_samples ?? 1}
            onChange={v => setDraft({ ...draft, market_follow_min_samples: v })} disabled={!on} />
        </div>
        {noMarket === 'baseline' && (
          <div title="Price used (times 1 + markup%) for items nobody else is selling, when 'Baseline' is chosen below.">
            <NumField label="Baseline price (item_price)" value={draft.market_follow_baseline ?? 100}
              onChange={v => setDraft({ ...draft, market_follow_baseline: v })} disabled={!on} />
          </div>
        )}
      </div>

      <div>
        <span className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">When nobody else is selling an item</span>
        <div className="inline-flex rounded-lg border border-border overflow-hidden">
          {noMarketOpts.map(([val, label, tip]) => (
            <button key={val} type="button" disabled={!on} title={tip}
              onClick={() => setDraft({ ...draft, market_follow_no_market: val as 'formula' | 'skip' | 'baseline' })}
              className={`px-3 py-1.5 text-xs font-medium transition-colors disabled:opacity-50 ${noMarket === val ? 'bg-accent text-bg' : 'bg-surface-2 text-text-muted hover:text-text'}`}>
              {label}
            </button>
          ))}
        </div>
      </div>

      <div title="When on, the buy-side over-market guard (dice roll AND price within the over-market % of the market median) is forced on in this mode, even if the standalone guard toggle on the Buy tab is off.">
        <Toggle label="Force buy guard in this mode" checked={draft.market_follow_force_guard ?? true}
          onChange={v => setDraft({ ...draft, market_follow_force_guard: v })} disabled={!on} />
      </div>

      <details className="rounded-lg border border-border bg-surface-2/40 p-3">
        <summary className="text-sm font-medium text-text cursor-pointer select-none">How market-follow pricing works</summary>
        <div className="mt-2 space-y-2 text-[11px] text-text-muted leading-relaxed">
          <p>
            <strong>The basis.</strong> For each item, Duke finds the <strong>median</strong> price of all
            <em> other</em> players' current sell orders (his own and other bots' listings are excluded), per
            quality grade where there's data. He then lists at <span className="font-mono">median × (1 + markup%)</span>.
            Use this when the formula under-prices things (e.g. augments).
          </p>
          <p>
            <strong>Min competing orders.</strong> A median is only trusted once at least this many other
            sellers are listing the item. Thinner markets fall through to the no-market rule.
          </p>
          <p>
            <strong>When nobody else is selling.</strong> <em>Formula</em> keeps Duke listing the item at the
            normal tier/rarity price; <em>Skip</em> leaves it unlisted; <em>Baseline</em> lists it at the fixed
            baseline price you set (also × 1 + markup%).
          </p>
          <p>
            <strong>Buy side.</strong> With <em>Force buy guard</em> on, a winning dice roll only buys when the
            seller's price is within the over-market % (set on the Buy tab) of the market median — so Duke never
            overpays even while following the market. Everything else on the buy side is bypassed except the dice roll.
          </p>
          <p className="text-warning">
            <strong>All-or-nothing + wipe.</strong> This replaces the formula/upstream pricing for every listing.
            Enabling or disabling it wipes and rebuilds all of Duke's listings on the next list tick so prices
            switch over cleanly.
          </p>
        </div>
      </details>
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

  const [showAddOverride, setShowAddOverride] = useState(false)
  const [newTmpl, setNewTmpl] = useState('')
  const [newName, setNewName] = useState('')
  const [newPrice, setNewPrice] = useState('0')

  const setMap = (key: 'tier_base_prices' | 'stack_unit_prices' | 'category_factors' | 'rarity_multipliers' | 'vendor_multipliers',
                  next: Record<string, number>) => {
    setDraft({ ...draft, [key]: next })
  }

  const tierKeys = ['0', '1', '2', '3', '4', '5', '6']

  return (
    <div className="space-y-4">
      <MarketFollowCard draft={draft} setDraft={setDraft} />

      <div className="card p-3 text-xs text-text-muted border-l-2 border-warning flex items-start gap-2">
        <Icon name="TriangleAlert" size={14} className="text-warning shrink-0 mt-0.5" />
        <span>
          Sane-pricing defaults (item_price cap, tier base prices, category factors, rarity multipliers,
          and 95 % vendor floor) govern the bot's pricing. Touch with care — these directly drive
          every listing the bot writes.
        </span>
      </div>

      <div className="card p-4 grid grid-cols-1 sm:grid-cols-3 gap-4">
        <NumField label="Price cap (item_price)" value={draft.price_cap ?? 100000}
          onChange={v => setDraft({ ...draft, price_cap: v })} />
        <NumField label="Price floor (item_price, 0 = off)" value={draft.price_floor ?? 50}
          onChange={v => setDraft({ ...draft, price_floor: v })} />
        <NumField label="Default unit price (fallback)" value={draft.default_unit_price ?? 50}
          onChange={v => setDraft({ ...draft, default_unit_price: v })} />
      </div>

      <div className="card p-4 space-y-3">
        <Toggle label="Cap displayed price (Solari)" checked={draft.display_cap_enabled ?? false}
          onChange={v => setDraft({ ...draft, display_cap_enabled: v })} />
        <p className="text-[11px] text-text-dim">
          Off by default. The in-game Solari shown to players is the stored item_price × 10, so the
          Price cap above (100,000) actually displays as up to 1,000,000 Solari. Turn this on to cap
          the real player-facing number — e.g. 100,000 keeps every Duke listing at or under 100 k Solari.
        </p>
        <NumField label="Displayed price cap (Solari)" value={draft.display_cap_solari ?? 100000}
          disabled={!(draft.display_cap_enabled ?? false)}
          onChange={v => setDraft({ ...draft, display_cap_solari: v })} />
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
          <button className="btn-secondary text-xs" onClick={() => setShowAddOverride(s => !s)}>
            <Icon name={showAddOverride ? 'X' : 'Plus'} size={13} /> {showAddOverride ? 'Cancel' : 'Add override'}
          </button>
        </div>
        <p className="text-[11px] text-text-dim mb-2">
          Manual price (Solari, integer) for specific template IDs. Overrides win over the formula, then the 100 k cap applies.
        </p>
        {showAddOverride && (
          <div className="mb-3 p-3 rounded-lg bg-surface-2 border border-border space-y-2">
            <ItemPicker
              value={newTmpl}
              displayValue={newName || newTmpl}
              onChange={(tpl, item) => { setNewTmpl(tpl); setNewName(item ? item.name : '') }}
              label="Item"
              placeholder="Type to search items by name or template id…"
              autoFocus
            />
            <div className="flex items-end gap-2">
              <label className="block flex-1 max-w-[200px]">
                <span className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Override price (Solari)</span>
                <input type="number" value={newPrice} min={0}
                  onChange={e => setNewPrice(e.target.value)}
                  className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad" />
              </label>
              <button className="btn-primary"
                disabled={!newTmpl.trim() || !Number.isFinite(parseInt(newPrice, 10)) || parseInt(newPrice, 10) < 0}
                onClick={() => {
                  const tmpl = newTmpl.trim()
                  const n = parseInt(newPrice, 10)
                  if (!tmpl || !Number.isFinite(n) || n < 0) return
                  setDraft({ ...draft, price_overrides: { ...overrides, [tmpl]: n } })
                  setNewTmpl(''); setNewName(''); setNewPrice('0'); setShowAddOverride(false)
                }}>
                <Icon name="Plus" size={14} /> Add
              </button>
            </div>
          </div>
        )}
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
