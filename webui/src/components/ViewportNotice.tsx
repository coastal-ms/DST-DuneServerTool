import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from './Icon'

export type ViewportNoticeKind = 'ok' | 'warn' | 'err'

interface Props {
  kind: ViewportNoticeKind
  text: string
  onDismiss: () => void
  autoDismissMs?: number | null
}

export function ViewportNotice({
  kind,
  text,
  onDismiss,
  autoDismissMs = kind === 'ok' ? 6_000 : null,
}: Props) {
  const dismissRef = useRef(onDismiss)
  dismissRef.current = onDismiss

  useEffect(() => {
    if (autoDismissMs === null || autoDismissMs <= 0) return
    const timer = window.setTimeout(() => dismissRef.current(), autoDismissMs)
    return () => window.clearTimeout(timer)
  }, [autoDismissMs, kind, text])

  return createPortal(
    <div className="pointer-events-none fixed inset-x-4 bottom-4 z-[11000] flex justify-center sm:left-auto sm:right-4 sm:w-full sm:max-w-lg">
      <div
        role={kind === 'err' ? 'alert' : 'status'}
        aria-live={kind === 'err' ? 'assertive' : 'polite'}
        aria-atomic="true"
        className={`card pointer-events-auto flex max-h-[min(50vh,24rem)] w-full items-start gap-2 overflow-y-auto p-3 text-sm shadow-lg ${
          kind === 'ok'
            ? 'border-success/40 bg-success/10 text-success'
            : kind === 'warn'
              ? 'border-warning/40 bg-warning/10 text-warning'
              : 'border-danger/40 bg-danger/10 text-danger'
        }`}
      >
        <Icon name={kind === 'ok' ? 'CheckCircle2' : kind === 'warn' ? 'ShieldAlert' : 'AlertCircle'} size={15} className="mt-0.5 shrink-0" />
        <span className="min-w-0 flex-1 whitespace-pre-wrap break-words">{text}</span>
        <button
          type="button"
          className="shrink-0 rounded p-1 text-current/70 transition-colors hover:bg-white/10 hover:text-current focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-current"
          onClick={onDismiss}
          aria-label="Dismiss notification"
          title="Dismiss"
        >
          <Icon name="X" size={14} />
        </button>
      </div>
    </div>,
    document.body,
  )
}
