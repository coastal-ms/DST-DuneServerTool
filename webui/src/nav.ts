export type NavGroup = 'overview' | 'terminal' | 'data' | 'solo' | 'database' | 'system'

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
  // Owner-only items stay available on the host and to remote Owner accounts,
  // but are hidden from delegated remote Admin accounts. The API must enforce
  // the same boundary; this is only the navigation half.
  ownerOnly?: boolean
  windowsOnly?: boolean
}

export const NAV_ITEMS: NavItem[] = [
  { to: '/',            label: 'Server Health', icon: 'LayoutDashboard', group: 'overview' },
  { to: '/pods',        label: 'Pods',          icon: 'Boxes',           group: 'overview' },
  { to: '/commands',    label: 'Commands',     icon: 'Zap',             group: 'terminal' },
  { to: '/terminal',    label: 'PowerShell',   icon: 'SquareTerminal',  group: 'terminal', localOnly: true },
  { to: '/gameconfig',  label: 'Game Config',  icon: 'Sliders',         group: 'data', ownerOnly: true },
  { to: '/experimental', label: 'Experimental Lab', icon: 'FlaskConical',   group: 'data', ownerOnly: true },
  { to: '/gameplay',    label: 'Gameplay Admin', icon: 'Gamepad2',        group: 'data' },
  { to: '/broadcasts',  label: 'Broadcasts',   icon: 'Megaphone',       group: 'data' },
  {
    to: '/dd-map',
    label: 'DD Seed Maps',
    icon: 'Map',
    group: 'data',
    badge: 'Experimental',
  },
  { to: '/solo',        label: 'Solo Mode',      icon: 'Orbit',           group: 'solo', localOnly: true, windowsOnly: true, badge: 'Preview' },
  { to: '/database',    label: 'Database',       icon: 'Database',        group: 'database', ownerOnly: true },
  { to: '/sietches',    label: 'Sietches',     icon: 'Network',         group: 'database', ownerOnly: true },
  { to: '/map-spinup',  label: 'Map SpinUp',   icon: 'Globe',           group: 'database' },
  { to: '/settings',    label: 'Settings',     icon: 'Settings',        group: 'system', ownerOnly: true },
  { to: '/setup',       label: 'Setup Wizard', icon: 'Wand2',           group: 'system', localOnly: true },
]

export const GROUP_ORDER: readonly NavGroup[] = ['overview', 'terminal', 'data', 'solo', 'database', 'system'] as const

export const GROUP_LABELS: Record<NavGroup, string> = {
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
  overview: 'LayoutDashboard',
  terminal: 'SquareTerminal',
  data:     'Gamepad2',
  solo:     'Orbit',
  database: 'Database',
  system:   'Settings',
}
