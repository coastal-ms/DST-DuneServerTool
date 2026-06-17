// Wrappers in src/api/gameplay.ts each forward to a specific REST URL with a
// specific JSON body. These tests stub `fetch` globally and assert each
// wrapper builds the URL + body correctly. They catch typos, dropped fields,
// and accidental URL drift introduced during refactors.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as gp from '../../src/api/gameplay'

interface FetchCall {
  url: string
  method?: string
  body?: unknown
  headers: Record<string, string>
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
    const headers: Record<string, string> = {}
    if (init?.headers) {
      const h = new Headers(init.headers)
      h.forEach((v, k) => { headers[k] = v })
    }
    let body: unknown = undefined
    if (init?.body) {
      try { body = JSON.parse(init.body as string) } catch { body = init.body }
    }
    calls.push({ url, method: init?.method, body, headers })
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

describe('Phase A — currency / progression writes', () => {
  it('giveScrip POSTs /give-scrip with account_id + amount', async () => {
    await gp.giveScrip(42, 1000)
    const c = last()
    expect(c.url).toBe('/api/gameplay/players/give-scrip')
    expect(c.method).toBe('POST')
    expect(c.body).toEqual({ actor_id: 42, delta: 1000 })
    expect(c.headers['content-type']).toBe('application/json')
    expect(c.headers['accept']).toBe('application/json')
  })

  it('giveFactionRep includes faction id + delta', async () => {
    await gp.giveFactionRep(7, 'atreides', -5)
    expect(last().body).toEqual({ actor_id: 7, faction_id: 1, delta: -5 })
    expect(last().url).toBe('/api/gameplay/players/give-faction-rep')
  })

  it('setFactionTier sends tier as a plain number', async () => {
    await gp.setFactionTier(7, 'harkonnen', 12)
    expect(last().body).toEqual({ actor_id: 7, faction_id: 2, tier: 12 })
  })

  it('awardCharXp uses pawn_id + delta + default category', async () => {
    await gp.awardCharXp(99, 10_000)
    expect(last().url).toBe('/api/gameplay/players/award-char-xp')
    expect(last().body).toEqual({ pawn_id: 99, delta: 10_000, category: 'Combat' })
  })

  it('awardIntel sends actor_id + pawn_id + delta (backend award-intel contract)', async () => {
    await gp.awardIntel(123, 99, 50)
    expect(last().url).toBe('/api/gameplay/players/award-intel')
    expect(last().body).toEqual({ actor_id: 123, pawn_id: 99, delta: 50 })
  })

  it('deleteAccount targets /delete-account', async () => {
    await gp.deleteAccount(404)
    expect(last().url).toBe('/api/gameplay/players/delete-account')
    expect(last().body).toEqual({ account_id: 404, confirm: 'DELETE' })
  })
})

describe('Phase C/D/E/F — items, vehicles, teleport, progression, jobs', () => {
  it('giveItems forwards the items array and overflow flag', async () => {
    const items = [
      { template: 'sword', qty: 1, quality: 5 },
      { template: 'shield', qty: 2 },
    ]
    await gp.giveItems(11, items, true)
    expect(last().url).toBe('/api/gameplay/players/give-items')
    expect(last().body).toEqual({ pawn_id: 11, items, allow_overflow: true })
  })

  it('repairGear / repairVehicle / refuelVehicle hit the right URLs', async () => {
    await gp.repairGear(11)
    expect(last().url).toBe('/api/gameplay/players/repair-gear')
    expect(last().body).toEqual({ pawn_id: 11 })

    await gp.repairVehicle(22)
    expect(last().url).toBe('/api/gameplay/players/repair-vehicle')
    expect(last().body).toEqual({ vehicle_id: 22 })

    await gp.refuelVehicle(22)
    expect(last().body).toEqual({ vehicle_id: 22 })
    await gp.refuelVehicle(22, 75)
    expect(last().body).toEqual({ vehicle_id: 22, fuel: 75 })
  })

  it('teleportToPlayer maps source/target ids correctly', async () => {
    await gp.teleportToPlayer(100, 200)
    expect(last().body).toEqual({ source_pawn_id: 100, target_pawn_id: 200 })
    expect(last().url).toBe('/api/gameplay/players/teleport-to-player')
  })

  it('progressionUnlock + progressionReverse + applyProgressionPreset', async () => {
    await gp.progressionUnlock(11, ['n1', 'n2'])
    expect(last().body).toEqual({ pawn_id: 11, node_ids: ['n1', 'n2'] })

    await gp.progressionReverse(11, ['n1'])
    expect(last().url).toBe('/api/gameplay/players/progression-reverse')
    expect(last().body).toEqual({ pawn_id: 11, node_ids: ['n1'] })

    await gp.applyProgressionPreset(11, 'survival-starter')
    expect(last().url).toBe('/api/gameplay/players/progression/apply-preset')
    expect(last().body).toEqual({ account_id: 11, preset_id: 'survival-starter' })
  })

  it('journey: complete + reset + wipe', async () => {
    await gp.completeJourneyStep(5, 'step-7')
    expect(last().body).toEqual({ account_id: 5, step_id: 'step-7' })

    await gp.resetJourney(5)
    expect(last().url).toBe('/api/gameplay/players/journey/reset')
    expect(last().body).toEqual({ account_id: 5 })

    await gp.wipeJourney(5)
    expect(last().url).toBe('/api/gameplay/players/journey/wipe')
  })

  it('contracts: complete one, bulk complete, bulk reverse', async () => {
    await gp.completeContract(5, 'c1')
    expect(last().body).toEqual({ account_id: 5, contract_id: 'c1' })

    await gp.completeContracts(5, ['c1', 'c2'])
    expect(last().url).toBe('/api/gameplay/players/contracts/complete')
    expect(last().body).toEqual({ account_id: 5, contract_ids: ['c1', 'c2'] })

    await gp.reverseContracts(5, ['c1'])
    expect(last().url).toBe('/api/gameplay/players/contracts/reverse')
  })

  it('jobs + starter class + tutorial/codex resets', async () => {
    await gp.grantJobSkills(11, 'planetologist')
    expect(last().body).toEqual({ pawn_id: 11, job_id: 'planetologist' })

    await gp.resetJobSkills(11, 'planetologist')
    expect(last().url).toBe('/api/gameplay/players/reset-job-skills')

    await gp.setStarterClass(11, 'fremen')
    expect(last().body).toEqual({ pawn_id: 11, class_id: 'fremen' })

    await gp.deleteTutorials(5)
    expect(last().url).toBe('/api/gameplay/players/delete-tutorials')

    await gp.wipeCodex(5)
    expect(last().url).toBe('/api/gameplay/players/wipe-codex')
  })
})

describe('Phase G+H — RMQ live commands (PlayerTarget shape)', () => {
  it('kickPlayer with fls_id only', async () => {
    await gp.kickPlayer({ fls_id: 'F-abc' })
    expect(last().url).toBe('/api/gameplay/players/kick')
    expect(last().body).toEqual({ fls_id: 'F-abc' })
  })

  it('kickPlayer with actor_id only', async () => {
    await gp.kickPlayer({ actor_id: 7777 })
    expect(last().body).toEqual({ actor_id: 7777 })
  })

  it('kickPlayer with both ids passes both through', async () => {
    await gp.kickPlayer({ fls_id: 'F-abc', actor_id: 7777 })
    expect(last().body).toEqual({ fls_id: 'F-abc', actor_id: 7777 })
  })

  it('setSkillPoints adds skill_points to PlayerTarget body', async () => {
    await gp.setSkillPoints({ fls_id: 'F-abc' }, 50)
    expect(last().url).toBe('/api/gameplay/players/set-skill-points')
    expect(last().body).toEqual({ fls_id: 'F-abc', skill_points: 50 })
  })

  it('cleanPlayerInventory + resetProgressionLive (target-only)', async () => {
    await gp.cleanPlayerInventory({ actor_id: 9 })
    expect(last().url).toBe('/api/gameplay/players/clean-inventory')
    expect(last().body).toEqual({ actor_id: 9 })

    await gp.resetProgressionLive({ actor_id: 9 })
    expect(last().url).toBe('/api/gameplay/players/reset-progression')
  })

  it('setSkillModuleLive sends module_id + level', async () => {
    await gp.setSkillModuleLive({ fls_id: 'F-x' }, 'mod.weapons', 3)
    expect(last().body).toEqual({ fls_id: 'F-x', module_id: 'mod.weapons', level: 3 })
  })

  it('giveItemLive sends template + qty + quality', async () => {
    await gp.giveItemLive({ fls_id: 'F-x' }, 'tpl.crysknife', 1, 5)
    expect(last().body).toEqual({ fls_id: 'F-x', template: 'tpl.crysknife', qty: 1, quality: 5 })
  })

  it('cheatScript sends script string verbatim', async () => {
    await gp.cheatScript({ fls_id: 'F-x' }, 'god')
    expect(last().body).toEqual({ fls_id: 'F-x', script_name: 'god' })
  })

  it('grantLive uses controller_id (NOT a PlayerTarget) + template + amount', async () => {
    await gp.grantLive(444, 'tpl.solari', 250)
    expect(last().url).toBe('/api/gameplay/players/grant-live')
    expect(last().body).toEqual({ controller_id: 444, template: 'tpl.solari', amount: 250 })
  })

  it('spawnVehicle copies fls_id/actor_id + optional location', async () => {
    await gp.spawnVehicle({ target: { fls_id: 'F-x' }, className: 'tpl.ornithopter' })
    expect(last().url).toBe('/api/gameplay/vehicles/spawn')
    expect(last().body).toEqual({ class_name: 'tpl.ornithopter', fls_id: 'F-x' })

    await gp.spawnVehicle({
      target: { actor_id: 1 },
      className: 'tpl.sandbike',
      location: { x: 1, y: 2, z: 3 },
    })
    expect(last().body).toEqual({
      class_name: 'tpl.sandbike',
      actor_id: 1,
      x: 1, y: 2, z: 3,
    })
  })

  it('chatWhisper sends fls_id + message (NOT a PlayerTarget)', async () => {
    await gp.chatWhisper('F-abc', 'hello there')
    expect(last().url).toBe('/api/gameplay/chat/whisper')
    expect(last().body).toEqual({ fls_id: 'F-abc', message: 'hello there' })
  })
})

describe('Phase I — tags delta + auto-dispatch fill-water', () => {
  it('updatePlayerTags sends add + remove arrays', async () => {
    await gp.updatePlayerTags(5, ['vip', 'mod'], ['banned'])
    expect(last().url).toBe('/api/gameplay/players/update-tags')
    expect(last().body).toEqual({ account_id: 5, add: ['vip', 'mod'], remove: ['banned'] })
  })

  it('updatePlayerTags tolerates empty arrays on either side', async () => {
    await gp.updatePlayerTags(5, ['vip'], [])
    expect(last().body).toEqual({ account_id: 5, add: ['vip'], remove: [] })

    await gp.updatePlayerTags(5, [], ['mod'])
    expect(last().body).toEqual({ account_id: 5, add: [], remove: ['mod'] })
  })

  it('fillWater hits the auto-dispatch endpoint with pawn_id', async () => {
    await gp.fillWater(11)
    expect(last().url).toBe('/api/gameplay/players/fill-water')
    expect(last().body).toEqual({ pawn_id: 11 })
  })

  it('setItemWater posts item_id + amount to set-item-water', async () => {
    await gp.setItemWater(70007, 2500)
    expect(last().url).toBe('/api/gameplay/players/set-item-water')
    expect(last().method).toBe('POST')
    expect(last().body).toEqual({ item_id: 70007, amount: 2500 })
  })
})

describe('Phase B — read endpoints (GET, no body)', () => {
  it('getPlayersOnline GETs /players/online', async () => {
    await gp.getPlayersOnline()
    const c = last()
    expect(c.url).toBe('/api/gameplay/players/online')
    expect(c.method).toBeUndefined()
    expect(c.body).toBeUndefined()
  })

  it('catalog reads hit the right URLs', async () => {
    await gp.getFactionCatalog()
    expect(last().url).toBe('/api/gameplay/players/factions')

    await gp.getSpecCatalog()
    expect(last().url).toBe('/api/gameplay/players/specs')

    await gp.getPartitions()
    expect(last().url).toBe('/api/gameplay/players/partitions')

    await gp.getContracts()
    expect(last().url).toBe('/api/gameplay/contracts')

    await gp.getProgressionPresets()
    expect(last().url).toBe('/api/gameplay/progression/presets')
  })

  it('per-player reads embed the id in the URL query', async () => {
    await gp.getPlayerJourney(123)
    expect(last().url).toBe('/api/gameplay/players/journey?account_id=123')

    await gp.exportPlayerData(123)
    expect(last().url).toBe('/api/gameplay/players/export?account_id=123')

    await gp.getPlayerCharXp(123)
    expect(last().url).toBe('/api/gameplay/players/char-xp?actor_id=123')

    await gp.getPlayerKeystones(123)
    expect(last().url).toBe('/api/gameplay/players/keystones?player_id=123')

    await gp.getPlayerVehicles(123)
    expect(last().url).toBe('/api/gameplay/players/vehicles?controller_id=123')

    await gp.getPlayerDungeons(123)
    expect(last().url).toBe('/api/gameplay/players/dungeons?player_id=123')

    await gp.getPlayerIds(123)
    expect(last().url).toBe('/api/gameplay/players/player-ids?actor_id=123')
  })

  it('getStorageOwnerDebug embeds placeable id', async () => {
    await gp.getStorageOwnerDebug(555)
    expect(last().url).toBe('/api/gameplay/storage/555/owner-debug')
  })
})

describe('api() transport contract', () => {
  it('sets Accept header on every request', async () => {
    await gp.getPlayersOnline()
    expect(last().headers['accept']).toBe('application/json')
  })

  it('omits Content-Type when no body is sent', async () => {
    await gp.getPlayersOnline()
    expect(last().headers['content-type']).toBeUndefined()
  })

  it('forwards X-Dune-Token header from sessionStorage', async () => {
    sessionStorage.setItem('dune.token', 'secret-token-xyz')
    await gp.giveScrip(1, 1)
    expect(last().headers['x-dune-token']).toBe('secret-token-xyz')
  })

  it('omits X-Dune-Token when no token is set', async () => {
    await gp.giveScrip(1, 1)
    expect(last().headers['x-dune-token']).toBeUndefined()
  })
})

describe('error path', () => {
  it('rejects with ApiError when the server returns non-2xx', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => {
      return new Response(JSON.stringify({ error: 'boom' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    await expect(gp.giveScrip(1, 1)).rejects.toMatchObject({
      status: 500,
      message: 'boom',
    })
  })
})

describe('isValidTemplateId — numeric give-item guard', () => {
  it('accepts real class-string template ids', () => {
    for (const t of ['CopperBar', 'Buggy_Booster_Mk6', 'BuildingBlueprint_CopyDevice', 'Combat_Light_SpiceMask']) {
      expect(gp.isValidTemplateId(t)).toBe(true)
    }
  })

  it('rejects a purely-numeric id (the "859" leak)', () => {
    expect(gp.isValidTemplateId('859')).toBe(false)
    expect(gp.isValidTemplateId('  859  ')).toBe(false)
    expect(gp.isValidTemplateId('0')).toBe(false)
  })

  it('rejects empty / whitespace-only ids', () => {
    expect(gp.isValidTemplateId('')).toBe(false)
    expect(gp.isValidTemplateId('   ')).toBe(false)
  })
})

describe('flattenItemCatalog — catalog shape parsing', () => {
  // The backend serializes `items` as an ARRAY of { templateId, name, category }.
  // The parser must read templateId, NOT the array index, or every picked item
  // gets a numeric template_id and the give-item guard makes it unselectable.
  it('reads the class-string templateId from the array shape (the live bug)', () => {
    const out = gp.flattenItemCatalog([
      { templateId: 'AzuriteOre', name: 'Copper Ore', category: 'Resources' },
      { templateId: 'CopperBar', name: 'Copper Ingot', category: 'Resources' },
    ])
    const copper = out.find(i => i.name === 'Copper Ore')
    expect(copper?.template_id).toBe('AzuriteOre')
    // No entry may carry a bare-numeric template_id (would be rejected on pick).
    expect(out.every(i => gp.isValidTemplateId(i.template_id))).toBe(true)
    expect(out.every(i => !/^\d+$/.test(i.template_id))).toBe(true)
  })

  it('still supports the legacy dict shape', () => {
    const out = gp.flattenItemCatalog({
      AzuriteOre: { name: 'Copper Ore', category: 'Resources' },
    })
    expect(out[0]?.template_id).toBe('AzuriteOre')
    expect(out[0]?.name).toBe('Copper Ore')
  })

  it('sorts by display name and skips entries with no template id', () => {
    const out = gp.flattenItemCatalog([
      { templateId: 'Zeta', name: 'Zeta Thing', category: '' },
      { templateId: '', name: 'No Id', category: '' },
      { templateId: 'Alpha', name: 'Alpha Thing', category: '' },
    ])
    expect(out.map(i => i.template_id)).toEqual(['Alpha', 'Zeta'])
  })
})

describe('parseTcnoPackageText', () => {
  const catalog: gp.CatalogItem[] = [
    { template_id: 'ComplexMachinery', name: 'Complex Machinery', category: 'Resources' },
    { template_id: 'DuraluminumRod', name: 'Duraluminum Ingot', category: 'Resources' },
    { template_id: 'PlastaniumBar', name: 'Plastanium Ingot', category: 'Resources' },
    { template_id: 'Silicone', name: 'Silicone Block', category: 'Resources' },
    { template_id: 'MelangeSpice', name: 'Spice Melange', category: 'Resources' },
  ]

  it('imports tcno two-line item/quantity format by display name', () => {
    const parsed = gp.parseTcnoPackageText(`Complex Machinery:
50
Duraluminum Ingot:
150
Plastanium Ingot:
70
Silicone Block:
104
Spice Melange:
39`, catalog)

    expect(parsed.warnings).toEqual([])
    expect(parsed.items).toEqual([
      { template: 'ComplexMachinery', name: 'Complex Machinery', qty: 50, quality: 0 },
      { template: 'DuraluminumRod', name: 'Duraluminum Ingot', qty: 150, quality: 0 },
      { template: 'PlastaniumBar', name: 'Plastanium Ingot', qty: 70, quality: 0 },
      { template: 'Silicone', name: 'Silicone Block', qty: 104, quality: 0 },
      { template: 'MelangeSpice', name: 'Spice Melange', qty: 39, quality: 0 },
    ])
  })

  it('reports unknown names without creating partial hidden failures', () => {
    const parsed = gp.parseTcnoPackageText('Mystery Goo:\n5', catalog)

    expect(parsed.items).toEqual([])
    expect(parsed.warnings).toEqual(['Unknown item "Mystery Goo"'])
  })
})
