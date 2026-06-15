import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS, GROUP_ORDER, type NavGroup } from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { buildDiagnosticBundle, type DiagnosticBundle } from '../api/diagnostics'
import { getAutostartState, setAutostartEnabled, type AutostartState } from '../api/autostart'
import { getConsoleState, setConsoleVisible, type ConsoleState } from '../api/console'
import { isLocalViewer } from '../util/viewer'

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

  // Backend-console state. Loopback-only (the backend route 403s remote
  // callers anyway, and the menu item is hidden for them via `local`).
  // null = not loaded yet / route unavailable on older backends.
  const [consoleState, setConsoleState] = useState<ConsoleState | null>(null)
  const [consoleBusy, setConsoleBusy] = useState(false)

  // Diagnostics-bundle result, surfaced so the user always learns where the
  // ZIP landed (Desktop vs. %APPDATA% fallback) or why it couldn't be built —
  // instead of the old fire-and-forget that silently swallowed both.
  const [diag, setDiag] = useState<
    null | { status: 'building' } | { status: 'done'; result: DiagnosticBundle } | { status: 'error'; error: string }
  >(null)

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

  // Console state — refresh when the Help menu opens so the Show / Hide label
  // tracks the real window state even if the user minimized / restored it
  // outside the app (e.g. via the taskbar).
  const refreshConsole = useCallback(async () => {
    if (!local) return
    try {
      const s = await getConsoleState()
      setConsoleState(s)
    } catch {
      setConsoleState(null)
    }
  }, [local])

  useEffect(() => { void refreshConsole() }, [refreshConsole])
  useEffect(() => { if (open === 'help') void refreshConsole() }, [open, refreshConsole])

  const onConsoleToggleClick = async () => {
    if (!consoleState || !consoleState.available || consoleBusy) return
    // If currently visible AND not minimized, hide it. Otherwise show it
    // (this also un-minimizes via SW_RESTORE in the backend).
    const nextVisible = !(consoleState.visible && !consoleState.minimized)
    setConsoleBusy(true)
    try {
      const s = await setConsoleVisible(nextVisible)
      setConsoleState(s)
      setOpen(null)
    } catch {
      // Best-effort: leave state as it was, user can retry.
    } finally {
      setConsoleBusy(false)
    }
  }

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
  // a user gesture), then builds the diagnostics bundle. The result is surfaced
  // in a modal so the user always learns where the ZIP landed (Desktop, or the
  // %APPDATA% fallback when the Desktop isn't writable — e.g. OneDrive KFM) or
  // why it failed. We intentionally do NOT await the bundle before opening the
  // issue — a slow zip should never make the issue tab fail to open.
  const onReportIssue = () => {
    setOpen(null)
    window.open(issueHref, '_blank', 'noopener,noreferrer')
    setDiag({ status: 'building' })
    buildDiagnosticBundle()
      .then((result) => setDiag({ status: 'done', result }))
      .catch((e) =>
        setDiag({ status: 'error', error: e instanceof Error ? e.message : String(e) }),
      )
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
            {local && consoleState && consoleState.available && (
              <button
                type="button"
                onClick={onConsoleToggleClick}
                disabled={consoleBusy}
                className="w-full flex items-start gap-2 px-2.5 py-1.5 rounded text-sm text-text-muted hover:text-text hover:bg-surface-2 transition-colors text-left disabled:opacity-60 disabled:cursor-wait"
                title={
                  consoleState.visible && !consoleState.minimized
                    ? 'Hide the backend PowerShell console window. The server keeps running — log output still goes to dune-server.log.'
                    : 'Bring the backend PowerShell console window to the foreground so you can watch the server work in real time.'
                }
              >
                <Icon name="Terminal" size={14} className="mt-0.5" />
                <span className="flex-1">
                  <span className="block">
                    {consoleState.visible && !consoleState.minimized
                      ? 'Hide backend console'
                      : 'Show backend console'}
                  </span>
                  <span className="block text-[11px] text-text-dim">
                    {consoleState.visible
                      ? (consoleState.minimized
                          ? 'Currently minimized — click to restore to a visible window'
                          : 'Currently visible — click to hide')
                      : 'Currently hidden — click to reveal the live server output'}
                  </span>
                </span>
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

      {/* Marketing site link, pushed to the far right of the menu bar.
          ml-auto consumes the remaining horizontal space so this sits flush
          right while the page groups + Help stay left-aligned. */}
      <a
        href="https://coastal-ms.github.io/DST-DuneServerTool/"
        target="_blank"
        rel="noopener noreferrer"
        onMouseEnter={() => { if (open !== null) setOpen(null) }}
        className="ml-auto mr-1 px-3 h-7 inline-flex items-center gap-1.5 rounded-md text-text-muted hover:text-text hover:bg-surface-2/80 transition-colors"
        title="Open the Dune Server Tool website — screenshots, install guide, and changelog"
      >
        <Icon name="Globe" size={14} />
        <span>Website</span>
        <Icon name="ExternalLink" size={11} className="text-text-dim" />
      </a>

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

      {/* Diagnostics bundle result — surfaced so "Report an issue" always tells
          the user what happened instead of failing silently. */}
      {diag && (
        <div
          className="fixed inset-0 z-[60] bg-black/60 flex items-center justify-center p-4"
          onClick={() => { if (diag.status !== 'building') setDiag(null) }}
        >
          <div
            className="bg-surface border border-border rounded-xl shadow-2xl max-w-md w-full p-5"
            onClick={(e) => e.stopPropagation()}
          >
            {diag.status === 'building' && (
              <div className="flex items-start gap-3">
                <Icon name="Loader" size={20} className="text-accent-bright mt-0.5 animate-spin" />
                <div className="flex-1">
                  <h2 className="text-base font-semibold text-text mb-1">Building diagnostics bundle…</h2>
                  <p className="text-sm text-text-muted leading-snug">
                    Collecting and redacting logs into a ZIP you can attach to your GitHub issue.
                  </p>
                </div>
              </div>
            )}

            {diag.status === 'done' && (
              <>
                <div className="flex items-start gap-3 mb-3">
                  <Icon name="CheckCircle" size={20} className="text-success mt-0.5" />
                  <div className="flex-1 min-w-0">
                    <h2 className="text-base font-semibold text-text mb-1">Diagnostics bundle saved</h2>
                    <p className="text-sm text-text-muted leading-snug">
                      An Explorer window should have opened with the ZIP selected. Drag it into your
                      GitHub issue to attach it.
                    </p>
                  </div>
                </div>
                <div className="mb-3 p-2.5 rounded bg-surface-2 border border-border text-xs">
                  <div className="text-text-dim mb-0.5">Saved to</div>
                  <div className="text-text break-all font-mono">{diag.result.path}</div>
                  <div className="text-text-dim mt-1.5">
                    {diag.result.fileCount} file{diag.result.fileCount === 1 ? '' : 's'} ·{' '}
                    {Math.max(1, Math.round(diag.result.sizeBytes / 1024))} KB
                    {diag.result.sanitized ? ' · redacted' : ''}
                  </div>
                </div>
                {diag.result.warnings.length > 0 && (
                  <div className="mb-3 p-2.5 rounded bg-warning/10 border border-warning/30 text-xs text-warning space-y-1">
                    {diag.result.warnings.map((w, i) => (
                      <div key={i}>{w}</div>
                    ))}
                  </div>
                )}
              </>
            )}

            {diag.status === 'error' && (
              <>
                <div className="flex items-start gap-3 mb-3">
                  <Icon name="AlertTriangle" size={20} className="text-danger mt-0.5" />
                  <div className="flex-1">
                    <h2 className="text-base font-semibold text-text mb-1">Couldn’t build the diagnostics bundle</h2>
                    <p className="text-sm text-text-muted leading-snug">
                      You can still file the issue — attach your logs manually from
                      <span className="font-mono text-text"> %APPDATA%\DuneServer\.logs</span>.
                    </p>
                  </div>
                </div>
                <div className="mb-3 p-2 rounded bg-danger/10 border border-danger/30 text-sm text-danger break-words">
                  {diag.error}
                </div>
              </>
            )}

            {diag.status !== 'building' && (
              <div className="flex justify-end">
                <button
                  type="button"
                  onClick={() => setDiag(null)}
                  className="px-3 py-1.5 rounded text-sm bg-accent text-white hover:bg-accent-bright"
                >
                  Close
                </button>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
