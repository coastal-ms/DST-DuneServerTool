// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setMapPartySharing } from '../../src/api/mapSpinUp'

interface FetchCall {
  url: string
  method?: string
  body?: unknown
}

let calls: FetchCall[]

beforeEach(() => {
  calls = []
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({
      url: typeof input === 'string' ? input : input.toString(),
      method: init?.method,
      body: init?.body ? JSON.parse(init.body as string) : undefined,
    })
    return new Response(JSON.stringify({ ok: true, sharedParties: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('Map Spin-Up party sharing API', () => {
  it('updates the URL-encoded map through the dedicated endpoint', async () => {
    await setMapPartySharing('CB_Story_DestroyedZanovar', true)
    expect(calls.at(-1)).toEqual({
      url: '/api/map-spinup/CB_Story_DestroyedZanovar/party-sharing',
      method: 'POST',
      body: { shared: true },
    })
  })
})
