// Shared atoms used by the Characters tabs.
import { useEffect, useState, type ReactNode } from 'react'
import { Icon } from '../../components/Icon'

// ----- ConfirmDialog --------------------------------------------------------

type ConfirmProps = {
  open: boolean
  title: string
  message: ReactNode
  confirmLabel?: string
  confirmIcon?: string
  danger?: boolean
  onCancel: () => void
  onConfirm: () => void | Promise<void>
}

export function ConfirmDialog({
  open, title, message, confirmLabel = 'Confirm', confirmIcon = 'Check',
  danger = false, onCancel, onConfirm,
}: ConfirmProps) {
  const [busy, setBusy] = useState(false)
  useEffect(() => { if (!open) setBusy(false) }, [open])
  if (!open) return null
  async function handle() {
    setBusy(true)
    try { await onConfirm() } finally { setBusy(false) }
  }
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
         onClick={onCancel}>
      <div className="card p-5 max-w-md w-full" onClick={e => e.stopPropagation()}>
        <div className="flex items-start gap-3 mb-4">
          <div className={`w-9 h-9 rounded-lg flex items-center justify-center
                          ${danger ? 'bg-danger/15 text-danger' : 'bg-accent/15 text-accent-bright'}`}>
            <Icon name={danger ? 'AlertTriangle' : 'HelpCircle'} size={18} />
          </div>
          <div className="flex-1">
            <h3 className="font-semibold text-text mb-1">{title}</h3>
            <div className="text-sm text-text-muted">{message}</div>
          </div>
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" className="btn-ghost" disabled={busy} onClick={onCancel}>Cancel</button>
          <button type="button" className={danger ? 'btn-danger' : 'btn-primary'}
                  disabled={busy} onClick={handle}>
            <Icon name={busy ? 'Loader2' : confirmIcon} size={15} className={busy ? 'animate-spin' : ''} />
            {busy ? 'Working…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}

// ----- Toast (auto-fade) ----------------------------------------------------

type ToastProps = { kind: 'success' | 'error'; message: string | null; onClear?: () => void }

export function Toast({ kind, message, onClear }: ToastProps) {
  useEffect(() => {
    if (!message || !onClear) return
    const id = window.setTimeout(onClear, kind === 'error' ? 6000 : 3000)
    return () => window.clearTimeout(id)
  }, [message, kind, onClear])
  if (!message) return null
  const cls = kind === 'success'
    ? 'border-success/40 bg-success/10 text-success'
    : 'border-danger/40 bg-danger/10 text-danger'
  const icon = kind === 'success' ? 'CheckCircle2' : 'AlertCircle'
  return (
    <div className={`card p-3 mb-3 text-sm flex items-center gap-2 ${cls}`}>
      <Icon name={icon} size={14} /> {message}
    </div>
  )
}

// ----- Section card ---------------------------------------------------------

export function SectionCard({ title, icon, actions, children }:
  { title: string; icon?: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <div className="card p-5 mb-4">
      <div className="flex items-center justify-between mb-4">
        <h3 className="font-semibold text-text flex items-center gap-2">
          {icon && <Icon name={icon} size={16} className="text-accent-bright" />}
          {title}
        </h3>
        {actions && <div className="flex items-center gap-2">{actions}</div>}
      </div>
      {children}
    </div>
  )
}

// ----- Number input field ---------------------------------------------------

export function NumberField({ label, value, onChange, min, max, step, suffix }:
  { label: string; value: string; onChange: (v: string) => void
    min?: number; max?: number; step?: number; suffix?: string }) {
  return (
    <div>
      <label className="block text-xs font-medium text-text-muted mb-1">{label}</label>
      <div className="relative">
        <input
          type="number"
          value={value}
          min={min}
          max={max}
          step={step}
          onChange={e => onChange(e.target.value)}
          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm
                     focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
        />
        {suffix && (
          <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-text-dim pointer-events-none">
            {suffix}
          </span>
        )}
      </div>
    </div>
  )
}

// ----- Empty / error states -------------------------------------------------

export function EmptyState({ icon, title, description }:
  { icon: string; title: string; description?: string }) {
  return (
    <div className="text-center py-12 text-text-muted">
      <Icon name={icon} size={36} className="mx-auto mb-3 opacity-40" />
      <div className="font-medium text-text">{title}</div>
      {description && <div className="text-sm mt-1">{description}</div>}
    </div>
  )
}
