// Shared collapsible section card.
//
// Every section card on Settings / Game Config / Database / Dashboard uses this so
// users can roll a card up purely for aesthetics. Cards default to OPEN; the
// open/closed choice persists per card in localStorage under `dst.card.<id>`.
//
// Pattern lifted from the original one-off in dashboard/ScheduledRestarts.tsx.

import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Icon } from './Icon'

const KEY_PREFIX = 'dst.card.'

export function useCardCollapse(id: string, defaultOpen = true) {
  const storageKey = KEY_PREFIX + id
  const [open, setOpen] = useState<boolean>(() => {
    try {
      const v = localStorage.getItem(storageKey)
      return v === null ? defaultOpen : v === '1'
    } catch {
      return defaultOpen
    }
  })

  useEffect(() => {
    try {
      localStorage.setItem(storageKey, open ? '1' : '0')
    } catch {
      /* private mode / storage disabled - collapse still works for this session */
    }
  }, [storageKey, open])

  const toggle = useCallback(() => setOpen(v => !v), [])
  return { open, setOpen, toggle }
}

type Props = {
  /** Stable id used for the localStorage key. */
  id: string
  title: ReactNode
  /** Plain label used by the page-level Jump to section selector. */
  navigationLabel?: string
  /** Lucide icon name shown next to the title. */
  icon?: string
  iconClassName?: string
  /** Secondary line under the title. */
  subtitle?: ReactNode
  /** Compact status shown on the right ONLY while collapsed. */
  summary?: ReactNode
  /** Always-visible header content to the right of the toggle (may contain buttons). */
  headerRight?: ReactNode
  defaultOpen?: boolean
  className?: string
  titleClassName?: string
  /** Padding/box classes for the header row. */
  headerClassName?: string
  /** Padding/box classes for the body. */
  bodyClassName?: string
  children: ReactNode
}

export function CollapsibleCard({
  id,
  title,
  navigationLabel,
  icon,
  iconClassName,
  subtitle,
  summary,
  headerRight,
  defaultOpen = true,
  className,
  titleClassName,
  headerClassName,
  bodyClassName,
  children,
}: Props) {
  const { open, toggle } = useCardCollapse(id, defaultOpen)
  const sectionLabel = navigationLabel ??
    (typeof title === 'string'
      ? title
      : id.split('.').pop()?.replace(/([a-z])([A-Z])/g, '$1 $2') ?? 'Section')

  return (
    <div
      className={`card ${className ?? 'mb-4'}`}
      data-section-nav-id={id}
      data-section-nav-label={sectionLabel}
    >
      <div className={`flex items-center gap-3 ${headerClassName ?? 'px-5 py-4'}`}>
        <button
          type="button"
          onClick={toggle}
          aria-expanded={open}
          data-section-nav-toggle
          className="flex-1 min-w-0 flex items-center justify-between gap-3 text-left"
        >
          <span className="flex items-center gap-2 min-w-0">
            <Icon
              name={open ? 'ChevronDown' : 'ChevronRight'}
              size={16}
              className="text-text-dim shrink-0"
            />
            {icon && (
              <Icon name={icon} size={16} className={iconClassName ?? 'text-text-muted shrink-0'} />
            )}
            <span className="min-w-0">
              <span className={`block ${titleClassName ?? 'font-semibold'}`}>{title}</span>
              {subtitle && <span className="block text-sm text-text-muted">{subtitle}</span>}
            </span>
          </span>
          {!open && summary && (
            <span className="text-[11px] font-medium text-text-dim normal-case shrink-0">
              {summary}
            </span>
          )}
        </button>
        {headerRight && <div className="shrink-0 flex items-center gap-2">{headerRight}</div>}
      </div>

      {open && <div className={bodyClassName ?? 'px-5 pb-5'}>{children}</div>}
    </div>
  )
}
