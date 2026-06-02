// Database API — typed wrappers around /api/db/*
import { api } from './client'
import type {
  DbInfo,
  SqlResult,
  BackupSchedule,
  BackupHistory,
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

export function putBackupSchedule(opts: { preset: string; retentionDays: number }) {
  return api<BackupSchedule>('/api/db/backup-schedule', {
    method: 'PUT',
    body: JSON.stringify({ preset: opts.preset, retentionDays: opts.retentionDays }),
  })
}

export function getBackupHistory(opts: { recent?: number; logLines?: number } = {}) {
  const params = new URLSearchParams()
  if (opts.recent   != null) params.set('recent',   String(opts.recent))
  if (opts.logLines != null) params.set('logLines', String(opts.logLines))
  const qs = params.toString()
  return api<BackupHistory>(`/api/db/backup-history${qs ? `?${qs}` : ''}`)
}
