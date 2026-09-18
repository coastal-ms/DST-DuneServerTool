import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  getDeepDesertPvp,
  applyGameConfigClient,
  getGameConfigExperimentalCategories,
  getGameConfigExperimentalCategory,
  getRetailServerSettings,
  saveRetailServerSettings,
  getSpicefieldState,
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

describe('Official Retail Server Settings API', () => {
  it('uses a read-only endpoint', async () => {
    await getRetailServerSettings()
    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/retail-server-settings',
      method: undefined,
      body: undefined,
    })
  })

  it('sends the expected revision and changed values through the guarded write endpoint', async () => {
    await saveRetailServerSettings('sha256-current', { FiefdomLimit: '4' })
    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/retail-server-settings',
      method: 'PUT',
      body: {
        revision: 'sha256-current',
        updates: { FiefdomLimit: '4' },
      },
    })
  })
})

describe('Game Config local client API', () => {
  it('sends an explicit client-evaluated shield update to the local-only apply route', async () => {
    await applyGameConfigClient([{
      file: 'engine',
      section: 'ConsoleVariables',
      key: 'Dune.DisableShieldOnShooting',
      label: 'Shield Drops While Shooting',
      value: '0',
    }], '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\Windows')

    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/client/apply',
      method: 'PUT',
      body: {
        updates: [{
          file: 'engine',
          key: 'Dune.DisableShieldOnShooting',
          value: '0',
        }],
        dir: '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\Windows',
      },
    })
  })
})

describe('Spicefield state API', () => {
  it('loads bounded raw state for one spicefield summary row', async () => {
    await getSpicefieldState(42)
    expect(calls.at(-1)).toEqual({
      url: '/api/gameconfig/spicefields/42/state',
      method: undefined,
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
