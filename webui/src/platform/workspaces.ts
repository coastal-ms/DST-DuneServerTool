import type { ComponentType } from 'react'

export type WorkspaceId =
  | 'home'
  | 'map'
  | 'players'
  | 'bases'
  | 'vehicles'
  | 'economy'
  | 'operations'
  | 'settings'

export type WorkspaceVisibility = 'all' | 'owner'
export type FeatureDisposition = 'remain' | 'move' | 'merge' | 'replace'
export type LazyPageModule = { default: ComponentType }

export type WorkspaceDefinition = {
  id: WorkspaceId
  label: string
  path: string
  icon: string
  purpose: string
  responsivePattern: string
  visibility: WorkspaceVisibility
  load: () => Promise<LazyPageModule>
}

export const WORKSPACE_MANIFEST: readonly WorkspaceDefinition[] = [
  {
    id: 'home',
    label: 'Home',
    path: '/',
    icon: 'LayoutDashboard',
    purpose: 'Health and cross-domain summaries.',
    responsivePattern: 'Summary cards linking into focused workspaces.',
    visibility: 'all',
    load: () => import('../pages/workspaces/HomeWorkspace'),
  },
  {
    id: 'map',
    label: 'Map',
    path: '/map',
    icon: 'Map',
    purpose: 'Deep Desert atlas, Coriolis context, and map lifecycle.',
    responsivePattern: 'Map canvas with scrollable views and phone detail sheets.',
    visibility: 'all',
    load: () => import('../pages/workspaces/MapWorkspace'),
  },
  {
    id: 'players',
    label: 'Players',
    path: '/players',
    icon: 'Users',
    purpose: 'Profiles, progression, inventory, and moderation.',
    responsivePattern: 'Search and selection followed by focused detail.',
    visibility: 'all',
    load: () => import('../pages/workspaces/PlayersWorkspace'),
  },
  {
    id: 'bases',
    label: 'Bases',
    path: '/bases',
    icon: 'Castle',
    purpose: 'Claims, blueprints, access, and base inventory.',
    responsivePattern: 'Filterable list with task-specific detail.',
    visibility: 'all',
    load: () => import('../pages/workspaces/BasesWorkspace'),
  },
  {
    id: 'vehicles',
    label: 'Vehicles',
    path: '/vehicles',
    icon: 'Truck',
    purpose: 'Fleet, cargo, ownership, and integrity.',
    responsivePattern: 'Fleet list with a phone bottom sheet for detail.',
    visibility: 'all',
    load: () => import('../pages/workspaces/VehiclesWorkspace'),
  },
  {
    id: 'economy',
    label: 'Economy',
    path: '/economy',
    icon: 'Landmark',
    purpose: 'Market, market bot, Landsraad, and governance.',
    responsivePattern: 'Scoped dashboards and horizontally contained tables.',
    visibility: 'all',
    load: () => import('../pages/workspaces/EconomyWorkspace'),
  },
  {
    id: 'operations',
    label: 'Operations',
    path: '/operations',
    icon: 'Activity',
    purpose: 'Runtime, commands, backups, updates, and maintenance.',
    responsivePattern: 'Status-led task list with guarded action surfaces.',
    visibility: 'all',
    load: () => import('../pages/workspaces/OperationsWorkspace'),
  },
  {
    id: 'settings',
    label: 'Settings',
    path: '/settings',
    icon: 'Settings',
    purpose: 'Server configuration, connectivity, accounts, and appearance.',
    responsivePattern: 'Registered, collapsible sections with conformance previews.',
    visibility: 'owner',
    load: () => import('../pages/Settings').then(module => ({ default: module.Settings })),
  },
]

export type FeaturePlacement = {
  currentFeature: string
  currentRoutes: readonly string[]
  destination: string
  workspaceId: WorkspaceId | 'solo'
  disposition: FeatureDisposition
}

export const FEATURE_PLACEMENTS: readonly FeaturePlacement[] = [
  { currentFeature: 'Server Health dashboard', currentRoutes: ['/'], destination: 'Home', workspaceId: 'home', disposition: 'remain' },
  { currentFeature: 'Dashboard map pod and spice summaries', currentRoutes: ['/'], destination: 'Home summary and Map', workspaceId: 'map', disposition: 'move' },
  { currentFeature: 'Pods', currentRoutes: ['/pods'], destination: 'Operations / Runtime', workspaceId: 'operations', disposition: 'move' },
  { currentFeature: 'Commands', currentRoutes: ['/commands'], destination: 'Operations / Commands', workspaceId: 'operations', disposition: 'move' },
  { currentFeature: 'PowerShell', currentRoutes: ['/terminal'], destination: 'Operations / Host Tools', workspaceId: 'operations', disposition: 'move' },
  { currentFeature: 'Game Config', currentRoutes: ['/gameconfig'], destination: 'Settings / Game Server', workspaceId: 'settings', disposition: 'move' },
  { currentFeature: 'Experimental Lab', currentRoutes: ['/experimental'], destination: 'Settings / Advanced', workspaceId: 'settings', disposition: 'move' },
  { currentFeature: 'Gameplay Overview', currentRoutes: ['/gameplay?view=overview'], destination: 'Home and Operations / In-game Commands', workspaceId: 'home', disposition: 'merge' },
  { currentFeature: 'Gameplay Players', currentRoutes: ['/gameplay?view=players'], destination: 'Players', workspaceId: 'players', disposition: 'move' },
  { currentFeature: 'Gameplay Bases', currentRoutes: ['/gameplay?view=bases'], destination: 'Bases', workspaceId: 'bases', disposition: 'move' },
  { currentFeature: 'Gameplay Storage', currentRoutes: ['/gameplay?view=storage'], destination: 'Shared inventory explorer', workspaceId: 'players', disposition: 'replace' },
  { currentFeature: 'Gameplay Blueprints', currentRoutes: ['/gameplay?view=blueprints'], destination: 'Bases / Blueprints', workspaceId: 'bases', disposition: 'move' },
  { currentFeature: 'Gameplay Market and Market Bot', currentRoutes: ['/gameplay?view=market', '/gameplay?view=marketbot'], destination: 'Economy / Market', workspaceId: 'economy', disposition: 'move' },
  { currentFeature: 'Gameplay Landsraad', currentRoutes: ['/gameplay?view=landsraad'], destination: 'Economy / Governance', workspaceId: 'economy', disposition: 'move' },
  { currentFeature: 'Broadcasts', currentRoutes: ['/broadcasts'], destination: 'Operations / Communications', workspaceId: 'operations', disposition: 'move' },
  { currentFeature: 'DD Seed Maps', currentRoutes: ['/dd-map', '/wick-maps'], destination: 'Map / DD Atlas', workspaceId: 'map', disposition: 'remain' },
  { currentFeature: 'Map SpinUp and remote map cards', currentRoutes: ['/map-spinup', '/remote/maps'], destination: 'Map / Lifecycle', workspaceId: 'map', disposition: 'merge' },
  { currentFeature: 'Coriolis player card', currentRoutes: ['/gameplay?view=players'], destination: 'Map / Coriolis', workspaceId: 'map', disposition: 'move' },
  { currentFeature: 'Database and backup catalog', currentRoutes: ['/database'], destination: 'Operations / Data Protection', workspaceId: 'operations', disposition: 'move' },
  { currentFeature: 'Sietches', currentRoutes: ['/sietches'], destination: 'Operations / Topology', workspaceId: 'operations', disposition: 'move' },
  { currentFeature: 'Settings', currentRoutes: ['/settings'], destination: 'Settings', workspaceId: 'settings', disposition: 'remain' },
  { currentFeature: 'Setup Wizard', currentRoutes: ['/setup'], destination: 'Settings / Setup', workspaceId: 'settings', disposition: 'remain' },
  { currentFeature: 'Solo Mode', currentRoutes: ['/solo'], destination: 'Separate local mode', workspaceId: 'solo', disposition: 'remain' },
  { currentFeature: 'Legacy reduced remote SPA', currentRoutes: ['/remote', '/remote/maps'], destination: 'Responsive full AppShell', workspaceId: 'home', disposition: 'replace' },
]

export function getWorkspace(id: WorkspaceId) {
  const workspace = WORKSPACE_MANIFEST.find(item => item.id === id)
  if (!workspace) throw new Error(`Unknown workspace: ${id}`)
  return workspace
}
