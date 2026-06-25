import { api } from './client'

export type FlsWorld = {
  ok: boolean
  reachable: boolean
  world?: string
  hostId?: string
  phase?: string
  error?: string | null
}

export type FlsStepStatus = 'pending' | 'running' | 'done' | 'failed'

export type FlsStep = {
  id: string
  label: string
  status: FlsStepStatus
  detail?: string
}

export type FlsRotateStatus = {
  phase?: 'idle' | 'starting' | 'running' | 'done' | 'error'
  running?: boolean
  steps?: FlsStep[]
  error?: string
  backup?: string
  updated?: string
}

export type FlsRotateStart = {
  ok: boolean
  running: boolean
  message?: string
}

// Probe the live battlegroup (world / HostId / phase). SSH round-trip; called on
// mount and after a rotation, not on every poll.
export function getFlsWorld(): Promise<FlsWorld> {
  return api<FlsWorld>('/api/fls-token/world')
}

// Fast (file-only) rotation progress for polling.
export function getFlsRotateStatus(): Promise<FlsRotateStatus> {
  return api<FlsRotateStatus>('/api/fls-token/status')
}

// Start the background rotation with the pasted self-hosting token.
export function rotateFlsToken(token: string): Promise<FlsRotateStart> {
  return api<FlsRotateStart>('/api/fls-token/rotate', {
    method: 'POST',
    body: JSON.stringify({ token }),
  })
}
