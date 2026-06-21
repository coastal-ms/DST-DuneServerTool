// Pods API — read-only Kubernetes pod inspector (list + per-pod events).
import { api } from './client'

export interface PodSummary {
  namespace: string
  name: string
  ready: string
  status: string
  phase: string
  restarts: number
  node: string
  ip: string
  startTime: string
}

export interface PodsListResponse {
  ok: boolean
  pods: PodSummary[]
  count: number
}

export interface PodEvent {
  type: string
  reason: string
  message: string
  count: number
  time: string
  source: string
}

export interface PodEventsResponse {
  ok: boolean
  namespace: string
  name: string
  events: PodEvent[]
  describe: string
}

export function getPods() {
  return api<PodsListResponse>('/api/pods')
}

export function getPodEvents(namespace: string, name: string) {
  const qs = `?namespace=${encodeURIComponent(namespace)}&name=${encodeURIComponent(name)}`
  return api<PodEventsResponse>(`/api/pods/events${qs}`)
}
