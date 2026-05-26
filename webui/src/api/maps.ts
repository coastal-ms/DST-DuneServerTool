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
