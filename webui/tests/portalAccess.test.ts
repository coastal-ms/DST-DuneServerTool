import { describe, expect, it } from 'vitest'
import { NAV_ITEMS, getVisibleGroupLabel } from '../src/nav'
import { resolvePortalAccess } from '../src/auth/portalAccess'
import { canAccessCommand } from '../src/auth/commandAccess'

describe('Browser Portal role access', () => {
  it('gives remote Owners full portal access except host-only Setup', () => {
    expect(resolvePortalAccess(false, true, 'owner')).toEqual({
      canAccessOwnerSurfaces: true,
      canAccessSetup: false,
    })
  })

  it('limits remote Admins to delegated operational surfaces', () => {
    expect(resolvePortalAccess(false, true, 'admin')).toEqual({
      canAccessOwnerSurfaces: false,
      canAccessSetup: false,
    })
  })

  it('keeps the local host fully trusted regardless of account role', () => {
    expect(resolvePortalAccess(true, true, 'admin')).toEqual({
      canAccessOwnerSurfaces: true,
      canAccessSetup: true,
    })
  })

  it('fails closed for remote account-mode launch access without an account role', () => {
    expect(resolvePortalAccess(false, true, null).canAccessOwnerSurfaces).toBe(false)
    expect(resolvePortalAccess(false, false, null).canAccessOwnerSurfaces).toBe(true)
  })

  it('marks sensitive pages Owner-only and Setup host-only', () => {
    for (const path of ['/gameconfig', '/experimental', '/database', '/sietches', '/settings']) {
      expect(NAV_ITEMS.find(item => item.to === path)?.ownerOnly).toBe(true)
    }
    expect(NAV_ITEMS.find(item => item.to === '/setup')?.localOnly).toBe(true)
  })

  it('labels server and gameplay domains explicitly', () => {
    expect(getVisibleGroupLabel('overview')).toBe('Server Management')
    expect(getVisibleGroupLabel('workspaces')).toBe('Gameplay Administration')
  })

  it('adds Funcom server Update only for authenticated remote Owners', () => {
    expect(canAccessCommand('update', false, 'owner')).toBe(true)
    expect(canAccessCommand('update', false, 'admin')).toBe(false)
    expect(canAccessCommand('update', false, null)).toBe(false)
    expect(canAccessCommand('restart', false, 'admin')).toBe(true)
  })
})
