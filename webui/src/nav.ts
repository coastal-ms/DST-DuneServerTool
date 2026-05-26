export type NavItem = {
  to: string
  label: string
  icon: string  // lucide-react icon name
  group?: 'core' | 'data' | 'system'
}

export const NAV_ITEMS: NavItem[] = [
  { to: '/',            label: 'Dashboard',    icon: 'LayoutDashboard', group: 'core' },
  { to: '/monitoring',  label: 'Monitoring',   icon: 'Activity',        group: 'core' },
  { to: '/terminal',    label: 'Terminal',     icon: 'SquareTerminal',  group: 'core' },
  { to: '/characters',  label: 'Characters',   icon: 'Users',           group: 'data' },
  { to: '/gameconfig',  label: 'Game Config',  icon: 'Sliders',         group: 'data' },
  { to: '/database',    label: 'Database',     icon: 'Database',        group: 'data' },
  { to: '/sietches',    label: 'Sietches',     icon: 'Network',         group: 'data' },
  { to: '/settings',    label: 'Settings',     icon: 'Settings',        group: 'system' },
  { to: '/setup',       label: 'Setup Wizard', icon: 'Wand2',           group: 'system' },
]

export const GROUP_LABELS: Record<NonNullable<NavItem['group']>, string> = {
  core:   'Server',
  data:   'Game Data',
  system: 'System',
}
