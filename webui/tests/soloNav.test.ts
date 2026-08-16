import { describe, expect, it } from 'vitest'
import { GROUP_LABELS, GROUP_ORDER, NAV_ITEMS } from '../src/nav'

describe('Solo Mode navigation', () => {
  it('has a dedicated host-local preview group', () => {
    const item = NAV_ITEMS.find(entry => entry.to === '/solo')
    expect(item).toMatchObject({
      label: 'Solo Mode',
      group: 'solo',
      localOnly: true,
      windowsOnly: true,
      badge: 'Preview',
    })
    expect(GROUP_ORDER).toContain('solo')
    expect(GROUP_LABELS.solo).toBe('Solo Mode')
  })
})
