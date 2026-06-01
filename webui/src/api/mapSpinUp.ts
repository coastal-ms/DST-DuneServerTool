// Map SpinUp API — toggle each map's MinServers floor (0/1) in director.ini.
import { api } from './client'

export interface SpinUpMap {
  map: string
  label: string
  group: 'supported' | 'experimental'
  minServers: number
  enabled: boolean
}

export interface SpinUpMapsResult {
  ok: boolean
  ns?: string
  name?: string
  maps: SpinUpMap[]
}

export interface SpinUpSetResult {
  ok: boolean
  map: string
  label?: string
  minServers?: number
  enabled?: boolean
  noop?: boolean
  raw?: string
  message?: string
}

export function getMapSpinUp() {
  return api<SpinUpMapsResult>('/api/map-spinup')
}

export function setMapSpinUp(map: string, enabled: boolean) {
  return api<SpinUpSetResult>(`/api/map-spinup/${encodeURIComponent(map)}`, {
    method: 'POST',
    body: JSON.stringify({ enabled }),
  })
}
