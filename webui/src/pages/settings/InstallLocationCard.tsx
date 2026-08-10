import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { getInstallLocation, openInstallLocation } from '../../api/system'

export function InstallLocationCard() {
  const [path, setPath] = useState('')
  const [installed, setInstalled] = useState(false)
  const [loading, setLoading] = useState(true)
  const [opening, setOpening] = useState(false)
  const [error, setError] = useState('')
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    getInstallLocation()
      .then(result => {
        setPath(result.path || '')
        setInstalled(!!result.installed)
      })
      .catch(err => setError(err instanceof Error ? err.message : String(err)))
      .finally(() => setLoading(false))
  }, [])

  async function copyPath() {
    if (!path) return
    setError('')
    try {
      await navigator.clipboard.writeText(path)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1500)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function openFolder() {
    setOpening(true)
    setError('')
    try {
      await openInstallLocation()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setOpening(false)
    }
  }

  return (
    <CollapsibleCard
      id="settings.installLocation"
      icon="FolderOpen"
      title="Dune Server Tool installation"
      titleClassName="text-lg font-semibold"
      headerClassName="px-4 md:px-6 pt-4 md:pt-6 pb-2"
      bodyClassName="px-4 md:px-6 pb-4 md:pb-6 space-y-3"
    >
      <p className="text-sm text-text-dim">
        Location of DST itself on this PC. Use this path for antivirus exclusions,
        manual file checks, or troubleshooting.
      </p>
      {loading ? (
        <div className="text-text-dim text-sm flex items-center gap-2">
          <Icon name="Loader2" size={13} className="animate-spin" /> Loading...
        </div>
      ) : error && !path ? (
        <div className="text-danger text-sm">{error}</div>
      ) : (
        <>
          <div className="text-[11px] uppercase tracking-wider text-text-dim">
            {installed ? 'Install folder' : 'Development folder'}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <code className="basis-full lg:basis-auto lg:flex-1 min-w-0 px-2 py-1.5 rounded bg-surface-2 border border-border/50 text-text text-xs break-all">
              {path}
            </code>
            <button
              type="button"
              className="btn-secondary shrink-0"
              onClick={() => void copyPath()}
              title="Copy install path"
            >
              <Icon name={copied ? 'Check' : 'Copy'} size={14} />
              {copied ? 'Copied' : 'Copy'}
            </button>
            <button
              type="button"
              className="btn-secondary shrink-0"
              onClick={() => void openFolder()}
              disabled={opening}
            >
              <Icon name={opening ? 'Loader2' : 'FolderOpen'} size={14} className={opening ? 'animate-spin' : ''} />
              {opening ? 'Opening...' : 'Open folder'}
            </button>
          </div>
          {error && <div className="text-danger text-xs">{error}</div>}
        </>
      )}
    </CollapsibleCard>
  )
}
