import { describe, expect, it } from 'vitest'
import { GROUP_LABELS, GROUP_ORDER, NAV_ITEMS } from '../src/nav'

describe('Solo Mode navigation', () => {
  it('has a dedicated released host-local group', () => {
    const item = NAV_ITEMS.find(entry => entry.to === '/solo')
    expect(item).toMatchObject({
      label: 'Solo Mode',
      group: 'solo',
      localOnly: true,
      windowsOnly: true,
    })
    expect(item?.badge).toBeUndefined()
    expect(GROUP_ORDER).toContain('solo')
    expect(GROUP_LABELS.solo).toBe('Solo Mode')
  })
})
