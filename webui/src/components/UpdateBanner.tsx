import { useEffect, useRef, useState } from 'react'
import { Icon } from './Icon'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { installUpdate } from '../api/update'

const DISMISS_KEY = 'dune.update.dismissed'

function isDismissed(version: string): boolean {
  return sessionStorage.getItem(DISMISS_KEY) === version
}

function markDismissed(version: string) {
  sessionStorage.setItem(DISMISS_KEY, version)
}

// Best-effort close of THIS browser window. Works for windows the script can
// close (PWA / app-mode / script-opened). For a normal tab the browser blocks
// it — that's why the overlay below also tells the user to close it manually.
function tryCloseWindow() {
  try { window.close() } catch { /* ignore */ }
}

/**
 * Full-screen takeover shown once the updater has launched. The running server
 * (DuneServer.exe) is about to be killed and a brand-new portal window opens
 * automatically when the installer finishes. This screen makes it unmistakable
 * that the CURRENT window is now stale, so nobody sits on a dead window
 * thinking the tool is broken. We poll the server and, the moment it stops
 * responding, flip to a definitive "disconnected — safe to close" state and
 * attempt to auto-close the window.
 */
function UpdatingOverlay({ toVersion }: { toVersion?: string }) {
  const [offline, setOffline] = useState(false)
  const triedClose = useRef(false)

  useEffect(() => {
    let cancelled = false
    const ping = async () => {
      try {
        // Any response (even an error status) means the server is still up.
        await fetch(`${window.location.origin}/api/update/check`, {
          method: 'GET',
          cache: 'no-store',
        })
        return true
      } catch {
        return false
      }
    }
    const tick = async () => {
      const up = await ping()
      if (cancelled) return
      if (!up) {
        setOffline(true)
        if (!triedClose.current) {
          triedClose.current = true
          // Give the browser a beat, then attempt to close (PWA/app windows).
          setTimeout(tryCloseWindow, 400)
        }
      }
    }
    const id = setInterval(() => { void tick() }, 1000)
    return () => { cancelled = true; clearInterval(id) }
  }, [])

  return (
    <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-slate-950/95 backdrop-blur-sm p-6">
      <div className="max-w-md w-full rounded-xl border border-amber-400/30 bg-slate-900 p-7 text-center shadow-2xl">
        <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-amber-400/15">
          <Icon name="Download" size={24} className="text-amber-300" />
        </div>
        <h2 className="text-lg font-semibold text-amber-100">
          {offline ? 'This window is now offline' : 'Updating Dune Server Tool…'}
        </h2>
        {toVersion && (
          <p className="mt-1 text-sm text-amber-200/70">Upgrading to v{toVersion}</p>
        )}

        {offline ? (
          <>
            <p className="mt-4 text-sm text-slate-300">
              The update is being installed. A <strong className="text-white">new Dune Server
              window will open automatically</strong> when the installer finishes.
            </p>
            <p className="mt-3 text-sm text-amber-100">
              You can safely <strong>close this window</strong> — it&apos;s no longer connected.
            </p>
            <button
              type="button"
              onClick={tryCloseWindow}
              className="mt-5 w-full rounded-md bg-amber-400 px-4 py-2 text-sm font-semibold text-amber-950 hover:bg-amber-300"
            >
              Close this window
            </button>
            <p className="mt-2 text-xs text-slate-500">
              If it doesn&apos;t close, your browser is blocking it — just close this tab manually.
            </p>
          </>
        ) : (
          <>
            <p className="mt-4 text-sm text-slate-300">
              The installer wizard is opening. This portal is going offline — wait for it to
              finish, then the updated tool relaunches in a new window.
            </p>
            <div className="mt-5 flex items-center justify-center gap-2 text-amber-300/80">
              <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400" />
              <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400 [animation-delay:150ms]" />
              <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400 [animation-delay:300ms]" />
            </div>
            <p className="mt-4 text-xs text-slate-500">
              Don&apos;t use this window after the wizard appears — it will stop working once the
              update applies.
            </p>
          </>
        )}
      </div>
    </div>
  )
}

export function UpdateBanner() {
  const { data, error } = useUpdateCheck()
  const [installing, setInstalling] = useState(false)
  const [launched, setLaunched] = useState(false)
  const [launchedVersion, setLaunchedVersion] = useState<string | undefined>(undefined)
  const [installErr, setInstallErr] = useState<string | null>(null)
  const [dismissed, setDismissed] = useState(false)

  // Once the updater is launched, take over the whole screen so the now-stale
  // window can't be mistaken for a working one.
  if (launched) return <UpdatingOverlay toVersion={launchedVersion} />

  if (!data || !data.available || !data.latestVersion) return null
  if (dismissed || isDismissed(data.latestVersion)) return null

  const onInstall = async () => {
    setInstalling(true)
    setInstallErr(null)
    try {
      const res = await installUpdate()
      if (res.launched) {
        setLaunchedVersion(res.toVersion)
        setLaunched(true)
      } else {
        setInstallErr(res.reason ?? 'Installer did not launch.')
      }
    } catch (e) {
      setInstallErr(e instanceof Error ? e.message : String(e))
    } finally {
      setInstalling(false)
    }
  }

  const onDismiss = () => {
    if (data.latestVersion) markDismissed(data.latestVersion)
    setDismissed(true)
  }

  if (error) {
    // Quiet failure — we don't pester the user when GitHub is unreachable.
    return null
  }

  return (
    <div className="shrink-0 border-b border-amber-400/30 bg-amber-400/10 px-5 py-2 text-sm text-amber-100 flex items-center gap-3">
      <Icon name="Download" size={16} className="text-amber-300 shrink-0" />
      <div className="flex-1 min-w-0">
        <strong className="font-semibold">Update available:</strong>{' '}
        <span className="text-amber-50">v{data.latestVersion}</span>
        <span className="text-amber-200/70"> (you're on v{data.currentVersion})</span>
        {data.releaseUrl && (
          <>
            {' · '}
            <a
              href={data.releaseUrl}
              target="_blank"
              rel="noreferrer"
              className="underline hover:text-white"
            >
              release notes
            </a>
          </>
        )}
        {installErr && (
          <div className="mt-1 text-red-300 text-xs">{installErr}</div>
        )}
      </div>
      <div className="flex items-center gap-2 shrink-0">
        <button
          type="button"
          className="px-3 py-1 rounded-md bg-amber-400 text-amber-950 font-semibold text-xs hover:bg-amber-300 disabled:opacity-60 disabled:cursor-wait"
          onClick={() => { void onInstall() }}
          disabled={installing}
        >
          {installing ? 'Installing…' : 'Update now'}
        </button>
        <button
          type="button"
          className="px-2 py-1 rounded-md text-amber-200 hover:text-white hover:bg-amber-400/10 text-xs"
          onClick={onDismiss}
          title="Dismiss for this session"
        >
          Later
        </button>
      </div>
    </div>
  )
}
