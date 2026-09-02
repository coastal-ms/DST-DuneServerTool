import { useEffect, useId, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from './Icon'

type Props = {
  title: string
  description: string
  confirmLabel: string
  onConfirm: () => void
  onCancel: () => void
  children?: ReactNode
}

export function ConfirmationModal({
  title,
  description,
  confirmLabel,
  onConfirm,
  onCancel,
  children,
}: Props) {
  const titleId = useId()
  const descriptionId = useId()
  const modalRef = useRef<HTMLDivElement | null>(null)
  const cancelRef = useRef<HTMLButtonElement | null>(null)
  const onCancelRef = useRef(onCancel)
  onCancelRef.current = onCancel

  useEffect(() => {
    const previousFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null
    const previousOverflow = document.body.style.overflow
    const root = document.getElementById('root')
    const previousInert = root?.inert ?? false
    document.body.style.overflow = 'hidden'
    if (root) root.inert = true
    cancelRef.current?.focus()

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onCancelRef.current()
        return
      }
      if (event.key !== 'Tab') return
      const focusable = Array.from(modalRef.current?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ) ?? [])
      if (focusable.length === 0) {
        event.preventDefault()
        cancelRef.current?.focus()
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

    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.body.style.overflow = previousOverflow
      if (root) root.inert = previousInert
      document.removeEventListener('keydown', onKeyDown)
      previousFocus?.focus()
    }
  }, [])

  return createPortal(
    <div
      className="fixed inset-0 z-[12000] flex items-center justify-center bg-black/70 p-3 sm:p-5"
      role="presentation"
      onClick={onCancel}
    >
      <div
        ref={modalRef}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={descriptionId}
        className="w-full max-w-lg overflow-hidden rounded-xl border border-danger/40 bg-surface shadow-[0_8px_0_rgba(0,0,0,0.18),0_28px_70px_-18px_rgba(0,0,0,0.85)]"
        onClick={(event) => event.stopPropagation()}
      >
        <header className="flex items-start gap-3 border-b border-border px-4 py-4 sm:px-5">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-danger/30 bg-danger/15 text-danger">
            <Icon name="TriangleAlert" size={20} />
          </div>
          <div className="min-w-0 flex-1">
            <h2 id={titleId} className="text-base font-semibold text-text sm:text-lg">
              {title}
            </h2>
            <p id={descriptionId} className="mt-1 text-sm leading-relaxed text-text-muted">
              {description}
            </p>
          </div>
          <button
            type="button"
            aria-label="Cancel and close"
            className="btn-icon min-h-11 min-w-11 shrink-0"
            onClick={onCancel}
          >
            <Icon name="X" size={17} />
          </button>
        </header>

        {children && (
          <div className="max-h-[55dvh] overflow-y-auto px-4 py-4 sm:px-5">
            {children}
          </div>
        )}

        <footer className="flex flex-col gap-2 border-t border-border px-4 py-4 sm:flex-row sm:justify-end sm:px-5">
          <button
            ref={cancelRef}
            type="button"
            className="btn-secondary min-h-11 justify-center"
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className="btn-danger min-h-11 justify-center"
            onClick={onConfirm}
          >
            <Icon name="TriangleAlert" size={15} />
            {confirmLabel}
          </button>
        </footer>
      </div>
    </div>,
    document.body,
  )
}
