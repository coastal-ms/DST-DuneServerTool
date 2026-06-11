// Shared bits for the Gameplay Environment sub-tabs (theme: Eyes of Ibad).
import { Icon } from '../../components/Icon'
import type { DataSource } from '../../api/gameplay'

// Format a Solari amount with thousands separators.
export function fmtSolari(n: number | undefined): string {
  if (n === undefined || n === null || Number.isNaN(n)) return '—'
  return new Intl.NumberFormat('en-US').format(Math.round(n))
}

export function fmtNum(n: number | undefined): string {
  if (n === undefined || n === null || Number.isNaN(n)) return '—'
  return new Intl.NumberFormat('en-US').format(n)
}

export function fmtUptime(seconds: number | undefined): string {
  if (!seconds || seconds <= 0) return '—'
  const d = Math.floor(seconds / 86400)
  const h = Math.floor((seconds % 86400) / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

// A small pill showing whether data is live (game DB) or demo (bundled sample).
export function SourceBadge({ source }: { source?: DataSource }) {
  if (!source) return null
  const live = source === 'live'
  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-medium border ${
        live
          ? 'border-success/40 text-success bg-success/10'
          : 'border-border-bright text-text-muted bg-surface-2'
      }`}
      title={live ? 'Reading from the live game database' : 'Sample data — start the battlegroup to see live market data'}
    >
      <Icon name={live ? 'Wifi' : 'FlaskConical'} size={11} />
      {live ? 'Live' : 'Demo'}
    </span>
  )
}

const RARITY_CLASS: Record<string, string> = {
  common:    'text-text-dim',
  uncommon:  'text-success',
  rare:      'text-info',
  epic:      'text-accent-bright',
  legendary: 'text-warning',
}

export function rarityClass(rarity: string | undefined): string {
  if (!rarity) return 'text-text-dim'
  return RARITY_CLASS[rarity.toLowerCase()] ?? 'text-text'
}

export function RarityTag({ rarity }: { rarity: string | undefined }) {
  if (!rarity) return <span className="text-text-dim">—</span>
  return <span className={`capitalize ${rarityClass(rarity)}`}>{rarity}</span>
}

// Pretty category leaf: "items/weapons/sidearm" -> "sidearm".
export function categoryLeaf(cat: string | undefined): string {
  if (!cat) return '—'
  const parts = cat.split('/').filter(Boolean)
  return parts[parts.length - 1] ?? cat
}

// Small stat card used across the gameplay tabs.
export function StatCard({ label, value, sub, icon }: { label: string; value: string; sub?: string; icon: string }) {
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between">
        <span className="text-xs uppercase tracking-wider text-text-dim">{label}</span>
        <Icon name={icon} size={15} className="text-accent" />
      </div>
      <div className="mt-1 text-xl font-semibold text-text truncate">{value}</div>
      {sub && <div className="text-[11px] text-text-dim truncate">{sub}</div>}
    </div>
  )
}

// "Showing sample data" banner shown when a tab is on demo data.
export function DemoNotice({ liveError, what }: { liveError?: string; what: string }) {
  return (
    <div className="card p-3 mb-4 text-xs text-text-muted border-l-2 border-accent flex items-start gap-2">
      <Icon name="Info" size={14} className="text-accent shrink-0 mt-0.5" />
      <span>
        Showing sample {what}. {liveError ? <span className="text-warning">{liveError}</span> : 'Start the battlegroup'} — this
        view reads the live game database automatically once it is reachable.
      </span>
    </div>
  )
}

// Quality level -> rarity-ish colour (game quality 0..5).
export function qualityClass(q: number | undefined): string {
  switch (q) {
    case 1: return 'text-success'
    case 2: return 'text-info'
    case 3: return 'text-accent-bright'
    case 4: return 'text-warning'
    case 5: return 'text-danger'
    default: return 'text-text-dim'
  }
}
