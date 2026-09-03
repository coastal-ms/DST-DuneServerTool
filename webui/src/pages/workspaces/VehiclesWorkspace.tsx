import { useCallback, useEffect, useMemo, useState } from 'react'
import { ApiError } from '../../api/client'
import {
  cancelVehicleDeletion,
  getVehicleDeletionQueue,
  getVehicleFleet,
  processVehicleDeletions,
  queueVehicleDeletion,
  type VehicleDeletionQueue,
  type VehicleFleetRow,
} from '../../api/gameplay'
import { Icon } from '../../components/Icon'
import { SharedInventoryExplorer } from '../../components/inventory/SharedInventoryExplorer'
import { DataState, FreshnessBadge } from '../../components/platform/DataState'
import { WorkspaceLayout, WorkspaceSection, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'

const TABS: readonly WorkspaceTab[] = [
  { id: 'fleet', label: 'Fleet', to: '/vehicles?view=fleet', icon: 'Truck' },
  { id: 'cargo', label: 'Cargo', to: '/vehicles?view=cargo', icon: 'PackageSearch' },
]

function vehicleLabel(vehicle: VehicleFleetRow) {
  return vehicle.vehicle_name?.trim() || vehicle.class || `Vehicle ${vehicle.id}`
}

function errorMessage(error: unknown) {
  return error instanceof ApiError ? error.message : error instanceof Error ? error.message : String(error)
}

function VehicleFleetWorkspace() {
  const [vehicles, setVehicles] = useState<VehicleFleetRow[] | null>(null)
  const [queue, setQueue] = useState<VehicleDeletionQueue | null>(null)
  const [error, setError] = useState('')
  const [unavailable, setUnavailable] = useState(false)
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState<string | null>(null)

  const load = useCallback(async () => {
    setError('')
    setUnavailable(false)
    try {
      const [fleetResult, queueResult] = await Promise.all([
        getVehicleFleet(),
        getVehicleDeletionQueue(),
      ])
      setVehicles(fleetResult.vehicles ?? [])
      setQueue(queueResult)
    } catch (loadError) {
      const missingRoute = loadError instanceof ApiError
        && (loadError.status === 404 || loadError.message.includes('No route for'))
      if (missingRoute) {
        setUnavailable(true)
      } else {
        setError(errorMessage(loadError))
      }
    }
  }, [])

  useEffect(() => { void load() }, [load])

  const queuedVehicleIds = useMemo(
    () => new Set((queue?.entries ?? []).map(entry => entry.vehicle_id)),
    [queue?.entries],
  )

  const queueDeletion = useCallback(async (vehicle: VehicleFleetRow) => {
    const required = `DELETE ${vehicle.id}`
    const typed = window.prompt(
      `Queue permanent removal of ${vehicleLabel(vehicle)}?\n\n`
      + 'The vehicle, modules, stored items, ownership, markers, and recovery records will be removed during the next safe deletion window. '
      + 'A full database safety backup is mandatory before anything is deleted.\n\n'
      + `Type ${required} to continue.`,
    )
    if (typed !== required) {
      if (typed !== null) setError(`Removal was not queued because the confirmation did not match ${required}.`)
      return
    }
    setBusy(`queue:${vehicle.id}`); setError(''); setMessage('')
    try {
      const result = await queueVehicleDeletion(vehicle.id, typed)
      setMessage(result.message)
      await load()
    } catch (queueError) {
      setError(errorMessage(queueError))
    } finally {
      setBusy(null)
    }
  }, [load])

  const cancelDeletion = useCallback(async (entryId: string) => {
    setBusy(`cancel:${entryId}`); setError(''); setMessage('')
    try {
      const result = await cancelVehicleDeletion(entryId)
      setMessage(result.message)
      await load()
    } catch (cancelError) {
      setError(errorMessage(cancelError))
    } finally {
      setBusy(null)
    }
  }, [load])

  const processQueue = useCallback(async () => {
    const required = 'RESTART AND DELETE'
    const typed = window.prompt(
      'Open the safe vehicle deletion window now?\n\n'
      + 'DST will create a database backup, stop the entire battlegroup, delete and verify every queued vehicle, then start the battlegroup again. '
      + 'All connected players will be disconnected.\n\n'
      + `Type ${required} to continue.`,
    )
    if (typed !== required) {
      if (typed !== null) setError(`Nothing changed because the confirmation did not match ${required}.`)
      return
    }
    setBusy('process'); setError(''); setMessage('')
    try {
      const result = await processVehicleDeletions(typed)
      setMessage(result.message)
      await load()
    } catch (processError) {
      setError(errorMessage(processError))
      await load()
    } finally {
      setBusy(null)
    }
  }, [load])

  const loading = vehicles === null || queue === null

  if (loading && unavailable) {
    return (
      <WorkspaceLayout workspace={getWorkspace('vehicles')} tabs={TABS} activeTab="fleet">
        <DataState
          state="unavailable"
          title="Vehicle management is not included in this build"
          message="Install the matching DST backend build to use live fleet inventory and protected vehicle removal."
        />
      </WorkspaceLayout>
    )
  }

  if (loading && error) {
    return (
      <WorkspaceLayout workspace={getWorkspace('vehicles')} tabs={TABS} activeTab="fleet">
        <DataState
          state="error"
          title="Vehicle management unavailable"
          message={error}
          action={(
            <button className="btn-secondary" onClick={() => { void load() }}>
              <Icon name="RefreshCw" size={14} />
              Retry
            </button>
          )}
        />
      </WorkspaceLayout>
    )
  }

  return (
    <WorkspaceLayout workspace={getWorkspace('vehicles')} tabs={TABS} activeTab="fleet">
      <WorkspaceSection
        id="vehicles-fleet"
        title="Vehicle fleet"
        description="Live database inventory of player-owned vehicles. Queue permanent removals here, then apply them together inside one protected restart window."
      >
        {loading && !error && <DataState state="loading" title="Loading vehicle fleet" />}
        {error && <DataState state="error" title="Vehicle operation failed" message={error} />}
        {message && (
          <div className="mb-3 rounded-lg border border-success/35 bg-success/10 px-4 py-3 text-sm text-text" role="status">
            {message}
          </div>
        )}
        {!loading && vehicles && queue && (
          <>
            <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
              <div className="flex flex-wrap items-center gap-2">
                <FreshnessBadge state="fresh" label={`${vehicles.length} live vehicle${vehicles.length === 1 ? '' : 's'}`} />
                <span
                  className="pill border-info/40 bg-info/10 text-info"
                  title="This page uses temporary sample vehicle records until live vehicle details are complete."
                >
                  Demo Data
                </span>
              </div>
              <button className="btn-secondary" disabled={busy !== null} onClick={() => { void load() }}>
                <Icon name="RefreshCw" size={14} />
                Refresh
              </button>
            </div>
            {vehicles.length === 0 ? (
              <DataState state="empty" title="No player-owned vehicles found" />
            ) : (
              <ul className="grid min-w-0 grid-cols-1 gap-2 xl:grid-cols-2">
                {vehicles.map(vehicle => {
                  const queued = queuedVehicleIds.has(vehicle.id)
                  const working = busy === `queue:${vehicle.id}`
                  return (
                    <li key={vehicle.id} className="min-w-0 rounded-lg border border-border bg-surface-2 p-4">
                      <div className="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                        <div className="min-w-0">
                          <div className="flex flex-wrap items-center gap-2">
                            <h3 className="break-words font-semibold text-text">{vehicleLabel(vehicle)}</h3>
                            {queued && <span className="pill border-warning/40 text-warning">Queued</span>}
                            {vehicle.actor_state && <span className="pill border-border text-text-muted">{vehicle.actor_state}</span>}
                          </div>
                          <p className="mt-1 break-all font-mono text-xs text-text-dim">Actor {vehicle.id}</p>
                          <dl className="mt-3 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
                            <div>
                              <dt className="text-xs text-text-dim">Owners</dt>
                              <dd className="mt-0.5 break-words text-text">{vehicle.owners || 'No named owner'}</dd>
                            </div>
                            <div>
                              <dt className="text-xs text-text-dim">Map</dt>
                              <dd className="mt-0.5 break-words text-text">{vehicle.map || 'Not reported'}</dd>
                            </div>
                          </dl>
                        </div>
                        <button
                          className="btn-danger shrink-0"
                          disabled={busy !== null || queued}
                          onClick={() => { void queueDeletion(vehicle) }}
                        >
                          <Icon name={working ? 'Loader2' : 'Trash2'} size={14} className={working ? 'animate-spin' : undefined} />
                          {queued ? 'Queued' : working ? 'Queuing...' : 'Queue removal'}
                        </button>
                      </div>
                    </li>
                  )
                })}
              </ul>
            )}
          </>
        )}
      </WorkspaceSection>

      <WorkspaceSection
        id="vehicles-deletion-queue"
        title="Safe deletion queue"
        description="Nothing is deleted while maps are live. Processing creates a labeled safety backup, stops the battlegroup, deletes and verifies every queued actor transactionally, then starts the battlegroup."
      >
        {!queue || queue.entries.length === 0 ? (
          <DataState state={queue ? 'empty' : 'loading'} title={queue ? 'No vehicles queued' : 'Loading deletion queue'} />
        ) : (
          <div className="card min-w-0 p-4">
            <ul className="divide-y divide-border">
              {queue.entries.map(entry => (
                <li key={entry.id} className="flex min-w-0 flex-col gap-3 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0">
                    <div className="break-words font-medium text-text">{entry.vehicle_name || entry.class || `Vehicle ${entry.vehicle_id}`}</div>
                    <p className="mt-1 break-words text-xs text-text-dim">
                      Actor {entry.vehicle_id} · {entry.owners || 'No named owner'} · queued {new Date(entry.created_at).toLocaleString()}
                    </p>
                    {entry.message && <p className="mt-1 text-xs text-text-muted">{entry.message}</p>}
                  </div>
                  <button
                    className="btn-secondary shrink-0"
                    disabled={busy !== null}
                    onClick={() => { void cancelDeletion(entry.id) }}
                  >
                    <Icon name={busy === `cancel:${entry.id}` ? 'Loader2' : 'X'} size={14} className={busy === `cancel:${entry.id}` ? 'animate-spin' : undefined} />
                    Cancel
                  </button>
                </li>
              ))}
            </ul>
            <div className="mt-4 flex flex-col gap-2 border-t border-border pt-4 sm:flex-row sm:items-center sm:justify-between">
              <p className="max-w-[72ch] text-xs text-warning">
                Processing disconnects every player and restarts the full battlegroup.
              </p>
              <button className="btn-danger shrink-0" disabled={busy !== null || queue.running} onClick={() => { void processQueue() }}>
                <Icon name={busy === 'process' || queue.running ? 'Loader2' : 'ShieldAlert'} size={14} className={busy === 'process' || queue.running ? 'animate-spin' : undefined} />
                {busy === 'process' || queue.running ? 'Processing...' : `Backup, restart, and delete ${queue.entries.length}`}
              </button>
            </div>
          </div>
        )}
      </WorkspaceSection>
    </WorkspaceLayout>
  )
}

export default function VehiclesWorkspace() {
  const view = new URLSearchParams(useSearch()).get('view')
  if (view !== 'cargo') return <VehicleFleetWorkspace />
  return (
    <WorkspaceLayout workspace={getWorkspace('vehicles')} tabs={TABS} activeTab="cargo">
      <SharedInventoryExplorer
        entityTypes={[]}
        title="Vehicle cargo"
        description="The shared inventory workspace will use this view once the game database relationship is proven."
        unavailableReason="Vehicle ownership is proven, but a vehicle-to-cargo inventory join is not. DST will not guess from actor classes or owner names."
      />
    </WorkspaceLayout>
  )
}
