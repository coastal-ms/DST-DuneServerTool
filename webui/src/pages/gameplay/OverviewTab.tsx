import { useNavigate } from 'react-router-dom'
import { Icon } from '../../components/Icon'
import { useApi } from '../../hooks/useApi'
import type { GameplayStatus } from '../../api/gameplay'
import type { GameplaySubTab } from '../GameplayEnvironment'

type FeatureStatus = 'live' | 'native' | 'roadmap'

interface Feature {
  name: string
  icon: string
  desc: string
  status: FeatureStatus
  // Action: either switch to a gameplay sub-tab, or navigate to an existing DST page.
  tab?: GameplaySubTab
  route?: string
  routeLabel?: string
}

const FEATURES: Feature[] = [
  {
    name: 'Market / Exchange', icon: 'Store', status: 'live', tab: 'market',
    desc: 'Browse every active exchange listing aggregated by item — lowest price, stock, bot vs player split, per-item listings and recent sales. Reads the live game database directly.',
  },
  {
    name: 'Market Bot (Duke)', icon: 'Bot', status: 'live', tab: 'marketbot',
    desc: 'Monitor the automated vendor and tune its pricing: rarity & grade multipliers, buy threshold, tick intervals, listings per grade, and a disabled-items list.',
  },
  {
    name: 'Database / SQL', icon: 'Database', status: 'native', route: '/database', routeLabel: 'Open Database',
    desc: 'Run read-only (or write) SQL against the live game Postgres with a guarded editor. This is the same bridge the Market features are built on.',
  },
  {
    name: 'Game Config', icon: 'Sliders', status: 'native', route: '/gameconfig', routeLabel: 'Open Game Config',
    desc: 'Edit server gameplay settings and rules — already first-class in Dune Server Tool.',
  },
  {
    name: 'Logs & Console', icon: 'Terminal', status: 'native', route: '/', routeLabel: 'Open Server Health',
    desc: 'Stream pod logs and export battlegroup / operator logs. Available from Server Health and the PowerShell console.',
  },
  {
    name: 'Battlegroup control', icon: 'Server', status: 'native', route: '/commands', routeLabel: 'Open Commands',
    desc: 'Start / stop / update the battlegroup and run maintenance commands — handled by the Commands and Server Health pages.',
  },
  {
    name: 'Players', icon: 'Users', status: 'live', tab: 'players',
    desc: 'Inspect and edit player characters: inventory, currencies, and specialization tracks. Give Solari or items, rename, award XP, and repair or delete items — straight against the live game database.',
  },
  {
    name: 'Bases', icon: 'Castle', status: 'live', tab: 'bases',
    desc: 'Browse every player base with its building-piece and placeable counts. Search and sort across the world for moderation and cleanup.',
  },
  {
    name: 'Storage', icon: 'Package', status: 'live', tab: 'storage',
    desc: 'Inspect container and stockpile contents across the world — open any container to see exactly what is inside, for moderation and economy analysis.',
  },
  {
    name: 'Blueprints', icon: 'ScrollText', status: 'live', tab: 'blueprints',
    desc: 'Catalog of player blueprints with their building-piece and placeable counts and owners.',
  },
]

const STATUS_META: Record<FeatureStatus, { label: string; cls: string; icon: string }> = {
  live:    { label: 'Live now',    cls: 'border-success/40 text-success bg-success/10', icon: 'CircleCheck' },
  native:  { label: 'In Dune Server Tool', cls: 'border-info/40 text-info bg-info/10',  icon: 'Link' },
  roadmap: { label: 'Roadmap',     cls: 'border-border-bright text-text-muted bg-surface-2', icon: 'Hammer' },
}

export function OverviewTab({ onOpenTab }: { onOpenTab: (tab: GameplaySubTab) => void }) {
  const navigate = useNavigate()
  const { data: status } = useApi<GameplayStatus>('/api/gameplay/status', { intervalMs: 15000 })

  const liveCount = FEATURES.filter(f => f.status === 'live').length
  const nativeCount = FEATURES.filter(f => f.status === 'native').length
  const roadmapCount = FEATURES.filter(f => f.status === 'roadmap').length

  return (
    <div>
      {/* Intro */}
      <div className="card p-5 mb-4">
        <div className="flex items-start gap-3">
          <div className="w-10 h-10 rounded-lg bg-accent/15 border border-accent/30 flex items-center justify-center text-accent-bright shrink-0">
            <Icon name="Gamepad2" size={20} />
          </div>
          <div>
            <h2 className="text-lg font-semibold text-text">A native gameplay console</h2>
            <p className="text-sm text-text-muted mt-1 max-w-3xl">
              A complete gameplay admin console, built into Dune Server Tool — one console,
              one theme, no second program to install. The Market and Market Bot tabs are live now and read
              straight from your game database. The rest is mapped below.
            </p>
          </div>
        </div>
        <div className="flex flex-wrap gap-2 mt-4">
          <Pill icon="CircleCheck" cls="text-success">{liveCount} live</Pill>
          <Pill icon="Link" cls="text-info">{nativeCount} already in DST</Pill>
          <Pill icon="Hammer" cls="text-text-muted">{roadmapCount} on the roadmap</Pill>
          <span className="flex-1" />
          <Pill icon={status?.db_available ? 'Wifi' : 'WifiOff'} cls={status?.db_available ? 'text-success' : 'text-text-muted'}>
            {status?.db_available ? 'Game DB connected' : 'Game DB offline (demo data)'}
          </Pill>
        </div>
      </div>

      {/* Feature grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {FEATURES.map(f => {
          const meta = STATUS_META[f.status]
          const clickable = !!f.tab || !!f.route
          return (
            <div key={f.name}
              className={`card p-4 flex flex-col ${clickable ? 'card-hover cursor-pointer' : ''}`}
              onClick={() => { if (f.tab) onOpenTab(f.tab); else if (f.route) navigate(f.route) }}>
              <div className="flex items-start justify-between gap-2 mb-2">
                <div className="flex items-center gap-2.5">
                  <div className="w-8 h-8 rounded-lg bg-surface-2 border border-border flex items-center justify-center text-accent">
                    <Icon name={f.icon} size={16} />
                  </div>
                  <h3 className="font-semibold text-text">{f.name}</h3>
                </div>
                <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-medium border shrink-0 ${meta.cls}`}>
                  <Icon name={meta.icon} size={11} /> {meta.label}
                </span>
              </div>
              <p className="text-sm text-text-muted flex-1">{f.desc}</p>
              {f.tab && (
                <button className="btn-primary mt-3 self-start" onClick={e => { e.stopPropagation(); onOpenTab(f.tab!) }}>
                  Open <Icon name="ArrowRight" size={14} />
                </button>
              )}
              {f.route && (
                <button className="btn-secondary mt-3 self-start" onClick={e => { e.stopPropagation(); navigate(f.route!) }}>
                  {f.routeLabel ?? 'Open'} <Icon name="ArrowUpRight" size={14} />
                </button>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function Pill({ icon, cls, children }: { icon: string; cls: string; children: React.ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-surface-2 border border-border ${cls}`}>
      <Icon name={icon} size={12} /> {children}
    </span>
  )
}
