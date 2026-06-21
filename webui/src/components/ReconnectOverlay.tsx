import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { subscribeConn, getConnState } from '../api/connection'
import { Icon } from './Icon'

// How long the backend must stay unreachable before we surface the overlay, so
// a single transient blip doesn't flash a full-screen takeover.
const SHOW_DELAY_MS = 1200
// How often to probe the static index while waiting for the server to return.
const POLL_MS = 1500
// Loop guard: if we auto-reload this many times inside the window, stop and
// offer a manual button instead of thrashing.
const RELOAD_WINDOW_MS = 30_000
const MAX_RELOADS = 3
const RELOAD_LOG_KEY = 'dune.reconnect.reloads'

function recentReloadCount(): number {
  try {
    const raw = sessionStorage.getItem(RELOAD_LOG_KEY)
    const arr = raw ? (JSON.parse(raw) as number[]) : []
    const cutoff = Date.now() - RELOAD_WINDOW_MS
    return arr.filter((t) => t > cutoff).length
  } catch {
    return 0
  }
}

function logReload(): void {
  try {
    const raw = sessionStorage.getItem(RELOAD_LOG_KEY)
    const arr = raw ? (JSON.parse(raw) as number[]) : []
    arr.push(Date.now())
    sessionStorage.setItem(RELOAD_LOG_KEY, JSON.stringify(arr.slice(-10)))
  } catch {
    /* ignore */
  }
}

// True while THIS tab is deliberately running the in-app updater. The
// UpdateBanner's full-screen <UpdatingPage> owns that flow, so we stand down and
// let it manage the reload/close messaging instead of reloading underneath it.
function isUpdatingHere(): boolean {
  return !!(window as unknown as { __duneUpdating?: boolean }).__duneUpdating
}

// Recovers a stranded browser tab after the backend restarts or self-updates.
// The per-launch token rotates on restart and the listener briefly drops, so a
// detached tab is left with dead "Failed to fetch" panels. We wait for the
// server to answer again, then reload — the fresh index.html re-injects the
// current token and the session heals.
export function ReconnectOverlay() {
  const state = useSyncExternalStore(subscribeConn, getConnState, getConnState)
  const recovering = state === 'recovering'
  const [visible, setVisible] = useState(false)
  const [giveUp, setGiveUp] = useState(false)
  const pollRef = useRef<number | null>(null)

  // Debounced show.
  useEffect(() => {
    if (!recovering) {
      setVisible(false)
      setGiveUp(false)
      return
    }
    const id = window.setTimeout(() => setVisible(true), SHOW_DELAY_MS)
    return () => window.clearTimeout(id)
  }, [recovering])

  // While shown, probe the static index until the server answers, then reload.
  useEffect(() => {
    if (!visible || giveUp) return
    let cancelled = false

    const probe = async () => {
      if (isUpdatingHere()) return
      try {
        await fetch(`${window.location.origin}/?_=${Date.now()}`, {
          method: 'HEAD',
          cache: 'no-store',
        })
      } catch {
        return // still down — keep waiting
      }
      if (cancelled) return
      if (recentReloadCount() >= MAX_RELOADS) {
        setGiveUp(true)
        return
      }
      logReload()
      window.location.reload()
    }

    pollRef.current = window.setInterval(() => { void probe() }, POLL_MS)
    void probe()
    return () => {
      cancelled = true
      if (pollRef.current) window.clearInterval(pollRef.current)
    }
  }, [visible, giveUp])

  if (!visible || isUpdatingHere()) return null

  return (
    <div className="fixed inset-0 z-[9998] flex items-center justify-center bg-slate-950/95 p-6">
      <div className="max-w-md w-full text-center">
        <div className="mx-auto mb-5 flex h-14 w-14 items-center justify-center rounded-full bg-amber-400/15">
          <Icon
            name="RefreshCw"
            size={28}
            className={`text-amber-300 ${giveUp ? '' : 'animate-spin'}`}
          />
        </div>
        <h1 className="text-xl font-semibold text-amber-100">
          {giveUp ? 'Still trying to reconnect…' : 'Reconnecting to Dune Server Tool…'}
        </h1>
        <p className="mt-3 text-sm leading-relaxed text-slate-300">
          {giveUp
            ? 'The tool is taking a while to come back. It may still be updating or restarting.'
            : 'The tool restarted or updated and is coming back. This page reconnects automatically.'}
        </p>
        {giveUp && (
          <button
            type="button"
            className="mt-5 px-4 py-1.5 rounded-md bg-amber-400 text-amber-950 font-semibold text-sm hover:bg-amber-300"
            onClick={() => window.location.reload()}
          >
            Reload now
          </button>
        )}
      </div>
    </div>
  )
}
