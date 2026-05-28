import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'

type MapSource = {
  key: string
  cardLabel: string
  title: string
  description: string
  url: string
}

const SOURCES: MapSource[] = [
  {
    key: 'method',
    cardLabel: 'Method.gg',
    title: 'Deep Desert Map & Loot Tables',
    description:
      'Interactive Deep Desert map with all key POIs, rotating weekly loot tables, and PVE guides for Testing Stations & Wrecks.',
    url: 'https://www.method.gg/dune-awakening/deep-desert-companion',
  },
  {
    key: 'gamingtools',
    cardLabel: 'Dune Gaming Tools',
    title: 'Deep Desert Companion',
    description:
      'Filterable Deep Desert map with togglable POI categories, search, and per-resource overlays.',
    url: 'https://dune.gaming.tools/deep-desert',
  },
]

export function DDMap() {
  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        title="DD Map"
        icon="Map"
        description="Deep Desert map references. Both sites block embedding — links open in a new tab."
      />

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-stretch">
        {SOURCES.map(src => (
          <div key={src.key} className="card p-5 flex flex-col">
            <div className="text-xs font-semibold uppercase tracking-widest text-accent mb-3">
              {src.cardLabel}
            </div>

            <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">Title</label>
            <div className="w-full mb-3 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text">
              {src.title}
            </div>

            <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">Description</label>
            <div className="w-full mb-3 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text">
              {src.description}
            </div>

            <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">URL</label>
            <div className="w-full mb-3 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm break-all">
              {src.url}
            </div>

            <div className="mt-auto pt-2 flex items-center justify-end gap-2">
              <a
                href={src.url}
                target="_blank"
                rel="noopener noreferrer"
                className="btn-primary"
              >
                <Icon name="ExternalLink" size={14} />
                Open in new tab
              </a>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
