import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ApiError } from '../../api/client'
import {
  getSharedInventory,
  getSharedInventoryOccurrences,
  type InventoryEntityType,
  type SharedInventoryGroup,
  type SharedInventoryItem,
  type SharedInventoryLocationFacet,
  type SharedInventoryOccurrenceSort,
  type SharedInventoryResponse,
  type SharedInventorySort,
} from '../../api/gameplay'
import { usePlatformCapabilities } from '../../hooks/usePlatformCapabilities'
import { Link, useSearch } from '../../router'
import { Icon } from '../Icon'
import { DataState, FreshnessBadge } from '../platform/DataState'
import { DetailPanel } from '../platform/DetailPanel'
import { WorkspaceSection } from '../platform/WorkspaceLayout'
import { itemDetailsUrl, resolveItemIcon } from './InventoryItemIcon'
import { InventorySlot } from './InventorySlot'

const catalogSorts: Array<{ value: SharedInventorySort; label: string }> = [
  { value: 'name-asc', label: 'Name A-Z' },
  { value: 'name-desc', label: 'Name Z-A' },
  { value: 'quantity-desc', label: 'Total quantity: high to low' },
  { value: 'quantity-asc', label: 'Total quantity: low to high' },
  { value: 'unit-volume-desc', label: 'Unit volume: high to low' },
  { value: 'unit-volume-asc', label: 'Unit volume: low to high' },
  { value: 'total-volume-desc', label: 'Total volume: high to low' },
  { value: 'total-volume-asc', label: 'Total volume: low to high' },
  { value: 'tier-desc', label: 'Tier: high to low' },
  { value: 'tier-asc', label: 'Tier: low to high' },
  { value: 'quality-desc', label: 'Quality: high to low' },
  { value: 'quality-asc', label: 'Quality: low to high' },
  { value: 'occurrences-desc', label: 'Occurrences: high to low' },
  { value: 'occurrences-asc', label: 'Occurrences: low to high' },
  { value: 'locations-desc', label: 'Locations: high to low' },
  { value: 'locations-asc', label: 'Locations: low to high' },
]

const occurrenceSorts: Array<{ value: SharedInventoryOccurrenceSort; label: string }> = [
  { value: 'player-asc', label: 'Player A-Z' },
  { value: 'player-desc', label: 'Player Z-A' },
  { value: 'location-asc', label: 'Location A-Z' },
  { value: 'location-desc', label: 'Location Z-A' },
  { value: 'quantity-desc', label: 'Quantity: high to low' },
  { value: 'quantity-asc', label: 'Quantity: low to high' },
  { value: 'quality-desc', label: 'Quality: high to low' },
  { value: 'quality-asc', label: 'Quality: low to high' },
]

function errorMessage(error: unknown) {
  return error instanceof ApiError ? error.message : error instanceof Error ? error.message : String(error)
}

function entityTypeLabel(type: InventoryEntityType) {
  return type === 'player' ? 'Backpack' : 'Storage box'
}

function valueOrNotReported(value: string) {
  return value && value !== 'N/A' ? value : 'Not reported'
}

function parsePositiveId(value: string | null) {
  if (!value || !/^\d+$/.test(value)) return undefined
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined
}

function setUrlFilters(changes: Record<string, string | undefined>) {
  const params = new URLSearchParams(window.location.search)
  Object.entries(changes).forEach(([key, value]) => {
    if (value) params.set(key, value)
    else params.delete(key)
  })
  const next = `${window.location.pathname}${params.size ? `?${params}` : ''}`
  window.history.pushState(null, '', next)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

function locationValue(location?: { type: InventoryEntityType; id: number } | null) {
  return location ? `${location.type}:${location.id}` : ''
}

function locationLabel(location: SharedInventoryLocationFacet, allPlayers: boolean, duplicateOrdinal = 0) {
  const base = location.type === 'player' ? 'Backpack' : location.label || 'Storage box'
  const owner = location.playerName || location.owner
  const owned = allPlayers && owner ? `${base} - ${owner}` : base
  return duplicateOrdinal > 0 ? `${owned} (${duplicateOrdinal})` : owned
}

function duplicateOrdinals<T>(items: T[], labelOf: (item: T) => string, keyOf: (item: T) => string) {
  const counts = new Map<string, number>()
  const seen = new Map<string, number>()
  const ordinals = new Map<string, number>()
  items.forEach(item => {
    const label = labelOf(item)
    counts.set(label, (counts.get(label) ?? 0) + 1)
  })
  items.forEach(item => {
    const label = labelOf(item)
    if ((counts.get(label) ?? 0) < 2) return
    const ordinal = (seen.get(label) ?? 0) + 1
    seen.set(label, ordinal)
    ordinals.set(keyOf(item), ordinal)
  })
  return ordinals
}

export function SharedInventoryExplorer({
  entityTypes,
  title = 'Shared Inventory Explorer',
  description = 'Browse distinct item types across proven player backpacks and storage locations from one read-only view.',
  unavailableReason,
}: {
  entityTypes: InventoryEntityType[]
  title?: string
  description?: string
  unavailableReason?: string
}) {
  const search = useSearch()
  const params = useMemo(() => new URLSearchParams(search), [search])
  const requestedScopeType = params.get('scope_type')
  const requestedScopeId = params.get('scope_id')
  const parsedScopeId = parsePositiveId(requestedScopeId)
  const hasScopeType = params.has('scope_type')
  const hasScopeId = params.has('scope_id')
  const validScopeType = requestedScopeType === 'player' || requestedScopeType === 'storage'
  const scopeError = hasScopeType !== hasScopeId
    ? 'Both scope_type and scope_id are required for a scoped inventory link.'
    : hasScopeType && (!validScopeType || !entityTypes.includes(requestedScopeType as InventoryEntityType))
      ? 'The requested inventory scope type is not supported in this workspace.'
      : hasScopeId && !parsedScopeId ? 'The requested inventory scope ID must be a positive integer.' : ''
  const scopeType = !scopeError && validScopeType ? requestedScopeType as InventoryEntityType : undefined
  const scopeId = !scopeError ? parsedScopeId : undefined
  const requestedPlayerId = params.get('player_id')
  const playerId = parsePositiveId(requestedPlayerId)
  const playerError = params.has('player_id') && !playerId
    ? 'The requested player ID must be a positive integer.'
    : ''
  const requestedLocationType = params.get('location_type')
  const locationType = requestedLocationType === 'player' || requestedLocationType === 'storage'
    ? requestedLocationType : undefined
  const locationId = parsePositiveId(params.get('location_id'))
  const locationError = params.has('location_type') !== params.has('location_id')
    || (params.has('location_type') && (!locationType || !locationId))
  const query = params.get('q') ?? ''
  const sort = catalogSorts.some(option => option.value === params.get('sort'))
    ? params.get('sort') as SharedInventorySort : 'name-asc'
  const demo = ['1', 'true', 'yes'].includes((params.get('demo') ?? '').toLowerCase())
  const [draftQuery, setDraftQuery] = useState(query)
  const [response, setResponse] = useState<SharedInventoryResponse | null>(null)
  const [groups, setGroups] = useState<SharedInventoryGroup[]>([])
  const [selected, setSelected] = useState<SharedInventoryGroup | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState('')
  const [loadedIdentity, setLoadedIdentity] = useState('')
  const requestVersion = useRef(0)
  const capabilities = usePlatformCapabilities()
  const capabilityReady = capabilities.data !== null
  const canReadInventory = capabilities.hasCapability('inventory.read')
  const requestIdentity = JSON.stringify({
    query: query.trim(), entityTypes, scopeType, scopeId, playerId, locationType, locationId, sort,
    source: demo ? 'demo' : 'live', scopeError, playerError, locationError,
  })
  const current = loadedIdentity === requestIdentity ? response : null
  const currentGroups = loadedIdentity === requestIdentity ? groups : []
  const playerOrdinals = useMemo(() => duplicateOrdinals(
    current?.data.players ?? [], player => player.name, player => String(player.id),
  ), [current])
  const locationOrdinals = useMemo(() => duplicateOrdinals(
    current?.data.locations ?? [], location => location.label, location => `${location.type}:${location.id}`,
  ), [current])

  const load = useCallback(async (cursor?: string, append = false) => {
    if (!canReadInventory || unavailableReason || scopeError || playerError || locationError) return
    const version = ++requestVersion.current
    if (append) setLoadingMore(true)
    else {
      setLoading(true)
      setResponse(null)
      setGroups([])
      setSelected(null)
      setLoadedIdentity('')
    }
    setError('')
    try {
      const result = await getSharedInventory({
        q: query.trim(), types: entityTypes, scopeType, scopeId, playerId, locationType, locationId,
        sort, limit: 100, cursor, demo,
      })
      if (version !== requestVersion.current) return
      setResponse(result)
      setGroups(existing => append ? [...existing, ...result.data.groups] : result.data.groups)
      setLoadedIdentity(requestIdentity)
    } catch (reason) {
      if (version !== requestVersion.current) return
      setResponse(null)
      setGroups([])
      setSelected(null)
      setLoadedIdentity('')
      setError(errorMessage(reason))
    } finally {
      if (version === requestVersion.current) {
        setLoading(false)
        setLoadingMore(false)
      }
    }
  }, [
    canReadInventory, demo, entityTypes, locationError, locationId, locationType, playerError, playerId, query,
    requestIdentity, scopeError, scopeId, scopeType, sort, unavailableReason,
    setError, setGroups, setLoadedIdentity, setLoading, setLoadingMore, setResponse, setSelected,
  ])

  useEffect(() => setDraftQuery(query), [query])
  useEffect(() => {
    requestVersion.current += 1
    setResponse(null)
    setGroups([])
    setSelected(null)
    setError('')
    setLoadedIdentity('')
    setLoadingMore(false)
  }, [requestIdentity])
  useEffect(() => {
    if (capabilityReady && canReadInventory && !unavailableReason && !scopeError && !playerError && !locationError) void load()
  }, [capabilityReady, canReadInventory, load, locationError, playerError, scopeError, unavailableReason])
  useEffect(() => () => { requestVersion.current += 1 }, [])

  if (unavailableReason) {
    return <WorkspaceSection id="shared-inventory" title={title} description={description}><DataState state="unavailable" title="Inventory scope not yet available" message={unavailableReason} /></WorkspaceSection>
  }
  if (scopeError || playerError || locationError) {
    return <WorkspaceSection id="shared-inventory" title={title} description={description}><DataState state="error" title="Invalid inventory scope" message={scopeError || playerError || 'Both location_type and location_id must identify a supported location.'} /></WorkspaceSection>
  }
  if (!capabilityReady && capabilities.loading) {
    return <WorkspaceSection id="shared-inventory" title={title} description={description}><DataState state="loading" title="Checking inventory access" /></WorkspaceSection>
  }
  if (!capabilityReady && capabilities.error) {
    return <WorkspaceSection id="shared-inventory" title={title} description={description}><DataState state="error" title="Could not check inventory access" message={capabilities.error} action={<button className="btn-secondary min-h-11" onClick={() => { void capabilities.refresh() }}>Retry capability check</button>} /></WorkspaceSection>
  }
  if (capabilityReady && !canReadInventory) {
    return <WorkspaceSection id="shared-inventory" title={title} description={description}><DataState state="unavailable" title="Shared inventory is not included in this backend" message="Install the matching DST backend build to use the read-only inventory explorer." /></WorkspaceSection>
  }

  const validSelectedLocation = !locationType || current?.data.selectedLocationValid !== false

  return (
    <WorkspaceSection id="shared-inventory" title={title} description={description}>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <span className="pill border-info/40 text-info">Read-only</span>
        {entityTypes.map(type => <span key={type} className="pill border-border text-text-muted">{type === 'player' ? 'Player backpacks' : 'Storage boxes'}</span>)}
        {current && <FreshnessBadge state={current.freshness.state} observedAt={current.freshness.observedAt} label={current.data.mode === 'demo' ? 'Demo inventory' : 'Live database'} />}
      </div>
      {scopeType && scopeId && <div className="mb-3 rounded-lg border border-info/35 bg-info/10 px-4 py-3 text-sm text-text" role="status">Scoped to {entityTypeLabel(scopeType).toLowerCase()} actor {scopeId}.</div>}
      <form
        className="card mb-4 grid min-w-0 grid-cols-1 gap-3 p-4 sm:grid-cols-2 xl:grid-cols-[minmax(15rem,1fr)_minmax(10rem,.55fr)_minmax(10rem,.55fr)_minmax(12rem,.7fr)_auto_auto] xl:items-end"
        role="search"
        onSubmit={event => {
          event.preventDefault()
          if (draftQuery === query) void load()
          else setUrlFilters({ q: draftQuery.trim() || undefined })
        }}
      >
        <label className="min-w-0 text-sm font-medium text-text">
          Search inventory
          <input className="input mt-1 min-h-11 w-full" value={draftQuery} maxLength={200} placeholder="Item, owner, or location" onChange={event => setDraftQuery(event.target.value)} />
        </label>
        <label className="min-w-0 text-sm font-medium text-text">
          Player
          <select
            aria-label="Player"
            className="input mt-1 min-h-11 w-full"
            value={playerId ?? ''}
            onChange={event => setUrlFilters({ player_id: event.target.value || undefined, location_type: undefined, location_id: undefined })}
          >
            <option value="">All players</option>
            {current?.data.players.map(player => {
              const ordinal = playerOrdinals.get(String(player.id))
              return <option key={player.id} value={player.id}>{player.name || 'Unnamed player'}{ordinal ? ` (${ordinal})` : ''}</option>
            })}
          </select>
        </label>
        <label className="min-w-0 text-sm font-medium text-text">
          Location
          <select
            aria-label="Location"
            className="input mt-1 min-h-11 w-full"
            value={validSelectedLocation ? locationValue(locationType && locationId ? { type: locationType, id: locationId } : null) : ''}
            onChange={event => {
              const [type, id] = event.target.value.split(':')
              setUrlFilters({ location_type: type || undefined, location_id: id || undefined })
            }}
          >
            <option value="">All locations</option>
            {current?.data.locations.map(location => (
              <option key={`${location.type}:${location.id}`} value={locationValue(location)}>
                {locationLabel(
                  location,
                  !playerId,
                  locationOrdinals.get(`${location.type}:${location.id}`) ?? 0,
                )}
              </option>
            ))}
          </select>
        </label>
        <label className="min-w-0 text-sm font-medium text-text">
          Sort by
          <select aria-label="Sort by" className="input mt-1 min-h-11 w-full" value={sort} onChange={event => setUrlFilters({ sort: event.target.value === 'name-asc' ? undefined : event.target.value })}>
            {catalogSorts.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        <button type="submit" className="btn-primary min-h-11" disabled={loading || loadingMore}><Icon name="Search" size={15} />Search</button>
        <button type="button" className="btn-secondary min-h-11" disabled={loading || loadingMore} onClick={() => { void load() }}><Icon name="RefreshCw" size={14} />Refresh</button>
      </form>

      {locationType && current && !validSelectedLocation && <DataState state="error" title="Location does not match this player" message="Choose a location available to the selected player." />}
      {current?.data.mode === 'demo' && <DataState state="fresh" title="Showing bundled demo inventory" message="Demo mode was explicitly requested; these grouped items are examples and not live server contents." />}
      {error && <div className="mb-4"><DataState state="error" title="Inventory search failed" message={error} action={<button className="btn-secondary min-h-11" onClick={() => { void load() }}>Retry</button>} /></div>}
      {loading && currentGroups.length === 0 && !error && <DataState state="loading" title="Loading inventory catalog" />}
      {!loading && !error && current && currentGroups.length === 0 && <DataState state="empty" title="No matching inventory items" message="Try another item, player, location, or source filter." />}
      {currentGroups.length > 0 && (
        <>
          <ul className="grid min-w-0 grid-cols-[repeat(auto-fill,minmax(min(6.5rem,100%),1fr))] gap-2.5" aria-label="Inventory results">
            {currentGroups.map(group => <li key={group.groupKey} className="min-w-0"><InventorySlot item={group} onSelect={setSelected} /></li>)}
          </ul>
          {current?.page.nextCursor && <div className="mt-4 flex justify-center"><button className="btn-secondary min-h-11" disabled={loadingMore} onClick={() => { void load(current.page.nextCursor ?? undefined, true) }}><Icon name={loadingMore ? 'Loader2' : 'ChevronDown'} size={14} className={loadingMore ? 'animate-spin' : undefined} />{loadingMore ? 'Loading...' : 'Load more items'}</button></div>}
        </>
      )}
      <OccurrencePanel
        group={selected}
        players={current?.data.players ?? []}
        locations={current?.data.locations ?? []}
        initialPlayerId={playerId}
        initialLocation={locationType && locationId ? { type: locationType, id: locationId } : undefined}
        entityTypes={entityTypes}
        scopeType={scopeType}
        scopeId={scopeId}
        demo={demo}
        onClose={() => setSelected(null)}
      />
    </WorkspaceSection>
  )
}

function OccurrencePanel({
  group, players, locations, initialPlayerId, initialLocation, entityTypes, scopeType, scopeId, demo, onClose,
}: {
  group: SharedInventoryGroup | null
  players: SharedInventoryResponse['data']['players']
  locations: SharedInventoryLocationFacet[]
  initialPlayerId?: number
  initialLocation?: { type: InventoryEntityType; id: number }
  entityTypes: InventoryEntityType[]
  scopeType?: InventoryEntityType
  scopeId?: number
  demo: boolean
  onClose: () => void
}) {
  const [playerId, setPlayerId] = useState<number | undefined>(initialPlayerId)
  const [location, setLocation] = useState(initialLocation)
  const [sort, setSort] = useState<SharedInventoryOccurrenceSort>('player-asc')
  const [items, setItems] = useState<SharedInventoryItem[]>([])
  const [panelPlayers, setPanelPlayers] = useState(players)
  const [panelLocations, setPanelLocations] = useState(locations)
  const [nextCursor, setNextCursor] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [verifiedDetailsUrl, setVerifiedDetailsUrl] = useState<string | null>(null)
  const version = useRef(0)
  const initialLocationType = initialLocation?.type
  const initialLocationId = initialLocation?.id
  const identity = JSON.stringify({ templateId: group?.templateId, playerId, location, sort, scopeType, scopeId, demo })
  const playerOrdinals = useMemo(() => duplicateOrdinals(
    panelPlayers, player => player.name, player => String(player.id),
  ), [panelPlayers])
  const filteredLocations = useMemo(
    () => panelLocations.filter(candidate => !playerId || candidate.playerId === playerId),
    [panelLocations, playerId],
  )
  const locationOrdinals = useMemo(() => duplicateOrdinals(
    filteredLocations, location => location.label, location => `${location.type}:${location.id}`,
  ), [filteredLocations])

  const load = useCallback(async (cursor?: string, append = false) => {
    if (!group) return
    const request = ++version.current
    setLoading(true)
    setError('')
    if (!append) {
      setItems([])
      setNextCursor(null)
    }
    try {
      const result = await getSharedInventoryOccurrences({
        templateId: group.templateId, types: entityTypes, scopeType, scopeId, playerId,
        locationType: location?.type, locationId: location?.id, sort, limit: 50, cursor, demo,
      })
      if (request !== version.current) return
      setItems(current => append ? [...current, ...result.data.items] : result.data.items)
      setNextCursor(result.page.nextCursor)
      setPanelPlayers(current => {
        if (!playerId || result.data.players.some(player => player.id === playerId)) return result.data.players
        const active = current.find(player => player.id === playerId)
        return active ? [...result.data.players, active] : result.data.players
      })
      setPanelLocations(current => {
        if (!location || result.data.locations.some(candidate => candidate.type === location.type && candidate.id === location.id)) {
          return result.data.locations
        }
        const active = current.find(candidate => candidate.type === location.type && candidate.id === location.id)
        return active ? [...result.data.locations, active] : result.data.locations
      })
    } catch (reason) {
      if (request === version.current) setError(errorMessage(reason))
    } finally {
      if (request === version.current) setLoading(false)
    }
  }, [demo, entityTypes, group, location, playerId, scopeId, scopeType, sort])

  useEffect(() => {
    setPlayerId(initialPlayerId)
    setLocation(current => {
      if (!initialLocationType || !initialLocationId) return undefined
      if (current?.type === initialLocationType && current.id === initialLocationId) return current
      return { type: initialLocationType, id: initialLocationId }
    })
    setSort('player-asc')
    setPanelPlayers(players)
    setPanelLocations(locations)
  }, [group?.groupKey, initialLocationId, initialLocationType, initialPlayerId, locations, players])
  useEffect(() => {
    version.current += 1
    setItems([])
    setNextCursor(null)
    setError('')
    if (group) void load()
  }, [identity, group, load])
  useEffect(() => {
    setVerifiedDetailsUrl(null)
    if (!group) return
    let active = true
    void resolveItemIcon(group.templateId).then(icon => {
      if (active && icon) setVerifiedDetailsUrl(itemDetailsUrl(group.templateId))
    })
    return () => { active = false }
  }, [group])

  return (
    <DetailPanel open={group !== null} title={group?.displayName || group?.templateId || 'Inventory item'} onClose={onClose}>
      {group && (
        <div className="min-w-0">
          <div className="mb-4 flex flex-wrap gap-2">
            <span className="pill border-info/40 text-info">Read-only</span>
            <span className="pill border-border">x{group.totalQuantity} total</span>
            <span className="pill border-border">{group.occurrenceCount} occurrences</span>
            <span className="pill border-border">{group.locationCount} locations</span>
          </div>
          <p className="mb-4 break-all font-mono text-xs text-text-muted">{group.templateId}</p>
          <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
            <label className="text-sm font-medium text-text">Player
              <select aria-label="Occurrence player" className="input mt-1 min-h-11 w-full" value={playerId ?? ''} onChange={event => {
                setPlayerId(parsePositiveId(event.target.value))
                setLocation(undefined)
              }}>
                <option value="">All players</option>
                {panelPlayers.map(player => {
                  const ordinal = playerOrdinals.get(String(player.id))
                  return <option key={player.id} value={player.id}>{player.name || 'Unnamed player'}{ordinal ? ` (${ordinal})` : ''}</option>
                })}
              </select>
            </label>
            <label className="text-sm font-medium text-text">Location
              <select aria-label="Occurrence location" className="input mt-1 min-h-11 w-full" value={locationValue(location)} onChange={event => {
                const [type, id] = event.target.value.split(':')
                setLocation(type && id ? { type: type as InventoryEntityType, id: Number(id) } : undefined)
              }}>
                <option value="">All locations</option>
                {filteredLocations.map(option => <option key={`${option.type}:${option.id}`} value={locationValue(option)}>{locationLabel(option, !playerId, locationOrdinals.get(`${option.type}:${option.id}`) ?? 0)}</option>)}
              </select>
            </label>
            <label className="text-sm font-medium text-text">Sort occurrences
              <select aria-label="Sort occurrences" className="input mt-1 min-h-11 w-full" value={sort} onChange={event => setSort(event.target.value as SharedInventoryOccurrenceSort)}>
                {occurrenceSorts.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}
              </select>
            </label>
          </div>
          {error && <DataState state="error" title="Could not load occurrences" message={error} />}
          {loading && items.length === 0 && <DataState state="loading" title="Loading occurrences" />}
          {!loading && !error && items.length === 0 && <DataState state="empty" title="No matching occurrences" message="Try another player or location." />}
          {items.length > 0 && (
            <ul className="divide-y divide-border" aria-label="Item occurrences">
              {items.map(item => (
                <li key={`${item.entity.type}:${item.id}`} className="py-3 first:pt-0">
                  <div className="flex min-w-0 items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="truncate font-semibold text-text">{entityTypeLabel(item.entity.type)}: {item.entity.label || `Actor ${item.entity.id}`}</p>
                      <p className="mt-0.5 truncate text-xs text-text-muted">{item.player?.name || item.entity.owner || 'Owner not proven'} · {item.entity.map || 'Map not reported'}</p>
                    </div>
                    <span className="shrink-0 font-semibold text-accent-bright">x{item.quantity}</span>
                  </div>
                  <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
                    <div><dt className="text-text-dim">Quality</dt><dd>{item.quality}</dd></div>
                    <div><dt className="text-text-dim">Durability</dt><dd>{valueOrNotReported(item.durability)} / {valueOrNotReported(item.maxDurability)}</dd></div>
                    <div><dt className="text-text-dim">Item</dt><dd>{item.id}</dd></div>
                    <div><dt className="text-text-dim">Inventory</dt><dd>{item.entity.inventoryType}</dd></div>
                  </dl>
                  <Link className="mt-2 inline-flex text-xs font-semibold text-info hover:text-ibad" to={item.entity.workspacePath}>Open {item.entity.type === 'player' ? 'player' : 'container'}</Link>
                </li>
              ))}
            </ul>
          )}
          {nextCursor && <button className="btn-secondary mt-4 min-h-11 w-full" disabled={loading} onClick={() => { void load(nextCursor, true) }}>{loading ? 'Loading...' : 'Load more occurrences'}</button>}
          {verifiedDetailsUrl && <a className="btn-ghost mt-4 inline-flex min-h-11 text-text-muted" href={verifiedDetailsUrl} target="_blank" rel="noopener noreferrer">View on dune.gaming.tools<Icon name="ExternalLink" size={14} /></a>}
        </div>
      )}
    </DetailPanel>
  )
}
