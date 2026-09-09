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
export type WorkspaceDomain = 'server-management' | 'gameplay-admin'
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
  domain: WorkspaceDomain
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
    domain: 'server-management',
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
    domain: 'gameplay-admin',
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
    domain: 'gameplay-admin',
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
    domain: 'gameplay-admin',
    load: () => import('../pages/workspaces/BasesWorkspace'),
  },
  {
    id: 'vehicles',
    label: 'Vehicles',
    path: '/vehicles',
    icon: 'Truck',
    purpose: 'Live fleet inventory and protected vehicle removal.',
    responsivePattern: 'Responsive fleet cards with one guarded deletion queue.',
    visibility: 'all',
    domain: 'gameplay-admin',
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
    domain: 'gameplay-admin',
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
    domain: 'server-management',
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
    domain: 'server-management',
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
  { currentFeature: 'Server Health dashboard', currentRoutes: ['/'], destination: 'Server Management / Overview', workspaceId: 'home', disposition: 'remain' },
  { currentFeature: 'Dashboard map pod and spice summaries', currentRoutes: ['/'], destination: 'Server overview summary and Gameplay Admin / Map', workspaceId: 'map', disposition: 'move' },
  { currentFeature: 'Pods', currentRoutes: ['/pods'], destination: 'Server Management / Runtime', workspaceId: 'operations', disposition: 'remain' },
  { currentFeature: 'Commands', currentRoutes: ['/commands'], destination: 'Server Management / Commands', workspaceId: 'operations', disposition: 'remain' },
  { currentFeature: 'PowerShell', currentRoutes: ['/terminal'], destination: 'Server Management / Host Tools', workspaceId: 'operations', disposition: 'remain' },
  { currentFeature: 'Game Config', currentRoutes: ['/gameconfig'], destination: 'Server Management / Game Config', workspaceId: 'settings', disposition: 'remain' },
  { currentFeature: 'Experimental Lab', currentRoutes: ['/experimental'], destination: 'Server Management / Experimental Lab', workspaceId: 'settings', disposition: 'remain' },
  { currentFeature: 'Gameplay Overview', currentRoutes: ['/gameplay?view=overview'], destination: 'Gameplay Admin / Overview', workspaceId: 'home', disposition: 'remain' },
  { currentFeature: 'Gameplay Players', currentRoutes: ['/players', '/gameplay?view=players'], destination: 'Gameplay Admin / Players', workspaceId: 'players', disposition: 'move' },
  { currentFeature: 'In-game chat commands and shared teleport destinations', currentRoutes: ['/gameplay?view=overview'], destination: 'Gameplay Admin / Players / Community tools', workspaceId: 'players', disposition: 'move' },
  { currentFeature: 'Welcome Back packages', currentRoutes: ['/gameplay?view=overview'], destination: 'Gameplay Admin / Players / Community tools', workspaceId: 'players', disposition: 'move' },
  { currentFeature: 'Gameplay Bases', currentRoutes: ['/bases', '/gameplay?view=bases'], destination: 'Gameplay Admin / Bases', workspaceId: 'bases', disposition: 'move' },
  { currentFeature: 'Gameplay Storage', currentRoutes: ['/gameplay?view=storage'], destination: 'Shared Inventory Explorer in Players, Bases, Vehicles, and Economy', workspaceId: 'players', disposition: 'merge' },
  { currentFeature: 'Gameplay Blueprints', currentRoutes: ['/gameplay?view=blueprints'], destination: 'Gameplay Admin / Bases / Blueprints', workspaceId: 'bases', disposition: 'move' },
  { currentFeature: 'Gameplay Market and Market Bot', currentRoutes: ['/economy', '/gameplay?view=market', '/gameplay?view=marketbot'], destination: 'Gameplay Admin / Economy', workspaceId: 'economy', disposition: 'move' },
  { currentFeature: 'Gameplay Landsraad', currentRoutes: ['/gameplay?view=landsraad'], destination: 'Gameplay Admin / Economy / Governance', workspaceId: 'economy', disposition: 'move' },
  { currentFeature: 'Broadcasts', currentRoutes: ['/broadcasts'], destination: 'Server Management / Communications', workspaceId: 'operations', disposition: 'remain' },
  { currentFeature: 'DD Seed Maps', currentRoutes: ['/map', '/dd-map', '/wick-maps'], destination: 'Gameplay Admin / Map / DD Atlas', workspaceId: 'map', disposition: 'remain' },
  { currentFeature: 'Map SpinUp and remote map cards', currentRoutes: ['/map-spinup', '/remote/maps'], destination: 'Gameplay Admin / Map / Lifecycle', workspaceId: 'map', disposition: 'merge' },
  { currentFeature: 'Coriolis player card', currentRoutes: ['/gameplay?view=players'], destination: 'Gameplay Admin / Map / Coriolis', workspaceId: 'map', disposition: 'move' },
  { currentFeature: 'Database and backup catalog', currentRoutes: ['/database'], destination: 'Server Management / Data Protection', workspaceId: 'operations', disposition: 'remain' },
  { currentFeature: 'Sietches', currentRoutes: ['/sietches'], destination: 'Server Management / Topology', workspaceId: 'operations', disposition: 'remain' },
  { currentFeature: 'Settings', currentRoutes: ['/settings'], destination: 'Server Management / Settings', workspaceId: 'settings', disposition: 'remain' },
  { currentFeature: 'Setup Wizard', currentRoutes: ['/setup'], destination: 'Server Management / Setup', workspaceId: 'settings', disposition: 'remain' },
  { currentFeature: 'Solo Mode', currentRoutes: ['/solo'], destination: 'Separate local mode', workspaceId: 'solo', disposition: 'remain' },
  { currentFeature: 'Legacy reduced remote SPA', currentRoutes: ['/remote', '/remote/maps'], destination: 'Responsive full AppShell', workspaceId: 'home', disposition: 'replace' },
]

export function getWorkspace(id: WorkspaceId) {
  const workspace = WORKSPACE_MANIFEST.find(item => item.id === id)
  if (!workspace) throw new Error(`Unknown workspace: ${id}`)
  return workspace
}
