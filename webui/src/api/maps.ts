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

// Per-map memory limits vs Funcom's world-template defaults. Funcom's
// experimental swap preset rewrites these to crushed values (Hagga 12Gi -> 1Gi,
// Overmap 2Gi -> 200Mi, Deep Desert 15Gi -> 10Gi) and they survive a VM resize,
// so "I gave the VM more RAM" never undoes them and produces no feedback.
export interface MapMemoryLimitEntry {
  map: string
  limit: string
  expected: string
  swapModeValue: boolean
  drifted: boolean
  idx?: number
}

export interface MapMemoryLimitReport {
  ok: boolean
  battlegroup?: string
  namespace?: string
  entries: MapMemoryLimitEntry[]
  drifted: MapMemoryLimitEntry[]
  swapMode: boolean
  message?: string
}

export function getMapMemoryLimits() {
  return api<MapMemoryLimitReport>('/api/maps/memory-limits')
}

export interface MapMemoryLimitRestoreResult {
  ok: boolean
  noop?: boolean
  patched: { map: string; from: string; to: string }[]
  raw?: string
  message?: string
}

// Patches only maps whose limit is BELOW the template default; a limit the
// operator deliberately raised is left alone.
export function restoreMapMemoryLimits() {
  return api<MapMemoryLimitRestoreResult>('/api/maps/memory-limits/restore', {
    method: 'POST', body: '{}',
  })
}
