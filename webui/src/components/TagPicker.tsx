// TagPicker — typeahead autocomplete for the known gameplay-tag catalog.
// Used in the player Tags editor. Lazy-loads the catalog on first focus, filters
// on every keystroke against the friendly label OR the raw tag, then GROUPS the
// matches by their parent breadcrumb (everything except the final segment) so
// related tags read as a set. Each group shows an "Add all (N)" button; each
// leaf tag is an explicit "+ Add" row. Results render inline (not a floating
// popup) and paginate by group. Tags the player already has are excluded.

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { Icon } from './Icon'
import { filterTagCatalog, getTagCatalog, tagFriendlyLabel, type TagCatalogEntry } from '../api/gameplay'

const GROUPS_PER_PAGE = 8

interface TagGroup {
  key: string            // parent prefix (raw), '' for single-segment tags
  label: string          // friendly breadcrumb of the parent
  leafLabel: (tag: string) => string
  entries: TagCatalogEntry[]
}

interface Props {
  value: string
  onChange: (text: string) => void
  /** Add a single tag (raw string). */
  onPick: (tag: string) => void
  /** Add a whole set of tags at once (raw strings). */
  onPickMany?: (tags: string[]) => void
  /** Called on Enter when there are no suggestions — add the raw typed text. */
  onEnterRaw?: () => void
  /** Tags the player already has — excluded from suggestions. */
  exclude?: string[]
  placeholder?: string
  autoFocus?: boolean
  disabled?: boolean
}

// Friendly label for just the final segment of a tag (the leaf within its group).
function leafFriendly(tag: string): string {
  const parts = tag.split('.')
  const last = parts[parts.length - 1] || tag
  return tagFriendlyLabel(last)
}

function groupMatches(entries: TagCatalogEntry[]): TagGroup[] {
  const byKey = new Map<string, TagCatalogEntry[]>()
  for (const e of entries) {
    const segs = e.tag.split('.')
    const key = segs.length > 1 ? segs.slice(0, -1).join('.') : ''
    const arr = byKey.get(key)
    if (arr) arr.push(e)
    else byKey.set(key, [e])
  }
  const groups: TagGroup[] = []
  for (const [key, arr] of byKey) {
    groups.push({
      key,
      label: key ? tagFriendlyLabel(key) : 'Ungrouped',
      leafLabel: leafFriendly,
      entries: arr.slice().sort((a, b) => a.tag.localeCompare(b.tag)),
    })
  }
  groups.sort((a, b) => a.label.localeCompare(b.label))
  return groups
}

export function TagPicker({
  value, onChange, onPick, onPickMany, onEnterRaw, exclude, placeholder, autoFocus, disabled,
}: Props) {
  const inputId = useId()
  const [catalog, setCatalog] = useState<TagCatalogEntry[] | null>(null)
  const [catalogError, setCatalogError] = useState<string | null>(null)
  const [catalogLoading, setCatalogLoading] = useState(false)
  const [open, setOpen] = useState(false)
  const [page, setPage] = useState(0)
  const wrapRef = useRef<HTMLDivElement>(null)

  const ensureCatalog = useCallback(() => {
    if (catalog || catalogLoading) return
    setCatalogLoading(true)
    getTagCatalog()
      .then(setCatalog)
      .catch(e => setCatalogError(e instanceof Error ? e.message : String(e)))
      .finally(() => setCatalogLoading(false))
  }, [catalog, catalogLoading])

  const excludeSet = useMemo(() => new Set(exclude || []), [exclude])
  const matches: TagCatalogEntry[] = useMemo(
    () => (catalog ? filterTagCatalog(catalog, value, Number.MAX_SAFE_INTEGER, excludeSet) : []),
    [catalog, value, excludeSet],
  )
  const groups = useMemo(() => groupMatches(matches), [matches])

  const pageCount = Math.max(1, Math.ceil(groups.length / GROUPS_PER_PAGE))
  const pageClamped = Math.min(page, pageCount - 1)
  const visibleGroups = groups.slice(pageClamped * GROUPS_PER_PAGE, (pageClamped + 1) * GROUPS_PER_PAGE)

  // Close when clicking outside the picker.
  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (wrapRef.current?.contains(e.target as Node)) return
      setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const setQuery = (text: string) => { onChange(text); setOpen(true); setPage(0) }
  const goPage = (p: number) => setPage(Math.max(0, Math.min(p, pageCount - 1)))

  const addOne = (tag: string) => onPick(tag)
  const addGroup = (g: TagGroup) => {
    const tags = g.entries.map(e => e.tag)
    if (onPickMany) onPickMany(tags)
    else tags.forEach(onPick)
  }

  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      onEnterRaw?.()
    } else if (e.key === 'Escape') {
      setOpen(false); e.preventDefault()
    }
  }

  return (
    <div ref={wrapRef} className="relative flex-1 min-w-0">
      <div className="relative">
        <input
          id={inputId}
          type="text"
          autoComplete="off"
          spellCheck={false}
          disabled={disabled}
          autoFocus={autoFocus}
          value={value}
          placeholder={placeholder || 'Search tags…'}
          onFocus={() => { ensureCatalog(); setOpen(true) }}
          onChange={e => setQuery(e.target.value)}
          onKeyDown={onKey}
          className="w-full pl-9 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
        />
        <Icon name="Search" size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim pointer-events-none" />
      </div>

      {open && (
        <div className="mt-2 rounded-lg border border-border bg-surface overflow-hidden">
          <div className="flex items-center justify-between px-3 py-1.5 border-b border-border text-[11px] text-text-dim">
            <span>
              {catalogLoading ? 'Loading tag catalog…'
                : catalogError ? <span className="text-danger">Load failed</span>
                : `${matches.length} tag${matches.length === 1 ? '' : 's'} in ${groups.length} group${groups.length === 1 ? '' : 's'}`}
            </span>
            {pageCount > 1 && (
              <span className="flex items-center gap-2">
                <button type="button" className="px-1.5 py-0.5 rounded hover:bg-surface-2 disabled:opacity-40"
                  disabled={pageClamped <= 0} onMouseDown={ev => { ev.preventDefault(); goPage(pageClamped - 1) }}>
                  <Icon name="ChevronLeft" size={13} />
                </button>
                <span className="tabular-nums">Page {pageClamped + 1} / {pageCount}</span>
                <button type="button" className="px-1.5 py-0.5 rounded hover:bg-surface-2 disabled:opacity-40"
                  disabled={pageClamped >= pageCount - 1} onMouseDown={ev => { ev.preventDefault(); goPage(pageClamped + 1) }}>
                  <Icon name="ChevronRight" size={13} />
                </button>
              </span>
            )}
          </div>

          <div className="max-h-80 overflow-y-auto overscroll-contain">
            {catalogError && (
              <div className="px-3 py-2 text-xs text-danger">{catalogError}</div>
            )}
            {!catalogLoading && !catalogError && matches.length === 0 && (
              <div className="px-3 py-2 text-xs text-text-dim">
                {value.trim().length > 0
                  ? <>No known tags match "{value}". Press <span className="text-text">Add</span> to use it anyway.</>
                  : 'No more tags to add.'}
              </div>
            )}
            {visibleGroups.map(g => (
              <div key={g.key || '__ungrouped__'} className="border-b border-border/60 last:border-b-0">
                <div className="flex items-center justify-between gap-2 px-3 py-1.5 bg-surface-2/40">
                  <span className="min-w-0 truncate text-[11px] uppercase tracking-wider text-text-dim" title={g.label}>
                    {g.label} <span className="text-text-dim/70">({g.entries.length})</span>
                  </span>
                  {g.entries.length > 1 && (
                    <button type="button" className="btn-secondary text-[11px] px-2 py-0.5 shrink-0"
                      onMouseDown={ev => { ev.preventDefault(); addGroup(g) }}
                      title={`Add all ${g.entries.length} tags in this set`}>
                      <Icon name="Plus" size={11} /> Add all ({g.entries.length})
                    </button>
                  )}
                </div>
                {g.entries.map(e => (
                  <button
                    key={e.tag}
                    type="button"
                    onMouseDown={ev => { ev.preventDefault(); addOne(e.tag) }}
                    className="w-full text-left px-3 py-2 flex items-center gap-2 hover:bg-surface-2 group"
                  >
                    <span className="flex-1 min-w-0">
                      <span className="block text-sm text-text">{g.leafLabel(e.tag)}</span>
                      <span className="block text-[11px] font-mono text-text-dim truncate">{e.tag}</span>
                    </span>
                    <span className="shrink-0 inline-flex items-center gap-1 text-[11px] text-text-dim group-hover:text-text">
                      <Icon name="Plus" size={12} /> Add
                    </span>
                  </button>
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
