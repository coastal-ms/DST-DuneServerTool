import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ApiError } from '../../api/client'
import {
  getInventoryPlayers,
  deleteInventoryItem,
  deleteStorageItem,
  renameStorage,
  repairStorageContents,
  setItemStack,
  setStorageItemStack,
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

import { useInventoryImages } from './useInventoryImages'
import { InventoryReadSession } from './InventoryReadSession'

const inventoryFieldClass = 'mt-1 min-h-11 w-full rounded-lg border border-border bg-surface-2 px-3 py-2 text-sm text-text placeholder:text-text-dim focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/25'

const locationChoicesCache = new Map<string, SharedInventoryLocationFacet[]>()

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
  return type === 'player' ? 'Backpack' : type === 'vehicle' ? 'Vehicle cargo' : 'Storage box'
}

function valueOrNotReported(value: string) {
  return value && value !== 'N/A' ? value : 'Not reported'
}

function parsePositiveId(value: string | null) {
  if (!value || !/^\d+$/.test(value)) return undefined
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined
}

function assertInventoryGroups(groups: SharedInventoryGroup[]) {
  const malformed = groups.find(group => (
    !group.groupKey?.trim()
    || !group.templateId?.trim()
    || !group.displayName?.trim()
    || !Number.isFinite(group.totalQuantity)
    || !Number.isFinite(group.occurrenceCount)
    || !Number.isFinite(group.locationCount)
  ))
  if (malformed) throw new Error('Inventory response contained a malformed grouped item. Refresh after updating the backend.')
}

function assertInventoryOccurrences(items: SharedInventoryItem[]) {
  const malformed = items.find(item => (
    !Number.isSafeInteger(item.id)
    || item.id <= 0
    || !item.templateId?.trim()
    || !item.displayName?.trim()
    || !item.entity?.type
    || !Number.isSafeInteger(item.entity.id)
    || item.entity.id <= 0
  ))
  if (malformed) throw new Error('Inventory response contained a malformed item occurrence. Refresh after updating the backend.')
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

function inventoryItemKey(item: SharedInventoryItem) {
  return `${item.entity.type}:${item.id}`
}

function locationLabel(location: SharedInventoryLocationFacet, allPlayers: boolean, duplicateOrdinal = 0) {
  const base = location.label || (location.type === 'player' ? 'Backpack' : 'Storage box')
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
  title = 'Inventory',
  description = 'Inspect items and manage the selected inventory.',
  unavailableReason,
  selectedPlayer,
  demoMode,
  refreshKey = 0,
}: {
  entityTypes: InventoryEntityType[]
  demoMode?: boolean
  refreshKey?: number
  selectedPlayer?: { id: number; name: string }
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
  const validScopeType = requestedScopeType === 'player' || requestedScopeType === 'storage' || requestedScopeType === 'vehicle'
  const scopeError = hasScopeType !== hasScopeId
    ? 'Both scope_type and scope_id are required for a scoped inventory link.'
    : hasScopeType && (!validScopeType || !entityTypes.includes(requestedScopeType as InventoryEntityType))
      ? 'The requested inventory scope type is not supported in this workspace.'
      : hasScopeId && !parsedScopeId ? 'The requested inventory scope ID must be a positive integer.' : ''
  const scopeType = !scopeError && validScopeType ? requestedScopeType as InventoryEntityType : undefined
  const scopeId = !scopeError ? parsedScopeId : undefined
  const fixedVehicleScope = scopeType === 'vehicle' && Boolean(scopeId)
  const requestedPlayerId = params.get('player_id')
  const playerId = selectedPlayer?.id ?? (fixedVehicleScope ? undefined : parsePositiveId(requestedPlayerId))
  const playerError = !selectedPlayer && !fixedVehicleScope && params.has('player_id') && !playerId
    ? 'The requested player ID must be a positive integer.'
    : ''
  const requestedLocationType = params.get('location_type')
  const locationType = !fixedVehicleScope && (requestedLocationType === 'player' || requestedLocationType === 'storage' || requestedLocationType === 'vehicle')
    ? requestedLocationType : undefined
  const locationId = fixedVehicleScope ? undefined : parsePositiveId(params.get('location_id'))
  const locationError = !fixedVehicleScope && (
    params.has('location_type') !== params.has('location_id')
    || (params.has('location_type') && (!locationType || !locationId))
  )
  const query = params.get('q') ?? ''
  const sort = catalogSorts.some(option => option.value === params.get('sort'))
    ? params.get('sort') as SharedInventorySort : 'name-asc'
  const demo = demoMode ?? ['1', 'true', 'yes'].includes((params.get('demo') ?? '').toLowerCase())
  const locationCacheKey = JSON.stringify([window.__duneRemoteToken ?? sessionStorage.getItem('dune.token') ?? '', demo, playerId, scopeType, scopeId, entityTypes])
  const [loadImages, setLoadImages] = useInventoryImages()
  const pageSize = loadImages ? 28 : 100
  const [draftQuery, setDraftQuery] = useState(query)
  const [response, setResponse] = useState<SharedInventoryResponse | null>(null)
  const [groups, setGroups] = useState<SharedInventoryGroup[]>([])
  const [selected, setSelected] = useState<SharedInventoryGroup | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState('')
  const [renameOpen, setRenameOpen] = useState(false)
  const [renameDraft, setRenameDraft] = useState('')
  const [renameLoading, setRenameLoading] = useState(false)
  const [renameError, setRenameError] = useState('')
  const [renameMessage, setRenameMessage] = useState('')
  const [inventoryMutationMessage, setInventoryMutationMessage] = useState('')
  const [inventoryMutationError, setInventoryMutationError] = useState('')
  const [repairLoading, setRepairLoading] = useState(false)
  const [loadedIdentity, setLoadedIdentity] = useState('')
  const [pageCursors, setPageCursors] = useState<(string | undefined)[]>([undefined])
  const readSession = useMemo(() => new InventoryReadSession(), [])
  const detailWarmup = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const requestVersion = useRef(0)
  const [playerChoices, setPlayerChoices] = useState<{ id: number; name: string }[]>([])
  const [playerListAttempt, setPlayerListAttempt] = useState(0)
  const needsPlayer = !demo && !scopeType && !entityTypes.includes('vehicle') && !playerId
  const renameRequestVersion = useRef(0)
  const mutationRefresh = useRef<() => Promise<void>>(async () => {})
  const capabilities = usePlatformCapabilities()
  const capabilityReady = capabilities.data !== null
  const canReadInventory = capabilities.hasCapability('inventory.read')
  const canManageBases = capabilities.hasCapability('base.manage')
  const canDeletePlayerItems = capabilities.hasCapability('player.manage.destructive')
  const canDeleteStorageItems = capabilities.hasCapability('base.manage.destructive')
  const requestIdentity = JSON.stringify({
    query: query.trim(), entityTypes, scopeType, scopeId, playerId, locationType, locationId, sort, pageSize,
    source: demo ? 'demo' : 'live', scopeError, playerError, locationError,
  })
  const current = loadedIdentity === requestIdentity ? response : null
  const availableLocations = current?.data.locations ?? locationChoicesCache.get(locationCacheKey) ?? []
  const currentGroups = loadedIdentity === requestIdentity ? groups : []
  const playerOrdinals = useMemo(() => duplicateOrdinals(
    demo ? current?.data.players ?? [] : playerChoices, player => player.name, player => String(player.id),
  ), [current, demo, playerChoices])
  const locationOrdinals = useMemo(() => duplicateOrdinals(
    current?.data.locations ?? [], location => location.label, location => `${location.type}:${location.id}`,
  ), [current])
  const renameActorId = locationType === 'storage' && locationId
    ? locationId
    : scopeType === 'storage' && scopeId ? scopeId : undefined
  const renameTarget = renameActorId
    ? current?.data.locations.find(location => location.type === 'storage' && location.id === renameActorId)
    : undefined

  const load = useCallback(async (cursor?: string, append = false, preserveSelection = false) => {
    if (!canReadInventory || unavailableReason || scopeError || playerError || locationError) return
    if (needsPlayer) {
      setLoading(false)
      return
    }
    const version = ++requestVersion.current
    if (append) setLoadingMore(true)
    else if (!preserveSelection) {
      setLoading(true)
      setResponse(null)
      setGroups([])
      setSelected(null)
      setLoadedIdentity('')
    } else {
      setLoading(true)
    }
    setError('')
    try {
      const result = await readSession.groups({
        q: query.trim(), types: entityTypes, scopeType, scopeId, playerId, locationType, locationId,
        sort, limit: pageSize, cursor, demo,
      })
      if (version !== requestVersion.current) return
      assertInventoryGroups(result.data.groups)
      const cachedLocations = locationChoicesCache.get(locationCacheKey)
      if (JSON.stringify(cachedLocations) === JSON.stringify(result.data.locations)) result.data.locations = cachedLocations!
      else {
        if (locationChoicesCache.size >= 32) locationChoicesCache.delete(locationChoicesCache.keys().next().value!)
        locationChoicesCache.set(locationCacheKey, result.data.locations)
      }
      setResponse(result)
      setGroups(existing => JSON.stringify(existing) === JSON.stringify(result.data.groups) ? existing : result.data.groups)
      if (preserveSelection) {
        setSelected(currentSelection => (
          currentSelection
            ? result.data.groups.find(group => group.groupKey === currentSelection.groupKey) ?? null
            : null
        ))
      }
      setLoadedIdentity(requestIdentity)
      // Warm only the next page of the view the user has requested.
      if (result.page.nextCursor) void readSession.groups({
        q: query.trim(), types: entityTypes, scopeType, scopeId, playerId, locationType, locationId,
        sort, limit: pageSize, cursor: result.page.nextCursor, demo,
      }).catch(() => { /* normal navigation reports failures and retries */ })
    } catch (reason) {
      if (version !== requestVersion.current) return
      if (!preserveSelection) {
        setResponse(null)
        setGroups([])
        setSelected(null)
        setLoadedIdentity('')
      }
      setError(errorMessage(reason))
    } finally {
      if (version === requestVersion.current) {
        setLoading(false)
        setLoadingMore(false)
      }
    }
  }, [
    canReadInventory, demo, entityTypes, needsPlayer, locationError, locationId, locationType, playerError, playerId, query,
    requestIdentity, scopeError, scopeId, scopeType, sort, unavailableReason,
    pageSize, readSession, locationCacheKey, setError, setGroups, setLoadedIdentity, setLoading, setLoadingMore, setResponse, setSelected,
  ])
  mutationRefresh.current = () => { readSession.clear(); setPageCursors([undefined]); return load(undefined, false, true) }
  const refresh = useCallback(async () => {
    readSession.clear()
    if (demo) {
      await load()
      return
    }
    setLoading(true)
    setPageCursors([undefined])
    setError('')
    try {
      await load(undefined, false, true)
    } catch (reason) {
      setError(errorMessage(reason))
      setLoading(false)
    }
  }, [demo, load, readSession, setError, setLoading, setPageCursors])

  useEffect(() => {
    if (selectedPlayer) { setPlayerChoices([selectedPlayer]); return }
    if (demo || fixedVehicleScope || !canReadInventory || unavailableReason) return
    let active = true
    getInventoryPlayers().then(result => { if (active) setPlayerChoices(result.players) })
      .catch(reason => { if (active) setError(errorMessage(reason)) })
    return () => { active = false }
  }, [demo, fixedVehicleScope, canReadInventory, unavailableReason, playerListAttempt, selectedPlayer])

  useEffect(() => setDraftQuery(query), [query])
  useEffect(() => {
    requestVersion.current += 1
    setResponse(null)
    setGroups([])
    setSelected(null)
    setError('')
    setInventoryMutationMessage('')
    setInventoryMutationError('')
    setLoadedIdentity('')
    setLoadingMore(false)
    setPageCursors([undefined])
  }, [requestIdentity])
  useEffect(() => {
    renameRequestVersion.current += 1
    setRenameOpen(false)
    setRenameError('')
    setRenameMessage('')
  }, [requestIdentity])
  useEffect(() => {
    readSession.clear()
    if (capabilityReady && canReadInventory && !unavailableReason && !scopeError && !playerError && !locationError) void load()
  }, [capabilityReady, canReadInventory, load, locationError, playerError, scopeError, unavailableReason, refreshKey, readSession])
  useEffect(() => () => {
    clearTimeout(detailWarmup.current)
    readSession.clear()
    requestVersion.current += 1
    renameRequestVersion.current += 1
  }, [readSession])

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
    return <WorkspaceSection id="shared-inventory" title={title} description={description}><DataState state="unavailable" title="Shared inventory is not included in this backend" message="Install the matching DST backend build to use the inventory explorer." /></WorkspaceSection>
  }

  const storageOnly = entityTypes.length === 1 && entityTypes[0] === 'storage'
  const validSelectedLocation = !locationType || current?.data.selectedLocationValid !== false

  return (
    <WorkspaceSection id="shared-inventory" title={title} description={description}>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        {current && <FreshnessBadge state={current.freshness.state} observedAt={current.freshness.observedAt} label={current.data.mode === 'demo' ? 'Demo inventory' : 'Live database'} />}
      </div>
      {scopeType && scopeId && <div className="mb-3 rounded-lg border border-info/35 bg-info/10 px-4 py-3 text-sm text-text" role="status">{selectedPlayer?.name || current?.data.locations.find(location => location.type === scopeType && location.id === scopeId)?.playerName || current?.data.locations.find(location => location.type === scopeType && location.id === scopeId)?.owner || entityTypeLabel(scopeType)}</div>}
      <form className="mb-4 flex min-w-0 flex-wrap items-end gap-3" role="search"
        onSubmit={event => {
          event.preventDefault()
          if (draftQuery === query) void load()
          else setUrlFilters({ q: draftQuery.trim() || undefined })
        }}>
        {!fixedVehicleScope && <div className="flex basis-full min-w-0 flex-wrap items-end gap-3 rounded-xl border border-border bg-surface-1 p-3">
          {!selectedPlayer && <label className="min-w-0 flex-[1_1_14rem] text-xs font-medium text-text-muted">
            Player
            <select aria-label="Player" className={inventoryFieldClass} value={playerId ?? ''}
              onChange={event => setUrlFilters({ player_id: event.target.value || undefined, location_type: undefined, location_id: undefined })}>
              <option value="">{demo ? 'All players' : 'Select Player for Inventory'}</option>
              {(demo ? current?.data.players ?? [] : playerChoices).map(player => {
                const ordinal = playerOrdinals.get(String(player.id))
                return <option key={player.id} value={player.id}>{player.name || 'Unnamed player'}{ordinal ? ` (${ordinal})` : ''}</option>
              })}
            </select>
          </label>}
          <label className="min-w-0 flex-[1_1_14rem] text-xs font-medium text-text-muted">
            {storageOnly ? 'Storage container' : 'Location'}
            <select aria-label={storageOnly ? 'Storage container' : 'Location'} className={inventoryFieldClass}
              value={validSelectedLocation ? locationValue(locationType && locationId ? { type: locationType, id: locationId } : null) : ''}
              onChange={event => {
                const [type, id] = event.target.value.split(':')
                setUrlFilters({ location_type: type || undefined, location_id: id || undefined })
              }}>
              <option value="">{storageOnly ? 'Select a storage container' : 'All locations'}</option>
              {availableLocations.map(location => <option key={`${location.type}:${location.id}`} value={locationValue(location)}>
                {locationLabel(location, !playerId, locationOrdinals.get(`${location.type}:${location.id}`) ?? 0)}
              </option>)}
            </select>
          </label>
        {canManageBases && entityTypes.includes('storage') && !demo && (
          <button type="button" className="btn-primary min-h-11 max-w-full shrink-0 whitespace-normal text-left" disabled={!renameTarget || current?.data.mode !== 'live' || loading || loadingMore || repairLoading || renameLoading}
            onClick={async () => {
              if (!renameTarget) return
              const version = renameRequestVersion.current
              setRepairLoading(true); setInventoryMutationError(''); setInventoryMutationMessage('')
              try {
                const result = await repairStorageContents(renameTarget.id)
                if (version !== renameRequestVersion.current) return
                setInventoryMutationMessage(result.message || 'Storage contents repaired.')
                await mutationRefresh.current()
              } catch (reason) { if (version === renameRequestVersion.current) setInventoryMutationError(errorMessage(reason)) }
              finally { setRepairLoading(false) }
            }}>
            <Icon name="Wrench" size={14} />{renameTarget ? `Repair items in ${renameTarget.label}` : 'Repair container items'}
          </button>
        )}
        {canManageBases && current?.data.mode === 'live' && renameTarget && (
          <button
            type="button"
            className="btn-secondary min-h-11"
            disabled={loading || loadingMore || renameLoading}
            onClick={() => {
              setRenameDraft(renameTarget.label)
              setRenameError('')
              setRenameMessage('')
              setRenameOpen(true)
            }}
          >
            <Icon name="PenLine" size={14} />Rename box
          </button>
        )}
          {storageOnly && !renameTarget && <p className="basis-full text-xs text-text-dim">Choose a container above to repair its items.</p>}
        </div>}
        <label className="min-w-0 flex-[1_1_16rem] text-xs font-medium text-text-muted">
          Search inventory
          <input type="search" className={inventoryFieldClass} value={draftQuery} maxLength={200}
            placeholder="Search items…" onChange={event => setDraftQuery(event.target.value)} />
        </label>
        <label className="min-w-0 flex-[0_1_10rem] text-xs font-medium text-text-muted">
          Sort by
          <select aria-label="Sort by" className={inventoryFieldClass} value={sort}
            onChange={event => setUrlFilters({ sort: event.target.value === 'name-asc' ? undefined : event.target.value })}>
            {catalogSorts.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        <button type="submit" className="btn-secondary min-h-11" disabled={needsPlayer || loading || loadingMore}><Icon name="Search" size={15} />Search</button>
        <button type="button" className="btn-secondary min-h-11" aria-label="Refresh inventory" title="Refresh inventory" disabled={needsPlayer || loading || loadingMore} onClick={() => { void refresh() }}><Icon name="RefreshCw" size={14} /></button>
        <label className="flex min-h-11 items-center gap-2 text-sm text-text">
          <input type="checkbox" checked={loadImages} onChange={event => setLoadImages(event.target.checked)} />Load images
        </label>
      </form>
      {renameOpen && renameTarget && (
        <form
          aria-label="Rename storage box"
          className="mb-4 flex flex-col gap-3 rounded-lg border border-accent/35 bg-accent/10 p-4 sm:flex-row sm:items-end"
          onSubmit={async event => {
            event.preventDefault()
            const name = renameDraft.trim()
            if (!name) {
              setRenameError('Enter a name for this storage box.')
              return
            }
            if (name.length > 64) {
              setRenameError('Storage box names must be 64 characters or fewer.')
              return
            }
            const renameVersion = ++renameRequestVersion.current
            setRenameLoading(true)
            setRenameError('')
            try {
              const result = await renameStorage(renameTarget.id, name)
              if (renameVersion !== renameRequestVersion.current) return
              setRenameOpen(false)
              setRenameMessage(result.message || `Renamed storage box to ${name}.`)
              await mutationRefresh.current()
            } catch (reason) {
              if (renameVersion !== renameRequestVersion.current) return
              setRenameError(errorMessage(reason))
            } finally {
              if (renameVersion === renameRequestVersion.current) setRenameLoading(false)
            }
          }}
        >
          <label className="min-w-0 flex-1 text-sm font-medium text-text">
            Storage box name
            <input
              autoFocus
              className="input mt-1 min-h-11 w-full"
              value={renameDraft}
              maxLength={64}
              onChange={event => setRenameDraft(event.target.value)}
            />
          </label>
          <div className="flex gap-2">
            <button type="submit" className="btn-primary min-h-11" disabled={renameLoading}>
              <Icon name={renameLoading ? 'Loader2' : 'Check'} size={14} className={renameLoading ? 'animate-spin' : undefined} />
              {renameLoading ? 'Saving...' : 'Save name'}
            </button>
            <button type="button" className="btn-secondary min-h-11" disabled={renameLoading} onClick={() => setRenameOpen(false)}>Cancel</button>
          </div>
          {renameError && <p className="text-sm text-danger" role="alert">{renameError}</p>}
        </form>
      )}
      {renameMessage && <div className="mb-4 rounded-lg border border-success/35 bg-success/10 px-4 py-3 text-sm text-text" role="status">{renameMessage}</div>}
      {inventoryMutationMessage && <div className="mb-4 rounded-lg border border-success/35 bg-success/10 px-4 py-3 text-sm text-text" role="status">{inventoryMutationMessage}</div>}
      {inventoryMutationError && <div className="mb-4 rounded-lg border border-danger/35 bg-danger/10 px-4 py-3 text-sm text-danger" role="alert">{inventoryMutationError}</div>}

      {locationType && current && !validSelectedLocation && <DataState state="error" title="Location does not match this player" message="Choose a location available to the selected player." />}
      {current?.data.mode === 'demo' && <DataState state="fresh" title="Showing bundled demo inventory" message="Demo mode was explicitly requested; these grouped items are examples and not live server contents." />}
      {error && <div className="mb-4"><DataState state="error" title="Inventory search failed" message={error} action={<button className="btn-secondary min-h-11" onClick={() => { setError(''); setPlayerListAttempt(n => n + 1); void load() }}>Retry</button>} /></div>}
      {needsPlayer && !error && <DataState state="empty" title="Select Player for Inventory" />}
      {loading && currentGroups.length === 0 && !error && <DataState state="loading" title="Loading inventory catalog" />}
      {!loading && !error && current && currentGroups.length === 0 && <DataState
        state="empty"
        title={scopeType === 'vehicle' ? 'No persisted cargo items' : 'No matching inventory items'}
        message={scopeType === 'vehicle'
          ? 'This vehicle has no items in its persisted actor-owned cargo hold.'
          : 'Try another item, player, location, or source filter.'}
      />}
      {(currentGroups.length > 0 || pageCursors.length > 1) && (
        <>
          <ul className={loadImages ? "grid min-w-0 grid-cols-[repeat(auto-fill,minmax(min(6.5rem,100%),1fr))] gap-2.5" : "grid min-w-0 grid-cols-1 gap-1.5"} aria-label="Inventory results">
            {currentGroups.map(group => <li key={group.groupKey} className="min-w-0" onPointerEnter={() => {
              clearTimeout(detailWarmup.current)
              detailWarmup.current = setTimeout(() => {
                void readSession.occurrences({ templateId: group.templateId, types: entityTypes, scopeType, scopeId, playerId,
                  locationType, locationId, sort: 'player-asc', limit: pageSize, demo }).catch(() => {})
              }, 180)
            }} onPointerLeave={() => clearTimeout(detailWarmup.current)} onFocus={() => {
              void readSession.occurrences({ templateId: group.templateId, types: entityTypes, scopeType, scopeId, playerId,
                locationType, locationId, sort: 'player-asc', limit: pageSize, demo }).catch(() => {})
            }}><InventorySlot item={group} showImages={loadImages} onSelect={setSelected} /></li>)}
          </ul>
          <div className="mt-4 flex items-center justify-center gap-3" aria-label="Inventory pages">
            <button className="btn-secondary min-h-11" disabled={loadingMore || pageCursors.length === 1} onClick={() => { const previous = pageCursors.slice(0, -1); setPageCursors(previous); void load(previous[previous.length - 1], true) }}>Previous</button>
            <span className="text-sm text-text-dim">Page {pageCursors.length} · Showing {currentGroups.length} {currentGroups.length === 1 ? 'item type' : 'item types'}</span>
            <button className="btn-secondary min-h-11" disabled={loadingMore || !current?.page.nextCursor} onClick={() => { const cursor = current?.page.nextCursor ?? undefined; setPageCursors(previous => [...previous, cursor]); void load(cursor, true) }}>{loadingMore ? 'Loading...' : 'Next'}</button>
          </div>
        </>
      )}
      <OccurrencePanel
        pageSize={pageSize}
        readSession={readSession}
        group={selected}
        players={current?.data.players ?? []}
        locations={current?.data.locations ?? []}
        initialPlayerId={playerId}
        initialLocation={locationType && locationId ? { type: locationType, id: locationId } : undefined}
        entityTypes={entityTypes}
        scopeType={scopeType}
        scopeId={scopeId}
        demo={demo}
        canDeletePlayerItems={canDeletePlayerItems}
        canDeleteStorageItems={canDeleteStorageItems}
        onInventoryChanged={() => mutationRefresh.current()}
        onDeleteResult={(message, mutationError) => {
          setInventoryMutationMessage(message)
          setInventoryMutationError(mutationError)
        }}
        onClose={() => setSelected(null)}
      />
    </WorkspaceSection>
  )
}

function OccurrencePanel({
  pageSize, readSession, group, players, locations, initialPlayerId, initialLocation, entityTypes, scopeType, scopeId, demo,
  canDeletePlayerItems, canDeleteStorageItems, onInventoryChanged, onDeleteResult, onClose,
}: {
  pageSize: number
  readSession: InventoryReadSession
  group: SharedInventoryGroup | null
  players: SharedInventoryResponse['data']['players']
  locations: SharedInventoryLocationFacet[]
  initialPlayerId?: number
  initialLocation?: { type: InventoryEntityType; id: number }
  entityTypes: InventoryEntityType[]
  scopeType?: InventoryEntityType
  scopeId?: number
  demo: boolean
  canDeletePlayerItems: boolean
  canDeleteStorageItems: boolean
  onInventoryChanged: () => Promise<void>
  onDeleteResult: (message: string, error: string) => void
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
  const [selectedItemKeys, setSelectedItemKeys] = useState<Set<string>>(new Set())
  const [deleteQuantities, setDeleteQuantities] = useState<Record<string, string>>({})
  const [deleteBusy, setDeleteBusy] = useState(false)
  const [verifiedDetailsUrl, setVerifiedDetailsUrl] = useState<string | null>(null)
  const version = useRef(0)
  const groupTemplateId = group?.templateId
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
  const canDelete = (item: SharedInventoryItem) => !demo && (
    item.entity.type === 'player' ? canDeletePlayerItems : item.entity.type === 'storage' && canDeleteStorageItems
  )
  const deletableItems = items.filter(canDelete)
  const selectedItems = deletableItems.filter(item => selectedItemKeys.has(inventoryItemKey(item)))

  const deleteItems = async (targets: SharedInventoryItem[]) => {
    if (targets.length === 0) return
    const requests = targets.map(item => ({
      item,
      quantity: Number(deleteQuantities[inventoryItemKey(item)] ?? item.quantity),
    }))
    const invalid = requests.find(request => (
      !Number.isSafeInteger(request.quantity)
      || request.quantity < (request.item.quantity === 0 ? 0 : 1)
      || request.quantity > request.item.quantity
    ))
    if (invalid) {
      onDeleteResult('', `Delete quantity for ${invalid.item.displayName} must be a whole number from 1 to ${invalid.item.quantity}.`)
      return
    }
    const quantity = requests.reduce((sum, request) => sum + request.quantity, 0)
    const baseMessage = targets.length === 1
      ? `Delete ${quantity} of ${targets[0].displayName} (stack x${targets[0].quantity}) from ${targets[0].entity.label || entityTypeLabel(targets[0].entity.type)}? This cannot be undone.`
      : `Delete ${quantity} total items across ${targets.length} selected occurrences? Any full stacks will be removed. This cannot be undone.`
    const message = targets.some(item => item.entity.type === 'player')
      ? `${baseMessage}\n\nReserve rows cannot be deleted or reduced here. DST will reject them because remaining Reserve contents can become hidden and keep base recycling blocked.`
      : baseMessage
    if (!window.confirm(message)) return

    setDeleteBusy(true)
    setError('')
    const updated = new Map<string, number>()
    const failures: string[] = []
    let removedQuantity = 0
    const partialEntityTypes = new Set<InventoryEntityType>()
    for (const request of requests) {
      const { item, quantity: deleteQuantity } = request
      try {
        const remaining = item.quantity - deleteQuantity
        const result = remaining === 0
          ? item.entity.type === 'player'
            ? await deleteInventoryItem(item.id, item.quantity)
            : await deleteStorageItem(item.id, item.quantity)
          : item.entity.type === 'player'
            ? await setItemStack(item.id, remaining, item.quantity)
            : await setStorageItemStack(item.id, remaining, item.quantity)
        if (!result.ok) throw new Error(result.message || 'The inventory update was rejected.')
        updated.set(inventoryItemKey(item), remaining)
        removedQuantity += deleteQuantity
        if (remaining > 0) partialEntityTypes.add(item.entity.type)
      } catch (reason) {
        failures.push(`${item.displayName} in ${item.entity.label || entityTypeLabel(item.entity.type)}: ${errorMessage(reason)}`)
      }
    }

    if (updated.size > 0) {
      setItems(current => current
        .filter(item => updated.get(inventoryItemKey(item)) !== 0)
        .map(item => {
          const remaining = updated.get(inventoryItemKey(item))
          return remaining === undefined ? item : { ...item, quantity: remaining }
        }))
      setSelectedItemKeys(current => new Set([...current].filter(key => !updated.has(key))))
      setDeleteQuantities(current => {
        const next = { ...current }
        updated.forEach((remaining, key) => {
          if (remaining === 0) delete next[key]
          else next[key] = String(remaining)
        })
        return next
      })
    }
    let successMessage = updated.size > 0
      ? removedQuantity === 0
        ? `Deleted ${updated.size} empty occurrence${updated.size === 1 ? '' : 's'}.`
        : `Removed ${removedQuantity} item${removedQuantity === 1 ? '' : 's'} from ${updated.size} occurrence${updated.size === 1 ? '' : 's'}.`
      : ''
    if (partialEntityTypes.has('player')) {
      successMessage += ' Player changes require a relog or map restart and may be overwritten while the player is online.'
    }
    if (partialEntityTypes.has('storage')) {
      successMessage += ' Storage changes appear in-game after the server zone restarts.'
    }
    const failureMessage = failures.length > 0
      ? `${updated.size > 0 ? `${updated.size} updated; ` : ''}${failures.length} failed. ${failures.join(' ')}`
      : ''
    onDeleteResult(successMessage, failureMessage)
    if (updated.size > 0) await onInventoryChanged()
    setDeleteBusy(false)
  }

  const load = useCallback(async (cursor?: string, append = false) => {
    if (!groupTemplateId) return
    const request = ++version.current
    setLoading(true)
    setError('')
    if (!append) {
      setItems([])
      setNextCursor(null)
    }
    try {
      const result = await readSession.occurrences({
        templateId: groupTemplateId, types: entityTypes, scopeType, scopeId, playerId,
        locationType: location?.type, locationId: location?.id, sort, limit: pageSize, cursor, demo,
      })
      if (request !== version.current) return
      assertInventoryOccurrences(result.data.items)
      setItems(current => JSON.stringify(current) === JSON.stringify(result.data.items) ? current : result.data.items)
      setDeleteQuantities(current => {
        const next = append ? { ...current } : {}
        result.data.items.forEach(item => { next[inventoryItemKey(item)] = String(item.quantity) })
        return next
      })
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
  }, [demo, entityTypes, groupTemplateId, location, pageSize, playerId, readSession, scopeId, scopeType, sort])

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
    setSelectedItemKeys(new Set())
    setDeleteQuantities({})
  }, [group?.groupKey])
  useEffect(() => {
    version.current += 1
    setItems([])
    setNextCursor(null)
    setError('')
    if (groupTemplateId) void load()
  }, [identity, groupTemplateId, load])
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
            {(canDeletePlayerItems || canDeleteStorageItems) && !demo
              ? <span className="pill border-danger/40 text-danger">Deletion enabled</span>
              : <span className="pill border-info/40 text-info">Read-only</span>}
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
                <option value="" disabled={!demo}>{demo ? 'All players' : 'Select Player for Inventory'}</option>
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
            <>
              {deletableItems.length > 0 && (
                <div className="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-surface-2 p-3">
                  <label className="flex min-h-11 items-center gap-2 text-sm font-medium text-text">
                    <input
                      type="checkbox"
                      aria-label="Select all loaded occurrences"
                      checked={selectedItems.length === deletableItems.length}
                      disabled={deleteBusy}
                      onChange={event => setSelectedItemKeys(current => {
                        const next = new Set(current)
                        deletableItems.forEach(item => event.target.checked ? next.add(inventoryItemKey(item)) : next.delete(inventoryItemKey(item)))
                        return next
                      })}
                    />
                    Select all loaded
                  </label>
                  <button type="button" className="btn-danger min-h-11" disabled={deleteBusy || selectedItems.length === 0} onClick={() => { void deleteItems(selectedItems) }}>
                    <Icon name={deleteBusy ? 'Loader2' : 'Trash2'} size={14} className={deleteBusy ? 'animate-spin' : undefined} />
                    {deleteBusy ? 'Deleting...' : `Delete selected (${selectedItems.length})`}
                  </button>
                </div>
              )}
              <ul className="divide-y divide-border" aria-label="Item occurrences">
              {items.map(item => (
                <li key={`${item.entity.type}:${item.id}`} className="py-3 first:pt-0">
                  <div className="flex min-w-0 items-start justify-between gap-3">
                    <div className="flex min-w-0 items-start gap-3">
                      {canDelete(item) && (
                        <input
                          type="checkbox"
                          className="mt-1"
                          aria-label={`Select ${item.displayName} in ${item.entity.label || entityTypeLabel(item.entity.type)}`}
                          checked={selectedItemKeys.has(inventoryItemKey(item))}
                          disabled={deleteBusy}
                          onChange={event => setSelectedItemKeys(current => {
                            const next = new Set(current)
                            if (event.target.checked) next.add(inventoryItemKey(item))
                            else next.delete(inventoryItemKey(item))
                            return next
                          })}
                        />
                      )}
                      <div className="min-w-0">
                      <p className="truncate font-semibold text-text">{entityTypeLabel(item.entity.type)}: {item.entity.label || `Actor ${item.entity.id}`}</p>
                      <p className="mt-0.5 truncate text-xs text-text-muted">{item.player?.name || item.entity.owner || 'Owner not proven'} · {item.entity.map || 'Map not reported'}</p>
                      </div>
                    </div>
                    <div className="flex shrink-0 items-center gap-2">
                      {canDelete(item) && (
                        <label className="text-xs font-medium text-text-muted">
                          Delete quantity
                          <input
                            type="number"
                            className="input mt-1 h-9 w-20 text-right font-semibold text-accent-bright"
                            aria-label={`Delete quantity for ${item.displayName} in ${item.entity.label || entityTypeLabel(item.entity.type)}`}
                            min={item.quantity === 0 ? 0 : 1}
                            max={item.quantity}
                            step={1}
                            inputMode="numeric"
                            value={deleteQuantities[inventoryItemKey(item)] ?? String(item.quantity)}
                            disabled={deleteBusy}
                            onChange={event => setDeleteQuantities(current => ({
                              ...current,
                              [inventoryItemKey(item)]: event.target.value,
                            }))}
                          />
                        </label>
                      )}
                      {!canDelete(item) && <span className="font-semibold text-accent-bright">x{item.quantity}</span>}
                      {canDelete(item) && (
                        <button
                          type="button"
                          className="btn-icon min-h-11 min-w-11 text-danger"
                          aria-label={`Delete ${item.displayName} from ${item.entity.label || entityTypeLabel(item.entity.type)}`}
                          disabled={deleteBusy}
                          onClick={() => { void deleteItems([item]) }}
                        >
                          <Icon name="Trash2" size={15} />
                        </button>
                      )}
                    </div>
                  </div>
                  <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
                    <div><dt className="text-text-dim">Quality</dt><dd>{item.quality}</dd></div>
                    <div><dt className="text-text-dim">Durability</dt><dd>{valueOrNotReported(item.durability)} / {item.maxDurability && item.maxDurability !== 'N/A' ? item.maxDurability : (item.metadata.baseMaxDurability ?? 0) > 0 ? <span title="Base maximum from the game item definition; the save omits this value.">{item.metadata.baseMaxDurability} (base)</span> : 'Not reported'}</dd></div>
                    <div><dt className="text-text-dim">Item</dt><dd>{item.id}</dd></div>
                    <div><dt className="text-text-dim">Inventory</dt><dd>{item.entity.inventoryType}</dd></div>
                  </dl>
                  <Link className="mt-2 inline-flex text-xs font-semibold text-info hover:text-ibad" to={item.entity.type === 'storage' && (item.player?.id || playerId)
                    ? `/players?player_id=${item.player?.id || playerId}&section=inventory&scope_type=storage&scope_id=${item.entity.id}&location_type=storage&location_id=${item.entity.id}${demo ? '&demo=1' : ''}`
                    : item.entity.workspacePath}>Open {item.entity.type === 'player' ? 'player' : item.entity.type === 'vehicle' ? 'vehicle cargo' : 'container'}</Link>
                </li>
              ))}
              </ul>
            </>
          )}
          {nextCursor && <button className="btn-secondary mt-4 min-h-11 w-full" disabled={loading} onClick={() => { void load(nextCursor, true) }}>{loading ? 'Loading...' : 'Next {pageSize} occurrences'}</button>}
          {verifiedDetailsUrl && <a className="btn-ghost mt-4 inline-flex min-h-11 text-text-muted" href={verifiedDetailsUrl} target="_blank" rel="noopener noreferrer">View on dune.gaming.tools<Icon name="ExternalLink" size={14} /></a>}
        </div>
      )}
    </DetailPanel>
  )
}
