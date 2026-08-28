import { useEffect, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from '../Icon'

export function DetailPanel({
  open,
  title,
  onClose,
  children,
}: {
  open: boolean
  title: string
  onClose: () => void
  children: ReactNode
}) {
  const closeRef = useRef<HTMLButtonElement | null>(null)
  const panelRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!open) return
    const previousFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null
    const previousOverflow = document.body.style.overflow
    const root = document.getElementById('root')
    const previousInert = root?.inert ?? false
    const scrollContainer = document.querySelector<HTMLElement>('[data-app-scroll-container]')
    const previousScrollOverflow = scrollContainer?.style.overflowY ?? ''
    document.body.style.overflow = 'hidden'
    if (root) root.inert = true
    if (scrollContainer) scrollContainer.style.overflowY = 'hidden'
    closeRef.current?.focus()
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }
      if (event.key !== 'Tab') return
      const focusable = Array.from(panelRef.current?.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ) ?? [])
      if (focusable.length === 0) {
        event.preventDefault()
        closeRef.current?.focus()
        return
      }
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = previousOverflow
      if (root) root.inert = previousInert
      if (scrollContainer) scrollContainer.style.overflowY = previousScrollOverflow
      document.removeEventListener('keydown', onKey)
      previousFocus?.focus()
    }
  }, [open, onClose])

  if (!open) return null

  return createPortal(
    <div className="fixed inset-0 z-[70]" role="presentation">
      <button
        type="button"
        aria-label="Dismiss detail panel"
        className="absolute inset-0 bg-black/65"
        onClick={onClose}
      />
      <section
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="workspace-detail-title"
        className="absolute inset-x-0 bottom-0 max-h-[82dvh] overflow-hidden rounded-t-2xl border border-border bg-surface shadow-2xl sm:inset-y-0 sm:right-0 sm:left-auto sm:h-full sm:max-h-none sm:w-[min(34rem,92vw)] sm:rounded-none sm:rounded-l-2xl"
      >
        <header className="flex min-h-14 items-center gap-3 border-b border-border px-4">
          <h2 id="workspace-detail-title" className="min-w-0 flex-1 truncate font-semibold">
            {title}
          </h2>
          <button
            ref={closeRef}
            type="button"
            aria-label="Close detail panel"
            onClick={onClose}
            className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg text-text-muted hover:bg-surface-2 hover:text-text focus:outline-none focus-visible:ring-2 focus-visible:ring-ibad"
          >
            <Icon name="X" size={18} />
          </button>
        </header>
        <div className="max-h-[calc(82dvh-3.5rem)] overflow-y-auto p-4 pb-[max(1rem,env(safe-area-inset-bottom))] sm:max-h-[calc(100dvh-3.5rem)]">
          {children}
        </div>
      </section>
    </div>,
    document.body,
  )
}
