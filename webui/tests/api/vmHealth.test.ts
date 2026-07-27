import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanupOldFuncomImages, getVmHealth } from '../../src/api/diagnostics'

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
    return new Response(JSON.stringify({ ok: true, faults: [] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('VM info API', () => {
  it('reads VM facts over GET', async () => {
    await getVmHealth()
    expect(calls.at(-1)).toEqual({ url: '/api/diagnostics/vm-health', method: undefined, body: undefined })
  })

  it('reads facts without issuing a mutation', async () => {
    await getVmHealth()
    expect(calls.every(c => c.method === undefined || c.method === 'GET')).toBe(true)
  })

  it('starts selective image cleanup only through its explicit POST', async () => {
    await cleanupOldFuncomImages()
    expect(calls.at(-1)).toEqual({
      url: '/api/diagnostics/cleanup-old-images',
      method: 'POST',
      body: {},
    })
  })
})
