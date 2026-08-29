import { describe, expect, it } from 'vitest'
import type { StatusSnapshot } from '../src/api/types'
import {
  readCachedStatus,
  STATUS_CACHE_KEY,
  STATUS_CACHE_MAX_AGE_MS,
  writeCachedStatus,
} from '../src/hooks/useStatus'

function makeStorage(): Pick<Storage, 'getItem' | 'setItem'> {
  const values = new Map<string, string>()
  return {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => { values.set(key, value) },
  }
}

const snapshot: StatusSnapshot = {
  vm: {
    exists: true,
    name: 'dune-awakening',
    state: 'Running',
    running: true,
    ip: '192.0.2.10',
    uptime: 60,
  },
  bg: null,
  ports: null,
  ts: '2026-08-29T16:00:00.000Z',
}

describe('Server Health status cache', () => {
  it('restores a recent status snapshot across app reloads', () => {
    const storage = makeStorage()
    writeCachedStatus(snapshot, storage, 1_000)

    expect(readCachedStatus(storage, 2_000)).toEqual(snapshot)
  })

  it('rejects expired, future, and malformed snapshots', () => {
    const storage = makeStorage()
    writeCachedStatus(snapshot, storage, 1_000)
    expect(readCachedStatus(storage, 1_000 + STATUS_CACHE_MAX_AGE_MS + 1)).toBeNull()

    writeCachedStatus(snapshot, storage, 2_000)
    expect(readCachedStatus(storage, 1_999)).toBeNull()

    storage.setItem(STATUS_CACHE_KEY, '{"savedAt":2000,"status":{"ts":4}}')
    expect(readCachedStatus(storage, 2_001)).toBeNull()
  })
})
