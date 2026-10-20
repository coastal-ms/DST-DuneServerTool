import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { InventoryItemIcon, itemDetailsUrl, resolveItemIcon } from '../src/components/inventory/InventoryItemIcon'
let intersectionCallback: IntersectionObserverCallback | null = null
class IntersectionObserverMock {
  constructor(callback: IntersectionObserverCallback) { intersectionCallback = callback }
  observe() {}
  unobserve() {}
  disconnect() {}
}
beforeEach(() => { vi.stubGlobal('IntersectionObserver', IntersectionObserverMock) })
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks() })
describe('packaged inventory art', () => {
  it('resolves game art with all metadata network access disabled', async () => {
    const fetchMock = vi.fn(() => { throw new Error('Network disabled') })
    vi.stubGlobal('fetch', fetchMock)
    const first = await resolveItemIcon('FullStabilizationBelt')
    expect(first).toMatch(/^\/item-icons\/[a-f0-9]{20}\.webp$/)
    expect(await resolveItemIcon('fullstabilizationbelt')).toBe(first)
    expect(await resolveItemIcon('MelangeSpice')).toMatch(/^\/item-icons\//)
    expect(fetchMock).not.toHaveBeenCalled()
  })
  it('does not invent or remotely fetch unknown images', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    for (const name of ['', '../secret', 'NoSuchGameItem']) expect(await resolveItemIcon(name)).toBeNull()
    expect(fetchMock).not.toHaveBeenCalled()
  })
  it('loads a packaged image when its item comes into view', async () => {
    const { container } = render(<InventoryItemIcon templateId="FullStabilizationBelt" displayName="Belt" />)
    expect(container.querySelector('img')).toBeNull()
    await act(async () => { intersectionCallback?.([{ isIntersecting:true, target:container.firstElementChild } as IntersectionObserverEntry], {} as IntersectionObserver) })
    await waitFor(() => expect(container.querySelector('img')).toHaveAttribute('src', expect.stringMatching(/^\/item-icons\//)))
  })
  it('keeps the existing fallback when a game template has no image', async () => {
    const { container } = render(<InventoryItemIcon templateId="NoSuchGameItem" displayName="Unknown item" />)
    await act(async () => { intersectionCallback?.([{ isIntersecting:true, target:container.firstElementChild } as IntersectionObserverEntry], {} as IntersectionObserver) })
    expect(container.querySelector('img')).toBeNull()
    expect(screen.getByTitle('Unknown item icon unavailable')).toBeInTheDocument()
  })
  it('retains an optional user-clicked detail link', () => {
    expect(itemDetailsUrl('MelangeSpice')).toBe('https://dune.gaming.tools/items/melangespice')
  })
})
