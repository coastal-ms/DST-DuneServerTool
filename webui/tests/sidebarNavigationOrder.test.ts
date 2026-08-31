import { beforeEach, describe, expect, it } from 'vitest'
import {
  SIDEBAR_DIVIDER_LABEL_MAX_LENGTH,
  SIDEBAR_ORDER_STORAGE_KEY,
  SIDEBAR_ORDER_V1_STORAGE_KEY,
  applySidebarNavigationOrder,
  getCanonicalSidebarNavigationOrder,
  normalizeSidebarNavigationOrder,
  removeSidebarDivider,
  renameSidebarDivider,
  reorderSidebarNavigationItem,
  sanitizeSidebarDividerLabel,
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

describe('sidebar navigation order v2', () => {
  it('defines a single canonical sequence of page and divider entries', () => {
    expect(getCanonicalSidebarNavigationOrder(items)).toEqual({
      version: 2,
      items: [
        { type: 'divider', id: 'divider:overview', label: 'Server Management' },
        { type: 'page', id: '/' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/pods' },
        { type: 'divider', id: 'divider:terminal', label: 'Server Controls' },
        { type: 'page', id: '/commands' },
        { type: 'page', id: '/gameconfig' },
      ],
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
      version: 2,
      items: [
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/missing' },
        { type: 'divider', id: 'bad-id', label: 'Bad' },
        { type: 'divider', id: 'divider:user:empty', label: ' \u0000 ' },
        { type: 'divider', id: 'divider:user:valid', label: '  My   Section  ' },
        null,
      ],
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
  })

  it('reconciles newly introduced routes beside their canonical neighbors', () => {
    const normalized = normalizeSidebarNavigationOrder({
      version: 2,
      items: [
        { type: 'divider', id: 'divider:overview', label: 'Server Management' },
        { type: 'page', id: '/operations' },
        { type: 'page', id: '/' },
        { type: 'divider', id: 'divider:terminal', label: 'Server Controls' },
        { type: 'page', id: '/commands' },
      ],
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
    const label = sanitizeSidebarDividerLabel(`  My\u0000  ${'x'.repeat(100)}  `)
    expect(label).not.toContain('\u0000')
    expect(label.length).toBe(SIDEBAR_DIVIDER_LABEL_MAX_LENGTH)
  })

  it('uses distinct storage keys for v2 and migration input', () => {
    expect(SIDEBAR_ORDER_STORAGE_KEY).toBe('dst.sidebar.navigation-order.v2')
    expect(SIDEBAR_ORDER_V1_STORAGE_KEY).toBe('dst.sidebar.navigation-order.v1')
  })
})
