// Database API — typed wrappers around /api/db/*
import { api } from './client'
import type { DbInfo, SqlResult } from './types'

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
