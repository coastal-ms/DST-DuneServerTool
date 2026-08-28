import type { ReactNode } from 'react'
import { Icon } from '../Icon'

export type DataStateKind =
  | 'loading'
  | 'fresh'
  | 'refreshing'
  | 'stale'
  | 'partial'
  | 'empty'
  | 'unavailable'
  | 'error'

const PRESENTATION: Record<DataStateKind, { icon: string; tone: string; label: string }> = {
  loading: { icon: 'Loader2', tone: 'text-text-muted', label: 'Loading' },
  fresh: { icon: 'CheckCircle2', tone: 'text-success', label: 'Fresh' },
  refreshing: { icon: 'RefreshCw', tone: 'text-info', label: 'Refreshing' },
  stale: { icon: 'Clock3', tone: 'text-warning', label: 'Stale' },
  partial: { icon: 'CircleDashed', tone: 'text-warning', label: 'Partial' },
  empty: { icon: 'Inbox', tone: 'text-text-muted', label: 'No data' },
  unavailable: { icon: 'CircleOff', tone: 'text-text-muted', label: 'Unavailable' },
  error: { icon: 'AlertTriangle', tone: 'text-danger', label: 'Error' },
}

export function FreshnessBadge({
  state,
  label,
  observedAt,
}: {
  state: Extract<DataStateKind, 'fresh' | 'refreshing' | 'stale' | 'partial' | 'unavailable'>
  label?: string
  observedAt?: string | null
}) {
  const presentation = PRESENTATION[state]
  const detail = observedAt ? `Observed ${observedAt}` : undefined
  return (
    <span
      className={`pill bg-surface-2 border-border ${presentation.tone}`}
      title={detail}
      role="status"
      data-freshness-state={state}
    >
      <Icon
        name={presentation.icon}
        size={11}
        className={state === 'refreshing' ? 'animate-spin motion-reduce:animate-none' : undefined}
      />
      {label ?? presentation.label}
    </span>
  )
}

export function DataState({
  state,
  title,
  message,
  action,
  children,
}: {
  state: DataStateKind
  title?: string
  message?: string
  action?: ReactNode
  children?: ReactNode
}) {
  if (state === 'fresh' && children) return <>{children}</>
  const presentation = PRESENTATION[state]
  return (
    <div
      className="card px-4 py-5 sm:px-5"
      role={state === 'error' ? 'alert' : 'status'}
      data-data-state={state}
    >
      <div className="flex items-start gap-3">
        <Icon
          name={presentation.icon}
          size={18}
          className={`mt-0.5 shrink-0 ${presentation.tone} ${
            state === 'loading' || state === 'refreshing'
              ? 'animate-spin motion-reduce:animate-none'
              : ''
          }`}
        />
        <div className="min-w-0 flex-1">
          <div className={`font-medium ${presentation.tone}`}>
            {title ?? presentation.label}
          </div>
          {message && <p className="mt-1 max-w-[72ch] text-sm text-text-muted">{message}</p>}
          {action && <div className="mt-3 flex flex-wrap gap-2">{action}</div>}
        </div>
      </div>
    </div>
  )
}
