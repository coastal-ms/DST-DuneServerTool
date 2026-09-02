import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ApiError } from '../../api/client'
import {
  getSharedInventory,
  type InventoryEntityType,
  type SharedInventoryItem,
  type SharedInventoryResponse,
} from '../../api/gameplay'
import { usePlatformCapabilities } from '../../hooks/usePlatformCapabilities'
import { Link, useSearch } from '../../router'
import { Icon } from '../Icon'
import { DataState, FreshnessBadge } from '../platform/DataState'
import { DetailPanel } from '../platform/DetailPanel'
import { WorkspaceSection } from '../platform/WorkspaceLayout'

function errorMessage(error: unknown) {
  return error instanceof ApiError ? error.message : error instanceof Error ? error.message : String(error)
}

function entityTypeLabel(type: InventoryEntityType) {
  return type === 'player' ? 'Player inventory' : 'Storage container'
}

function valueOrNotReported(value: string) {
  return value && value !== 'N/A' ? value : 'Not reported'
}

export function SharedInventoryExplorer({
  entityTypes,
  title = 'Shared Inventory Explorer',
  description = 'Search item names, template IDs, owners, containers, and proven entity types from one read-only view.',
  unavailableReason,
}: {
  entityTypes: InventoryEntityType[]
  title?: string
  description?: string
  unavailableReason?: string
}) {
  const search = useSearch()
  const searchParams = useMemo(() => new URLSearchParams(search), [search])
  const hasScopeType = searchParams.has('scope_type')
  const hasScopeId = searchParams.has('scope_id')
  const requestedScopeType = searchParams.get('scope_type')
  const requestedScopeId = searchParams.get('scope_id')
  const parsedScopeId = Number(requestedScopeId)
  const validScopeType = requestedScopeType === 'player' || requestedScopeType === 'storage'
  const validScopeId = requestedScopeId !== null
    && /^\d+$/.test(requestedScopeId)
    && Number.isSafeInteger(parsedScopeId)
    && parsedScopeId > 0
  const scopeError = hasScopeType !== hasScopeId
    ? 'Both scope_type and scope_id are required for a scoped inventory link.'
    : hasScopeType && (!validScopeType || !entityTypes.includes(requestedScopeType as InventoryEntityType))
      ? 'The requested inventory scope type is not supported in this workspace.'
      : hasScopeId && !validScopeId
        ? 'The requested inventory scope ID must be a positive integer.'
        : ''
  const scopeType = !scopeError && validScopeType
    ? requestedScopeType as InventoryEntityType
    : undefined
  const scopeId = !scopeError && validScopeId ? parsedScopeId : undefined
  const demoRequested = ['1', 'true', 'yes'].includes((searchParams.get('demo') ?? '').toLowerCase())
  const initialQuery = searchParams.get('q') ?? ''
  const [draftQuery, setDraftQuery] = useState(initialQuery)
  const [submittedQuery, setSubmittedQuery] = useState(initialQuery)
  const syncedUrlQuery = useRef(initialQuery)
  const urlQueryChanged = syncedUrlQuery.current !== initialQuery
  const currentDraftQuery = urlQueryChanged ? initialQuery : draftQuery
  const currentSubmittedQuery = urlQueryChanged ? initialQuery : submittedQuery
  const [response, setResponse] = useState<SharedInventoryResponse | null>(null)
  const [items, setItems] = useState<SharedInventoryItem[]>([])
  const [selected, setSelected] = useState<SharedInventoryItem | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState('')
  const [loadedIdentity, setLoadedIdentity] = useState('')
  const requestVersion = useRef(0)
  const capabilities = usePlatformCapabilities()
  const capabilityReady = capabilities.data !== null
  const canReadInventory = capabilities.hasCapability('inventory.read')
  const requestIdentity = JSON.stringify({
    query: currentSubmittedQuery.trim(),
    entityTypes,
    scopeType: scopeType ?? null,
    scopeId: scopeId ?? null,
    source: demoRequested ? 'demo' : 'live',
    scopeError,
  })
  const hasCurrentResult = loadedIdentity === requestIdentity
  const currentResponse = hasCurrentResult ? response : null
  const currentItems = hasCurrentResult ? items : []
  const currentSelection = hasCurrentResult ? selected : null

  const load = useCallback(async (cursor?: string, append = false) => {
    if (!canReadInventory || unavailableReason || scopeError) return
    const version = ++requestVersion.current
    if (append) setLoadingMore(true)
    else {
      setLoading(true)
      setResponse(null)
      setItems([])
      setSelected(null)
      setLoadedIdentity('')
    }
    setError('')
    try {
      const result = await getSharedInventory({
        q: currentSubmittedQuery.trim(),
        types: entityTypes,
        scopeType,
        scopeId,
        limit: 100,
        cursor,
        demo: demoRequested,
      })
      if (version !== requestVersion.current) return
      setResponse(result)
      setItems(current => append ? [...current, ...result.data.items] : result.data.items)
      setLoadedIdentity(requestIdentity)
    } catch (loadError) {
      if (version !== requestVersion.current) return
      setResponse(null)
      setItems([])
      setSelected(null)
      setLoadedIdentity('')
      setError(errorMessage(loadError))
    } finally {
      if (version === requestVersion.current) {
        setLoading(false)
        setLoadingMore(false)
      }
    }
  }, [
    canReadInventory,
    demoRequested,
    entityTypes,
    requestIdentity,
    scopeError,
    scopeId,
    scopeType,
    setError,
    setItems,
    setLoadedIdentity,
    setLoading,
    setLoadingMore,
    setResponse,
    setSelected,
    currentSubmittedQuery,
    unavailableReason,
  ])

  useEffect(() => {
    syncedUrlQuery.current = initialQuery
    setDraftQuery(initialQuery)
    setSubmittedQuery(initialQuery)
  }, [initialQuery])

  useEffect(() => {
    requestVersion.current += 1
    setResponse(null)
    setItems([])
    setSelected(null)
    setLoadedIdentity('')
    setError('')
    setLoadingMore(false)
  }, [requestIdentity])

  useEffect(() => {
    if (capabilityReady && canReadInventory && !unavailableReason && !scopeError) void load()
  }, [capabilityReady, canReadInventory, load, scopeError, unavailableReason])

  useEffect(() => () => {
    requestVersion.current += 1
  }, [])

  const busy = loading || loadingMore

  if (unavailableReason) {
    return (
      <WorkspaceSection id="shared-inventory" title={title} description={description}>
        <DataState state="unavailable" title="Inventory scope not yet available" message={unavailableReason} />
      </WorkspaceSection>
    )
  }

  if (scopeError) {
    return (
      <WorkspaceSection id="shared-inventory" title={title} description={description}>
        <DataState state="error" title="Invalid inventory scope" message={scopeError} />
      </WorkspaceSection>
    )
  }

  if (!capabilityReady && capabilities.loading) {
    return (
      <WorkspaceSection id="shared-inventory" title={title} description={description}>
        <DataState state="loading" title="Checking inventory access" />
      </WorkspaceSection>
    )
  }

  if (!capabilityReady && capabilities.error) {
    return (
      <WorkspaceSection id="shared-inventory" title={title} description={description}>
        <DataState
          state="error"
          title="Could not check inventory access"
          message={capabilities.error}
          action={(
            <button className="btn-secondary min-h-11" onClick={() => { void capabilities.refresh() }}>
              <Icon name="RefreshCw" size={14} />
              Retry capability check
            </button>
          )}
        />
      </WorkspaceSection>
    )
  }

  if (capabilityReady && !canReadInventory) {
    return (
      <WorkspaceSection id="shared-inventory" title={title} description={description}>
        <DataState
          state="unavailable"
          title="Shared inventory is not included in this backend"
          message="Install the matching DST backend build to use the read-only inventory explorer."
        />
      </WorkspaceSection>
    )
  }

  return (
    <WorkspaceSection id="shared-inventory" title={title} description={description}>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <span className="pill border-info/40 text-info">Read-only</span>
        {entityTypes.map(type => (
          <span key={type} className="pill border-border text-text-muted">{entityTypeLabel(type)}</span>
        ))}
        {currentResponse && (
          <FreshnessBadge
            state={currentResponse.freshness.state}
            observedAt={currentResponse.freshness.observedAt}
            label={currentResponse.data.mode === 'demo' ? 'Demo inventory' : 'Live database'}
          />
        )}
      </div>

      {scopeType && scopeId && (
        <div className="mb-3 rounded-lg border border-info/35 bg-info/10 px-4 py-3 text-sm text-text" role="status">
          Scoped to {entityTypeLabel(scopeType).toLowerCase()} actor {scopeId}.
        </div>
      )}

      <form
        className="card mb-4 flex min-w-0 flex-col gap-3 p-4 sm:flex-row sm:items-end"
        role="search"
        onSubmit={event => {
          event.preventDefault()
          if (currentDraftQuery === currentSubmittedQuery) {
            void load()
          } else {
            setItems([])
            setResponse(null)
            setSubmittedQuery(currentDraftQuery)
          }
        }}
      >
        <label className="min-w-0 flex-1 text-sm font-medium text-text">
          Search inventory
          <input
            className="input mt-1 min-h-11 w-full"
            value={currentDraftQuery}
            maxLength={200}
            placeholder="Item, template ID, owner, container, or entity type"
            onChange={event => setDraftQuery(event.target.value)}
          />
        </label>
        <button type="submit" className="btn-primary min-h-11 shrink-0" disabled={busy}>
          <Icon name="Search" size={15} />
          Search
        </button>
        <button
          type="button"
          className="btn-secondary min-h-11 shrink-0"
          disabled={busy}
          onClick={() => { void load() }}
        >
          <Icon name="RefreshCw" size={14} />
          Refresh
        </button>
      </form>

      {currentResponse?.data.mode === 'demo' && (
        <DataState
          state="fresh"
          title="Showing bundled demo inventory"
          message="Demo mode was explicitly requested; these rows are examples and not live server contents."
        />
      )}
      {error && (
        <div className="mb-4">
          <DataState
            state="error"
            title="Inventory search failed"
            message={error}
            action={<button className="btn-secondary min-h-11" onClick={() => { void load() }}>Retry</button>}
          />
        </div>
      )}
      {loading && currentItems.length === 0 && !error && <DataState state="loading" title="Loading inventory" />}
      {!loading && !error && currentResponse && currentItems.length === 0 && (
        <DataState
          state="empty"
          title="No matching inventory items"
          message="Try a display name, template ID, owner, container name, or another supported entity type."
        />
      )}

      {currentItems.length > 0 && (
        <>
          <ul className="grid min-w-0 grid-cols-1 gap-2 xl:grid-cols-2" aria-label="Inventory results">
            {currentItems.map(item => (
              <li key={`${item.entity.type}:${item.id}`} className="min-w-0">
                <button
                  type="button"
                  className="card min-h-11 w-full min-w-0 p-4 text-left hover:border-accent/45 focus:outline-none focus-visible:ring-2 focus-visible:ring-ibad"
                  onClick={() => setSelected(item)}
                >
                  <div className="flex min-w-0 flex-wrap items-start justify-between gap-2">
                    <div className="min-w-0">
                      <h3 className="break-words font-semibold text-text">{item.displayName || item.templateId}</h3>
                      <p className="mt-1 break-all font-mono text-xs text-text-dim">{item.templateId}</p>
                    </div>
                    <span className="pill shrink-0 border-border text-text-muted">x{item.quantity}</span>
                  </div>
                  <dl className="mt-3 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
                    <div>
                      <dt className="text-xs text-text-dim">Source</dt>
                      <dd className="mt-0.5 break-words text-text">{entityTypeLabel(item.entity.type)}</dd>
                    </div>
                    <div>
                      <dt className="text-xs text-text-dim">Entity</dt>
                      <dd className="mt-0.5 break-words text-text">{item.entity.label || `Actor ${item.entity.id}`}</dd>
                    </div>
                    <div>
                      <dt className="text-xs text-text-dim">Owner</dt>
                      <dd className="mt-0.5 break-words text-text">{item.entity.owner || 'Not proven'}</dd>
                    </div>
                    <div>
                      <dt className="text-xs text-text-dim">Map</dt>
                      <dd className="mt-0.5 break-words text-text">{item.entity.map || 'Not reported'}</dd>
                    </div>
                  </dl>
                </button>
              </li>
            ))}
          </ul>
          {currentResponse?.page.nextCursor && (
            <div className="mt-4 flex justify-center">
              <button
                className="btn-secondary min-h-11"
                disabled={loadingMore}
                onClick={() => { void load(currentResponse.page.nextCursor ?? undefined, true) }}
              >
                <Icon name={loadingMore ? 'Loader2' : 'ChevronDown'} size={14} className={loadingMore ? 'animate-spin' : undefined} />
                {loadingMore ? 'Loading...' : 'Load more'}
              </button>
            </div>
          )}
        </>
      )}

      <DetailPanel
        open={currentSelection !== null}
        title={currentSelection?.displayName || currentSelection?.templateId || 'Inventory item'}
        onClose={() => setSelected(null)}
      >
        {currentSelection && (
          <div className="min-w-0">
            <div className="mb-4 flex flex-wrap gap-2">
              <span className="pill border-info/40 text-info">Read-only</span>
              {currentSelection.metadata.category && <span className="pill border-border">{currentSelection.metadata.category}</span>}
              {currentSelection.metadata.rarity && <span className="pill border-border">{currentSelection.metadata.rarity}</span>}
              {currentSelection.metadata.tier > 0 && <span className="pill border-border">Tier {currentSelection.metadata.tier}</span>}
            </div>
            <dl className="grid grid-cols-1 gap-3 text-sm sm:grid-cols-2">
              <div><dt className="text-text-dim">Template ID</dt><dd className="break-all font-mono">{currentSelection.templateId}</dd></div>
              <div><dt className="text-text-dim">Item ID</dt><dd>{currentSelection.id}</dd></div>
              <div><dt className="text-text-dim">Quantity</dt><dd>{currentSelection.quantity}</dd></div>
              <div><dt className="text-text-dim">Quality</dt><dd>{currentSelection.quality}</dd></div>
              <div><dt className="text-text-dim">Durability</dt><dd>{valueOrNotReported(currentSelection.durability)} / {valueOrNotReported(currentSelection.maxDurability)}</dd></div>
              <div><dt className="text-text-dim">Water</dt><dd>{valueOrNotReported(currentSelection.waterAmount)}{currentSelection.waterType ? ` ${currentSelection.waterType}` : ''}</dd></div>
              <div><dt className="text-text-dim">Source</dt><dd>{entityTypeLabel(currentSelection.entity.type)}</dd></div>
              <div><dt className="text-text-dim">Inventory type</dt><dd>{currentSelection.entity.inventoryType}</dd></div>
              <div><dt className="text-text-dim">Entity</dt><dd className="break-words">{currentSelection.entity.label || `Actor ${currentSelection.entity.id}`}</dd></div>
              <div><dt className="text-text-dim">Owner</dt><dd className="break-words">{currentSelection.entity.owner || 'Not proven'}</dd></div>
              <div><dt className="text-text-dim">Map</dt><dd className="break-words">{currentSelection.entity.map || 'Not reported'}</dd></div>
              <div><dt className="text-text-dim">Observed</dt><dd>{currentResponse?.freshness.observedAt ? new Date(currentResponse.freshness.observedAt).toLocaleString() : 'Not reported'}</dd></div>
            </dl>
            <Link className="btn-secondary mt-5 inline-flex min-h-11" to={currentSelection.entity.workspacePath}>
              Open owning {currentSelection.entity.type === 'player' ? 'player' : 'container'}
            </Link>
          </div>
        )}
      </DetailPanel>
    </WorkspaceSection>
  )
}
