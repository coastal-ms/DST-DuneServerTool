import { getVisibleNavItems, type NavItem } from '../nav'
import { WORKSPACE_MANIFEST } from '../platform/workspaces'

const TASK_COPY: Record<string, { description: string; keywords: string }> = {
  '/': { description: 'See the server and choose your next task.', keywords: 'home health status' },
  '/pods': { description: 'Inspect workloads and their reported state.', keywords: 'logs containers k3s failures' },
  '/operations': { description: 'Review runtime activity and maintenance tools.', keywords: 'runtime maintenance' },
  '/commands': { description: 'Choose a server action and review its safeguards.', keywords: 'start stop restart update' },
  '/database': { description: 'Manage backups, restores, and database queries.', keywords: 'backup restore sql protection' },
  '/players': {
    description: 'Inspect players, inventory, progression, and community tools.',
    keywords: 'give item grant ammo augments skills chat commands welcome back shared destinations teleport tp',
  },
  '/bases': { description: 'Inspect claims, ownership, and base inventory.', keywords: 'buildings claims' },
  '/vehicles': { description: 'Inspect the fleet and vehicle inventory.', keywords: 'ornithopter buggy cargo' },
  '/economy': { description: 'Review market and governance tools.', keywords: 'market trade landsraad' },
  '/map': { description: 'Explore the atlas and map workspace.', keywords: 'deep desert atlas' },
  '/map?view=atlas': { description: 'Open the static Deep Desert atlas.', keywords: 'deep desert atlas map' },
  '/gameplay': { description: 'Open all gameplay administration views.', keywords: 'storage blueprints market landsraad' },
  '/gameconfig': { description: 'Review and edit server configuration.', keywords: 'ini settings' },
  '/broadcasts': { description: 'Send a message through the existing broadcast tools.', keywords: 'message announcement' },
  '/solo': { description: 'Work with local Solo saves and inventory.', keywords: 'ptc single player' },
  '/settings': { description: 'Configure DST, connections, and remote access.', keywords: 'appearance theme remote accounts updates' },
}

const STATIC_DECK_DESTINATIONS: NavItem[] = [
  { to: '/map?view=atlas', label: 'DD Atlas', icon: 'Map' },
]

export type DeckDestination = NavItem & { description: string; keywords: string }

export const DECK_TASK_LABELS: Record<string, string> = {
  '/players': 'Inspect a player',
  '/bases': 'Explore base inventory',
  '/vehicles': 'Inspect the vehicle fleet',
  '/database': 'Manage backups',
  '/commands': 'Manage server lifecycle',
  '/map': 'Explore the world map',
}

export function getDeckDestinations(access: Parameters<typeof getVisibleNavItems>[0]): DeckDestination[] {
  const visible = getVisibleNavItems(access)
  const seen = new Set(visible.map(item => item.to))
  const workspaces: NavItem[] = WORKSPACE_MANIFEST
    .filter(item => !seen.has(item.path) && (item.visibility !== 'owner' || access.canAccessOwnerSurfaces))
    .map(item => ({
      to: item.path, label: item.label, icon: item.icon,
      ownerOnly: item.visibility === 'owner',
    }))
  const staticDestinations = STATIC_DECK_DESTINATIONS.filter(item => !seen.has(item.to))
  return [...visible, ...workspaces, ...staticDestinations].map(item => ({
    ...item,
    description: TASK_COPY[item.to]?.description ?? `Open ${item.label}.`,
    keywords: TASK_COPY[item.to]?.keywords ?? '',
  }))
}

export function searchDeck(destinations: DeckDestination[], query: string) {
  const words = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean)
  if (!words.length) return destinations
  return destinations.filter(item => {
    const text = `${item.label} ${item.description} ${item.keywords}`.toLocaleLowerCase()
    return words.every(word => text.includes(word))
  })
}
