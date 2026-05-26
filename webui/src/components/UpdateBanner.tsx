import { useState } from 'react'
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

export function UpdateBanner() {
  const { data, error } = useUpdateCheck()
  const [installing, setInstalling] = useState(false)
  const [installMsg, setInstallMsg] = useState<string | null>(null)
  const [installErr, setInstallErr] = useState<string | null>(null)
  const [dismissed, setDismissed] = useState(false)

  if (!data || !data.available || !data.latestVersion) return null
  if (dismissed || isDismissed(data.latestVersion)) return null

  const onInstall = async () => {
    setInstalling(true)
    setInstallErr(null)
    setInstallMsg(null)
    try {
      const res = await installUpdate()
      if (res.launched) {
        setInstallMsg(
          `Installer launched — upgrading to v${res.toVersion}. The portal will go offline briefly, then the new version will relaunch.`,
        )
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
        {installMsg ? (
          <span className="text-amber-100">{installMsg}</span>
        ) : (
          <>
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
          </>
        )}
        {installErr && (
          <div className="mt-1 text-red-300 text-xs">{installErr}</div>
        )}
      </div>
      {!installMsg && (
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
      )}
    </div>
  )
}
