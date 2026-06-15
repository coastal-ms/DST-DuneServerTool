import { NavLink } from 'react-router-dom'
import { useState } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS, GROUP_ORDER } from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { api } from '../api/client'
import { fmtToolVersion } from '../format'
import { isLocalViewer } from '../util/viewer'

// WebView2 host bridge — present only when the portal is rendered inside the
// native DuneShell.exe app window (not in a regular browser tab). We use it to
// hand the shell an "open URL in default browser then close yourself" message
// when the user clicks "Web Portal" below.
type WebView2Host = { postMessage: (data: unknown) => void }
function getWebView2(): WebView2Host | null {
  const w = window as unknown as { chrome?: { webview?: WebView2Host } }
  return w.chrome?.webview ?? null
}

type Props = {
  collapsed: boolean
}

export function Sidebar({ collapsed }: Props) {
  const { data: upd } = useUpdateCheck()
  const version = upd?.currentVersion ?? ''
  const [showPortalConfirm, setShowPortalConfirm] = useState(false)
  const [portalDetaching, setPortalDetaching] = useState(false)
  const [portalError, setPortalError] = useState<string | null>(null)

  // "Web Portal" is meaningful only inside the native shell. In a regular
  // browser tab the user is already in their browser, so we hide the button.
  const inShellWindow = getWebView2() !== null

  const onOpenWebPortal = async () => {
    if (portalDetaching) return
    setPortalDetaching(true)
    setPortalError(null)
    try {
      // Tell the server to flag itself as "intentionally detached" — the
      // app-window watcher in ConsoleHost.ps1 reads this flag and skips the
      // usual "shell exited -> stop listener" teardown. Server keeps running.
      const r = await api<{ ok: boolean; url: string }>(
        '/api/portal/open-in-browser', { method: 'POST' },
      )
      if (!r?.url) throw new Error('Server did not return a portal URL.')
      const wv = getWebView2()
      if (wv) {
        wv.postMessage({ action: 'open-and-close', url: r.url })
      } else {
        // Browser fallback: just open the URL in a new tab. We can't close
        // our own window from a regular browser tab.
        window.open(r.url, '_blank', 'noopener')
      }
      setShowPortalConfirm(false)
    } catch (e) {
      setPortalError(e instanceof Error ? e.message : String(e))
    } finally {
      setPortalDetaching(false)
    }
  }

  const groups = GROUP_ORDER.map(g => ({
    key: g,
    label: GROUP_LABELS[g],
    items: NAV_ITEMS
      .filter(i => i.group === g)
      .filter(i => !i.localOnly || isLocalViewer()),
  })).filter(g => g.items.length > 0)

  // Shared row renderer for a single nav item, in either layout mode.
  const renderItem = (item: typeof NAV_ITEMS[number]) => {
    return (
      <NavLink
        to={item.to}
        end={item.to === '/'}
        title={collapsed ? item.label : undefined}
        className={({ isActive }) =>
          collapsed
            ? `w-full flex items-center justify-center h-9 rounded-lg transition-all border ${
                isActive
                  ? 'bg-accent/15 text-accent-bright border-accent/30 shadow-inner'
                  : 'text-text-muted hover:text-text hover:bg-surface-2/60 border-transparent'
              }`
            : `flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-all border ${
                isActive
                  ? 'bg-accent/15 text-accent-bright border-accent/30 shadow-inner'
                  : 'text-text-muted hover:text-text hover:bg-surface-2/60 border-transparent'
              }`
        }
      >
        <Icon name={item.icon} size={collapsed ? 18 : 16} />
        {!collapsed && <span>{item.label}</span>}
        {!collapsed && item.badge && (
          <span className="ml-auto text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-ibad/15 text-ibad">
            {item.badge}
          </span>
        )}
      </NavLink>
    )
  }

  return (
    <aside
      className={`${collapsed ? 'w-14' : 'w-60'} shrink-0 border-r border-border bg-surface/60 backdrop-blur-md flex flex-col transition-[width] duration-150`}
    >
      <div
        className={`${
          collapsed ? 'px-2 justify-center' : 'px-5'
        } py-4 border-b border-border flex items-center gap-2.5`}
      >
        <img
          src="/logo.png"
          alt="Dune Server Tool logo"
          className="w-9 h-9 rounded-full shrink-0 object-contain"
        />
        {!collapsed && (
          <div className="flex-1 min-w-0">
            <div className="inline-block text-center leading-tight">
              <div className="text-2xl font-bold tracking-wide">DST</div>
              <div className="text-sm font-semibold tracking-wide">Dune Server Tool</div>
            </div>
            <div className="text-[10px] text-text-dim uppercase tracking-widest">Management Portal</div>
            <div className="text-[11px] font-bold tracking-wide mt-1 flex items-center gap-1">
              <Icon name="ThumbsUp" size={11} className="text-emerald-400" />
              <span className="bg-gradient-to-r from-emerald-400 via-sky-400 to-yellow-300 bg-clip-text text-transparent">Thank you Hawk_I5</span>
            </div>
          </div>
        )}
      </div>

      <nav
        className={`flex-1 overflow-y-auto ${
          collapsed ? 'px-1.5 py-2' : 'px-2 py-2'
        } ${collapsed ? '' : 'space-y-3'}`}
      >
        {groups.map((g, idx) => (
          <div key={g.key}>
            {/* In collapsed mode we draw a thin divider between groups instead
                of repeating the textual label, to keep the rail compact. */}
            {collapsed
              ? idx > 0 && <div className="my-2 border-t border-border/70" />
              : (
                <div className="px-3 mb-1 text-[10px] font-semibold uppercase tracking-widest text-text-dim">
                  {g.label}
                </div>
              )}
            <ul className={collapsed ? 'space-y-1' : 'space-y-0.5'}>
              {g.items.map(item => (
                <li key={item.to}>{renderItem(item)}</li>
              ))}
            </ul>
          </div>
        ))}
      </nav>

      <div
        className={`${
          collapsed ? 'px-1.5 py-2' : 'px-4 py-3'
        } border-t border-border text-[10px] text-text-dim space-y-2`}
      >
        {inShellWindow && (
          <button
            type="button"
            onClick={() => { setPortalError(null); setShowPortalConfirm(true) }}
            title="Open the portal in your default web browser and close this app window"
            className={
              collapsed
                ? 'w-full flex items-center justify-center h-8 rounded-md border border-accent/30 text-accent-bright/90 hover:text-accent-bright hover:bg-accent/10 hover:border-accent/50 transition-colors'
                : 'w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-md border border-accent/30 text-accent-bright/90 hover:text-accent-bright hover:bg-accent/10 hover:border-accent/50 transition-colors uppercase tracking-widest'
            }
          >
            <Icon name="ExternalLink" size={collapsed ? 14 : 11} />
            {!collapsed && <span>Web Portal</span>}
          </button>
        )}
        <a
          href="https://buymeacoffee.com/coastal_dst"
          target="_blank"
          rel="noopener noreferrer"
          title="Support development — Buy Me a Coffee"
          className={
            collapsed
              ? 'w-full flex items-center justify-center h-8 rounded-md border border-warning/50 text-warning hover:bg-warning/15 hover:border-warning/70 transition-colors'
              : 'w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-md border border-warning/50 text-warning hover:bg-warning/15 hover:border-warning/70 transition-colors uppercase tracking-widest font-semibold'
          }
        >
          <Icon name="Coffee" size={collapsed ? 14 : 11} />
          {!collapsed && <span>Buy Me a Coffee</span>}
        </a>
        {!collapsed && (
          <div className="flex items-center justify-between">
            <span>{version ? fmtToolVersion(version) : '—'}</span>
            <span className="font-mono">coastal-ms</span>
          </div>
        )}
      </div>

      {showPortalConfirm && createPortal(
        <div
          className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4"
          onClick={() => { if (!portalDetaching) setShowPortalConfirm(false) }}
        >
          <div
            className="card p-5 max-w-md w-full text-text"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 mb-3">
              <Icon name="ExternalLink" size={16} className="text-accent" />
              <h3 className="text-sm font-semibold uppercase tracking-widest text-accent">Open in web browser</h3>
            </div>
            <p className="text-sm text-text-muted mb-2">
              The Dune Server Tool <strong>app window will close</strong> and the portal will open in your <strong>default web browser</strong>.
            </p>
            <p className="text-sm text-text-muted mb-2">
              Your server keeps running in the background — the browser tab will work normally.
            </p>
            <p className="text-sm text-text-muted">
              Reopen Dune Server Tool any time to bring the app window back (the running server will be restarted).
            </p>
            {portalError && (
              <div className="mt-3 text-xs text-red-400 bg-red-950/40 border border-red-900/60 rounded px-3 py-2">
                {portalError}
              </div>
            )}
            <div className="mt-4 flex flex-col gap-2">
              <button
                className="btn-primary w-full justify-center"
                onClick={() => { void onOpenWebPortal() }}
                disabled={portalDetaching}
              >
                <Icon name={portalDetaching ? 'Loader2' : 'ExternalLink'} size={12} className={portalDetaching ? 'animate-spin' : ''} />
                {portalDetaching ? 'Opening…' : 'Open in browser'}
              </button>
              <button
                className="btn-secondary w-full justify-center"
                onClick={() => setShowPortalConfirm(false)}
                disabled={portalDetaching}
              >
                <Icon name="X" size={12} /> Cancel
              </button>
            </div>
          </div>
        </div>,
        document.body,
      )}
    </aside>
  )
}
