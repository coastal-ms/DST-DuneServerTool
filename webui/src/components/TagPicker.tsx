// TagPicker — typeahead autocomplete for the known gameplay-tag catalog.
// Used in the player Tags editor. Lazy-loads the catalog on first focus, filters
// on every keystroke against the friendly label OR the raw tag, and renders the
// matches as an INLINE, scrollable, paginated list (25 per page) directly under
// the input — not a floating popup, so it scrolls normally even when the editor
// sits at the bottom of a long page. Tags the player already has are excluded.
// Picking a row emits the raw tag string.

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { Icon } from './Icon'
import { filterTagCatalog, getTagCatalog, type TagCatalogEntry } from '../api/gameplay'

const PAGE_SIZE = 25

interface Props {
  value: string
  onChange: (text: string) => void
  /** Called when a suggestion is chosen — receives the raw tag string. */
  onPick: (tag: string) => void
  /** Called on Enter when no suggestion is active — lets the parent add the raw typed text. */
  onEnterRaw?: () => void
  /** Tags the player already has — excluded from suggestions. */
  exclude?: string[]
  placeholder?: string
  autoFocus?: boolean
  disabled?: boolean
}

export function TagPicker({ value, onChange, onPick, onEnterRaw, exclude, placeholder, autoFocus, disabled }: Props) {
  const inputId = useId()
  const [catalog, setCatalog] = useState<TagCatalogEntry[] | null>(null)
  const [catalogError, setCatalogError] = useState<string | null>(null)
  const [catalogLoading, setCatalogLoading] = useState(false)
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const [page, setPage] = useState(0)
  const wrapRef = useRef<HTMLDivElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const ensureCatalog = useCallback(() => {
    if (catalog || catalogLoading) return
    setCatalogLoading(true)
    getTagCatalog()
      .then(setCatalog)
      .catch(e => setCatalogError(e instanceof Error ? e.message : String(e)))
      .finally(() => setCatalogLoading(false))
  }, [catalog, catalogLoading])

  const excludeSet = useMemo(() => new Set(exclude || []), [exclude])
  const matches: TagCatalogEntry[] = catalog
    ? filterTagCatalog(catalog, value, Number.MAX_SAFE_INTEGER, excludeSet)
    : []

  const pageCount = Math.max(1, Math.ceil(matches.length / PAGE_SIZE))
  const pageClamped = Math.min(page, pageCount - 1)
  const visible = matches.slice(pageClamped * PAGE_SIZE, pageClamped * PAGE_SIZE + PAGE_SIZE)

  // Close when clicking outside the picker.
  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (wrapRef.current?.contains(e.target as Node)) return
      setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  // Keep the highlighted row scrolled into view within the list.
  useEffect(() => {
    if (!open) return
    listRef.current?.querySelector<HTMLElement>(`[data-idx="${active}"]`)?.scrollIntoView({ block: 'nearest' })
  }, [active, open])

  const setQuery = (text: string) => { onChange(text); setOpen(true); setActive(0); setPage(0) }
  const goPage = (p: number) => { setPage(Math.max(0, Math.min(p, pageCount - 1))); setActive(0) }

  const pick = (e: TagCatalogEntry) => { onPick(e.tag); setActive(0) }

  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') {
      if (!open && catalog) { setOpen(true); setActive(0) }
      else setActive(a => Math.min(a + 1, Math.max(visible.length - 1, 0)))
      e.preventDefault()
    } else if (e.key === 'ArrowUp') {
      setActive(a => Math.max(a - 1, 0)); e.preventDefault()
    } else if (e.key === 'Enter') {
      e.preventDefault()
      if (open && visible.length > 0) pick(visible[active])
      else onEnterRaw?.()
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
                : `${matches.length} match${matches.length === 1 ? '' : 'es'}`}
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

          <div ref={listRef} className="max-h-72 overflow-y-auto overscroll-contain divide-y divide-border/60">
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
            {visible.map((e, i) => (
              <div
                key={e.tag}
                data-idx={i}
                role="button"
                tabIndex={-1}
                onMouseEnter={() => setActive(i)}
                onMouseDown={ev => { ev.preventDefault(); pick(e) }}
                className={`px-3 py-2 cursor-pointer flex flex-col gap-0.5 ${
                  i === active ? 'bg-surface-2' : 'hover:bg-surface-2/60'
                }`}
              >
                <span className="text-sm text-text">{e.label}</span>
                <span className="text-[11px] font-mono text-text-dim truncate">{e.tag}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
