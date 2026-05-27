// Broadcasts API — generic + shutdown ServiceBroadcasts via mq-game.
import { api } from './client'

export type ShutdownType = 'Restart' | 'Shutdown' | 'Maintenance' | 'Update'

export interface BroadcastResult {
  ok: boolean
  action: 'broadcast' | 'shutdown' | 'cancel'
  message?: string
  raw?: string
  ns?: string
  pod?: string
  shutdownType?: ShutdownType
  delayMinutes?: number
  shutdownAt?: number
  cancel?: boolean
}

export function sendGenericBroadcast(title: string, body: string, durationSec: number) {
  return api<BroadcastResult>('/api/broadcasts/generic', {
    method: 'POST',
    body: JSON.stringify({ title, body, durationSec }),
  })
}

export function sendShutdownBroadcast(
  shutdownType: ShutdownType,
  delayMinutes: number,
  cancel = false,
) {
  return api<BroadcastResult>('/api/broadcasts/shutdown', {
    method: 'POST',
    body: JSON.stringify({ shutdownType, delayMinutes, cancel }),
  })
}
