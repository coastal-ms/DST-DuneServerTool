import { useEffect, useState } from 'react'
import { openAtlasSession } from '../../api/atlas'
import { getAtlasEmbedUrl, LocalAtlasPreview } from './LocalAtlasPreview'
import { DataState } from '../../components/platform/DataState'
import { VmMapHelperCard } from '../settings/VmMapHelperCard'
import { isLocalViewer } from '../../util/viewer'

/** The iframe shares selections with its map-only popup on the same local host. */
export function AtlasLiveState() {
  const [url, setUrl] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [needsSetup, setNeedsSetup] = useState(false)
  useEffect(() => {
    let active = true
    let retry: ReturnType<typeof setTimeout> | undefined
    const recover = () => { if (active) retry = setTimeout(() => setAttempt(value => value + 1), 5000) }
    setError(null)
    void openAtlasSession().then(session => {
      if (!active) return
      if (session.reasonCode === 'helper-not-enabled') { setNeedsSetup(true); return }
      const next = session.available ? getAtlasEmbedUrl(session.url) : null
      if (next) setUrl(next)
      else { setError(session.reasonCode === 'startup-pending'
        ? 'The map service is still starting. Please retry shortly.'
        : 'The map service is unavailable. Make sure the DST service is running.'); recover() }
    }).catch(() => { if (active) { setError('Could not reach the map service. Please retry.'); recover() } })
    return () => { active = false; clearTimeout(retry) }
  }, [attempt])
  if (needsSetup) return isLocalViewer() ? <VmMapHelperCard /> : <DataState state="unavailable" title="Live Maps is disabled" message="The server owner must enable Live Maps." />
  return url ? <LocalAtlasPreview url={url} /> : <DataState
    state={error ? 'unavailable' : 'loading'}
    title={error ? 'Live map unavailable' : 'Opening live map…'}
    message={error ?? undefined}
    action={error ? <button className="btn-secondary" onClick={() => setAttempt(value => value + 1)}>Retry</button> : undefined}
  />
}
