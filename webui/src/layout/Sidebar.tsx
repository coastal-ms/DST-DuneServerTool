import { NavLink } from 'react-router-dom'
import { useState } from 'react'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS } from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { api } from '../api/client'
import { getDuneAdminWebUrl } from '../api/duneAdmin'
import { fmtToolVersion } from '../format'

// WebView2 host bridge — present only when the portal is rendered inside the
// native DuneShell.exe app window (not in a regular browser tab). We use it to
// hand the shell an "open URL in default browser then close yourself" message
// when the user clicks "Web Portal" below.
type WebView2Host = { postMessage: (data: unknown) => void }
function getWebView2(): WebView2Host | null {
  const w = window as unknown as { chrome?: { webview?: WebView2Host } }
  return w.chrome?.webview ?? null
}

export function Sidebar() {
  const { data: upd } = useUpdateCheck()
  const version = upd?.currentVersion ?? ''
  const [showPortalConfirm, setShowPortalConfirm] = useState(false)
  const [portalDetaching, setPortalDetaching] = useState(false)
  const [portalError, setPortalError] = useState<string | null>(null)
  const [daLaunching, setDaLaunching] = useState(false)

  // "Web Portal" is meaningful only inside the native shell. In a regular
  // browser tab the user is already in their browser, so we hide the button.
  const inShellWindow = getWebView2() !== null

  // Characters live in dune-admin (Icehunter's tool), not in this portal.
  // Launch dune-admin (skipped server-side if already running) then open its
  // players web UI. The launch command opens the page itself, so we don't
  // window.open here — that would double-open the tab.
  const launchDuneAdmin = async () => {
    if (daLaunching) return
    setDaLaunching(true)
    try {
      await api('/api/commands/run/dune-admin', { method: 'POST' })
    } catch {
      // Best-effort fallback: if the launch endpoint fails, open the page so the
      // user can connect to an already-running instance. Resolve the REAL port
      // from the backend (per-user listen_addr — never assume 8080, which may be
      // AMP's panel). Only open if dune-admin is actually listening.
      try {
        const web = await getDuneAdminWebUrl()
        if (web.listening) window.open(web.url, '_blank', 'noopener')
      } catch {
        // give up silently — better than opening the wrong port
      }
    } finally {
      setDaLaunching(false)
    }
  }

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

  const groups = (['overview', 'terminal', 'data', 'system'] as const).map(g => ({
    key: g,
    label: GROUP_LABELS[g],
    items: NAV_ITEMS.filter(i => i.group === g),
  }))

  return (
    <aside className="w-60 shrink-0 border-r border-border bg-surface/60 backdrop-blur-md flex flex-col">
      <div className="px-5 py-4 border-b border-border flex items-center gap-2.5">
        <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-accent-bright to-accent flex items-center justify-center shadow-lg shadow-accent/20">
          <Icon name="Hexagon" size={18} className="text-base" strokeWidth={2.5} />
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-sm font-semibold tracking-wide">Dune Server Tool</div>
          <div className="text-[10px] text-text-dim uppercase tracking-widest">Management Portal</div>
        </div>
        <a
          href={`https://github.com/coastal-ms/DST-DuneServerTool/issues/new?template=bug_report.yml${version ? `&tool_version=v${encodeURIComponent(version)}` : ''}`}
          target="_blank"
          rel="noopener noreferrer"
          title="Report a bug / open a GitHub issue (prefilled template)"
          className="w-8 h-8 rounded-full border border-accent/40 bg-accent/10 text-accent-bright hover:text-accent hover:bg-accent/20 hover:border-accent/60 flex items-center justify-center transition-colors shrink-0"
        >
          <Icon name="HelpCircle" size={16} strokeWidth={2.25} />
        </a>
      </div>

      <nav className="flex-1 overflow-y-auto px-2 py-3 space-y-5">
        {groups.map(g => (
          <div key={g.key}>
            <div className="px-3 mb-1 text-[10px] font-semibold uppercase tracking-widest text-text-dim">
              {g.label}
            </div>
            <ul className="space-y-0.5">
              {g.items.map(item => (
                <li key={item.to}>
                  {item.action === 'launch-dune-admin' ? (
                    <button
                      type="button"
                      onClick={() => { void launchDuneAdmin() }}
                      title="Opens player/character editing in dune-admin (launches it if not already running)"
                      className="w-full flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-all
                                 text-text-muted hover:text-text hover:bg-surface-2/60 border border-transparent"
                    >
                      <Icon name={daLaunching ? 'Loader2' : item.icon} size={16} className={daLaunching ? 'animate-spin' : ''} />
                      <span>{item.label}</span>
                      <Icon name="ExternalLink" size={12} className="ml-auto text-text-dim" />
                    </button>
                  ) : (
                    <NavLink
                      to={item.to}
                      end={item.to === '/'}
                      className={({ isActive }) =>
                        `flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-all
                         ${isActive
                           ? 'bg-accent/15 text-accent-bright border border-accent/30 shadow-inner'
                           : 'text-text-muted hover:text-text hover:bg-surface-2/60 border border-transparent'}`
                      }
                    >
                      <Icon name={item.icon} size={16} />
                      <span>{item.label}</span>
                    </NavLink>
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </nav>

      <div className="px-4 py-3 border-t border-border text-[10px] text-text-dim space-y-2">
        {inShellWindow && (
          <button
            type="button"
            onClick={() => { setPortalError(null); setShowPortalConfirm(true) }}
            title="Open the portal in your default web browser and close this app window"
            className="w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-md border border-accent/30 text-accent-bright/90 hover:text-accent-bright hover:bg-accent/10 hover:border-accent/50 transition-colors uppercase tracking-widest"
          >
            <Icon name="ExternalLink" size={11} />
            <span>Web Portal</span>
          </button>
        )}
        <div className="flex items-center justify-between">
          <span>{version ? fmtToolVersion(version) : '—'}</span>
          <span className="font-mono">coastal-ms</span>
        </div>
      </div>

      {showPortalConfirm && (
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
            <div className="mt-4 flex justify-end gap-2">
              <button
                className="btn-secondary"
                onClick={() => setShowPortalConfirm(false)}
                disabled={portalDetaching}
              >
                <Icon name="X" size={12} /> Cancel
              </button>
              <button
                className="btn-primary"
                onClick={() => { void onOpenWebPortal() }}
                disabled={portalDetaching}
              >
                <Icon name={portalDetaching ? 'Loader2' : 'ExternalLink'} size={12} className={portalDetaching ? 'animate-spin' : ''} />
                {portalDetaching ? 'Opening…' : 'Open in browser'}
              </button>
            </div>
          </div>
        </div>
      )}
    </aside>
  )
}
