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
