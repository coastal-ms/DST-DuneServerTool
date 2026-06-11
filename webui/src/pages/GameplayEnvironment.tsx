import { useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { OverviewTab } from './gameplay/OverviewTab'
import { MarketTab } from './gameplay/MarketTab'
import { MarketBotTab } from './gameplay/MarketBotTab'

export type GameplaySubTab = 'overview' | 'market' | 'marketbot'

const TABS: { id: GameplaySubTab; label: string; icon: string }[] = [
  { id: 'overview',  label: 'Overview', icon: 'LayoutGrid' },
  { id: 'market',    label: 'Market',   icon: 'Store' },
  { id: 'marketbot', label: 'Market Bot', icon: 'Bot' },
]

export function GameplayEnvironment() {
  const [tab, setTab] = useState<GameplaySubTab>('overview')

  return (
    <>
      <PageHeader
        title="Gameplay Admin"
        icon="Gamepad2"
        description="Native market, exchange, and bot tools — the Dune admin portal, rebuilt inside Dune Server Tool."
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
    </>
  )
}
