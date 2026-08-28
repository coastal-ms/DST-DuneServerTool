// Maps API — on-demand control of optional map pods (e.g. Deep Desert)
import { api } from './client'

export interface MapState {
  ok: boolean
  key: string
  label: string
  present: boolean
  setCount: number
  totalReplicas: number
  hasDisabledPart: boolean
  missingPartitionBinding?: boolean
  stuckDedicatedScaling?: boolean
  running: boolean
  activeInstances?: number
  readyInstances?: number
  targetInstances?: number
  playersOnline?: number | null
  playerIds?: string[]
  playersError?: string | null
  sets: Array<{
    idx: number
    map: string
    replicas: number | null
    dedicatedScaling: boolean
    partitionCount: number
  }>
}

export interface MapStartResult {
  ok: boolean
  key: string
  label?: string
  noop?: boolean
  patchOps?: number
  raw?: string
  message?: string
}

export interface MapStopResult {
  ok: boolean
  key: string
  label?: string
  noop?: boolean
  patchOps?: number
  forced?: boolean
  playersOnline?: number
  playerIds?: string[]
  raw?: string
  message?: string
  requiresConfirmation?: boolean
}

export function getMapState(key: string) {
  return api<MapState>(`/api/maps/${encodeURIComponent(key)}`)
}

export type MapFreshnessState = 'fresh' | 'refreshing' | 'stale' | 'partial' | 'unavailable'

export interface MapFreshness {
  observedAt: string | null
  cachedAt: string | null
  ageSeconds: number | null
  state: MapFreshnessState
  lastErrorCode: string | null
}

export interface MapLayerEnvelope<T> {
  layerId: string
  source: 'live' | 'cache' | 'static' | 'mixed' | 'unavailable'
  freshness: MapFreshness
  count: number
  page: {
    limit: number
    nextCursor: string | null
    truncated: boolean
  }
  error: { code: string; message?: string } | null
  data: T
}

export interface ActiveSpiceItem {
  fieldId: string
  state: string
  tier: number | null
  observedAt: string
  position: {
    status: 'verified' | 'unresolved'
    coordinateSystem: string | null
    x: number | null
    y: number | null
    reason: string | null
  }
}

export interface ActiveSpiceLayerData {
  summary: {
    activeCount: number
    state: 'active' | 'none-active'
    tier: number | null
    spatialStatus: 'verified' | 'unresolved'
    historyStatus: 'cached-observations' | 'unavailable'
  }
  items: ActiveSpiceItem[]
  history: Array<{
    fieldId: string
    state: string
    observedAt: string
  }>
}

export interface MapsCacheHealth {
  cache: {
    available: boolean
    revision: number
    generation: string
    hydratedAt: string
    publishedAt: string
    lastErrorCode: string | null
  }
  sources: Array<{
    sourceKey: string
    schemaFingerprint: string
    lastAttemptAt: string | null
    lastSuccessAt: string | null
    expiresAt: string | null
    lastErrorCode: string | null
  }>
}

export interface DeepDesertMapSnapshot {
  schemaVersion: number
  requestId: string
  generatedAt: string
  source: 'cache' | 'mixed' | 'unavailable'
  freshness: MapFreshness
  capabilities: string[]
  data: {
    map: {
      farmId: string
      mapId: string
      partitionId: string
      label: string
    }
    health: MapsCacheHealth
    layers: [
      MapLayerEnvelope<ActiveSpiceLayerData>,
      MapLayerEnvelope<unknown[]>,
    ]
  }
}

export function getDeepDesertMapSnapshot() {
  return api<DeepDesertMapSnapshot>('/api/v1/maps/deep-desert')
}

export function startMap(key: string) {
  return api<MapStartResult>(`/api/maps/${encodeURIComponent(key)}/start`, {
    method: 'POST',
  })
}

export function stopMap(key: string, force = false) {
  const qs = force ? '?force=true' : ''
  return api<MapStopResult>(`/api/maps/${encodeURIComponent(key)}/stop${qs}`, {
    method: 'POST',
  })
}

export interface FixPartitionsResult {
  ok: boolean
  output?: string
  logTail?: string
  message?: string
}

export function fixOnDemandPartitions() {
  return api<FixPartitionsResult>('/api/maps/fix-partitions', {
    method: 'POST',
  })
}

export interface RestartPodsResult {
  ok: boolean
  key: string
  label?: string
  noop?: boolean
  podsFound?: number
  podsDeleted?: number
  pods?: string[]
  raw?: string
  message?: string
}

// key: 'survival' (Hagga / Survival_1) | 'deepdesert' (Deep Desert)
export function restartMapPods(key: 'survival' | 'deepdesert') {
  return api<RestartPodsResult>('/api/maps/restart-pods', {
    method: 'POST', body: JSON.stringify({ key }),
  })
}
