import { useEffect, useRef, useState } from 'react'

import bundledItemIcons from '../../data/item-icons.json'

const observedElements = new Map<Element, () => void>()
let sharedObserver: IntersectionObserver | null = null

export function itemSlug(templateId: string) {
  return encodeURIComponent(templateId.toLowerCase())
}

export function itemDetailsUrl(templateId: string) {
  return `https://dune.gaming.tools/items/${itemSlug(templateId)}`
}

export function resolveItemIcon(templateId: string): Promise<string | null> {
  const name = (bundledItemIcons as Record<string, string>)[templateId.trim().toLowerCase()]
  return Promise.resolve(name ? `/item-icons/${name}` : null)
}

export function clearItemIconCacheForTests() {
  // Packaged item art has no external metadata or request cache.
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
