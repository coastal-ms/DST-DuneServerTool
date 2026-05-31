export type NavItem = {
  to: string
  label: string
  icon: string  // lucide-react icon name
  group?: 'overview' | 'terminal' | 'data' | 'system'
  // When set, clicking runs an action instead of navigating. 'launch-dune-admin'
  // starts dune-admin (if not already running) and opens its players web UI.
  action?: 'launch-dune-admin'
}

export const NAV_ITEMS: NavItem[] = [
  { to: '/',            label: 'Server Health', icon: 'LayoutDashboard', group: 'overview' },
  { to: '/commands',    label: 'Commands',     icon: 'Zap',             group: 'terminal' },
  { to: '/terminal',    label: 'PowerShell',   icon: 'SquareTerminal',  group: 'terminal' },
  { to: 'http://localhost:8080/#/players', label: 'Characters', icon: 'Users', group: 'data', action: 'launch-dune-admin' },
  { to: '/gameconfig',  label: 'Game Config',  icon: 'Sliders',         group: 'data' },
  { to: '/database',    label: 'Database',     icon: 'Database',        group: 'data' },
  { to: '/sietches',    label: 'Sietches',     icon: 'Network',         group: 'data' },
  { to: '/dd-map',      label: 'DD Map',       icon: 'Map',             group: 'data' },
  { to: '/settings',    label: 'Settings',     icon: 'Settings',        group: 'system' },
  { to: '/setup',       label: 'Setup Wizard', icon: 'Wand2',           group: 'system' },
]

export const GROUP_LABELS: Record<NonNullable<NavItem['group']>, string> = {
  overview: 'Server Health',
  terminal: 'PowerShell',
  data:     'Game Data',
  system:   'System',
}
