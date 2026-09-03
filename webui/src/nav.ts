import { GAMEPLAY_PATHS } from './platform/gameplay'

export type NavGroup = 'workspaces' | 'overview' | 'terminal' | 'data' | 'solo' | 'database' | 'system'

export type NavItem = {
  to: string
  sidebarTo?: string
  label: string
  icon: string  // lucide-react icon name
  group?: NavGroup
  // Optional small pill rendered after the label in the expanded sidebar
  // (e.g. "BETA"). Purely cosmetic.
  badge?: string
  // When true, this item is hidden from the sidebar / menubar for any
  // viewer that isn't on the host machine itself (e.g. a friend reaching
  // the portal remotely). The corresponding /api or /ws routes
  // MUST also enforce loopback-only on the server — the client filter is
  // just a UX hide, not a security boundary.
  localOnly?: boolean
  // Hide this item from the desktop sidebar while retaining it in other
  // navigation surfaces such as the classic top menu.
  sidebarHidden?: boolean
  // Keep this item visible in the desktop sidebar even when the user
  // customizes optional page visibility.
  sidebarAlwaysVisible?: boolean
  // Hide this item from a grouped desktop top-menu dropdown when another
  // top-menu affordance links directly to the same route.
  topMenuGroupHidden?: boolean
  // Owner-only items stay available on the host and to remote Owner accounts,
  // but are hidden from delegated remote Admin accounts. The API must enforce
  // the same boundary; this is only the navigation half.
  ownerOnly?: boolean
  windowsOnly?: boolean
  workspaceId?: string
  legacy?: boolean
  activePaths?: readonly string[]
  inactivePaths?: readonly string[]
}

export const LEGACY_NAV_ITEMS: readonly NavItem[] = [
  { to: '/',            label: 'Server Overview', icon: 'LayoutDashboard', group: 'overview', workspaceId: 'home', sidebarAlwaysVisible: true },
  { to: '/pods',        label: 'Pods',          icon: 'Boxes',           group: 'overview', legacy: true },
  { to: '/operations',  label: 'Operations',    icon: 'Activity',        group: 'overview', workspaceId: 'operations' },
  { to: '/commands',    label: 'Commands',     icon: 'Zap',             group: 'terminal', legacy: true },
  { to: '/map?view=lifecycle', label: 'Map SpinUp', icon: 'Globe',        group: 'terminal', legacy: true },
  { to: '/terminal',    label: 'PowerShell',   icon: 'SquareTerminal',  group: 'terminal', localOnly: true, sidebarHidden: true, legacy: true },
  { to: '/gameconfig',  label: 'Game Config',  icon: 'Sliders',         group: 'terminal', ownerOnly: true, legacy: true },
  { to: '/experimental', label: 'Experimental Lab', icon: 'FlaskConical', group: 'terminal', ownerOnly: true, legacy: true },
  { to: '/broadcasts',  label: 'Broadcasts',   icon: 'Megaphone',       group: 'terminal', legacy: true },
  { to: '/gameplay', sidebarTo: '/gameplay?view=overview', label: 'Gameplay Admin', icon: 'Gamepad2', group: 'workspaces', activePaths: GAMEPLAY_PATHS, inactivePaths: ['/map?view=lifecycle'] },
  { to: '/solo',        label: 'Solo Mode',      icon: 'Orbit',           group: 'solo', localOnly: true, windowsOnly: true, badge: 'Preview', legacy: true },
  { to: '/database',    label: 'Database',       icon: 'Database',        group: 'database', ownerOnly: true, legacy: true },
  { to: '/sietches',    label: 'Sietches',     icon: 'Network',         group: 'database', ownerOnly: true, legacy: true },
  { to: '/settings',    label: 'Settings',     icon: 'Settings',        group: 'system', ownerOnly: true, workspaceId: 'settings' },
  { to: '/sponsors',    label: 'Sponsors & Credits', icon: 'HeartHandshake', group: 'system', topMenuGroupHidden: true, sidebarAlwaysVisible: true, legacy: true },
  { to: '/setup',       label: 'Setup Wizard', icon: 'Wand2',           group: 'system', localOnly: true, sidebarHidden: true, legacy: true },
]

export const NAV_ITEMS: readonly NavItem[] = LEGACY_NAV_ITEMS

export const GROUP_ORDER: readonly NavGroup[] = ['overview', 'terminal', 'workspaces', 'solo', 'database', 'system'] as const

export const GROUP_LABELS: Record<NavGroup, string> = {
  workspaces: 'Gameplay Administration',
  overview: 'Server Management',
  terminal: 'Server Controls',
  data:     'Server Configuration',
  solo:     'Solo Mode',
  database: 'Server Data',
  system:   'System',
}

export function getVisibleGroupLabel(group: NavGroup) {
  return GROUP_LABELS[group]
}

// Icon shown for the whole group (used in collapsed sidebar + menubar headers).
export const GROUP_ICONS: Record<NavGroup, string> = {
  workspaces: 'LayoutGrid',
  overview: 'LayoutDashboard',
  terminal: 'SquareTerminal',
  data:     'Gamepad2',
  solo:     'Orbit',
  database: 'Database',
  system:   'Settings',
}

export function getVisibleNavItems({
  local,
  windows,
  canAccessOwnerSurfaces,
  includeSidebarHidden = true,
}: {
  local: boolean
  windows: boolean
  canAccessOwnerSurfaces: boolean
  includeSidebarHidden?: boolean
}) {
  return NAV_ITEMS
    .filter(item => includeSidebarHidden || !item.sidebarHidden)
    .filter(item => !item.localOnly || local)
    .filter(item => !item.ownerOnly || canAccessOwnerSurfaces)
    .filter(item => !item.windowsOnly || windows)
}

function routeMatches(route: string, pathname: string, search: string) {
  const [routePath, routeQuery = ''] = route.split('?', 2)
  const pathMatches = routePath === '/'
    ? pathname === '/'
    : pathname === routePath || pathname.startsWith(`${routePath}/`)
  if (!pathMatches || !routeQuery) return pathMatches

  const currentQuery = new URLSearchParams(search)
  const requiredQuery = new URLSearchParams(routeQuery)
  return Array.from(requiredQuery.entries()).every(([key, value]) => currentQuery.get(key) === value)
}

export function isNavItemActive(item: NavItem, pathname: string, search = '') {
  if (item.inactivePaths?.some(path => routeMatches(path, pathname, search))) return false
  const paths = item.activePaths ?? [item.to]
  return paths.some(path => routeMatches(path, pathname, search))
}
