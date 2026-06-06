import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { Icon } from '../components/Icon'
import { api, ApiError } from '../api/client'
import { getDuneAdminWebUrl, type DuneAdminWebUrl } from '../api/duneAdmin'
import { isLocalViewer } from '../util/viewer'

// While we're waiting for dune-admin to come up after a "Start" click, poll
// fast so the iframe swaps in as soon as the port is listening.
const FAST_POLL_MS = 1500
// Once dune-admin is up and the iframe is rendered, slow the poll right down
// — we only need to know if it goes away (e.g. crashes / killed manually) so
// we can swap back to the start card.
const SLOW_POLL_MS = 15_000

export function DuneAdmin() {
  const [info, setInfo] = useState<DuneAdminWebUrl | null>(null)
  const [loading, setLoading] = useState(true)
  const [starting, setStarting] = useState(false)
  const [startErr, setStartErr] = useState<string | null>(null)
  const [iframeKey, setIframeKey] = useState(0)
  const inflight = useRef(false)

  const probe = useCallback(async () => {
    if (inflight.current) return
    inflight.current = true
    try {
      const res = await getDuneAdminWebUrl()
      setInfo(res)
    } catch {
      // Backend hiccup; keep last known state, poll loop will retry.
    } finally {
      inflight.current = false
      setLoading(false)
    }
  }, [])

  // Initial probe + adaptive poll: fast while waiting for the port, slow once up.
  useEffect(() => {
    void probe()
    const tick = () => { void probe() }
    const ms = info?.listening ? SLOW_POLL_MS : FAST_POLL_MS
    const id = window.setInterval(tick, ms)
    return () => window.clearInterval(id)
  }, [probe, info?.listening])

  const startDuneAdmin = useCallback(async () => {
    setStarting(true)
    setStartErr(null)
    try {
      await api('/api/commands/run/dune-admin', { method: 'POST' })
      // Give the process a beat to bind the port, then probe immediately so
      // the user sees the iframe appear without waiting for the next poll.
      window.setTimeout(() => { void probe() }, 500)
    } catch (e) {
      setStartErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setStarting(false)
    }
  }, [probe])

  // Header bar with title + actions, shown above both the iframe and any
  // status card so the page chrome doesn't jump around between states.
  const header = (
    <div className="h-9 shrink-0 border-b border-border bg-surface flex items-center gap-2 px-3 text-[12px]">
      <Icon name="LayoutGrid" size={14} className="text-text-muted" />
      <span className="text-text">Dune Admin</span>
      {info?.listening && info.url && (
        <span className="text-text-dim font-mono">{info.url}</span>
      )}
      <div className="flex-1" />
      {info?.listening && (
        <>
          <button
            type="button"
            onClick={() => setIframeKey(k => k + 1)}
            className="px-2 h-6 rounded text-text-muted hover:text-text hover:bg-surface-2 transition-colors flex items-center gap-1"
            title="Reload the embedded dune-admin view"
          >
            <Icon name="RotateCw" size={12} />
            <span>Reload</span>
          </button>
          {info.url && (
            <a
              href={info.url}
              target="_blank"
              rel="noopener noreferrer"
              className="px-2 h-6 rounded text-text-muted hover:text-text hover:bg-surface-2 transition-colors flex items-center gap-1"
              title="Open dune-admin in your default browser"
            >
              <Icon name="ExternalLink" size={12} />
              <span>Open in browser</span>
            </a>
          )}
        </>
      )}
    </div>
  )

  // 1) Listening: render the iframe full-bleed below the header.
  if (info?.configured && info.listening && info.url) {
    // Build the iframe URL based on where the DST portal is currently being
    // viewed FROM. On the host, window.location.hostname is 127.0.0.1 / localhost
    // and the backend's url (also 127.0.0.1:<port>) works. When the portal is
    // reached through the Tailscale friend bridge, window.location.hostname is
    // the host's tailnet name — so we swap the iframe's hostname to match,
    // pointing the friend's WebView2 at the host's dune-admin instead of the
    // friend's own 127.0.0.1. Requires host-side firewall to allow inbound on
    // dune-admin's port over the Tailscale interface (see helper/bridge).
    const viewerHost = typeof window !== 'undefined' ? window.location.hostname : ''
    const iframeUrl = isLocalViewer()
      ? info.url
      : `http://${viewerHost}:${info.port}`
    return (
      <div className="h-full flex flex-col">
        {header}
        <iframe
          key={iframeKey}
          src={iframeUrl}
          title="dune-admin"
          className="flex-1 w-full border-0 bg-white"
        />
      </div>
    )
  }

  // 2) Not yet listening — render one of three status cards in the middle.
  let body: ReactNode
  if (loading && !info) {
    body = (
      <div className="text-center text-text-muted">
        <Icon name="Loader2" size={20} className="animate-spin mx-auto mb-2" />
        Checking dune-admin status…
      </div>
    )
  } else if (!info?.configured) {
    body = (
      <div className="max-w-md text-center">
        <Icon name="PackageOpen" size={28} className="text-text-muted mx-auto mb-3" />
        <h2 className="text-base text-text mb-1">dune-admin isn't set up</h2>
        <p className="text-sm text-text-muted mb-4">
          DST didn't find a dune-admin install path in your config. Point Settings at a
          dune-admin.exe (or run the Setup Wizard) and this page will embed it here.
        </p>
        <div className="flex items-center justify-center gap-2">
          <Link
            to="/settings"
            className="px-3 h-8 rounded-md bg-accent text-accent-contrast hover:opacity-90 transition-opacity text-sm flex items-center gap-1.5"
          >
            <Icon name="Settings" size={13} />
            Open Settings
          </Link>
          <Link
            to="/setup"
            className="px-3 h-8 rounded-md border border-border text-text-muted hover:text-text hover:bg-surface-2 transition-colors text-sm flex items-center gap-1.5"
          >
            <Icon name="Wand2" size={13} />
            Setup Wizard
          </Link>
        </div>
      </div>
    )
  } else {
    body = (
      <div className="max-w-md text-center">
        <Icon name="Power" size={28} className="text-text-muted mx-auto mb-3" />
        <h2 className="text-base text-text mb-1">dune-admin isn't running</h2>
        <p className="text-sm text-text-muted mb-4">
          Found at <span className="font-mono text-text">{info.listenAddr || `:${info.port}`}</span>{' '}
          but nothing is listening yet. Start it and the web UI will load right here.
        </p>
        <button
          type="button"
          onClick={() => void startDuneAdmin()}
          disabled={starting}
          className="px-3 h-8 rounded-md bg-accent text-accent-contrast hover:opacity-90 transition-opacity text-sm flex items-center gap-1.5 mx-auto disabled:opacity-60"
        >
          <Icon name={starting ? 'Loader2' : 'Play'} size={13} className={starting ? 'animate-spin' : ''} />
          {starting ? 'Starting…' : 'Start dune-admin'}
        </button>
        {startErr && (
          <p className="mt-3 text-xs text-error">{startErr}</p>
        )}
      </div>
    )
  }

  return (
    <div className="h-full flex flex-col">
      {header}
      <div className="flex-1 flex items-center justify-center p-6">{body}</div>
    </div>
  )
}
