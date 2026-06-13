import { useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { OverviewTab } from './gameplay/OverviewTab'
import { MarketTab } from './gameplay/MarketTab'
import { MarketBotTab } from './gameplay/MarketBotTab'
import { PlayersTab } from './gameplay/PlayersTab'
import { BasesTab } from './gameplay/BasesTab'
import { StorageTab } from './gameplay/StorageTab'
import { BlueprintsTab } from './gameplay/BlueprintsTab'

export type GameplaySubTab =
  | 'overview' | 'market' | 'marketbot' | 'players' | 'bases' | 'storage' | 'blueprints'

const TABS: { id: GameplaySubTab; label: string; icon: string }[] = [
  { id: 'overview',  label: 'Overview', icon: 'LayoutGrid' },
  { id: 'market',    label: 'Market',   icon: 'Store' },
  { id: 'marketbot', label: 'Market Bot', icon: 'Bot' },
  { id: 'players',   label: 'Players',  icon: 'Users' },
  { id: 'bases',     label: 'Bases',    icon: 'Castle' },
  { id: 'storage',   label: 'Storage',  icon: 'Package' },
  { id: 'blueprints', label: 'Blueprints', icon: 'ScrollText' },
]

export function GameplayEnvironment() {
  const [tab, setTab] = useState<GameplaySubTab>('overview')

  return (
    <>
      <PageHeader
        title="Gameplay Admin"
        icon="Gamepad2"
        description="Native market, exchange, and bot tools — a full gameplay admin console, built into Dune Server Tool."
      />

      {/* Sub-tab nav */}
      <div className="flex items-center gap-1 mb-5 border-b border-border">
        {TABS.map(t => {
          const active = tab === t.id
          return (
            <button key={t.id}
              onClick={() => setTab(t.id)}
              className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors ${
                active
                  ? 'border-accent text-accent-bright'
                  : 'border-transparent text-text-muted hover:text-text'
              }`}>
              <Icon name={t.icon} size={15} /> {t.label}
            </button>
          )
        })}
      </div>

      {tab === 'overview' && <OverviewTab onOpenTab={setTab} />}
      {tab === 'market' && <MarketTab />}
      {tab === 'marketbot' && <MarketBotTab />}
      {tab === 'players' && <PlayersTab />}
      {tab === 'bases' && <BasesTab />}
      {tab === 'storage' && <StorageTab />}
      {tab === 'blueprints' && <BlueprintsTab />}
    </>
  )
}
