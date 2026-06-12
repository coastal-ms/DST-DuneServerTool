// ItemPicker — typeahead autocomplete for the item catalog.
// v11.5.7. Used in player Give Item, storage Give Item, etc.
//
// Behaviour mirrors dune-admin's item search: lazy-load the catalog on first
// keystroke, filter on every change with substring match against display
// name OR template_id (case-insensitive), show up to 20 matches in a popup
// listing "Name — template_id (category)". Arrow keys + Enter to select,
// Escape to clear.

import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { Icon } from './Icon'
import { filterCatalog, getItemCatalog, type CatalogItem } from '../api/gameplay'

interface Props {
  value: string
  onChange: (templateId: string) => void
  label?: string
  placeholder?: string
  autoFocus?: boolean
  disabled?: boolean
}

export function ItemPicker({ value, onChange, label, placeholder, autoFocus, disabled }: Props) {
  const inputId = useId()
  const [catalog, setCatalog] = useState<CatalogItem[] | null>(null)
  const [catalogError, setCatalogError] = useState<string | null>(null)
  const [catalogLoading, setCatalogLoading] = useState(false)
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const wrapRef = useRef<HTMLDivElement>(null)

  // Lazy-load on first focus.
  const ensureCatalog = useCallback(() => {
    if (catalog || catalogLoading) return
    setCatalogLoading(true)
    getItemCatalog()
      .then(setCatalog)
      .catch(e => setCatalogError(e instanceof Error ? e.message : String(e)))
      .finally(() => setCatalogLoading(false))
  }, [catalog, catalogLoading])

  // Compute matches against current value.
  const matches: CatalogItem[] = catalog ? filterCatalog(catalog, value, 20) : []

  // Close popup on outside click.
  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (!wrapRef.current) return
      if (!wrapRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const pick = (it: CatalogItem) => {
    onChange(it.template_id)
    setOpen(false)
    setActive(0)
  }

  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (!open || matches.length === 0) {
      if (e.key === 'ArrowDown' && catalog) { setOpen(true); setActive(0); e.preventDefault() }
      return
    }
    if (e.key === 'ArrowDown')      { setActive(a => Math.min(a + 1, matches.length - 1)); e.preventDefault() }
    else if (e.key === 'ArrowUp')   { setActive(a => Math.max(a - 1, 0));                    e.preventDefault() }
    else if (e.key === 'Enter')     { pick(matches[active]); e.preventDefault() }
    else if (e.key === 'Escape')    { setOpen(false); e.preventDefault() }
    else if (e.key === 'Tab' && matches.length > 0) { pick(matches[active]) }
  }

  return (
    <div ref={wrapRef} className="relative">
      {label && (
        <label htmlFor={inputId} className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">
          {label}
        </label>
      )}
      <div className="relative">
        <input
          id={inputId}
          type="text"
          autoComplete="off"
          spellCheck={false}
          disabled={disabled}
          autoFocus={autoFocus}
          value={value}
          placeholder={placeholder || 'e.g. spice, stillsuit, literjon…'}
          onFocus={() => { ensureCatalog(); setOpen(true) }}
          onChange={e => { onChange(e.target.value); setOpen(true); setActive(0) }}
          onKeyDown={onKey}
          className="w-full pl-9 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
        />
        <Icon name="Search" size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim pointer-events-none" />
      </div>

      {open && (catalogLoading || catalogError || matches.length > 0 || value.trim().length > 0) && (
        <div className="absolute left-0 right-0 mt-1 z-30 max-h-72 overflow-y-auto rounded-lg border border-border bg-surface-1 shadow-2xl">
          {catalogLoading && (
            <div className="px-3 py-2 text-xs text-text-dim flex items-center gap-2">
              <Icon name="Loader2" size={12} className="animate-spin" /> Loading item catalog…
            </div>
          )}
          {catalogError && (
            <div className="px-3 py-2 text-xs text-danger">
              Catalog load failed: {catalogError}
            </div>
          )}
          {!catalogLoading && !catalogError && matches.length === 0 && value.trim().length > 0 && (
            <div className="px-3 py-2 text-xs text-text-dim">
              No items match "{value}". Type fewer letters or paste the exact template id.
            </div>
          )}
          {matches.map((it, i) => (
            <button
              key={it.template_id}
              type="button"
              onMouseEnter={() => setActive(i)}
              onMouseDown={e => { e.preventDefault(); pick(it) }}
              className={`w-full text-left px-3 py-2 flex items-center gap-2 text-sm ${
                i === active ? 'bg-surface-2 text-text' : 'text-text-dim hover:bg-surface-2/60'
              }`}
            >
              <span className="flex-1 min-w-0 truncate">
                <span className={i === active ? 'text-text font-medium' : 'text-text'}>{it.name}</span>
                <span className="ml-2 text-text-dim text-[11px] font-mono">{it.template_id}</span>
              </span>
              {it.category && (
                <span className="text-[10px] uppercase tracking-wider text-text-dim/70 shrink-0">
                  {it.category}
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
