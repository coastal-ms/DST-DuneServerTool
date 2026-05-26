import type { ReactNode } from 'react'
import { Icon } from './Icon'

type Props = {
  title: string
  icon: string
  description?: string
  actions?: ReactNode
}

export function PageHeader({ title, icon, description, actions }: Props) {
  return (
    <div className="flex items-start justify-between mb-6">
      <div className="flex items-start gap-3">
        <div className="w-10 h-10 rounded-lg bg-surface-2 border border-border flex items-center justify-center text-accent-bright">
          <Icon name={icon} size={20} />
        </div>
        <div>
          <h1 className="text-xl font-semibold tracking-tight">{title}</h1>
          {description && (
            <p className="text-sm text-text-muted mt-0.5">{description}</p>
          )}
        </div>
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  )
}
