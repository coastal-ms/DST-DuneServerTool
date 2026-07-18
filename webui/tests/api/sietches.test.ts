// Wrappers in src/api/sietches.ts drive the v12.19.4 multi-Hagga sietch config
// feature. These stub `fetch` and assert each wrapper builds the right URL +
// body, so an accidental field rename (count/names/applyNames) or URL drift is
// caught before it breaks the reconcile-the-battlegroup call.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as s from '../../src/api/sietches'

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

describe('sietches API', () => {
  it('getSietches GETs /api/sietches with no body', async () => {
    await s.getSietches()
    const c = last()
    expect(c.url).toBe('/api/sietches')
    expect(c.method).toBeUndefined()
    expect(c.body).toBeUndefined()
  })

  it('setSietchConfig POSTs count + names + applyNames', async () => {
    await s.setSietchConfig(3, ['Alpha', 'Beta', 'Gamma'], true)
    const c = last()
    expect(c.url).toBe('/api/sietches/config')
    expect(c.method).toBe('POST')
    expect(c.body).toEqual({ count: 3, names: ['Alpha', 'Beta', 'Gamma'], applyNames: true })
  })

  it('setSietchConfig with applyNames=false still forwards the names array verbatim', async () => {
    // When the rename checkbox is off the UI passes applyNames=false; the names
    // array is still sent (backend ignores it) — the wrapper must not drop it.
    await s.setSietchConfig(1, [], false)
    expect(last().body).toEqual({ count: 1, names: [], applyNames: false })
  })

  it('setSietchConfig preserves an empty-string name in the middle of the array', async () => {
    // A blank name for one shard must keep its slot index, so it maps to the
    // right partition on the backend rather than shifting later names up.
    await s.setSietchConfig(3, ['First', '', 'Third'], true)
    expect(last().body).toEqual({ count: 3, names: ['First', '', 'Third'], applyNames: true })
  })
})
