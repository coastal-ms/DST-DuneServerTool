import { renderHook, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  SIDEBAR_DIVIDER_LABEL_MAX_LENGTH,
  SIDEBAR_ORDER_STORAGE_KEY,
  SIDEBAR_ORDER_V2_STORAGE_KEY,
  SIDEBAR_ORDER_V1_STORAGE_KEY,
  applySidebarNavigationOrder,
  getCanonicalSidebarNavigationOrder,
  normalizeSidebarNavigationOrder,
  removeSidebarDivider,
  renameSidebarDivider,
  reorderSidebarNavigationItem,
  sanitizeSidebarDividerLabel,
  setSidebarPagesHidden,
  useSidebarNavigationOrder,
} from '../src/hooks/useSidebarNavigationOrder'
import type { NavItem } from '../src/nav'

const items: NavItem[] = [
  { to: '/', label: 'Overview', icon: 'Home', group: 'overview' },
  { to: '/operations', label: 'Operations', icon: 'Activity', group: 'overview' },
  { to: '/pods', label: 'Pods', icon: 'Boxes', group: 'overview' },
  { to: '/commands', label: 'Commands', icon: 'Zap', group: 'terminal' },
  { to: '/gameconfig', label: 'Game Config', icon: 'Sliders', group: 'terminal', ownerOnly: true },
]

beforeEach(() => localStorage.clear())

describe('sidebar navigation preferences v3', () => {
  it('defines a single canonical sequence of page and divider entries', () => {
    expect(getCanonicalSidebarNavigationOrder(items)).toEqual({
      version: 3,
      items: [
        { type: 'divider', id: 'divider:overview', label: 'Server Management' },
        { type: 'page', id: '/' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/pods' },
        { type: 'divider', id: 'divider:terminal', label: 'Server Controls' },
        { type: 'page', id: '/commands' },
        { type: 'page', id: '/gameconfig' },
      ],
      hiddenPageIds: [],
    })
  })

  it('migrates customized v1 groups without discarding their page order', () => {
    const migrated = normalizeSidebarNavigationOrder({
      version: 1,
      groups: {
        overview: ['/operations', '/missing', '/operations', '/'],
        terminal: ['/gameconfig', '/commands'],
      },
    }, items)

    expect(migrated.items).toEqual([
      { type: 'divider', id: 'divider:overview', label: 'Server Management' },
      { type: 'page', id: '/operations' },
      { type: 'page', id: '/' },
      { type: 'page', id: '/pods' },
      { type: 'divider', id: 'divider:terminal', label: 'Server Controls' },
      { type: 'page', id: '/gameconfig' },
      { type: 'page', id: '/commands' },
    ])
  })

  it('rejects malformed, duplicate, unknown, and empty entries', () => {
    const normalized = normalizeSidebarNavigationOrder({
      version: 3,
      items: [
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/missing' },
        { type: 'divider', id: 'bad-id', label: 'Bad' },
        { type: 'divider', id: 'divider:user:empty', label: ' \u0000 ' },
        { type: 'divider', id: 'divider:user:valid', label: '  My   Section  ' },
        null,
      ],
      hiddenPageIds: ['/operations', '/operations', '/missing', 42],
    }, items)

    expect(normalized.items.filter(entry => entry.id === '/operations')).toHaveLength(1)
    expect(normalized.items).not.toContainEqual(expect.objectContaining({ id: '/missing' }))
    expect(normalized.items).not.toContainEqual(expect.objectContaining({ id: 'bad-id' }))
    expect(normalized.items).not.toContainEqual(expect.objectContaining({ id: 'divider:user:empty' }))
    expect(normalized.items).toContainEqual({
      type: 'divider',
      id: 'divider:user:valid',
      label: 'My Section',
    })
    expect(normalized.hiddenPageIds).toEqual(['/operations'])
  })

  it('reconciles newly introduced routes beside their canonical neighbors', () => {
    const normalized = normalizeSidebarNavigationOrder({
      version: 3,
      items: [
        { type: 'divider', id: 'divider:overview', label: 'Server Management' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/' },
        { type: 'divider', id: 'divider:terminal', label: 'Server Controls' },
        { type: 'page', id: '/commands' },
      ],
      hiddenPageIds: [],
    }, items)

    expect(normalized.items.map(entry => entry.id)).toEqual([
      'divider:overview',
      '/operations',
      '/',
      '/pods',
      'divider:terminal',
      '/commands',
      '/gameconfig',
    ])
  })

  it('filters temporarily hidden pages only when applying the saved layout', () => {
    const order = getCanonicalSidebarNavigationOrder(items)
    const visible = new Set(['/', '/operations', '/pods', '/commands'])
    const rendered = applySidebarNavigationOrder(items, order, visible)

    expect(rendered.map(entry => entry.id)).not.toContain('/gameconfig')
    expect(order.items.map(entry => entry.id)).toContain('/gameconfig')
  })

  it('moves pages freely across dividers and allows pages before the first divider', () => {
    const order = getCanonicalSidebarNavigationOrder(items)
    const moved = reorderSidebarNavigationItem(order, '/commands', 'divider:overview')

    expect(moved.items[0]).toEqual({ type: 'page', id: '/commands' })
  })

  it('renames and removes dividers without removing pages', () => {
    const order = getCanonicalSidebarNavigationOrder(items)
    const renamed = renameSidebarDivider(order, 'divider:overview', '  Favorites  ')
    const removed = removeSidebarDivider(renamed, 'divider:overview')

    expect(renamed.items[0]).toEqual({
      type: 'divider',
      id: 'divider:overview',
      label: 'Favorites',
    })
    expect(removed.items.some(entry => entry.id === 'divider:overview')).toBe(false)
    expect(removed.items.filter(entry => entry.type === 'page')).toHaveLength(5)
  })

  it('sanitizes control characters and bounds divider labels', () => {
    const label = sanitizeSidebarDividerLabel(`  My\u0000\u0085  ${'x'.repeat(100)}  `)
    expect(label).not.toContain('\u0000')
    expect(label).not.toContain('\u0085')
    expect(label.length).toBe(SIDEBAR_DIVIDER_LABEL_MAX_LENGTH)
  })

  it('uses distinct storage keys for v2 and migration input', () => {
    expect(SIDEBAR_ORDER_STORAGE_KEY).toBe('dst.sidebar.navigation-preferences.v3')
    expect(SIDEBAR_ORDER_V2_STORAGE_KEY).toBe('dst.sidebar.navigation-order.v2')
    expect(SIDEBAR_ORDER_V1_STORAGE_KEY).toBe('dst.sidebar.navigation-order.v1')
  })

  it('migrates v2 order with every page visible by default', () => {
    const migrated = normalizeSidebarNavigationOrder({
      version: 2,
      items: [
        { type: 'divider', id: 'divider:overview', label: 'Favorites' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/' },
      ],
    }, items)

    expect(migrated.version).toBe(3)
    expect(migrated.hiddenPageIds).toEqual([])
    expect(migrated.items.slice(0, 3)).toEqual([
      { type: 'divider', id: 'divider:overview', label: 'Favorites' },
      { type: 'page', id: '/operations' },
      { type: 'page', id: '/' },
    ])
  })

  it('persists v2 storage as v3 before removing the old key', async () => {
    const previousOrder = {
      version: 2,
      items: [
        { type: 'divider', id: 'divider:overview', label: 'Favorites' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/' },
      ],
    }
    localStorage.setItem(SIDEBAR_ORDER_V2_STORAGE_KEY, JSON.stringify(previousOrder))

    renderHook(() => useSidebarNavigationOrder(items, items))

    await waitFor(() => expect(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY)).not.toBeNull())
    expect(JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null')).toMatchObject({
      version: 3,
      hiddenPageIds: [],
    })
    expect(localStorage.getItem(SIDEBAR_ORDER_V2_STORAGE_KEY)).toBeNull()
  })

  it('never stores protected pages as hidden', () => {
    const protectedItems: NavItem[] = [
      { ...items[0], sidebarAlwaysVisible: true },
      ...items.slice(1),
    ]
    const canonical = getCanonicalSidebarNavigationOrder(protectedItems)
    const hidden = setSidebarPagesHidden(canonical, protectedItems, ['/', '/operations'], true)

    expect(hidden.hiddenPageIds).toEqual(['/operations'])
    expect(normalizeSidebarNavigationOrder({
      ...hidden,
      hiddenPageIds: ['/', '/operations', '/missing'],
    }, protectedItems).hiddenPageIds).toEqual(['/operations'])
  })

  it('retains the v1 order when persisting its migration fails', () => {
    const legacyOrder = {
      version: 1,
      groups: {
        overview: ['/operations', '/'],
        terminal: ['/commands'],
      },
    }
    localStorage.setItem(SIDEBAR_ORDER_V1_STORAGE_KEY, JSON.stringify(legacyOrder))
    const originalSetItem = Storage.prototype.setItem
    const setItem = vi.spyOn(Storage.prototype, 'setItem')
      .mockImplementation(function (key, value) {
        if (key === SIDEBAR_ORDER_STORAGE_KEY) throw new DOMException('Quota exceeded', 'QuotaExceededError')
        originalSetItem.call(this, key, value)
      })

    renderHook(() => useSidebarNavigationOrder(items, items))

    expect(setItem).toHaveBeenCalledWith(SIDEBAR_ORDER_STORAGE_KEY, expect.any(String))
    expect(localStorage.getItem(SIDEBAR_ORDER_V1_STORAGE_KEY)).toBe(JSON.stringify(legacyOrder))
  })
})
