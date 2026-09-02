import { useEffect, useRef, useState } from 'react'

const CDN_ORIGIN = 'https://cdn-hosted.gaming.tools'
const METADATA_PREFIX = `${CDN_ORIGIN}/dune/data/en/items/`
const IMAGE_PREFIX = `${CDN_ORIGIN}/dune`
const MAX_RESPONSE_BYTES = 64 * 1024
const RANGE_HEADER = 'bytes=0-4095'

const iconCache = new Map<string, Promise<string | null>>()
const observedElements = new Map<Element, () => void>()
let sharedObserver: IntersectionObserver | null = null

export function itemSlug(templateId: string) {
  return encodeURIComponent(templateId.toLowerCase())
}

export function itemMetadataUrl(templateId: string) {
  return `${METADATA_PREFIX}${itemSlug(templateId)}.d.json`
}

export function itemDetailsUrl(templateId: string) {
  return `https://dune.gaming.tools/items/${itemSlug(templateId)}`
}

function validatedImageUrl(path: string) {
  if (!path.startsWith('/images/') || /[\u0000-\u001f\u007f\\?#]/.test(path)) return null
  try {
    const segments = path.split('/').map(segment => decodeURIComponent(segment))
    if (segments.some(segment => segment === '..' || segment === '.')) return null
    const url = new URL(path, IMAGE_PREFIX)
    if (url.origin !== CDN_ORIGIN || !url.pathname.startsWith('/images/')) return null
    return `${IMAGE_PREFIX}${url.pathname}`
  } catch {
    return null
  }
}

export function extractItemImageUrl(prefix: string) {
  const match = prefix.match(/"(\/images\/(?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\\u0000-\u001f])*)"/)
  if (!match) return null
  try {
    return validatedImageUrl(JSON.parse(`"${match[1]}"`) as string)
  } catch {
    return null
  }
}

async function readBoundedResponse(response: Response) {
  const declaredLength = Number(response.headers.get('content-length'))
  if (Number.isFinite(declaredLength) && declaredLength > MAX_RESPONSE_BYTES) return null
  if (!response.body) return null

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      total += value.byteLength
      if (total > MAX_RESPONSE_BYTES) {
        await reader.cancel()
        return null
      }
      chunks.push(value)
    }
  } catch {
    return null
  }

  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(bytes)
}

async function fetchItemIcon(templateId: string) {
  if (!templateId.trim()) return null
  try {
    const response = await fetch(itemMetadataUrl(templateId), {
      headers: { Range: RANGE_HEADER },
    })
    if (response.status !== 200 && response.status !== 206) return null
    const prefix = await readBoundedResponse(response)
    return prefix ? extractItemImageUrl(prefix) : null
  } catch {
    return null
  }
}

export function resolveItemIcon(templateId: string) {
  const cacheKey = templateId.toLowerCase()
  const cached = iconCache.get(cacheKey)
  if (cached) return cached
  const pending = fetchItemIcon(templateId)
  iconCache.set(cacheKey, pending)
  return pending
}

export function clearItemIconCacheForTests() {
  iconCache.clear()
}

function observeNearViewport(element: Element, onVisible: () => void) {
  if (typeof IntersectionObserver === 'undefined') return () => undefined
  if (!sharedObserver) {
    sharedObserver = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        const callback = observedElements.get(entry.target)
        if (!callback) continue
        observedElements.delete(entry.target)
        sharedObserver?.unobserve(entry.target)
        callback()
      }
    }, { rootMargin: '160px' })
  }
  observedElements.set(element, onVisible)
  sharedObserver.observe(element)
  return () => {
    observedElements.delete(element)
    sharedObserver?.unobserve(element)
  }
}

export function InventoryItemIcon({
  templateId,
  displayName,
}: {
  templateId: string
  displayName: string
}) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [iconUrl, setIconUrl] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    let active = true
    setIconUrl(null)
    setFailed(false)
    const stopObserving = observeNearViewport(host, () => {
      void resolveItemIcon(templateId).then(url => {
        if (active) setIconUrl(url)
      })
    })
    return () => {
      active = false
      stopObserving()
    }
  }, [templateId])

  return (
    <div ref={hostRef} className="flex min-h-0 flex-1 items-center justify-center overflow-hidden">
      {iconUrl && !failed ? (
        <img
          src={iconUrl}
          alt=""
          loading="lazy"
          decoding="async"
          className="h-full w-full object-contain p-1"
          onError={() => setFailed(true)}
        />
      ) : (
        <span
          aria-hidden="true"
          title={`${displayName || templateId} icon unavailable`}
          className="flex h-12 w-12 items-center justify-center rounded-lg border border-border/70 bg-base/40 text-lg font-semibold text-text-dim"
        >
          {(displayName || templateId).trim().charAt(0).toUpperCase() || '?'}
        </span>
      )}
    </div>
  )
}
