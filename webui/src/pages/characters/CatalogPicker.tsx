// CatalogPicker — modal for choosing an item from the ~979-item catalog.
// Used by both InventoryTab (filtered by writable inventories) and CosmeticsTab.
import { useMemo, useState, useEffect } from 'react'
import { Icon } from '../../components/Icon'
import type { CatalogItem, ItemCatalog } from '../../api/types'

type Props = {
  open: boolean
  title?: string
  catalog: ItemCatalog | null
  loading?: boolean
  /** If set, only items whose category starts with one of these prefixes are shown. */
  categoryFilter?: (item: CatalogItem) => boolean
  /** Called with the selected item; modal stays open so caller can close after a successful add. */
  onPick: (item: CatalogItem) => void | Promise<void>
  onClose: () => void
  /** Optional secondary control rendered next to search (e.g. stack-size input). */
  extra?: React.ReactNode
}

export function CatalogPicker({
  open, title = 'Choose an item', catalog, loading, categoryFilter, onPick, onClose, extra,
}: Props) {
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('')
  const [busyId, setBusyId] = useState<string | null>(null)

  useEffect(() => { if (!open) { setSearch(''); setCategory(''); setBusyId(null) } }, [open])

  const items = catalog?.items ?? []
  const filtered = useMemo(() => {
    let arr = items
    if (categoryFilter) arr = arr.filter(categoryFilter)
    if (category)       arr = arr.filter(i => i.category === category)
    if (search) {
      const s = search.toLowerCase()
      arr = arr.filter(i =>
        i.name.toLowerCase().includes(s) ||
        i.templateId.toLowerCase().includes(s))
    }
    return arr.slice(0, 500)  // cap for render perf
  }, [items, search, category, categoryFilter])

  if (!open) return null

  const totalShown = (search || category) ? filtered.length : items.length

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
         onClick={onClose}>
      <div className="card p-0 max-w-3xl w-full max-h-[80vh] flex flex-col" onClick={e => e.stopPropagation()}>
        <div className="px-5 py-4 border-b border-border flex items-center justify-between">
          <h3 className="font-semibold text-text flex items-center gap-2">
            <Icon name="PackageSearch" size={16} className="text-accent-bright" />
            {title}
          </h3>
          <button type="button" className="btn-ghost px-2 py-1" onClick={onClose}>
            <Icon name="X" size={16} />
          </button>
        </div>

        <div className="px-5 py-3 border-b border-border flex flex-wrap items-center gap-2">
          <div className="relative flex-1 min-w-[200px]">
            <Icon name="Search" size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim" />
            <input
              type="text"
              value={search}
              autoFocus
              placeholder="Search name or template id…"
              onChange={e => setSearch(e.target.value)}
              className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-sm
                         focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
          </div>
          <select
            value={category}
            onChange={e => setCategory(e.target.value)}
            className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-sm
                       focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
          >
            <option value="">All categories</option>
            {(catalog?.categories ?? []).map(c => <option key={c} value={c}>{c}</option>)}
          </select>
          {extra}
        </div>

        <div className="overflow-auto flex-1">
          {loading ? (
            <div className="p-8 text-center text-text-muted">
              <Icon name="Loader2" size={20} className="animate-spin mx-auto mb-2" /> Loading catalog…
            </div>
          ) : filtered.length === 0 ? (
            <div className="p-8 text-center text-text-muted">
              <Icon name="SearchX" size={20} className="mx-auto mb-2 opacity-50" /> No items match.
            </div>
          ) : (
            <table className="w-full text-sm">
              <thead className="sticky top-0 bg-surface text-text-muted text-xs uppercase tracking-wider">
                <tr>
                  <th className="text-left px-5 py-2 font-medium">Name</th>
                  <th className="text-left px-3 py-2 font-medium">Category</th>
                  <th className="text-left px-3 py-2 font-medium">Template ID</th>
                  <th className="px-3 py-2"></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map(it => (
                  <tr key={it.templateId} className="border-t border-border hover:bg-surface-2/50">
                    <td className="px-5 py-2 text-text">{it.name}</td>
                    <td className="px-3 py-2 text-text-muted">{it.category}</td>
                    <td className="px-3 py-2 font-mono text-xs text-text-dim">{it.templateId}</td>
                    <td className="px-3 py-2 text-right">
                      <button
                        type="button"
                        className="btn-primary px-2 py-1 text-xs"
                        disabled={busyId === it.templateId}
                        onClick={async () => {
                          setBusyId(it.templateId)
                          try { await onPick(it) } finally { setBusyId(null) }
                        }}
                      >
                        <Icon name={busyId === it.templateId ? 'Loader2' : 'Plus'} size={13}
                              className={busyId === it.templateId ? 'animate-spin' : ''} />
                        Add
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        <div className="px-5 py-2.5 border-t border-border text-xs text-text-dim flex items-center justify-between">
          <span>
            Showing {filtered.length}{filtered.length >= 500 && '+'} of {totalShown.toLocaleString()}
          </span>
          {catalog?.meta && (
            <span className="font-mono">
              Catalog: {catalog.meta.total ?? items.length} items{catalog.meta.scraped ? ` · ${catalog.meta.scraped}` : ''}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}
