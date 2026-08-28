import { useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { OverviewTab } from './gameplay/OverviewTab'
import { MarketTab } from './gameplay/MarketTab'
import { MarketBotTab } from './gameplay/MarketBotTab'
import { PlayersTab } from './gameplay/PlayersTab'
import { BasesTab } from './gameplay/BasesTab'
import { StorageTab } from './gameplay/StorageTab'
import { BlueprintsTab } from './gameplay/BlueprintsTab'
import { LandsraadTab } from './gameplay/LandsraadTab'
import { useNavigate, useSearch } from '../router'

export type GameplaySubTab =
  | 'overview' | 'market' | 'marketbot' | 'players' | 'bases' | 'storage' | 'blueprints' | 'landsraad'

const TABS: { id: GameplaySubTab; label: string; icon: string }[] = [
  { id: 'overview',  label: 'Overview', icon: 'LayoutGrid' },
  { id: 'market',    label: 'Market',   icon: 'Store' },
  { id: 'marketbot', label: 'Market Bot', icon: 'Bot' },
  { id: 'players',   label: 'Players',  icon: 'Users' },
  { id: 'bases',     label: 'Bases',    icon: 'Castle' },
  { id: 'storage',   label: 'Storage',  icon: 'Package' },
  { id: 'blueprints', label: 'Blueprints', icon: 'ScrollText' },
  { id: 'landsraad', label: 'Landsraad Houses', icon: 'Landmark' },
]

const TAB_IDS = new Set<GameplaySubTab>(TABS.map(tab => tab.id))

function requestedTab(search: string, fallback: GameplaySubTab): GameplaySubTab {
  const value = new URLSearchParams(search).get('view') as GameplaySubTab | null
  return value && TAB_IDS.has(value) ? value : fallback
}

export function GameplayEnvironment({ initialTab = 'overview' }: { initialTab?: GameplaySubTab }) {
  const search = useSearch()
  const navigate = useNavigate()
  const [tab, setTab] = useState<GameplaySubTab>(() => requestedTab(search, initialTab))

  useEffect(() => {
    setTab(requestedTab(search, initialTab))
  }, [initialTab, search])

  const openTab = (next: GameplaySubTab) => {
    setTab(next)
    navigate(`/gameplay?view=${next}`)
  }

  return (
    <>
      <PageHeader
        title="Gameplay Admin"
        icon="Gamepad2"
        description="Native market, exchange, and bot tools — a full gameplay admin console, built into Dune Server Tool."
      />

      {/* Sub-tab nav */}
      <div
        role="tablist"
        aria-label="Gameplay Admin sections"
        className="flex items-center gap-1 mb-5 border-b border-border overflow-x-auto overscroll-x-contain scroll-smooth touch-pan-x [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        {TABS.map(t => {
          const active = tab === t.id
          return (
            <button key={t.id}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => openTab(t.id)}
              className={`shrink-0 min-h-11 flex items-center gap-2 px-4 py-2.5 text-sm font-medium whitespace-nowrap border-b-2 -mb-px transition-colors ${
                active
                  ? 'border-accent text-accent-bright'
                  : 'border-transparent text-text-muted hover:text-text'
              }`}>
              <Icon name={t.icon} size={15} /> {t.label}
            </button>
          )
        })}
      </div>

      {tab === 'overview' && <OverviewTab onOpenTab={openTab} />}
      {tab === 'market' && <MarketTab />}
      {tab === 'marketbot' && <MarketBotTab />}
      {tab === 'players' && <PlayersTab />}
      {tab === 'bases' && <BasesTab />}
      {tab === 'storage' && <StorageTab />}
      {tab === 'blueprints' && <BlueprintsTab />}
      {tab === 'landsraad' && <LandsraadTab />}
    </>
  )
}
