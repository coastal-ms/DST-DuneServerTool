export type NavGroup = 'overview' | 'terminal' | 'data' | 'database' | 'system'

export type NavItem = {
  to: string
  label: string
  icon: string  // lucide-react icon name
  group?: NavGroup
}

export const NAV_ITEMS: NavItem[] = [
  { to: '/',            label: 'Server Health', icon: 'LayoutDashboard', group: 'overview' },
  { to: '/commands',    label: 'Commands',     icon: 'Zap',             group: 'terminal' },
  { to: '/terminal',    label: 'PowerShell',   icon: 'SquareTerminal',  group: 'terminal' },
  { to: '/gameconfig',  label: 'Game Config',  icon: 'Sliders',         group: 'data' },
  { to: '/dd-map',      label: 'DD Map',       icon: 'Map',             group: 'data' },
  { to: '/database',    label: 'Database',     icon: 'Database',        group: 'database' },
  { to: '/sietches',    label: 'Sietches',     icon: 'Network',         group: 'database' },
  { to: '/map-spinup',  label: 'Map SpinUp',   icon: 'Globe',           group: 'database' },
  { to: '/settings',    label: 'Settings',     icon: 'Settings',        group: 'system' },
  { to: '/setup',       label: 'Setup Wizard', icon: 'Wand2',           group: 'system' },
]

export const GROUP_ORDER: readonly NavGroup[] = ['overview', 'terminal', 'data', 'database', 'system'] as const

export const GROUP_LABELS: Record<NavGroup, string> = {
  overview: 'Server Health',
  terminal: 'PowerShell',
  data:     'Game Data',
  database: 'Database',
  system:   'System',
}

// Icon shown for the whole group (used in collapsed sidebar + menubar headers).
export const GROUP_ICONS: Record<NavGroup, string> = {
  overview: 'LayoutDashboard',
  terminal: 'SquareTerminal',
  data:     'Gamepad2',
  database: 'Database',
  system:   'Settings',
}
