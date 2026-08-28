import type { LazyPageModule } from './workspaces'

export type RouteAccess = 'all' | 'owner' | 'local' | 'local-windows' | 'setup'

export type LazyRouteDefinition = {
  path: string
  label: string
  access: RouteAccess
  load: () => Promise<LazyPageModule>
}

export const LEGACY_ROUTE_MANIFEST: readonly LazyRouteDefinition[] = [
  { path: '/pods', label: 'Pods', access: 'all', load: () => import('../pages/Pods').then(module => ({ default: module.Pods })) },
  { path: '/commands', label: 'Commands', access: 'all', load: () => import('../pages/Commands').then(module => ({ default: module.Commands })) },
  { path: '/terminal', label: 'Terminal', access: 'local', load: () => import('../pages/Terminal').then(module => ({ default: module.TerminalPage })) },
  { path: '/gameconfig', label: 'Game Config', access: 'owner', load: () => import('../pages/GameConfig').then(module => ({ default: module.GameConfig })) },
  { path: '/experimental', label: 'Experimental Lab', access: 'owner', load: () => import('../pages/workspaces/ExperimentalWorkspace') },
  { path: '/gameplay', label: 'Gameplay Admin', access: 'all', load: () => import('../pages/GameplayEnvironment').then(module => ({ default: module.GameplayEnvironment })) },
  { path: '/broadcasts', label: 'Broadcasts', access: 'all', load: () => import('../pages/Broadcasts').then(module => ({ default: module.Broadcasts })) },
  { path: '/solo', label: 'Solo Mode', access: 'local-windows', load: () => import('../pages/SoloMode').then(module => ({ default: module.SoloMode })) },
  { path: '/database', label: 'Database', access: 'owner', load: () => import('../pages/Database').then(module => ({ default: module.Database })) },
  { path: '/sietches', label: 'Sietches', access: 'owner', load: () => import('../pages/Sietches').then(module => ({ default: module.Sietches })) },
  { path: '/setup', label: 'Setup Wizard', access: 'setup', load: () => import('../pages/SetupWizard').then(module => ({ default: module.SetupWizard })) },
]

export const COMPATIBILITY_REDIRECTS = [
  { from: '/home', to: '/' },
  { from: '/monitoring', to: '/' },
  { from: '/dd-map', to: '/map?view=atlas' },
  { from: '/wick-maps', to: '/map?view=atlas' },
  { from: '/map-spinup', to: '/map?view=lifecycle' },
] as const

export const LEGACY_REMOTE_MAP_ROUTE = '/remote/maps'
export const LEGACY_REMOTE_MAP_DESTINATION = '/map?view=lifecycle'

export function shouldRedirectLegacyRemoteMap(accountLoginEnabled: boolean) {
  return accountLoginEnabled
}

export function resolveCompatibilityRedirect(path: string) {
  return COMPATIBILITY_REDIRECTS.find(route => route.from === path)?.to ?? null
}
