// Sietches API — configure the number of Survival_1 (Hagga) shards + per-sietch names
import { api } from './client'

export interface Sietch {
  setIndex: number
  sietchNumber?: number
  map: string
  partitionId?: number
  partitions: number[]
  replicas: number | null
  memoryLimit: string | null
  name?: string | null
}

export interface SietchOverview {
  ok: boolean
  ns: string
  name: string
  sietchCount: number
  named?: boolean
  sietches: Sietch[]
  vmRamGB: number
  hostRamGB: number
  ramPerSietchGB: number
  baseInfraGB: number
  estimatedAfterAddGB: number
  willExceedHostRam: boolean
  maxPartitionId: number
}

export interface SietchMutation {
  ok: boolean
  message?: string
  partitionId?: number
  sietchNumber?: number
  removedPartition?: number
  count?: number
  named?: boolean
  sietches?: { dimension: number; partitionId: number; name: string | null }[]
  raw?: string
}

export function getSietches() {
  return api<SietchOverview>('/api/sietches')
}

export function addSietch() {
  return api<SietchMutation>('/api/sietches', { method: 'POST' })
}

export function removeLastSietch() {
  return api<SietchMutation>('/api/sietches/last', { method: 'DELETE' })
}

// Bulk configure: set the number of Hagga sietches (1-6), optionally naming each,
// then clean-restart the battlegroup.
export function setSietchConfig(count: number, names: string[], applyNames: boolean) {
  return api<SietchMutation>('/api/sietches/config', {
    method: 'POST',
    body: JSON.stringify({ count, names, applyNames }),
  })
}
