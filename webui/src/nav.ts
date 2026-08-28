import { WORKSPACE_MANIFEST } from './platform/workspaces'

export type NavGroup = 'workspaces' | 'overview' | 'terminal' | 'data' | 'solo' | 'database' | 'system'

export type NavItem = {
  to: string
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
  // Owner-only items stay available on the host and to remote Owner accounts,
  // but are hidden from delegated remote Admin accounts. The API must enforce
  // the same boundary; this is only the navigation half.
  ownerOnly?: boolean
  windowsOnly?: boolean
  workspaceId?: string
  legacy?: boolean
}

export const WORKSPACE_NAV_ITEMS: readonly NavItem[] = WORKSPACE_MANIFEST.map(workspace => ({
  to: workspace.path,
  label: workspace.label,
  icon: workspace.icon,
  group: 'workspaces',
  ownerOnly: workspace.visibility === 'owner',
  workspaceId: workspace.id,
}))

export const LEGACY_NAV_ITEMS: readonly NavItem[] = [
  { to: '/',            label: 'Server Health', icon: 'LayoutDashboard', group: 'overview', legacy: true },
  { to: '/pods',        label: 'Pods',          icon: 'Boxes',           group: 'overview', legacy: true },
  { to: '/commands',    label: 'Commands',     icon: 'Zap',             group: 'terminal', legacy: true },
  { to: '/terminal',    label: 'PowerShell',   icon: 'SquareTerminal',  group: 'terminal', localOnly: true, sidebarHidden: true, legacy: true },
  { to: '/gameconfig',  label: 'Game Config',  icon: 'Sliders',         group: 'data', ownerOnly: true, legacy: true },
  { to: '/experimental', label: 'Experimental Lab', icon: 'FlaskConical', group: 'data', ownerOnly: true, legacy: true },
  { to: '/gameplay',    label: 'Gameplay Admin', icon: 'Gamepad2',       group: 'data', legacy: true },
  { to: '/broadcasts',  label: 'Broadcasts',   icon: 'Megaphone',       group: 'data', legacy: true },
  {
    to: '/dd-map',
    label: 'DD Seed Maps',
    icon: 'Map',
    group: 'data',
    badge: 'Experimental',
    legacy: true,
  },
  { to: '/solo',        label: 'Solo Mode',      icon: 'Orbit',           group: 'solo', localOnly: true, windowsOnly: true, badge: 'Preview', legacy: true },
  { to: '/database',    label: 'Database',       icon: 'Database',        group: 'database', ownerOnly: true, legacy: true },
  { to: '/sietches',    label: 'Sietches',     icon: 'Network',         group: 'database', ownerOnly: true, legacy: true },
  { to: '/map-spinup',  label: 'Map SpinUp',   icon: 'Globe',           group: 'database', legacy: true },
  { to: '/settings',    label: 'Settings',     icon: 'Settings',        group: 'system', ownerOnly: true, legacy: true },
  { to: '/setup',       label: 'Setup Wizard', icon: 'Wand2',           group: 'system', localOnly: true, legacy: true },
]

export const NAV_ITEMS: readonly NavItem[] = [...WORKSPACE_NAV_ITEMS, ...LEGACY_NAV_ITEMS]

export const GROUP_ORDER: readonly NavGroup[] = ['workspaces', 'overview', 'terminal', 'data', 'solo', 'database', 'system'] as const

export const GROUP_LABELS: Record<NavGroup, string> = {
  workspaces: 'Workspaces',
  overview: 'Server Health',
  terminal: 'Commands',
  data:     'Game Data',
  solo:     'Solo Mode',
  database: 'Database',
  system:   'System',
}

export function getVisibleGroupLabel(group: NavGroup, items: readonly NavItem[]) {
  if (group === 'database' && items.length === 1 && items[0].to === '/map-spinup') {
    return 'Map Management'
  }
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
