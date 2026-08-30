import { beforeEach, describe, expect, it } from 'vitest'
import {
  SIDEBAR_ORDER_STORAGE_KEY,
  applySidebarNavigationOrder,
  normalizeSidebarNavigationOrder,
  reorderSidebarNavigationItem,
} from '../src/hooks/useSidebarNavigationOrder'
import type { NavItem } from '../src/nav'

const items: NavItem[] = [
  { to: '/', label: 'Overview', icon: 'Home', group: 'overview' },
  { to: '/operations', label: 'Operations', icon: 'Activity', group: 'overview' },
  { to: '/pods', label: 'Pods', icon: 'Boxes', group: 'overview' },
  { to: '/commands', label: 'Commands', icon: 'Zap', group: 'terminal' },
  { to: '/gameconfig', label: 'Game Config', icon: 'Sliders', group: 'terminal' },
]

beforeEach(() => localStorage.clear())

describe('sidebar navigation order', () => {
  it('normalizes persisted order and removes stale or duplicate IDs', () => {
    localStorage.setItem(SIDEBAR_ORDER_STORAGE_KEY, JSON.stringify({
      version: 1,
      groups: {
        overview: ['/operations', '/missing', '/operations', '/'],
      },
    }))
    const saved = JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null')

    expect(normalizeSidebarNavigationOrder(saved, items).groups.overview)
      .toEqual(['/operations', '/', '/pods'])
  })

  it('keeps every item inside its canonical category', () => {
    const normalized = normalizeSidebarNavigationOrder({
      version: 1,
      groups: {
        overview: ['/commands', '/operations'],
        terminal: ['/', '/gameconfig'],
      },
    }, items)

    expect(normalized.groups.overview).toEqual(['/operations', '/', '/pods'])
    expect(normalized.groups.terminal).toEqual(['/gameconfig', '/commands'])
  })

  it('appends newly introduced or newly visible items in canonical order', () => {
    const normalized = normalizeSidebarNavigationOrder({
      version: 1,
      groups: {
        overview: ['/operations', '/'],
        terminal: ['/commands'],
      },
    }, items)

    expect(normalized.groups.overview).toEqual(['/operations', '/', '/pods'])
    expect(normalized.groups.terminal).toEqual(['/commands', '/gameconfig'])
  })

  it('reorders only within the requested category', () => {
    const normalized = normalizeSidebarNavigationOrder(null, items)
    const moved = reorderSidebarNavigationItem(normalized, 'overview', '/pods', '/')
    const blocked = reorderSidebarNavigationItem(moved, 'overview', '/commands', '/')
    const ordered = applySidebarNavigationOrder(items, blocked)

    expect(moved.groups.overview).toEqual(['/pods', '/', '/operations'])
    expect(blocked).toBe(moved)
    expect(ordered.map(item => item.to)).toEqual([
      '/pods',
      '/',
      '/operations',
      '/commands',
      '/gameconfig',
    ])
  })
})
