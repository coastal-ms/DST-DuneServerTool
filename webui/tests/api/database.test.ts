// Wrappers in src/api/database.ts forward to /api/db/* with specific payloads.
// Several carry defaults (runSql readOnly/maxRows/timeout) or build query
// strings (backup-history) that are easy to break in a refactor, and some feed
// destructive backend actions (backup delete/prune), so lock the contracts.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as db from '../../src/api/database'

interface FetchCall {
  url: string
  method?: string
  body?: unknown
}

let calls: FetchCall[]

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

beforeEach(() => {
  calls = []
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.toString()
    let body: unknown = undefined
    if (init?.body) {
      try { body = JSON.parse(init.body as string) } catch { body = init.body }
    }
    calls.push({ url, method: init?.method, body })
    return jsonResponse({ ok: true })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

function last(): FetchCall {
  if (calls.length === 0) throw new Error('No fetch call recorded')
  return calls[calls.length - 1]!
}

describe('read endpoints (GET, no body)', () => {
  it('getDbInfo GETs /api/db/info', async () => {
    await db.getDbInfo()
    const c = last()
    expect(c.url).toBe('/api/db/info')
    expect(c.method).toBeUndefined()
    expect(c.body).toBeUndefined()
  })

  it('getBackupSchedule / getBackupDumpPods / getBackupMirror hit the right URLs', async () => {
    await db.getBackupSchedule()
    expect(last().url).toBe('/api/db/backup-schedule')

    await db.getBackupDumpPods()
    expect(last().url).toBe('/api/db/backup-dump-pods')

    await db.getBackupMirror()
    expect(last().url).toBe('/api/db/backup-mirror')
  })
})

describe('runSql defaults', () => {
  it('applies readOnly=true, maxRows=1000, timeoutSec=30 when omitted', async () => {
    await db.runSql({ sql: 'SELECT 1' })
    const c = last()
    expect(c.url).toBe('/api/db/query')
    expect(c.method).toBe('POST')
    expect(c.body).toEqual({ sql: 'SELECT 1', readOnly: true, maxRows: 1000, timeoutSec: 30 })
  })

  it('honours an explicit readOnly=false (write query) and custom caps', async () => {
    await db.runSql({ sql: 'UPDATE x SET y=1', readOnly: false, maxRows: 50, timeoutSec: 5 })
    expect(last().body).toEqual({ sql: 'UPDATE x SET y=1', readOnly: false, maxRows: 50, timeoutSec: 5 })
  })
})

describe('backup-history query string', () => {
  it('omits the query string entirely when no options are given', async () => {
    await db.getBackupHistory()
    expect(last().url).toBe('/api/db/backup-history')
  })

  it('encodes recent + logLines when provided', async () => {
    await db.getBackupHistory({ recent: 10, logLines: 200 })
    expect(last().url).toBe('/api/db/backup-history?recent=10&logLines=200')
  })

  it('includes recent=0 (a valid value, not treated as absent)', async () => {
    await db.getBackupHistory({ recent: 0 })
    expect(last().url).toBe('/api/db/backup-history?recent=0')
  })
})

describe('schedule + transfer + destructive payloads', () => {
  it('putBackupSchedule PUTs preset + retention knobs', async () => {
    await db.putBackupSchedule({ preset: 'daily', keepLast: 10, keepLastPods: 5, keepDaysPods: 3 })
    const c = last()
    expect(c.url).toBe('/api/db/backup-schedule')
    expect(c.method).toBe('PUT')
    expect(c.body).toEqual({ preset: 'daily', keepLast: 10, keepLastPods: 5, keepDaysPods: 3 })
  })

  it('downloadBackup / uploadBackup forward the paths', async () => {
    await db.downloadBackup({ vmPath: '/funcom/artifacts/a.backup', localPath: 'C:/dst/a.backup' })
    expect(last().url).toBe('/api/db/backup-download')
    expect(last().body).toEqual({ vmPath: '/funcom/artifacts/a.backup', localPath: 'C:/dst/a.backup' })

    await db.uploadBackup({ localPath: 'C:/dst/a.backup' })
    expect(last().url).toBe('/api/db/backup-upload')
    expect(last().body).toEqual({ localPath: 'C:/dst/a.backup' })
  })

  it('deleteBackups forwards the exact paths array (destructive — no mutation)', async () => {
    const paths = ['/funcom/artifacts/a.backup', '/funcom/artifacts/dst-scheduled-20260717-120000']
    await db.deleteBackups({ paths })
    expect(last().url).toBe('/api/db/backup-delete')
    expect(last().method).toBe('POST')
    expect(last().body).toEqual({ paths })
  })

  it('pruneBackupDumpPods sends keepLast + keepDays', async () => {
    await db.pruneBackupDumpPods({ keepLast: 10, keepDays: 7 })
    expect(last().url).toBe('/api/db/prune-backup-dump-pods')
    expect(last().body).toEqual({ keepLast: 10, keepDays: 7 })
  })
})

describe('local backup mirror', () => {
  it('setBackupMirror forwards only the provided fields', async () => {
    await db.setBackupMirror({ enabled: true, folder: 'C:/dst/mirror' })
    expect(last().url).toBe('/api/db/backup-mirror')
    expect(last().method).toBe('POST')
    expect(last().body).toEqual({ enabled: true, folder: 'C:/dst/mirror' })

    await db.setBackupMirror({ enabled: false })
    expect(last().body).toEqual({ enabled: false })
  })

  it('openBackupMirrorFolder posts an empty object by default', async () => {
    await db.openBackupMirrorFolder()
    expect(last().url).toBe('/api/db/backup-mirror/open')
    expect(last().body).toEqual({})

    await db.openBackupMirrorFolder({ folder: 'C:/dst/mirror' })
    expect(last().body).toEqual({ folder: 'C:/dst/mirror' })
  })

  it('syncBackupMirror posts to the sync endpoint with an empty body', async () => {
    await db.syncBackupMirror()
    expect(last().url).toBe('/api/db/backup-mirror/sync')
    expect(last().method).toBe('POST')
    expect(last().body).toEqual({})
  })
})
