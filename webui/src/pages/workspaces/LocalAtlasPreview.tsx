import { useCallback, useEffect, useRef, useState } from 'react'
import { TOKEN_KEYS } from '../../theme/tokens'

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
    <iframe
      ref={frame}
      onLoad={syncTheme}
      title="Own-server live atlas"
      src={url}
      allow="fullscreen"
      referrerPolicy="no-referrer"
      className="block w-full min-h-[420px] rounded-lg border border-border"
      style={{ height: height === null ? 'calc(100dvh - 280px)' : `${height}px` }}
    />
  )
}
