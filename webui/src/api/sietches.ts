// Sietches API — list / add / remove Survival_1 shards on the battlegroup CRD
import { api } from './client'

export interface Sietch {
  setIndex: number
  map: string
  partitions: number[]
  replicas: number | null
  memoryLimit: string | null
}

export interface SietchOverview {
  ok: boolean
  ns: string
  name: string
  sietchCount: number
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
