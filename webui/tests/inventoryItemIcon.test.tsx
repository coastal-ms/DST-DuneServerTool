import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  clearItemIconCacheForTests,
  extractItemImageUrl,
  InventoryItemIcon,
  itemDetailsUrl,
  itemMetadataUrl,
  resolveItemIcon,
} from '../src/components/inventory/InventoryItemIcon'

let intersectionCallback: IntersectionObserverCallback | null = null

class IntersectionObserverMock implements IntersectionObserver {
  readonly root = null
  readonly rootMargin = ''
  readonly thresholds = []

  constructor(callback: IntersectionObserverCallback) {
    intersectionCallback = callback
  }

  disconnect() {}
  observe() {}
  takeRecords() { return [] }
  unobserve() {}
}

beforeEach(() => {
  clearItemIconCacheForTests()
  vi.stubGlobal('IntersectionObserver', IntersectionObserverMock)
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('inventory item icon resolution', () => {
  it('builds fixed-origin encoded metadata and detail URLs', () => {
    expect(itemMetadataUrl('HealthPack /../?')).toBe(
      'https://cdn-hosted.gaming.tools/dune/data/en/items/healthpack%20%2F..%2F%3F.d.json',
    )
    expect(itemDetailsUrl('MelangeSpice')).toBe('https://dune.gaming.tools/items/melangespice')
  })

  it('extracts only safe root-relative image paths', () => {
    expect(extractItemImageUrl('{"icon":"/images/dune/items/spice.webp"}')).toBe(
      'https://cdn-hosted.gaming.tools/dune/images/dune/items/spice.webp',
    )
    expect(extractItemImageUrl('{"icon":"/images/../private.webp"}')).toBeNull()
    expect(extractItemImageUrl('{"icon":"/images/%2e%2e/private.webp"}')).toBeNull()
    expect(extractItemImageUrl('{"icon":"https://evil.example/images/item.webp"}')).toBeNull()
  })

  it('uses a bounded range request and caches success by lowercased template ID', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(
      '{"name":"Spice","icon":"/images/dune/items/spice.webp"}',
      { status: 206, headers: { 'content-length': '58' } },
    ))
    vi.stubGlobal('fetch', fetchMock)

    await expect(resolveItemIcon('MelangeSpice')).resolves.toContain('/images/dune/items/spice.webp')
    await expect(resolveItemIcon('melangespice')).resolves.toContain('/images/dune/items/spice.webp')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledWith(
      'https://cdn-hosted.gaming.tools/dune/data/en/items/melangespice.d.json',
      { headers: { Range: 'bytes=0-4095' } },
    )
  })

  it('caches null for failed and unexpectedly large responses', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response('ignored', {
      status: 200,
      headers: { 'content-length': String(65 * 1024) },
    }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(resolveItemIcon('OversizedItem')).resolves.toBeNull()
    await expect(resolveItemIcon('OversizedItem')).resolves.toBeNull()
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('waits for viewport proximity and falls back without broken image chrome', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 206 }))
    vi.stubGlobal('fetch', fetchMock)
    const { container } = render(<InventoryItemIcon templateId="UnknownItem" displayName="Unknown item" />)

    expect(fetchMock).not.toHaveBeenCalled()
    expect(container.querySelector('img')).not.toBeInTheDocument()
    expect(screen.getByTitle('Unknown item icon unavailable')).toBeInTheDocument()

    await act(async () => {
      intersectionCallback?.([{
        isIntersecting: true,
        target: container.firstElementChild as Element,
      } as IntersectionObserverEntry], {} as IntersectionObserver)
    })

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    expect(container.querySelector('img')).not.toBeInTheDocument()
  })
})
