// Database API — typed wrappers around /api/db/*
import { api } from './client'
import type {
  DbInfo,
  SqlResult,
  BackupSchedule,
  BackupHistory,
  BackupDumpPodList,
  BackupDumpPodPruneResult,
} from './types'

export function getDbInfo() {
  return api<DbInfo>('/api/db/info')
}

export function runSql(opts: {
  sql: string
  readOnly?: boolean
  maxRows?: number
  timeoutSec?: number
}) {
  return api<SqlResult>('/api/db/query', {
    method: 'POST',
    body: JSON.stringify({
      sql:        opts.sql,
      readOnly:   opts.readOnly ?? true,
      maxRows:    opts.maxRows ?? 1000,
      timeoutSec: opts.timeoutSec ?? 30,
    }),
  })
}

export function getBackupSchedule() {
  return api<BackupSchedule>('/api/db/backup-schedule')
}

export function putBackupSchedule(opts: {
  preset: string
  keepLast: number
  keepLastPods?: number
  keepDaysPods?: number
}) {
  return api<BackupSchedule>('/api/db/backup-schedule', {
    method: 'PUT',
    body: JSON.stringify({
      preset:       opts.preset,
      keepLast:     opts.keepLast,
      keepLastPods: opts.keepLastPods,
      keepDaysPods: opts.keepDaysPods,
    }),
  })
}

export function getBackupHistory(opts: { recent?: number; logLines?: number } = {}) {
  const params = new URLSearchParams()
  if (opts.recent   != null) params.set('recent',   String(opts.recent))
  if (opts.logLines != null) params.set('logLines', String(opts.logLines))
  const qs = params.toString()
  return api<BackupHistory>(`/api/db/backup-history${qs ? `?${qs}` : ''}`)
}

export type BackupTransferResult = {
  ok: boolean
  path?: string
  remotePath?: string
  sizeBytes?: number
  message?: string
  error?: string
}

export function downloadBackup(opts: { vmPath: string; localPath: string }) {
  return api<BackupTransferResult>('/api/db/backup-download', {
    method: 'POST',
    body: JSON.stringify({ vmPath: opts.vmPath, localPath: opts.localPath }),
  })
}

export function uploadBackup(opts: { localPath: string }) {
  return api<BackupTransferResult>('/api/db/backup-upload', {
    method: 'POST',
    body: JSON.stringify({ localPath: opts.localPath }),
  })
}

export type BackupDeleteResult = {
  ok: boolean
  deleted: string[]
  failed: { path: string; reason: string }[]
  message?: string
  error?: string
}

export function deleteBackups(opts: { paths: string[] }) {
  return api<BackupDeleteResult>('/api/db/backup-delete', {
    method: 'POST',
    body: JSON.stringify({ paths: opts.paths }),
  })
}

export function getBackupDumpPods() {
  return api<BackupDumpPodList>('/api/db/backup-dump-pods')
}

export function pruneBackupDumpPods(opts: { keepLast: number; keepDays: number }) {
  return api<BackupDumpPodPruneResult>('/api/db/prune-backup-dump-pods', {
    method: 'POST',
    body: JSON.stringify({ keepLast: opts.keepLast, keepDays: opts.keepDays }),
  })
}
