import { describe, expect, it } from 'vitest'
import { FEATURE_PLACEMENTS, WORKSPACE_MANIFEST } from '../src/platform/workspaces'
import {
  COMPATIBILITY_REDIRECTS,
  LEGACY_REMOTE_MAP_DESTINATION,
  LEGACY_REMOTE_MAP_ROUTE,
  LEGACY_ROUTE_MANIFEST,
  resolveCompatibilityRedirect,
  shouldRedirectLegacyRemoteMap,
} from '../src/platform/routes'
import { getVisibleNavItems, isNavItemActive, NAV_ITEMS } from '../src/nav'
import { GAMEPLAY_DESTINATIONS, GAMEPLAY_PATHS, resolveGameplaySection } from '../src/platform/gameplay'

const EXPECTED_WORKSPACES = [
  'home',
  'map',
  'players',
  'bases',
  'vehicles',
  'economy',
  'operations',
  'settings',
]

describe('workspace manifest', () => {
  it('defines every approved destination exactly once with a deferred page loader', () => {
    expect(WORKSPACE_MANIFEST.map(workspace => workspace.id)).toEqual(EXPECTED_WORKSPACES)
    expect(new Set(WORKSPACE_MANIFEST.map(workspace => workspace.path)).size).toBe(WORKSPACE_MANIFEST.length)
    for (const workspace of WORKSPACE_MANIFEST) {
      expect(workspace.path.startsWith('/')).toBe(true)
      expect(workspace.load).toBeTypeOf('function')
      expect(workspace.purpose.length).toBeGreaterThan(10)
      expect(workspace.responsivePattern.length).toBeGreaterThan(10)
      expect(['server-management', 'gameplay-admin']).toContain(workspace.domain)
    }
  })

  it('describes the shipped Vehicles surface without advertising future scaffolding', () => {
    expect(WORKSPACE_MANIFEST.find(workspace => workspace.id === 'vehicles')).toMatchObject({
      purpose: 'Live fleet inventory and protected vehicle removal.',
      responsivePattern: 'Responsive fleet cards with one guarded deletion queue.',
    })
  })

  it('keeps Solo separate and records every current feature disposition', () => {
    expect(WORKSPACE_MANIFEST.some(workspace => workspace.id === ('solo' as never))).toBe(false)
    expect(FEATURE_PLACEMENTS.find(item => item.currentFeature === 'Solo Mode')).toMatchObject({
      workspaceId: 'solo',
      disposition: 'remain',
    })
    expect(new Set(FEATURE_PLACEMENTS.map(item => item.disposition))).toEqual(
      new Set(['remain', 'move', 'merge', 'replace']),
    )
    for (const feature of FEATURE_PLACEMENTS) {
      expect(feature.currentRoutes.length).toBeGreaterThan(0)
      expect(feature.destination.length).toBeGreaterThan(0)
    }
  })

  it('maps every Classic Players and Inventory surface into Command Deck', () => {
    const playerPlacements = FEATURE_PLACEMENTS.filter(item => item.workspaceId === 'players')
    expect(playerPlacements).toEqual(expect.arrayContaining([
      expect.objectContaining({
        currentFeature: 'Gameplay Players',
        currentRoutes: ['/players', '/gameplay?view=players'],
      }),
      expect.objectContaining({
        currentFeature: 'Gameplay Storage',
        currentRoutes: ['/gameplay?view=storage'],
      }),
      expect.objectContaining({
        currentFeature: 'In-game chat commands and shared teleport destinations',
        currentRoutes: ['/gameplay?view=overview'],
        destination: 'Gameplay Admin / Players / Community tools',
      }),
      expect.objectContaining({
        currentFeature: 'Welcome Back packages',
        currentRoutes: ['/gameplay?view=overview'],
        destination: 'Gameplay Admin / Players / Community tools',
      }),
    ]))
  })

  it('keeps every route module lazy and preserves the current permission matrix', () => {
    for (const route of LEGACY_ROUTE_MANIFEST) expect(route.load).toBeTypeOf('function')

    const adminPaths = getVisibleNavItems({
      local: false,
      windows: false,
      canAccessOwnerSurfaces: false,
    }).map(item => item.to)
    expect(adminPaths).toContain('/gameplay')
    expect(adminPaths).toContain('/operations')
    expect(adminPaths).toContain('/sponsors')
    expect(adminPaths).not.toContain('/map')
    expect(adminPaths).not.toContain('/players')
    expect(adminPaths).not.toContain('/settings')
    expect(adminPaths).not.toContain('/database')
    expect(adminPaths).not.toContain('/terminal')
    expect(adminPaths).not.toContain('/solo')

    const localPaths = getVisibleNavItems({
      local: true,
      windows: true,
      canAccessOwnerSurfaces: true,
    }).map(item => item.to)
    expect(localPaths).toContain('/settings')
    expect(localPaths).toContain('/database')
    expect(localPaths).toContain('/terminal')
    expect(localPaths).toContain('/solo')
    expect(localPaths).toContain('/map?view=atlas')
    expect(localPaths).toContain('/sponsors')
  })

  it('keeps the primary rail server-first with one Gameplay Admin gateway', () => {
    const localItems = getVisibleNavItems({
      local: true,
      windows: true,
      canAccessOwnerSurfaces: true,
      includeSidebarHidden: false,
    })
    expect(localItems[0].label).toBe('Server Overview')
    expect(localItems.filter(item => item.label === 'Gameplay Admin')).toHaveLength(1)
    expect(localItems.filter(item => item.label === 'DD Atlas')).toHaveLength(1)
    expect(localItems.some(item => ['Map', 'Players', 'Bases', 'Vehicles', 'Economy'].includes(item.label))).toBe(false)
    expect(new Set(localItems.map(item => item.to)).size).toBe(localItems.length)
    expect(localItems.length).toBeLessThanOrEqual(14)
  })

  it('highlights DD Atlas instead of Gameplay Admin on the static atlas view', () => {
    const gameplay = NAV_ITEMS.find(item => item.label === 'Gameplay Admin')
    const atlas = NAV_ITEMS.find(item => item.label === 'DD Atlas')

    expect(gameplay).toBeDefined()
    expect(atlas).toBeDefined()
    expect(isNavItemActive(gameplay!, '/map', 'view=lifecycle')).toBe(false)
    expect(isNavItemActive(atlas!, '/map', 'view=lifecycle')).toBe(false)
    expect(isNavItemActive(gameplay!, '/map', 'view=atlas')).toBe(false)
    expect(isNavItemActive(atlas!, '/map', 'view=atlas')).toBe(true)
  })

  it('defines one compact Gameplay Admin destination set and singular route state', () => {
    expect(GAMEPLAY_DESTINATIONS.map(item => item.label)).toEqual([
      'Overview', 'Map', 'Players', 'Bases', 'Vehicles', 'Economy',
    ])
    expect(GAMEPLAY_PATHS).toEqual([
      '/gameplay', '/map', '/players', '/bases', '/vehicles', '/economy',
    ])
    expect(resolveGameplaySection('/players')).toBe('players')
    expect(resolveGameplaySection('/gameplay', 'view=storage')).toBe('players')
    expect(resolveGameplaySection('/gameplay', 'view=marketbot')).toBe('economy')
  })
})

describe('compatibility routes', () => {
  it('redirects existing bookmarks into matching workspace views', () => {
    expect(COMPATIBILITY_REDIRECTS).toEqual(expect.arrayContaining([
      { from: '/home', to: '/' },
      { from: '/monitoring', to: '/' },
      { from: '/dd-map', to: '/map?view=atlas' },
      { from: '/wick-maps', to: '/map?view=atlas' },
      { from: '/map-spinup', to: '/map?view=lifecycle' },
    ]))
    expect(resolveCompatibilityRedirect('/wick-maps')).toBe('/map?view=atlas')
    expect(resolveCompatibilityRedirect('/unknown')).toBeNull()
    expect(LEGACY_REMOTE_MAP_ROUTE).toBe('/remote/maps')
    expect(LEGACY_REMOTE_MAP_DESTINATION).toBe('/map?view=lifecycle')
    expect(shouldRedirectLegacyRemoteMap(true)).toBe(true)
    expect(shouldRedirectLegacyRemoteMap(false)).toBe(false)
  })
})
