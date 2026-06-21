// Scheduled BG restart API — DST-driven daily restart with an optional
// pre-restart in-game broadcast and a Funcom server-update check.
import { api } from './client'

export interface RestartSchedule {
  enabled: boolean
  time: string                 // 24h HH:mm in the DST host's local time
  broadcastLeadMinutes: number // 0 = no broadcast
  discordEnabled: boolean
  discordWebhookSet: boolean   // whether a webhook URL is stored (URL is write-only)
  lastRestartDate: string
  lastResult: string
  updateAvailable: boolean
  installedBuild: string
  latestBuild: string
  updateCheckedAt: string
}

export interface FuncomUpdateResult {
  ok: boolean
  available: boolean
  installedBuild: string
  latestBuild: string
  checkedAt: string
  message: string
}

export function getRestartSchedule() {
  return api<RestartSchedule>('/api/restart-schedule')
}

export function saveRestartSchedule(body: {
  enabled: boolean
  time: string
  broadcastLeadMinutes: number
  discordEnabled: boolean
  discordWebhookUrl?: string   // omit to leave the stored URL unchanged
}) {
  return api<RestartSchedule>('/api/restart-schedule', {
    method: 'PUT',
    body: JSON.stringify(body),
  })
}

export function checkFuncomUpdate() {
  return api<FuncomUpdateResult>('/api/restart-schedule/check-update', {
    method: 'POST',
  })
}

export function testDiscordWebhook() {
  return api<{ ok: boolean; message: string }>('/api/restart-schedule/test-discord', {
    method: 'POST',
  })
}
