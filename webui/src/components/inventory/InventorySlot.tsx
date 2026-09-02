import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { SharedInventoryItem } from '../../api/gameplay'
import { InventoryItemIcon } from './InventoryItemIcon'

function entityTypeLabel(type: SharedInventoryItem['entity']['type']) {
  return type === 'player' ? 'Player inventory' : 'Storage container'
}

export function InventorySlot({
  item,
  onSelect,
}: {
  item: SharedInventoryItem
  onSelect: (item: SharedInventoryItem) => void
}) {
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const tooltipId = useId()
  const [hovered, setHovered] = useState(false)
  const [hoverSuppressed, setHoverSuppressed] = useState(false)
  const [focused, setFocused] = useState(false)
  const [position, setPosition] = useState({ left: 8, top: 8 })
  const showInfo = (hovered && !hoverSuppressed) || focused
  const name = item.displayName || item.templateId
  const source = entityTypeLabel(item.entity.type)
  const entity = item.entity.label || `Actor ${item.entity.id}`

  const placeInfoCard = useCallback(() => {
    const rect = buttonRef.current?.getBoundingClientRect()
    if (!rect) return
    const width = Math.min(288, window.innerWidth - 16)
    const estimatedHeight = 184
    const left = Math.min(Math.max(8, rect.left + rect.width / 2 - width / 2), window.innerWidth - width - 8)
    const top = rect.bottom + estimatedHeight + 8 <= window.innerHeight
      ? rect.bottom + 8
      : Math.max(8, rect.top - estimatedHeight - 8)
    setPosition({ left, top })
  }, [])

  useEffect(() => {
    const handleFocusIn = (event: FocusEvent) => {
      const target = event.target
      if (!(target instanceof Element) || !target.closest('[data-inventory-slot]')) return
      setHoverSuppressed(target !== buttonRef.current)
    }
    document.addEventListener('focusin', handleFocusIn)
    return () => document.removeEventListener('focusin', handleFocusIn)
  }, [])

  useEffect(() => {
    if (!showInfo) return
    placeInfoCard()
    window.addEventListener('resize', placeInfoCard)
    window.addEventListener('scroll', placeInfoCard, true)
    return () => {
      window.removeEventListener('resize', placeInfoCard)
      window.removeEventListener('scroll', placeInfoCard, true)
    }
  }, [placeInfoCard, showInfo])

  return (
    <>
      <button
        ref={buttonRef}
        type="button"
        data-inventory-slot
        aria-label={`${name}, quantity ${item.quantity}, quality ${item.quality}, ${source}, ${entity}`}
        aria-describedby={showInfo ? tooltipId : undefined}
        className="group relative flex aspect-square min-h-22 w-full min-w-0 flex-col overflow-hidden rounded-xl border border-border bg-surface/85 text-left shadow-[inset_0_1px_rgba(255,255,255,0.04),0_6px_16px_-12px_rgba(0,0,0,0.9)] transition-[border-color,background-color,transform] duration-150 hover:-translate-y-0.5 hover:border-accent/60 hover:bg-surface-2 focus:outline-none focus-visible:border-ibad focus-visible:ring-2 focus-visible:ring-ibad active:translate-y-0"
        onMouseEnter={() => {
          setHoverSuppressed(false)
          setHovered(true)
        }}
        onMouseLeave={() => setHovered(false)}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onClick={() => {
          setHovered(false)
          setFocused(false)
          onSelect(item)
        }}
      >
        <span className="flex w-full items-center justify-between gap-1 px-1.5 pt-1.5">
          <span className="rounded-md border border-info/35 bg-base/90 px-1.5 py-0.5 text-[10px] font-semibold text-info">
            Q{item.quality}
          </span>
          <span className="rounded-md border border-accent/45 bg-base/90 px-1.5 py-0.5 text-[11px] font-bold text-accent-bright">
            x{item.quantity}
          </span>
        </span>
        <InventoryItemIcon templateId={item.templateId} displayName={name} />
        <span className="w-full truncate border-t border-border/80 bg-base/75 px-2 py-1.5 text-center text-xs font-semibold text-text">
          {name}
        </span>
      </button>

      {showInfo && createPortal(
        <div
          id={tooltipId}
          role="tooltip"
          style={{ position: 'fixed', left: position.left, top: position.top, width: 'min(18rem, calc(100vw - 1rem))' }}
          className="pointer-events-none z-[100] rounded-xl border border-border-bright bg-surface px-3 py-2.5 text-xs shadow-[0_12px_32px_-10px_rgba(0,0,0,0.85)]"
        >
          <p className="break-words text-sm font-semibold text-text">{name}</p>
          <p className="mt-0.5 break-all font-mono text-[11px] text-text-muted">{item.templateId}</p>
          <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
            <dt className="text-text-muted">Quantity</dt><dd className="text-right font-semibold text-text">{item.quantity}</dd>
            <dt className="text-text-muted">Quality</dt><dd className="text-right font-semibold text-text">{item.quality}</dd>
            <dt className="text-text-muted">Source</dt><dd className="break-words text-right text-text">{source}</dd>
            <dt className="text-text-muted">Entity</dt><dd className="break-words text-right text-text">{entity}</dd>
            {item.entity.owner && <><dt className="text-text-muted">Owner</dt><dd className="break-words text-right text-text">{item.entity.owner}</dd></>}
          </dl>
        </div>,
        document.body,
      )}
    </>
  )
}
