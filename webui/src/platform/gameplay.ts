export type GameplaySectionId =
  | 'overview'
  | 'map'
  | 'players'
  | 'bases'
  | 'vehicles'
  | 'economy'

export type GameplayDestination = {
  id: GameplaySectionId
  label: string
  to: string
  icon: string
}

export const GAMEPLAY_DESTINATIONS: readonly GameplayDestination[] = [
  { id: 'overview', label: 'Overview', to: '/gameplay?view=overview', icon: 'LayoutGrid' },
  { id: 'map', label: 'Map', to: '/map', icon: 'Map' },
  { id: 'players', label: 'Players', to: '/players', icon: 'Users' },
  { id: 'bases', label: 'Bases', to: '/bases', icon: 'Castle' },
  { id: 'vehicles', label: 'Vehicles', to: '/vehicles', icon: 'Truck' },
  { id: 'economy', label: 'Economy', to: '/economy', icon: 'Landmark' },
] as const

export const GAMEPLAY_PATHS = [
  '/gameplay',
  '/map',
  '/players',
  '/bases',
  '/vehicles',
  '/economy',
] as const

const LEGACY_VIEW_SECTIONS: Readonly<Record<string, GameplaySectionId>> = {
  overview: 'overview',
  map: 'map',
  players: 'players',
  bases: 'bases',
  storage: 'players',
  blueprints: 'bases',
  vehicles: 'vehicles',
  economy: 'economy',
  market: 'economy',
  marketbot: 'economy',
  landsraad: 'economy',
}

const STORED_DESTINATION_KEY = 'dst.gameplay.lastDestination'
const FALLBACK_DESTINATION = '/gameplay?view=overview'
type GameplayStorage = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>

function currentOrigin() {
  return typeof window === 'undefined' ? 'https://dst.local' : window.location.origin
}

export function resolveGameplaySection(pathname: string, search = ''): GameplaySectionId {
  const direct = GAMEPLAY_DESTINATIONS.find(destination => (
    destination.id !== 'overview'
    && (pathname === destination.to || pathname.startsWith(`${destination.to}/`))
  ))
  if (direct) return direct.id
  const view = new URLSearchParams(search).get('view')
  return view ? LEGACY_VIEW_SECTIONS[view] ?? 'overview' : 'overview'
}

export function normalizeGameplayDestination(value: string, origin = currentOrigin()) {
  try {
    const input = value.trim()
    if (!input || input.startsWith('//')) return null
    const base = new URL(origin)
    const target = new URL(input, base)
    if (target.origin !== base.origin) return null
    if (!GAMEPLAY_PATHS.includes(target.pathname as typeof GAMEPLAY_PATHS[number])) return null

    if (target.pathname === '/gameplay') {
      const view = target.searchParams.get('view')
      if (view === null) target.searchParams.set('view', 'overview')
      else if (!Object.hasOwn(LEGACY_VIEW_SECTIONS, view)) return null
    }

    return `${target.pathname}${target.search}${target.hash}`
  } catch {
    return null
  }
}

export function isGameplayDestination(value: string, origin = currentOrigin()) {
  return normalizeGameplayDestination(value, origin) !== null
}

export function readLastGameplayDestination(storage: GameplayStorage = localStorage) {
  try {
    const stored = storage.getItem(STORED_DESTINATION_KEY)
    if (!stored) return FALLBACK_DESTINATION
    const normalized = normalizeGameplayDestination(stored)
    if (!normalized) {
      storage.removeItem(STORED_DESTINATION_KEY)
      return FALLBACK_DESTINATION
    }
    if (normalized !== stored) storage.setItem(STORED_DESTINATION_KEY, normalized)
    return normalized
  } catch {
    return FALLBACK_DESTINATION
  }
}

export function rememberGameplayDestination(
  destination: string,
  storage: Pick<Storage, 'setItem'> = localStorage,
) {
  const normalized = normalizeGameplayDestination(destination)
  if (!normalized) return
  try {
    storage.setItem(STORED_DESTINATION_KEY, normalized)
  } catch {
    // Navigation still works when browser storage is unavailable.
  }
}
