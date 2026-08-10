import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  getDeepDesertPvp,
  getGameConfigExperimentalCategories,
  getGameConfigExperimentalCategory,
  reloadGameConfigPods,
  saveDeepDesertPvp,
} from '../../src/api/gameconfig'

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
    return new Response(JSON.stringify({
      ok: true,
      enabled: false,
      forceAll: false,
      selectedPartitionIds: [],
      inactiveSelectedPartitionIds: [],
      staleSelectedPartitionIds: [],
      instances: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('Deep Desert PvP API', () => {
  it('loads running partition state', async () => {
    await getDeepDesertPvp()
    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/deep-desert-pvp',
      method: undefined,
      body: undefined,
    })
  })

  it('saves selected partition ids', async () => {
    await saveDeepDesertPvp(true, [8, 12])
    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/deep-desert-pvp',
      method: 'PUT',
      body: { enabled: true, partitionIds: [8, 12] },
    })
  })
})

describe('Game Config pod reload API', () => {
  it('requests a rolling game-pod reload', async () => {
    await reloadGameConfigPods()
    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/reload-pods',
      method: 'POST',
      body: undefined,
    })
  })
})

describe('Experimental Lab lazy catalog API', () => {
  it('loads category metadata separately from the normal schema', async () => {
    await getGameConfigExperimentalCategories()
    expect(calls.at(-1)?.url).toBe('/api/gameconfig/experimental/categories')
  })

  it('loads and URL-encodes only the selected category', async () => {
    await getGameConfigExperimentalCategory('Audio - engine/internal')
    expect(calls.at(-1)?.url).toBe('/api/gameconfig/experimental/category?name=Audio%20-%20engine%2Finternal')
  })
})
