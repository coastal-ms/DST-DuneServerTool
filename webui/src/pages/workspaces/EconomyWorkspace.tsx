import { lazy, Suspense } from 'react'
import { DataState } from '../../components/platform/DataState'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'

const Market = lazy(() => import('../gameplay/MarketTab').then(module => ({ default: module.MarketTab })))
const MarketBot = lazy(() => import('../gameplay/MarketBotTab').then(module => ({ default: module.MarketBotTab })))
const Governance = lazy(() => import('../gameplay/LandsraadTab').then(module => ({ default: module.LandsraadTab })))

type EconomyView = 'market' | 'market-bot' | 'governance'

const TABS: readonly WorkspaceTab[] = [
  { id: 'market', label: 'Market', to: '/economy?view=market', icon: 'Store' },
  { id: 'market-bot', label: 'Market Bot', to: '/economy?view=market-bot', icon: 'Bot' },
  { id: 'governance', label: 'Governance', to: '/economy?view=governance', icon: 'Landmark' },
]

function currentView(search: string): EconomyView {
  const view = new URLSearchParams(search).get('view')
  if (view === 'market-bot' || view === 'governance') return view
  return 'market'
}

export default function EconomyWorkspace() {
  const search = useSearch()
  const view = currentView(search)
  return (
    <WorkspaceLayout workspace={getWorkspace('economy')} tabs={TABS} activeTab={view}>
      <Suspense fallback={<DataState state="loading" title="Loading economy view…" />}>
        {view === 'market' && <Market />}
        {view === 'market-bot' && <MarketBot />}
        {view === 'governance' && <Governance />}
      </Suspense>
    </WorkspaceLayout>
  )
}
