import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS, GROUP_ORDER, type NavGroup } from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { useDuneAdminWebUrl } from '../hooks/useDuneAdminWebUrl'
import { buildDiagnosticBundle } from '../api/diagnostics'
import { getAutostartState, setAutostartEnabled, type AutostartState } from '../api/autostart'
import { isLocalViewer } from '../util/viewer'

type MenuKey = NavGroup | 'help' | 'duneadmin'

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
  const { data: da } = useDuneAdminWebUrl()
  const version = upd?.currentVersion ?? ''
  const [open, setOpen] = useState<MenuKey | null>(null)
  const rootRef = useRef<HTMLDivElement | null>(null)

  // Autostart state. Only fetched on local viewers — the backend rejects
  // non-loopback callers anyway and there's nothing the remote viewer could
  // do with the result (the toggle is hidden for them below).
  const local = isLocalViewer()
  const [autostart, setAutostart] = useState<AutostartState | null>(null)
  const [autostartBusy, setAutostartBusy] = useState(false)
  const [autostartConfirm, setAutostartConfirm] = useState<null | { nextEnabled: boolean }>(null)
  const [autostartError, setAutostartError] = useState<string | null>(null)

  const refreshAutostart = useCallback(async () => {
    if (!local) return
    try {
      const s = await getAutostartState()
      setAutostart(s)
    } catch {
      // Older backends without the route just leave the item disabled —
      // no toast, no scary error, the feature simply isn't there.
      setAutostart(null)
    }
  }, [local])

  useEffect(() => { void refreshAutostart() }, [refreshAutostart])

  const onAutostartToggleClick = () => {
    if (!autostart || !autostart.available || autostartBusy) return
    setAutostartError(null)
    setAutostartConfirm({ nextEnabled: !autostart.enabled })
    setOpen(null)
  }

  const onAutostartConfirm = async () => {
    if (!autostartConfirm) return
    const target = autostartConfirm.nextEnabled
    setAutostartBusy(true)
    setAutostartError(null)
    try {
      const s = await setAutostartEnabled(target)
      setAutostart(s)
      setAutostartConfirm(null)
    } catch (e) {
      setAutostartError(e instanceof Error ? e.message : String(e))
    } finally {
      setAutostartBusy(false)
    }
  }

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

  // Help → Create GitHub Issue + Save Logs. Opens the prefilled issue form
  // synchronously inside the click handler (so the popup-blocker treats it as
  // a user gesture), then fires the diagnostics-bundle build in the
  // background. The backend pops an Explorer window with the ZIP selected so
  // the user can drag it straight into the new issue comment. We intentionally
  // do NOT await the bundle before opening the issue — a slow zip should
  // never make the issue tab fail to open.
  const onReportIssue = () => {
    setOpen(null)
    window.open(issueHref, '_blank', 'noopener,noreferrer')
    void buildDiagnosticBundle().catch(() => {
      /* the toastless world: backend already revealed the ZIP if it succeeded.
         A failure here just means no auto-bundle — the user can still file the
         issue manually and attach logs themselves. */
    })
  }

  const onItemClick = (item: typeof NAV_ITEMS[number]) => {
    setOpen(null)
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
        const items = NAV_ITEMS
          .filter(i => i.group === g)
          .filter(i => !i.localOnly || isLocalViewer())
        if (items.length === 0) return null
        // Single-item group (e.g. Server Health, which has only one page):
        // a dropdown with one entry is pure friction. Render the group
        // button as a direct link to that page instead. The button label
        // stays as the group label so the menu bar's visual layout is
        // unchanged; only the click behavior differs.
        if (items.length === 1) {
          const only = items[0]
          const active = isActive(only.to)
          return (
            <div key={g} className="relative">
              <button
                type="button"
                onClick={() => { setOpen(null); navigate(only.to) }}
                onMouseEnter={() => { if (open !== null) setOpen(null) }}
                className={`px-3 h-7 rounded-md transition-colors ${
                  active
                    ? 'bg-surface-3 text-text'
                    : 'text-text-muted hover:text-text hover:bg-surface-2/80'
                }`}
              >
                {GROUP_LABELS[g]}
              </button>
            </div>
          )
        }
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
                    <Icon name={item.icon} size={14} />
                    <span className="flex-1">{item.label}</span>
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
          <div className="absolute left-0 top-full mt-1 min-w-[260px] bg-surface border border-border rounded-xl p-1 shadow-xl shadow-black/40 z-50">
            <button
              type="button"
              onClick={onReportIssue}
              className="w-full flex items-start gap-2 px-2.5 py-1.5 rounded text-sm text-text-muted hover:text-text hover:bg-surface-2 transition-colors text-left"
              title="Opens the prefilled GitHub bug-report form and saves a redacted log ZIP to your Desktop (Explorer will pop with the ZIP selected — drag it into the issue comment)."
            >
              <Icon name="Github" size={14} className="mt-0.5" />
              <span className="flex-1">
                <span className="block">Create GitHub Issue + Save Logs</span>
                <span className="block text-[11px] text-text-dim">
                  Opens the issue form &amp; drops a redacted ZIP on your Desktop
                </span>
              </span>
              <Icon name="ExternalLink" size={11} className="text-text-dim mt-1" />
            </button>
            {local && autostart && autostart.available && (
              <button
                type="button"
                onClick={onAutostartToggleClick}
                disabled={autostartBusy}
                className="w-full flex items-start gap-2 px-2.5 py-1.5 rounded text-sm text-text-muted hover:text-text hover:bg-surface-2 transition-colors text-left disabled:opacity-60 disabled:cursor-wait"
                title={
                  autostart.enabled
                    ? 'Currently launching at Windows logon in the system tray. Click to stop running at startup.'
                    : 'Click to launch Dune Server automatically when you log in to Windows.'
                }
              >
                <Icon name="Power" size={14} className="mt-0.5" />
                <span className="flex-1">
                  <span className="block">Run at Windows startup</span>
                  <span className="block text-[11px] text-text-dim">
                    {autostart.enabled
                      ? 'Enabled — server keeps running when you close this window'
                      : 'Disabled — closing this window stops the server'}
                  </span>
                </span>
                {autostart.enabled && (
                  <Icon name="Check" size={13} className="text-success mt-1" />
                )}
              </button>
            )}
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

      {/* Dune Admin appears immediately to the right of Help only when DST
          detects a configured dune-admin install (config.yaml present). The
          item itself is shown whether or not dune-admin is currently
          listening — clicking it routes to /dune-admin, which then either
          embeds the live web UI or offers a Start button. The whole entry
          stays hidden for users who don't have the companion tool. */}
      {da?.configured && (
        <div className="relative">
          <button
            type="button"
            onClick={() => { setOpen(null); navigate('/dune-admin') }}
            onMouseEnter={() => { if (open !== null) setOpen(null) }}
            className={`px-3 h-7 rounded-md transition-colors flex items-center gap-1.5 ${
              isActive('/dune-admin')
                ? 'bg-surface-3 text-text'
                : 'text-text-muted hover:text-text hover:bg-surface-2/80'
            }`}
            title={
              da.listening
                ? `dune-admin live at ${da.url || `:${da.port}`}`
                : `dune-admin installed but not running`
            }
          >
            <span>Dune Admin</span>
            <span
              className={`w-1.5 h-1.5 rounded-full ${
                da.listening ? 'bg-success' : 'bg-text-dim'
              }`}
              aria-hidden
            />
          </button>
        </div>
      )}

      {/* Autostart toggle — confirmation modal. Lives at the menubar root
          rather than inside the dropdown so it stays visible after the menu
          closes on click. */}
      {autostartConfirm && (
        <div
          className="fixed inset-0 z-[60] bg-black/60 flex items-center justify-center p-4"
          onClick={() => { if (!autostartBusy) { setAutostartConfirm(null); setAutostartError(null) } }}
        >
          <div
            className="bg-surface border border-border rounded-xl shadow-2xl max-w-md w-full p-5"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-start gap-3 mb-3">
              <Icon name="Power" size={20} className="text-accent-bright mt-0.5" />
              <div className="flex-1">
                <h2 className="text-base font-semibold text-text mb-1">
                  {autostartConfirm.nextEnabled ? 'Run Dune Server at Windows startup?' : 'Stop running at Windows startup?'}
                </h2>
                <p className="text-sm text-text-muted leading-snug">
                  {autostartConfirm.nextEnabled
                    ? 'Dune Server will launch in the system tray every time you log in to Windows. Closing this window will no longer stop the server — use the tray icon’s “Quit (stop server)” to shut it down. You can turn this off any time from Help → Run at Windows startup.'
                    : 'Dune Server will no longer start automatically. This takes effect at your next login — the currently running server keeps going until you quit it. You can re-enable it any time from Help → Run at Windows startup.'}
                </p>
              </div>
            </div>
            {autostartError && (
              <div className="mb-3 p-2 rounded bg-danger/10 border border-danger/30 text-sm text-danger">
                {autostartError}
              </div>
            )}
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => { setAutostartConfirm(null); setAutostartError(null) }}
                disabled={autostartBusy}
                className="px-3 py-1.5 rounded text-sm text-text-muted hover:text-text hover:bg-surface-2 disabled:opacity-60"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={onAutostartConfirm}
                disabled={autostartBusy}
                className="px-3 py-1.5 rounded text-sm bg-accent text-white hover:bg-accent-bright disabled:opacity-60 disabled:cursor-wait"
              >
                {autostartBusy
                  ? 'Working…'
                  : autostartConfirm.nextEnabled
                    ? 'Enable autostart'
                    : 'Disable autostart'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
