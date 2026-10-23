import { useCallback, useEffect, useRef, useState } from 'react'
import { TOKEN_KEYS } from '../../theme/tokens'
import { useScreenAwake } from '../../hooks/useScreenAwake'

/** Local development bridge while the verified collector is being packaged.
 * Release builds never connect to a research service or include its access key.
 */
export function getLocalAtlasPreviewUrl(development: boolean, value: unknown): string | null {
  return development ? getAtlasEmbedUrl(value) : null
}

export function getAtlasEmbedUrl(value: unknown): string | null {
  if (typeof value !== 'string' || !value) return null
  try {
    if (value.startsWith('/api/v1/maps/atlas/view')) {
      const url = new URL(value, window.location.origin)
      if (url.origin !== window.location.origin || url.pathname !== '/api/v1/maps/atlas/view' || url.hash) return null
      if ([...url.searchParams.keys()].some(key => !['t', 'embedded', 'view'].includes(key))) return null
      url.searchParams.delete('view')
      url.searchParams.set('embedded', '1')
      return url.pathname + url.search
    }
    const url = new URL(value)
    if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(url.hostname)
      || url.username || url.password || url.pathname !== '/' || !url.searchParams.get('key')) return null
    url.searchParams.delete('view')
    url.searchParams.set('embedded', '1')
    url.hash = ''
    return url.href
  } catch { return null }
}

export const localAtlasPreviewUrl = import.meta.env.DEV && import.meta.env.MODE !== 'test'
  ? getLocalAtlasPreviewUrl(true, import.meta.env.VITE_LOCAL_ATLAS_URL)
  : null

export function LocalAtlasPreview({ url }: { url: string }) {
  const frame = useRef<HTMLIFrameElement>(null)
  const [height, setHeight] = useState<number | null>(null)
  const [expanded, setExpanded] = useState(false)
  const [viewerPaused, setViewerPaused] = useState(false)
  const awake = useScreenAwake(expanded && !viewerPaused)
  useEffect(() => {
    window.dispatchEvent(new CustomEvent('dst-map-viewer-paused', {detail:viewerPaused}))
    return () => { window.dispatchEvent(new CustomEvent('dst-map-viewer-paused', {detail:false})) }
  }, [viewerPaused])
  useEffect(() => {
    const origin = new URL(url, window.location.href).origin
    const receive = (event: MessageEvent) => {
      if (event.origin !== origin || event.source !== frame.current?.contentWindow) return
      if (event.data?.type === 'dst-atlas-toggle-expand') setExpanded(value => !value)
      if (event.data?.type === 'dst-atlas-collapse') setExpanded(false)
      if (event.data?.type === 'dst-atlas-viewer-paused' && typeof event.data.paused === 'boolean') setViewerPaused(event.data.paused)
    }
    window.addEventListener('message', receive)
    return () => window.removeEventListener('message', receive)
  }, [url])
  useEffect(() => {
    frame.current?.contentWindow?.postMessage({type:'dst-atlas-expanded', expanded}, new URL(url, window.location.href).origin)
    if (!expanded) return
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') setExpanded(false) }
    window.addEventListener('keydown', escape)
    return () => { document.body.style.overflow = previous; window.removeEventListener('keydown', escape) }
  }, [expanded, url])
  const syncTheme = useCallback(() => {
    const style = getComputedStyle(document.documentElement)
    const tokens = Object.fromEntries(TOKEN_KEYS.map(key => [key, style.getPropertyValue(key).trim()]))
    frame.current?.contentWindow?.postMessage({ type: 'dst-atlas-theme', tokens }, new URL(url, window.location.href).origin)
  }, [url])
  useEffect(() => {
    const observer = new MutationObserver(syncTheme)
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['style', 'class'] })
    syncTheme()
    return () => observer.disconnect()
  }, [syncTheme])
  useEffect(() => {
    let scheduled = 0
    const measure = () => {
      cancelAnimationFrame(scheduled)
      scheduled = requestAnimationFrame(() => {
        if (!frame.current) return
        const top = Math.max(0, frame.current.getBoundingClientRect().top)
        setHeight(Math.max(420, Math.floor(window.innerHeight - top - 16)))
      })
    }
    measure()
    window.addEventListener('resize', measure)
    window.addEventListener('focus', measure)
    window.addEventListener('pageshow', measure)
    window.addEventListener('scroll', measure, { passive: true, capture: true })
    return () => {
      cancelAnimationFrame(scheduled)
      window.removeEventListener('resize', measure)
      window.removeEventListener('focus', measure)
      window.removeEventListener('pageshow', measure)
      window.removeEventListener('scroll', measure, true)
    }
  }, [])
  return (
    <div data-map-expanded={expanded} className={expanded ? 'fixed inset-0 z-[65000] flex flex-col bg-base' : ''}>
      {expanded && <div className="absolute right-2 top-2 z-10 flex flex-col items-end gap-1">
        <span role="status" className="text-xs text-text-muted">{viewerPaused ? 'Live map paused' : awake === 'active' ? 'Screen stays awake' : awake === 'unavailable' ? 'Screen keep-awake unavailable' : 'Keeping screen awake…'}</span>
        <button type="button" className="btn-secondary text-sm" onClick={() => setExpanded(false)}>Restore map</button>
      </div>}
      <iframe
      ref={frame}
      onLoad={syncTheme}
      title="Own-server live atlas"
      src={url}
      allow="fullscreen"
      referrerPolicy="no-referrer"
      className={expanded ? 'block min-h-0 w-full flex-1 border-0' : 'block w-full min-h-[420px] rounded-lg border border-border'}
      style={expanded ? {height:'100dvh', minHeight:0} : { height: height === null ? 'calc(100dvh - 280px)' : `${height}px` }}
    />
    </div>
  )
}
