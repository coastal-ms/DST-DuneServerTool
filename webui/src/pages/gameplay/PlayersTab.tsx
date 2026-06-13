// v11.5.6 — Players tab. Two-column layout: left rail with player list +
// section selector, right pane with active section content.
//
// Reads /api/gameplay/players for the list + /api/gameplay/players/summary
// for the server overview. Each section component owns its own data fetch.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getPlayers, getPlayerSummary,
  type Player, type PlayerSummaryResponse, type DataSource,
} from '../../api/gameplay'
import { fmtNum, SourceBadge, StatCard, DemoNotice } from './shared'
import {
  SECTIONS, SECTION_COMPONENTS, type SectionId,
} from './players/sections'
import { CoriolisAdmin } from './players/coriolis'

type OnlineFilter = '' | 'online' | 'offline'

const isOnline = (s: string) => s.toLowerCase().includes('online')

export function PlayersTab() {
  const [players, setPlayers]   = useState<Player[]>([])
  const [source, setSource]     = useState<DataSource>('demo')
  const [liveError, setLive]    = useState<string | undefined>()
  const [loading, setLoading]   = useState(true)
  const [error, setError]       = useState<string | null>(null)
  const [search, setSearch]     = useState('')
  const [online, setOnline]     = useState<OnlineFilter>('')
  const [hideGm, setHideGm]     = useState<boolean>(() => {
    try { return localStorage.getItem('dst.players.hideGm') === '1' } catch { return false }
  })
  const [gmNoticeDismissed, setGmNoticeDismissed] = useState<boolean>(() => {
    try { return localStorage.getItem('dst.players.gmNoticeDismissed') === '1' } catch { return false }
  })
  const [selectedId, setSel]    = useState<number | null>(null)
  const [section, setSection]   = useState<SectionId>('stats')
  const [flash, setFlash]       = useState<{ msg: string; kind: 'ok' | 'err' } | null>(null)
  const [refreshKey, setRefresh] = useState(0)
  const [summary, setSummary]   = useState<PlayerSummaryResponse | null>(null)

  const loadList = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getPlayers()
      setPlayers(r.players); setSource(r.source); setLive(r.liveError)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  const loadSummary = useCallback(async () => {
    try {
      const r = await getPlayerSummary()
      setSummary(r)
    } catch {
      // summary is best-effort
    }
  }, [])

  useEffect(() => { void loadList(); void loadSummary() }, [loadList, loadSummary])

  // Auto-dismiss flash after 4s.
  useEffect(() => {
    if (!flash) return
    const t = window.setTimeout(() => setFlash(null), 4000)
    return () => window.clearTimeout(t)
  }, [flash])

  // Esc closes the open player and returns to the Server Overview. Ignored
  // when the user is typing in an input/textarea/contenteditable so it does
  // not steal escapes from inline forms.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const t = e.target as HTMLElement | null
      const tag = t?.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || t?.isContentEditable) return
      setSel(null)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // GM filter applies to the whole tab — counts, summary buckets, and the
  // list all hide the bot when toggled on.
  const visiblePlayers = useMemo(
    () => hideGm ? players.filter(p => (p.name || '').trim().toLowerCase() !== 'gm') : players,
    [players, hideGm],
  )

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    let out = visiblePlayers
    if (q) out = out.filter(p =>
      p.name.toLowerCase().includes(q) ||
      p.faction_name.toLowerCase().includes(q) ||
      String(p.id).includes(q) ||
      String(p.account_id).includes(q))
    if (online === 'online')  out = out.filter(p => isOnline(p.online_status))
    if (online === 'offline') out = out.filter(p => !isOnline(p.online_status))
    return [...out].sort((a, b) => {
      const ao = isOnline(a.online_status) ? 0 : 1
      const bo = isOnline(b.online_status) ? 0 : 1
      if (ao !== bo) return ao - bo
      return (a.name || '').localeCompare(b.name || '')
    })
  }, [visiblePlayers, search, online])

  const onlineCount = useMemo(() => visiblePlayers.filter(p => isOnline(p.online_status)).length, [visiblePlayers])

  // When hiding GM, rebuild the by_faction / by_map / totals locally from
  // visiblePlayers so the Server Overview buckets and the Factions stat card
  // do not count the bot. Otherwise pass the API summary through unchanged.
  const displaySummary = useMemo<PlayerSummaryResponse | null>(() => {
    if (!hideGm) return summary
    const buckets = (key: 'faction_name' | 'map') => {
      const m = new Map<string, number>()
      for (const p of visiblePlayers) {
        const name = (p[key] as string) || ''
        if (!name) continue
        m.set(name, (m.get(name) || 0) + 1)
      }
      return Array.from(m, ([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count)
    }
    const by_faction = buckets('faction_name')
    const by_map = buckets('map')
    return {
      ...(summary ?? {}),
      by_faction,
      by_map,
      totals: {
        ...(summary?.totals ?? {}),
        players: visiblePlayers.length,
        online: visiblePlayers.filter(p => isOnline(p.online_status)).length,
        factions: by_faction.length,
      },
    } as PlayerSummaryResponse
  }, [summary, hideGm, visiblePlayers])

  const selected = useMemo(() => players.find(p => p.id === selectedId) ?? null, [players, selectedId])

  const refresh = useCallback(() => {
    setRefresh(k => k + 1)
    void loadList()
    void loadSummary()
  }, [loadList, loadSummary])

  const SectionComponent = SECTION_COMPONENTS[section]

  return (
    <div>
      {/* Top-of-tab stat cards */}
      <section className="grid grid-cols-2 md:grid-cols-3 gap-3 mb-4">
        <StatCard label="Players"    value={fmtNum(visiblePlayers.length)}                                                icon="Users" />
        <StatCard label="Online now" value={fmtNum(onlineCount)}                                                          icon="Wifi" />
        <StatCard label="Factions"   value={fmtNum(displaySummary?.totals.factions ?? new Set(visiblePlayers.map(p => p.faction_name).filter(Boolean)).size)} icon="Flag" />
      </section>

      <div className="card p-3 mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[200px]">
          <Icon name="Search" size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-dim" />
          <input type="text" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search players, factions, ids…"
            className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <div className="flex rounded-lg border border-border overflow-hidden">
          {([['', 'All'], ['online', 'Online'], ['offline', 'Offline']] as const).map(([val, label]) => (
            <button key={val} onClick={() => setOnline(val)}
              className={`px-3 py-1.5 text-xs ${online === val ? 'bg-accent/20 text-accent-bright' : 'bg-surface-2 text-text-muted hover:text-text'}`}>
              {label}
            </button>
          ))}
        </div>
        <button onClick={() => {
            setHideGm(v => {
              const next = !v
              try { localStorage.setItem('dst.players.hideGm', next ? '1' : '0') } catch { /* ignore */ }
              return next
            })
          }}
          title={hideGm ? 'Showing real players only — click to include GM bot' : 'Hide the GM admin bot from the list'}
          className={`px-3 py-1.5 text-xs rounded-lg border flex items-center gap-1.5 ${hideGm ? 'bg-accent/20 text-accent-bright border-accent/40' : 'bg-surface-2 text-text-muted hover:text-text border-border'}`}>
          <Icon name={hideGm ? 'EyeOff' : 'Eye'} size={13} /> {hideGm ? 'GM hidden' : 'Hide GM'}
        </button>
        <button className="btn-secondary" onClick={refresh} disabled={loading}>
          <Icon name="RefreshCw" size={14} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
        <SourceBadge source={source} />
      </div>

      {source === 'demo' && <DemoNotice liveError={liveError} what="player data" />}
      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      {/* GM bot explainer — shown only when a "GM" entry is actually present in
          the live data, when the user hasn't already hidden it, and when they
          haven't dismissed this notice. New users have repeatedly thought the
          GM row was a real player who joined their server, so the explainer
          calls it out and offers a one-click toggle. */}
      {!hideGm && !gmNoticeDismissed && players.some(p => (p.name || '').trim().toLowerCase() === 'gm') && (
        <div className="card p-3 mb-4 text-xs flex items-start gap-3 border-accent/30 bg-accent/5">
          <Icon name="Info" size={14} className="text-accent-bright shrink-0 mt-0.5" />
          <div className="flex-1 min-w-0">
            <div className="text-text">
              <span className="font-medium">Heads up:</span> the player named <span className="font-mono">GM</span> is
              a Funcom-seeded system NPC used by the server for admin broadcasts — it isn't a real player who joined,
              and it doesn't occupy a slot. New servers and some patches re-seed it automatically.
            </div>
            <div className="mt-1.5 flex items-center gap-2">
              <button
                type="button"
                onClick={() => {
                  setHideGm(true)
                  try { localStorage.setItem('dst.players.hideGm', '1') } catch { /* ignore */ }
                }}
                className="px-2 py-0.5 rounded bg-accent/20 hover:bg-accent/30 text-accent-bright text-[11px] font-medium">
                Hide GM bot
              </button>
              <button
                type="button"
                onClick={() => {
                  setGmNoticeDismissed(true)
                  try { localStorage.setItem('dst.players.gmNoticeDismissed', '1') } catch { /* ignore */ }
                }}
                className="px-2 py-0.5 rounded bg-surface-2 hover:bg-surface-3 text-text-muted hover:text-text text-[11px]">
                Got it
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Two-column body */}
      <div className="grid grid-cols-1 lg:grid-cols-[320px_1fr] gap-4">
        {/* Left rail */}
        <aside className="space-y-3 min-w-0">
          {/* Player list */}
          <div className="card p-0 overflow-hidden">
            <div className="px-3 py-2 border-b border-border text-[11px] uppercase tracking-wider text-text-dim flex items-center justify-between">
              <span>Players</span>
              <span className="font-mono text-text-muted">{fmtNum(filtered.length)}</span>
            </div>
            <div className="max-h-[60vh] overflow-y-auto">
              {loading && filtered.length === 0 ? (
                <div className="px-3 py-6 text-center text-text-dim text-sm">
                  <Icon name="Loader2" size={15} className="animate-spin inline" /> Loading…
                </div>
              ) : filtered.length === 0 ? (
                <div className="px-3 py-6 text-center text-text-dim text-sm">No players match.</div>
              ) : (
                filtered.map(p => (
                  <button key={p.id} type="button" onClick={() => setSel(cur => cur === p.id ? null : p.id)}
                    title={selectedId === p.id ? 'Click again to close and return to Server Overview' : undefined}
                    className={`w-full flex items-center justify-between gap-2 px-3 py-2 text-left border-b border-border/30 hover:bg-surface-2 ${selectedId === p.id ? 'bg-surface-2 border-l-2 border-l-accent' : ''}`}>
                    <span className="min-w-0 flex-1">
                      <div className="text-sm text-text truncate">{p.name || <span className="italic text-text-dim">Unnamed</span>}</div>
                      <div className="text-[11px] text-text-dim truncate">
                        {p.faction_name || 'Unaligned'} {p.map ? `· ${p.map}` : ''}
                      </div>
                    </span>
                    <span className={`shrink-0 w-2 h-2 rounded-full ${isOnline(p.online_status) ? 'bg-success' : 'bg-text-dim/40'}`}
                      title={p.online_status} />
                  </button>
                ))
              )}
            </div>
          </div>

          {/* Section nav (only when a player is selected) */}
          {selected && (
            <div className="card p-0 overflow-hidden">
              <div className="px-3 py-2 border-b border-border text-[11px] uppercase tracking-wider text-text-dim">
                Sections
              </div>
              {SECTIONS.map(s => (
                <button key={s.id} type="button" onClick={() => setSection(s.id)}
                  className={`w-full flex items-center gap-2 px-3 py-2 text-sm text-left border-b border-border/30 last:border-b-0 hover:bg-surface-2 ${section === s.id ? 'bg-surface-2 text-accent-bright border-l-2 border-l-accent' : 'text-text'}`}>
                  <Icon name={s.icon} size={14} className="text-text-dim" />
                  <span>{s.label}</span>
                </button>
              ))}
            </div>
          )}
        </aside>

        {/* Right pane */}
        <section className="min-w-0">
          {flash && (
            <div className={`card p-2.5 mb-3 text-xs border-l-2 break-words ${flash.kind === 'ok' ? 'text-success border-success' : 'text-danger border-danger'}`}>
              {flash.msg}
            </div>
          )}
          {selected ? (
            <div className="space-y-3">
              <PlayerHeader player={selected} onClose={() => setSel(null)} />
              <SectionComponent
                player={selected}
                canWrite={source === 'live'}
                demo={source === 'demo'}
                refreshKey={refreshKey}
                flash={(msg, kind = 'ok') => setFlash({ msg, kind })}
                onChanged={refresh}
              />
            </div>
          ) : (
            <>
              <ServerOverview summary={displaySummary} />
              <div className="mt-3">
                <CoriolisAdmin flash={(msg, kind = 'ok') => setFlash({ msg, kind })} />
              </div>
            </>
          )}
        </section>
      </div>
    </div>
  )
}

function PlayerHeader({ player, onClose }: { player: Player; onClose: () => void }) {
  return (
    <div className="card p-3 flex items-start justify-between gap-3">
      <div className="min-w-0 flex-1">
        <h3 className="text-lg font-semibold text-text truncate">{player.name || 'Unnamed player'}</h3>
        <div className="text-xs text-text-dim flex flex-wrap gap-x-3 gap-y-0.5 mt-1">
          <span><Icon name="Hash" size={11} className="inline" /> pawn {player.id}</span>
          <span>account {player.account_id}</span>
          <span>controller {player.controller_id}</span>
          {player.class && <span>{player.class}</span>}
        </div>
        <div className="mt-2 flex items-center gap-3 text-xs text-text-muted">
          {player.faction_name && <span><Icon name="Flag" size={11} className="inline mr-1" />{player.faction_name}</span>}
          {player.map && <span><Icon name="MapPin" size={11} className="inline mr-1" />{player.map}</span>}
          <span className={isOnline(player.online_status) ? 'text-success' : 'text-text-dim'}>
            <Icon name={isOnline(player.online_status) ? 'Wifi' : 'WifiOff'} size={11} className="inline mr-1" />
            {player.online_status}
          </span>
        </div>
      </div>
      <button type="button" onClick={onClose}
        title="Close player (back to Server Overview) - Esc"
        className="shrink-0 text-text-dim hover:text-text rounded-lg p-1.5 hover:bg-surface-2 flex items-center gap-1 text-xs">
        <Icon name="X" size={14} /> Close
      </button>
    </div>
  )
}

function ServerOverview({ summary }: { summary: PlayerSummaryResponse | null }) {
  return (
    <div className="space-y-3">
      <div className="card p-4">
        <div className="flex items-center gap-2 text-xs uppercase tracking-wider text-text-dim mb-2">
          <Icon name="LayoutDashboard" size={13} /> Server overview
        </div>
        <p className="text-sm text-text-dim">Pick a player from the list to inspect or edit their data.</p>
      </div>

      {summary && (
        <>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <Bucket title="By faction" data={summary.by_faction} icon="Flag" />
            <Bucket title="By map"     data={summary.by_map}     icon="MapPin" />
          </div>
        </>
      )}
    </div>
  )
}

function Bucket({ title, data, icon }: {
  title: string; data: { name: string; count: number }[]; icon: string
}) {
  const total = data.reduce((acc, r) => acc + (r.count || 0), 0)
  const sorted = [...data].sort((a, b) => b.count - a.count)
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between mb-2">
        <h4 className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-1.5">
          <Icon name={icon} size={13} /> {title}
        </h4>
        <span className="font-mono text-xs text-text-muted">{fmtNum(total)}</span>
      </div>
      {sorted.length === 0 ? (
        <div className="text-sm text-text-dim italic">No data.</div>
      ) : (
        <div className="space-y-1.5">
          {sorted.map(row => {
            const pct = total > 0 ? (row.count / total) * 100 : 0
            return (
              <div key={row.name}>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-text truncate">{row.name || '—'}</span>
                  <span className="font-mono text-text-muted">{fmtNum(row.count)}</span>
                </div>
                <div className="h-1 bg-surface-2 rounded-full overflow-hidden">
                  <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
