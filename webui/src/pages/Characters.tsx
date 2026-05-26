// Characters page — list + tabbed editor (full v6.0.x parity).
import { useEffect, useMemo, useRef, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { EmptyState } from './characters/Shared'
import { StatsTab }     from './characters/StatsTab'
import { TechTab }      from './characters/TechTab'
import { SpecsTab }     from './characters/SpecsTab'
import { EconomyTab }   from './characters/EconomyTab'
import { CosmeticsTab } from './characters/CosmeticsTab'
import { InventoryTab } from './characters/InventoryTab'
import {
  getCharacter, getCharacterDefs, getItemCatalog, listCharacters,
} from '../api/characters'
import { useStatus } from '../hooks/useStatus'
import type {
  CharacterDefs, CharacterDetail, CharacterListEntry, CharactersListResponse, ItemCatalog,
} from '../api/types'

type TabId = 'stats' | 'tech' | 'specs' | 'economy' | 'cosmetics' | 'inventory'
const TABS: { id: TabId; label: string; icon: string }[] = [
  { id: 'stats',     label: 'Stats',       icon: 'HeartPulse' },
  { id: 'tech',      label: 'Tech Tree',   icon: 'Wrench' },
  { id: 'specs',     label: 'Specs',       icon: 'Sparkles' },
  { id: 'economy',   label: 'Economy',     icon: 'Coins' },
  { id: 'cosmetics', label: 'Cosmetics',   icon: 'Shirt' },
  { id: 'inventory', label: 'Inventory',   icon: 'Backpack' },
]

export function Characters() {
  const { status } = useStatus()
  const vmRunning = status?.vm?.running === true

  // ---- list -----
  const [list, setList] = useState<CharactersListResponse | null>(null)
  const [listLoading, setListLoading] = useState(true)
  const [listError, setListError] = useState<string | null>(null)
  const [search, setSearch] = useState('')

  async function refreshList() {
    setListLoading(true); setListError(null)
    try { setList(await listCharacters()) }
    catch (e) { setListError(e instanceof Error ? e.message : String(e)); setList(null) }
    finally { setListLoading(false) }
  }
  useEffect(() => { void refreshList() }, [])

  // ---- catalog defs (load once) -----
  const [defs, setDefs] = useState<CharacterDefs | null>(null)
  const [catalog, setCatalog] = useState<ItemCatalog | null>(null)
  const [catalogLoading, setCatalogLoading] = useState(true)
  useEffect(() => {
    void (async () => {
      try { setDefs(await getCharacterDefs()) } catch {}
    })()
    void (async () => {
      setCatalogLoading(true)
      try { setCatalog(await getItemCatalog()) } catch {}
      finally { setCatalogLoading(false) }
    })()
  }, [])

  // ---- selection + detail -----
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [detail, setDetail] = useState<CharacterDetail | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [activeTab, setActiveTab] = useState<TabId>('stats')
  const reloadSeq = useRef(0)

  async function loadDetail(id: number) {
    const seq = ++reloadSeq.current
    setDetailLoading(true); setDetailError(null)
    try {
      const d = await getCharacter(id)
      if (seq === reloadSeq.current) { setDetail(d) }
    } catch (e) {
      if (seq === reloadSeq.current) {
        setDetailError(e instanceof Error ? e.message : String(e))
        setDetail(null)
      }
    } finally {
      if (seq === reloadSeq.current) setDetailLoading(false)
    }
  }

  function selectCharacter(id: number) {
    setSelectedId(id)
    void loadDetail(id)
  }

  function refreshDetail() {
    if (selectedId != null) void loadDetail(selectedId)
  }

  const filtered: CharacterListEntry[] = useMemo(() => {
    const all = list?.characters ?? []
    if (!search) return all
    const s = search.toLowerCase()
    return all.filter(c => c.name?.toLowerCase().includes(s) || String(c.id).includes(s))
  }, [list, search])

  const selected = filtered.find(c => c.id === selectedId)
    ?? list?.characters.find(c => c.id === selectedId)
    ?? null
  const selectedName = selected?.name ?? ''

  // -------- render --------

  return (
    <>
      <PageHeader
        title="Characters"
        icon="Users"
        description="Live editor for player characters — talks to Postgres on the battlegroup VM."
        actions={
          <>
            <span className={vmRunning ? 'pill-success' : 'pill-warning'}>
              <Icon name={vmRunning ? 'CircleCheck' : 'AlertTriangle'} size={12} />
              {vmRunning ? 'BG running' : 'BG not running'}
            </span>
            <button type="button" className="btn-secondary" onClick={refreshList} disabled={listLoading}>
              <Icon name={listLoading ? 'Loader2' : 'RefreshCw'} size={14}
                    className={listLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          </>
        }
      />

      <div className="grid grid-cols-1 lg:grid-cols-[320px_1fr] gap-4">
        {/* Left rail */}
        <div className="card p-0 overflow-hidden flex flex-col h-[calc(100vh-220px)] min-h-[400px]">
          <div className="p-3 border-b border-border">
            <div className="relative">
              <Icon name="Search" size={14}
                    className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim" />
              <input
                type="text"
                value={search}
                placeholder="Filter by name or id…"
                onChange={e => setSearch(e.target.value)}
                className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-sm
                           focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
              />
            </div>
          </div>

          <div className="flex-1 overflow-auto">
            {listError ? (
              <div className="p-4 text-sm text-danger">
                <Icon name="AlertCircle" size={14} className="inline mr-1.5" />
                {listError}
                {!vmRunning && (
                  <div className="mt-2 text-text-muted text-xs">
                    The battlegroup VM is not running — start it from the Commands page.
                  </div>
                )}
              </div>
            ) : listLoading ? (
              <div className="p-4 text-center text-text-muted text-sm">
                <Icon name="Loader2" size={16} className="animate-spin inline mr-2" /> Loading…
              </div>
            ) : filtered.length === 0 ? (
              <div className="p-6 text-center text-text-muted text-sm">
                <Icon name="UserX" size={20} className="mx-auto mb-2 opacity-40" />
                {list?.characters.length
                  ? 'No matches.'
                  : 'No characters yet — has anyone joined this server?'}
              </div>
            ) : (
              <ul>
                {filtered.map(c => {
                  const active = c.id === selectedId
                  return (
                    <li key={c.id}>
                      <button
                        type="button"
                        onClick={() => selectCharacter(c.id)}
                        className={`w-full text-left px-4 py-2.5 border-l-2 text-sm transition-colors
                          ${active
                            ? 'bg-surface-2 border-l-accent-bright text-text'
                            : 'border-l-transparent text-text-muted hover:bg-surface-2/50 hover:text-text'}`}
                      >
                        <div className="font-medium truncate">{c.name || '(unnamed)'}</div>
                        <div className="text-xs text-text-dim font-mono">id {c.id}</div>
                      </button>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>

          <div className="px-3 py-2 border-t border-border text-xs text-text-dim flex items-center justify-between">
            <span>{list?.characters.length ?? 0} characters</span>
            {!vmRunning && <span className="text-warning">BG offline</span>}
          </div>
        </div>

        {/* Right pane — tabs + active tab body */}
        <div className="min-w-0">
          {!selectedId ? (
            <div className="card p-8">
              <EmptyState
                icon="UserSearch"
                title="Select a character"
                description="Pick a character from the list to view and edit their data."
              />
            </div>
          ) : detailLoading && !detail ? (
            <div className="card p-12 text-center text-text-muted">
              <Icon name="Loader2" size={24} className="animate-spin mx-auto mb-3" />
              Loading character {selectedId}…
            </div>
          ) : detailError ? (
            <div className="card p-6 border-danger/40 bg-danger/10 text-danger text-sm">
              <Icon name="AlertCircle" size={14} className="inline mr-1.5" /> {detailError}
              <button type="button" className="btn-secondary mt-3" onClick={refreshDetail}>
                <Icon name="RefreshCw" size={14} /> Retry
              </button>
            </div>
          ) : !detail || !defs ? (
            <div className="card p-12 text-center text-text-muted">
              <Icon name="Loader2" size={24} className="animate-spin mx-auto mb-3" /> Preparing…
            </div>
          ) : (
            <>
              <div className="card p-3 mb-4 flex flex-wrap items-center justify-between gap-3">
                <div>
                  <div className="text-base font-semibold text-text">
                    {selectedName || '(unnamed)'}
                  </div>
                  <div className="text-xs text-text-dim font-mono">
                    player_pawn_id {detail.id} · controller {detail.economy.controllerId || '—'}
                  </div>
                </div>
                <button type="button" className="btn-ghost" disabled={detailLoading}
                        onClick={refreshDetail}>
                  <Icon name={detailLoading ? 'Loader2' : 'RefreshCw'} size={14}
                        className={detailLoading ? 'animate-spin' : ''} />
                  Reload character
                </button>
              </div>

              <div className="flex flex-wrap items-center gap-1 mb-3 border-b border-border">
                {TABS.map(t => {
                  const active = t.id === activeTab
                  return (
                    <button
                      key={t.id}
                      type="button"
                      onClick={() => setActiveTab(t.id)}
                      className={`px-3 py-2 text-sm flex items-center gap-1.5 border-b-2 -mb-px
                        ${active
                          ? 'border-accent-bright text-text'
                          : 'border-transparent text-text-muted hover:text-text'}`}
                    >
                      <Icon name={t.icon} size={14} /> {t.label}
                    </button>
                  )
                })}
              </div>

              {activeTab === 'stats'     && <StatsTab     charId={detail.id} detail={detail} defs={defs} onSaved={refreshDetail} />}
              {activeTab === 'tech'      && <TechTab      charId={detail.id} charName={selectedName} />}
              {activeTab === 'specs'     && <SpecsTab     charId={detail.id} charName={selectedName} detail={detail} defs={defs} onSaved={refreshDetail} />}
              {activeTab === 'economy'   && <EconomyTab   charId={detail.id} detail={detail} defs={defs} onSaved={refreshDetail} />}
              {activeTab === 'cosmetics' && <CosmeticsTab charId={detail.id} detail={detail} catalog={catalog} catalogLoading={catalogLoading} onChanged={refreshDetail} />}
              {activeTab === 'inventory' && <InventoryTab detail={detail} defs={defs} catalog={catalog} catalogLoading={catalogLoading} onChanged={refreshDetail} />}
            </>
          )}
        </div>
      </div>
    </>
  )
}
