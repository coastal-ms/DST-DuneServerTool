// Map SpinUp API — toggle each map's MinServers floor in director.ini.
import { api } from './client'

export interface SpinUpMap {
  map: string
  label: string
  group: 'supported' | 'experimental'
  minServers: number
  enabled: boolean
  availablePartitions?: number
  supportsPartySharing?: boolean
  sharedParties?: boolean
}

// A map DST expects a director.ini section for, but whose [ Map_Name ]
// header is entirely absent (a config gap), not merely disabled. Distinct
// from a map simply not being controllable/known.
export interface SpinUpMissingSection {
  map: string
  label: string
  message: string
}

// A Retail map (see DuneSpinUpRetailMaps) whose section is absent only
// because it hasn't been started yet - the normal, low-severity case, not
// game-breaking. Distinct from SpinUpMissingSection's real-error tier.
export interface SpinUpNotStartedSection {
  map: string
  label: string
  message: string
}

export interface SpinUpMapsResult {
  ok: boolean
  ns?: string
  name?: string
  maps: SpinUpMap[]
  missingSections?: SpinUpMissingSection[]
  notStartedSections?: SpinUpNotStartedSection[]
}

export interface SpinUpSetResult {
  ok: boolean
  map: string
  label?: string
  minServers?: number
  enabled?: boolean
  availablePartitions?: number
  noop?: boolean
  raw?: string
  message?: string
  sharedParties?: boolean
  missingSection?: boolean
  notStarted?: boolean
  firstStart?: boolean
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

export function setMapPartySharing(map: string, shared: boolean) {
  return api<SpinUpSetResult>(`/api/map-spinup/${encodeURIComponent(map)}/party-sharing`, {
    method: 'POST',
    body: JSON.stringify({ shared }),
  })
}
