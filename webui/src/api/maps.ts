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
  running: boolean
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

export function getMapState(key: string) {
  return api<MapState>(`/api/maps/${encodeURIComponent(key)}`)
}

export function startMap(key: string) {
  return api<MapStartResult>(`/api/maps/${encodeURIComponent(key)}/start`, {
    method: 'POST',
  })
}
