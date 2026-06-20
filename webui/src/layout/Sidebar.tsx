import { NavLink } from 'react-router-dom'
import { useState, useRef } from 'react'
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
  const onTestChannel = upd?.channel === 'test'
  const [showPortalConfirm, setShowPortalConfirm] = useState(false)
  const [portalDetaching, setPortalDetaching] = useState(false)
  const [portalError, setPortalError] = useState<string | null>(null)
  // Issue #280 recovery flow: after handing the portal to the default browser
  // we keep the app window open until the browser checks in with the server.
  // 'confirm' = pre-flight dialog · 'waiting' = browser opened, polling for
  // check-in · 'failed' = browser never reached the server (offer Copy URL +
  // close anyway).
  const [portalPhase, setPortalPhase] = useState<'confirm' | 'waiting' | 'failed'>('confirm')
  const [portalUrl, setPortalUrl] = useState<string | null>(null)
  const [portalCopied, setPortalCopied] = useState(false)
  const portalCancelRef = useRef(false)

  // "Web Portal" is meaningful only inside the native shell. In a regular
  // browser tab the user is already in their browser, so we hide the button.
  const inShellWindow = getWebView2() !== null

  const onOpenWebPortal = async () => {
    if (portalDetaching) return
    setPortalDetaching(true)
    setPortalError(null)
    portalCancelRef.current = false
    try {
      // Tell the server to flag itself as "intentionally detached" — the
      // app-window watcher in ConsoleHost.ps1 reads this flag and skips the
      // usual "shell exited -> stop listener" teardown. Server keeps running.
      const r = await api<{ ok: boolean; url: string }>(
        '/api/portal/open-in-browser', { method: 'POST' },
      )
      if (!r?.url) throw new Error('Server did not return a portal URL.')
      setPortalUrl(r.url)
      const wv = getWebView2()
      if (wv) {
        // Open the browser but KEEP this window open. We wait for the freshly
        // opened browser tab to check in with the server (proving it could
        // actually reach 127.0.0.1) before closing ourselves. If it never
        // checks in, the user keeps a working app window + Copy URL fallback
        // instead of being stranded on a "page unavailable" error (issue #280).
        wv.postMessage({ action: 'open', url: r.url })
        setPortalPhase('waiting')
        void waitForBrowserCheckin()
      } else {
        // Browser fallback: just open the URL in a new tab. We can't close
        // our own window from a regular browser tab.
        window.open(r.url, '_blank', 'noopener')
        setShowPortalConfirm(false)
      }
    } catch (e) {
      setPortalError(e instanceof Error ? e.message : String(e))
    } finally {
      setPortalDetaching(false)
    }
  }

  // Poll the server until the browser we just opened checks in, then close the
  // app window. Times out into the 'failed' state so the user can copy the URL
  // or close anyway.
  const waitForBrowserCheckin = async () => {
    const deadline = Date.now() + 30000
    while (Date.now() < deadline) {
      await new Promise(res => setTimeout(res, 1200))
      if (portalCancelRef.current) return
      let checkedIn = false
      try {
        const s = await api<{ checkedIn: boolean }>('/api/portal/checkin-status')
        checkedIn = !!s?.checkedIn
      } catch { /* transient — keep polling */ }
      if (portalCancelRef.current) return
      if (checkedIn) {
        const wv = getWebView2()
        if (wv) wv.postMessage({ action: 'close' })
        return
      }
    }
    if (!portalCancelRef.current) setPortalPhase('failed')
  }

  // User gave up on the browser hand-off — re-attach so a normal window close
  // tears the server down again, and reset the dialog.
  const onCancelPortalHandoff = async () => {
    portalCancelRef.current = true
    try { await api('/api/portal/reattach', { method: 'POST' }) } catch { /* best effort */ }
    setShowPortalConfirm(false)
    setPortalPhase('confirm')
    setPortalUrl(null)
    setPortalError(null)
  }

  // Browser confirmed unreachable but the user wants to close anyway (server
  // stays running because it's already detached; they can paste the URL into a
  // working browser later).
  const onCloseAnyway = () => {
    const wv = getWebView2()
    if (wv) wv.postMessage({ action: 'close' })
  }

  const onCopyPortalUrl = async () => {
    if (!portalUrl) return
    try {
      await navigator.clipboard.writeText(portalUrl)
      setPortalCopied(true)
      setTimeout(() => setPortalCopied(false), 2000)
    } catch { /* clipboard blocked — the URL is shown in the box to copy manually */ }
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
            onClick={() => { setPortalError(null); setPortalPhase('confirm'); setShowPortalConfirm(true) }}
            title="Open the portal in your default web browser (the app window stays open until the browser connects)"
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
        {collapsed && onTestChannel && (
          <NavLink
            to="/settings"
            title="Test update channel — receiving pre-release builds. Click to open Settings."
            className="w-full flex items-center justify-center h-8 rounded-md border border-warning/50 text-warning hover:bg-warning/15 hover:border-warning/70 transition-colors"
          >
            <Icon name="FlaskConical" size={14} />
          </NavLink>
        )}
        {!collapsed && (
          <div className="flex items-center justify-between">
            <span className="flex items-center gap-1.5">
              {version ? fmtToolVersion(version) : '—'}
              {onTestChannel && (
                <NavLink
                  to="/settings"
                  title="Test update channel — receiving pre-release builds. Click to open Settings and switch back to Stable."
                  className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[9px] font-semibold uppercase tracking-wider border border-warning/40 bg-warning/10 text-warning hover:bg-warning/20 transition-colors"
                >
                  <Icon name="FlaskConical" size={9} /> Test
                </NavLink>
              )}
            </span>
            <span className="font-mono">coastal-ms</span>
          </div>
        )}
      </div>

      {showPortalConfirm && createPortal(
        <div
          className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4"
          onClick={() => { if (!portalDetaching && portalPhase === 'confirm') setShowPortalConfirm(false) }}
        >
          <div
            className="card p-5 max-w-md w-full text-text"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 mb-3">
              <Icon name="ExternalLink" size={16} className="text-accent" />
              <h3 className="text-sm font-semibold uppercase tracking-widest text-accent">Open in web browser</h3>
            </div>

            {portalPhase === 'confirm' && (
              <>
                <p className="text-sm text-text-muted mb-2">
                  The portal will open in your <strong>default web browser</strong>. The app window <strong>stays open</strong> until the browser connects, then closes automatically.
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
              </>
            )}

            {portalPhase === 'waiting' && (
              <>
                <p className="text-sm text-text-muted mb-3 flex items-center gap-2">
                  <Icon name="Loader2" size={14} className="animate-spin text-accent" />
                  Waiting for your browser to open the portal…
                </p>
                <p className="text-xs text-text-dim mb-3">
                  This window will close automatically once your browser connects. If your browser shows a “page unavailable” error, it may be blocked from reaching the server (antivirus, VPN or proxy) — use the URL below.
                </p>
                {portalUrl && <PortalUrlBox url={portalUrl} copied={portalCopied} onCopy={onCopyPortalUrl} />}
                <div className="mt-4 flex flex-col gap-2">
                  <button
                    className="btn-secondary w-full justify-center"
                    onClick={() => { void onCancelPortalHandoff() }}
                  >
                    <Icon name="X" size={12} /> Cancel — keep app window open
                  </button>
                </div>
              </>
            )}

            {portalPhase === 'failed' && (
              <>
                <p className="text-sm text-text-muted mb-2 flex items-center gap-2">
                  <Icon name="AlertTriangle" size={14} className="text-warning" />
                  Your browser didn’t reach the server.
                </p>
                <p className="text-xs text-text-dim mb-3">
                  The app window is still working, so nothing is lost. Your browser is likely blocked from <span className="font-mono">127.0.0.1</span> by antivirus, a VPN, or a proxy. Copy the URL below and open it in another browser, or add a loopback bypass and try again.
                </p>
                {portalUrl && <PortalUrlBox url={portalUrl} copied={portalCopied} onCopy={onCopyPortalUrl} />}
                <div className="mt-4 flex flex-col gap-2">
                  <button
                    className="btn-secondary w-full justify-center"
                    onClick={() => { void onCancelPortalHandoff() }}
                  >
                    <Icon name="ArrowLeft" size={12} /> Keep using the app window
                  </button>
                  <button
                    className="btn-ghost w-full justify-center text-text-dim"
                    onClick={onCloseAnyway}
                    title="Close the app window anyway — the server stays running so you can open the URL later"
                  >
                    <Icon name="X" size={12} /> Close app window anyway
                  </button>
                </div>
              </>
            )}
          </div>
        </div>,
        document.body,
      )}
    </aside>
  )
}

function PortalUrlBox({ url, copied, onCopy }: { url: string; copied: boolean; onCopy: () => void }) {
  return (
    <div className="flex items-center gap-2">
      <code className="flex-1 min-w-0 truncate text-xs bg-black/40 border border-border rounded px-2 py-1.5 font-mono" title={url}>
        {url}
      </code>
      <button
        type="button"
        onClick={onCopy}
        className="btn-secondary shrink-0"
        title="Copy portal URL"
      >
        <Icon name={copied ? 'Check' : 'Copy'} size={13} />
        {copied ? 'Copied' : 'Copy'}
      </button>
    </div>
  )
}
