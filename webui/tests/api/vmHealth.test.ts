import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getMapMemoryLimits, restoreMapMemoryLimits } from '../../src/api/maps'
import { getVmHealth } from '../../src/api/diagnostics'

interface FetchCall {
  url: string
  method?: string
  body?: unknown
}

let calls: FetchCall[]

beforeEach(() => {
  calls = []
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    let body: unknown
    if (init?.body) body = JSON.parse(init.body as string)
    calls.push({
      url: typeof input === 'string' ? input : input.toString(),
      method: init?.method,
      body,
    })
    return new Response(JSON.stringify({ ok: true, blockers: [] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

// Fences the VM-health surfaces added for the 2026-07-26 field cases against
// URL/method drift. The restore call MUTATES the battlegroup, so it must never
// silently become a GET.
describe('VM health + map memory limit API', () => {
  it('reads the VM health blockers over GET', async () => {
    await getVmHealth()
    expect(calls.at(-1)).toEqual({ url: '/api/diagnostics/vm-health', method: undefined, body: undefined })
  })

  it('reads per-map memory limits over GET', async () => {
    await getMapMemoryLimits()
    expect(calls.at(-1)).toEqual({ url: '/api/maps/memory-limits', method: undefined, body: undefined })
  })

  it('restores per-map memory limits over POST', async () => {
    await restoreMapMemoryLimits()
    expect(calls.at(-1)).toEqual({ url: '/api/maps/memory-limits/restore', method: 'POST', body: {} })
  })
})
