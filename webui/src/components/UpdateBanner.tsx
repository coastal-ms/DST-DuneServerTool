import { useEffect, useState } from 'react'
import { Icon } from './Icon'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { installUpdate } from '../api/update'
import { fmtToolVersion } from '../format'

const DISMISS_KEY = 'dune.update.dismissed'

function isDismissed(version: string): boolean {
  return sessionStorage.getItem(DISMISS_KEY) === version
}

function markDismissed(version: string) {
  sessionStorage.setItem(DISMISS_KEY, version)
}

// Full-screen takeover shown after the updater launches. We don't try to
// close or redirect anything by script (browser tabs can't be closed by JS,
// and there's nothing clever to do about the leftover console windows). We
// just tell the user plainly: the installer is running, a fresh window opens
// automatically when it finishes, and they can close all the old browser and
// console windows themselves. We poll the server and flip to a definitive
// "done — close everything" state the moment it stops responding.
function UpdatingPage({ toVersion }: { toVersion?: string }) {
  const [offline, setOffline] = useState(false)

  useEffect(() => {
    let cancelled = false
    const ping = async () => {
      try {
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
      if (!up) setOffline(true)
    }
    const id = setInterval(() => { void tick() }, 1000)
    return () => { cancelled = true; clearInterval(id) }
  }, [])

  return (
    <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-slate-950 p-6">
      <div className="max-w-md w-full text-center">
        <div className="mx-auto mb-5 flex h-14 w-14 items-center justify-center rounded-full bg-amber-400/15">
          <Icon name={offline ? 'CircleCheck' : 'Download'} size={28} className="text-amber-300" />
        </div>
        <h1 className="text-xl font-semibold text-amber-100">
          {offline ? 'Update installed' : 'Updating Dune Server Tool…'}
        </h1>
        {toVersion && (
          <p className="mt-1 text-sm text-amber-200/70">
            {offline ? `Now running ${fmtToolVersion(toVersion)}` : `Installing ${fmtToolVersion(toVersion)}`}
          </p>
        )}

        {offline ? (
          <>
            <p className="mt-5 text-sm leading-relaxed text-slate-300">
              A <strong className="text-white">new Dune Server Tool window has opened</strong> with the
              updated tool. The old version is shut down.
            </p>
            <div className="mt-4 rounded-lg border border-amber-400/30 bg-amber-400/10 px-4 py-3 text-left">
              <p className="text-sm font-semibold text-amber-100">You can now close:</p>
              <ul className="mt-1 list-disc pl-5 text-sm text-slate-300 space-y-0.5">
                <li><strong className="text-white">every Dune Server Tool browser tab/window</strong> (including this one)</li>
                <li>any leftover <strong className="text-white">Dune Server Tool console (black) windows</strong></li>
              </ul>
              <p className="mt-2 text-xs text-amber-200/70">
                They're all from the old version — closing them won't affect the new window.
              </p>
            </div>
          </>
        ) : (
          <>
            <p className="mt-5 text-sm leading-relaxed text-slate-300">
              The installer wizard is opening — <strong className="text-white">click through
              it</strong> (approve the Windows prompt if asked). When it finishes, the updated tool
              opens automatically in a new window.
            </p>
            <div className="mt-4 rounded-lg border border-amber-400/30 bg-amber-400/10 px-4 py-3 text-left">
              <p className="text-sm font-semibold text-amber-100">Once the new window opens:</p>
              <p className="mt-1 text-sm text-slate-300">
                Close <strong className="text-white">all other Dune Server Tool browser tabs/windows</strong>{' '}
                and any <strong className="text-white">console (black) windows</strong> — they're from the
                old version.
              </p>
            </div>
            <div className="mt-6 flex items-center justify-center gap-2 text-amber-300/80">
              <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400" />
              <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400 [animation-delay:150ms]" />
              <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400 [animation-delay:300ms]" />
            </div>
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
  if (launched) return <UpdatingPage toVersion={launchedVersion} />

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
        <span className="text-amber-50">{fmtToolVersion(data.latestVersion)}</span>
        <span className="text-amber-200/70"> (you're on {fmtToolVersion(data.currentVersion)})</span>
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
