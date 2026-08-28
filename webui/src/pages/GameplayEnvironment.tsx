import { lazy, Suspense } from 'react'
import { DataState } from '../components/platform/DataState'
import { GameplayAdminShell } from '../components/platform/GameplayAdminShell'
import { Navigate, useNavigate, useSearch } from '../router'
import { readLastGameplayDestination, resolveGameplaySection } from '../platform/gameplay'

const OverviewTab = lazy(() => import('./gameplay/OverviewTab').then(module => ({ default: module.OverviewTab })))
const MarketTab = lazy(() => import('./gameplay/MarketTab').then(module => ({ default: module.MarketTab })))
const MarketBotTab = lazy(() => import('./gameplay/MarketBotTab').then(module => ({ default: module.MarketBotTab })))
const PlayersWorkspace = lazy(() => import('./workspaces/PlayersWorkspace'))
const BasesWorkspace = lazy(() => import('./workspaces/BasesWorkspace'))
const VehiclesWorkspace = lazy(() => import('./workspaces/VehiclesWorkspace'))
const MapWorkspace = lazy(() => import('./workspaces/MapWorkspace'))
const EconomyWorkspace = lazy(() => import('./workspaces/EconomyWorkspace'))
const StorageTab = lazy(() => import('./gameplay/StorageTab').then(module => ({ default: module.StorageTab })))
const BlueprintsTab = lazy(() => import('./gameplay/BlueprintsTab').then(module => ({ default: module.BlueprintsTab })))
const LandsraadTab = lazy(() => import('./gameplay/LandsraadTab').then(module => ({ default: module.LandsraadTab })))

export type GameplaySubTab =
  | 'overview' | 'map' | 'market' | 'marketbot' | 'players' | 'bases' | 'storage'
  | 'blueprints' | 'landsraad' | 'vehicles' | 'economy'

const TAB_IDS = new Set<GameplaySubTab>([
  'overview', 'map', 'market', 'marketbot', 'players', 'bases', 'storage',
  'blueprints', 'landsraad', 'vehicles', 'economy',
])

function requestedTab(search: string, fallback: GameplaySubTab): GameplaySubTab {
  const value = new URLSearchParams(search).get('view') as GameplaySubTab | null
  return value && TAB_IDS.has(value) ? value : fallback
}

export function GameplayEnvironment({ initialTab = 'overview' }: { initialTab?: GameplaySubTab }) {
  const search = useSearch()
  const navigate = useNavigate()
  const requestedView = new URLSearchParams(search).get('view')
  const tab = requestedTab(search, initialTab)

  const openTab = (next: GameplaySubTab) => {
    navigate(`/gameplay?view=${next}`)
  }

  if (!requestedView && initialTab === 'overview') {
    const stored = readLastGameplayDestination()
    if (stored !== '/gameplay?view=overview') {
      return <Navigate to={stored} replace preserveLocation />
    }
  }

  return (
    <GameplayAdminShell activeSection={resolveGameplaySection('/gameplay', search)}>
      <Suspense fallback={<DataState state="loading" title="Loading Gameplay Admin view…" />}>
        {tab === 'overview' && <OverviewTab onOpenTab={openTab} />}
        {tab === 'map' && <MapWorkspace />}
        {tab === 'market' && <MarketTab />}
        {tab === 'marketbot' && <MarketBotTab />}
        {tab === 'players' && <PlayersWorkspace />}
        {tab === 'bases' && <BasesWorkspace />}
        {tab === 'storage' && <StorageTab />}
        {tab === 'blueprints' && <BlueprintsTab />}
        {tab === 'landsraad' && <LandsraadTab />}
        {tab === 'vehicles' && <VehiclesWorkspace />}
        {tab === 'economy' && <EconomyWorkspace />}
      </Suspense>
    </GameplayAdminShell>
  )
}
