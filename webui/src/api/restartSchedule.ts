// Scheduled BG restart API — DST-driven daily restart with an optional
// pre-restart in-game broadcast and a Funcom server-update check.
import { api } from './client'

export interface RestartSchedule {
  enabled: boolean
  time: string                 // 24h HH:mm in the DST host's local time
  broadcastLeadMinutes: number // 0 = no broadcast
  discordEnabled: boolean
  discordNotifyOnline: boolean
  discordNotifyOffline: boolean
  discordNotifyRestarting: boolean
  discordNotifyUpdate: boolean
  discordWebhookSet: boolean   // whether a webhook URL is stored (URL is write-only)
  discordMentionId: string     // role id or 'everyone'/'here' to ping; '' = no ping
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
  discordNotifyOnline: boolean
  discordNotifyOffline: boolean
  discordNotifyRestarting: boolean
  discordNotifyUpdate: boolean
  discordWebhookUrl?: string   // omit to leave the stored URL unchanged
  discordMentionId?: string    // omit to leave the stored mention unchanged
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

// Fire-and-return: launches `battlegroup update` on the VM as a detached job
// and returns immediately. Poll getApplyServerUpdateStatus for progress.
// Returns 409 when a job is already running.
export function applyServerUpdate() {
  return api<{ ok: boolean; running: boolean; message: string }>(
    '/api/restart-schedule/apply-server-update',
    { method: 'POST' },
  )
}

export interface ApplyServerUpdateStatus {
  phase: 'idle' | 'running' | 'done' | 'error'
  running: boolean
  started: string | null
  updated: string
  finished: string | null
  ok: boolean
  rc: number | null
  installedBefore: string
  installedAfter: string
  tail: string[]
  error: string
}

export function getApplyServerUpdateStatus() {
  return api<ApplyServerUpdateStatus>('/api/restart-schedule/apply-server-update-status')
}

export function testDiscordWebhook() {
  return api<{ ok: boolean; message: string }>('/api/restart-schedule/test-discord', {
    method: 'POST',
  })
}
