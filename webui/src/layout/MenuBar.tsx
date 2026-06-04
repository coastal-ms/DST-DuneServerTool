import { useEffect, useRef, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS, GROUP_ORDER, type NavGroup } from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { useLaunchDuneAdmin } from '../hooks/useLaunchDuneAdmin'

type MenuKey = NavGroup | 'help'

type Props = {
  sidebarCollapsed: boolean
  onToggleSidebar: () => void
}

// Classic Windows-style top menu bar. Each group from the sidebar (Server
// Health, PowerShell, Game Data, Database, System) appears here as a dropdown
// listing its pages, plus a "Help" dropdown immediately to the right of
// System for cross-cutting commands like "Create GitHub Issue" and the
// sidebar collapse toggle.
export function MenuBar({ sidebarCollapsed, onToggleSidebar }: Props) {
  const navigate = useNavigate()
  const location = useLocation()
  const { data: upd } = useUpdateCheck()
  const version = upd?.currentVersion ?? ''
  const { launching: daLaunching, launch: launchDuneAdmin } = useLaunchDuneAdmin()
  const [open, setOpen] = useState<MenuKey | null>(null)
  const rootRef = useRef<HTMLDivElement | null>(null)

  // Click-outside and Escape to close any open dropdown.
  useEffect(() => {
    if (!open) return
    const onClick = (e: MouseEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(null)
    }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(null) }
    document.addEventListener('mousedown', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const issueHref = `https://github.com/coastal-ms/DST-DuneServerTool/issues/new?template=bug_report.yml${
    version ? `&tool_version=v${encodeURIComponent(version)}` : ''
  }`

  const onItemClick = (item: typeof NAV_ITEMS[number]) => {
    setOpen(null)
    if (item.action === 'launch-dune-admin') {
      void launchDuneAdmin()
      return
    }
    navigate(item.to)
  }

  const isActive = (to: string) => {
    if (to === '/') return location.pathname === '/'
    return location.pathname === to || location.pathname.startsWith(`${to}/`)
  }

  return (
    <div
      ref={rootRef}
      className="h-8 shrink-0 border-b border-border bg-surface flex items-center px-1 text-[13px] select-none relative z-40"
    >
      {GROUP_ORDER.map(g => {
        const items = NAV_ITEMS.filter(i => i.group === g)
        if (items.length === 0) return null
        const isOpen = open === g
        return (
          <div key={g} className="relative">
            <button
              type="button"
              onClick={() => setOpen(isOpen ? null : g)}
              onMouseEnter={() => { if (open !== null) setOpen(g) }}
              className={`px-3 h-7 rounded-md transition-colors ${
                isOpen
                  ? 'bg-surface-3 text-text'
                  : 'text-text-muted hover:text-text hover:bg-surface-2/80'
              }`}
            >
              {GROUP_LABELS[g]}
            </button>
            {isOpen && (
              <div className="absolute left-0 top-full mt-1 min-w-[200px] bg-surface border border-border rounded-xl p-1 shadow-xl shadow-black/40 z-50">
                {items.map(item => (
                  <button
                    key={item.to}
                    type="button"
                    onClick={() => onItemClick(item)}
                    className={`w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-sm text-left transition-colors ${
                      isActive(item.to)
                        ? 'bg-accent/15 text-accent-bright'
                        : 'text-text-muted hover:text-text hover:bg-surface-2'
                    }`}
                  >
                    <Icon
                      name={item.action === 'launch-dune-admin' && daLaunching ? 'Loader2' : item.icon}
                      size={14}
                      className={item.action === 'launch-dune-admin' && daLaunching ? 'animate-spin' : ''}
                    />
                    <span className="flex-1">{item.label}</span>
                    {item.action === 'launch-dune-admin' && (
                      <Icon name="ExternalLink" size={11} className="text-text-dim" />
                    )}
                  </button>
                ))}
              </div>
            )}
          </div>
        )
      })}

      {/* Help sits immediately to the right of the last group (System). */}
      <div className="relative">
        <button
          type="button"
          onClick={() => setOpen(open === 'help' ? null : 'help')}
          onMouseEnter={() => { if (open !== null) setOpen('help') }}
          className={`px-3 h-7 rounded-md transition-colors ${
            open === 'help'
              ? 'bg-surface-3 text-text'
              : 'text-text-muted hover:text-text hover:bg-surface-2/80'
          }`}
        >
          Help
        </button>
        {open === 'help' && (
          <div className="absolute left-0 top-full mt-1 min-w-[220px] bg-surface border border-border rounded-xl p-1 shadow-xl shadow-black/40 z-50">
            <a
              href={issueHref}
              target="_blank"
              rel="noopener noreferrer"
              onClick={() => setOpen(null)}
              className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-sm text-text-muted hover:text-text hover:bg-surface-2 transition-colors"
            >
              <Icon name="Github" size={14} />
              <span className="flex-1">Create GitHub Issue</span>
              <Icon name="ExternalLink" size={11} className="text-text-dim" />
            </a>
            <button
              type="button"
              onClick={() => { onToggleSidebar(); setOpen(null) }}
              className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-sm text-text-muted hover:text-text hover:bg-surface-2 transition-colors"
            >
              <Icon name={sidebarCollapsed ? 'PanelLeftOpen' : 'PanelLeftClose'} size={14} />
              <span className="flex-1">
                {sidebarCollapsed ? 'Expand Sidebar' : 'Collapse Sidebar'}
              </span>
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
