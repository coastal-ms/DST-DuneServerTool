// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as solo from '../../src/api/solo'

interface FetchCall {
  url: string
  method?: string
  body?: unknown
}

let calls: FetchCall[]

beforeEach(() => {
  calls = []
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.toString()
    const body = init?.body ? JSON.parse(String(init.body)) : undefined
    calls.push({ url, method: init?.method, body })
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

function last(): FetchCall {
  const call = calls.at(-1)
  if (!call) throw new Error('No fetch call recorded')
  return call
}

describe('Solo Mode API contracts', () => {
  it('discovers profiles before connecting a selected root', async () => {
    await solo.discoverSolo('C:\\Solo\\Saved')
    expect(last()).toEqual({
      url: '/api/solo/discover',
      method: 'POST',
      body: { path: 'C:\\Solo\\Saved' },
    })
  })

  it('connects a selected data root and optional profile', async () => {
    await solo.connectSolo('C:\\Solo\\Saved', 'C:\\Solo\\Saved\\Cloud\\game.db')
    expect(last()).toEqual({
      url: '/api/solo/connect',
      method: 'POST',
      body: {
        path: 'C:\\Solo\\Saved',
        dbPath: 'C:\\Solo\\Saved\\Cloud\\game.db',
      },
    })
  })

  it('sends the exact offline settings confirmation phrase', async () => {
    await solo.saveSoloSettings({ GatheringAmount: '2.500000' }, 'profile-token')
    expect(last()).toEqual({
      url: '/api/solo/settings',
      method: 'PUT',
      body: {
        settings: { GatheringAmount: '2.500000' },
        expectedProfileToken: 'profile-token',
        confirm: 'APPLY SOLO SETTINGS',
      },
    })
  })

  it('creates and restores backups through distinct endpoints', async () => {
    await solo.createSoloBackup('profile-token')
    expect(last()).toEqual({
      url: '/api/solo/backups',
      method: 'POST',
      body: { expectedProfileToken: 'profile-token' },
    })

    await solo.restoreSoloBackup('123\\game-20260814.db', 'profile-token')
    expect(last()).toEqual({
      url: '/api/solo/restore',
      method: 'POST',
      body: {
        relativePath: '123\\game-20260814.db',
        expectedProfileToken: 'profile-token',
        confirm: 'RESTORE SOLO SAVE',
      },
    })

    await solo.deleteSoloBackup('FLS_beta-123\\game-old.db', 'profile-token')
    expect(last()).toEqual({
      url: '/api/solo/backups',
      method: 'DELETE',
      body: {
        relativePath: 'FLS_beta-123\\game-old.db',
        expectedProfileToken: 'profile-token',
        confirm: 'DELETE SOLO BACKUP',
      },
    })
  })

  it('sends item grants with destination, profile token, and offline confirmation', async () => {
    await solo.grantSoloItems(
      'inventory:49',
      [{ templateId: 'CopperBar', quantity: 100, quality: 0 }],
      'profile-token',
    )
    expect(last()).toEqual({
      url: '/api/solo/items/grant',
      method: 'POST',
      body: {
        destination: 'inventory:49',
        items: [{ templateId: 'CopperBar', quantity: 100, quality: 0 }],
        expectedProfileToken: 'profile-token',
        confirm: 'GIVE SOLO ITEMS',
      },
    })
  })

  it('sets exact currency balances with profile and offline confirmation', async () => {
    await solo.setSoloCurrencies(1_000_000, 250_000, 'profile-token')
    expect(last()).toEqual({
      url: '/api/solo/currencies',
      method: 'PUT',
      body: {
        solari: 1_000_000,
        scrip: 250_000,
        expectedProfileToken: 'profile-token',
        confirm: 'SET SOLO CURRENCIES',
      },
    })
  })

  it('fills a confirmed water container with profile and offline confirmation', async () => {
    await solo.fillSoloWaterContainer(787987, 'profile-token')
    expect(last()).toEqual({
      url: '/api/solo/fillables/water',
      method: 'POST',
      body: {
        itemId: 787987,
        expectedProfileToken: 'profile-token',
        confirm: 'FILL SOLO WATER',
      },
    })
  })

  it('sends the three verified progression actions with exact confirmations', async () => {
    await solo.maxSoloSpecializations('profile-token')
    expect(last()).toEqual({
      url: '/api/solo/progression/specializations/max',
      method: 'POST',
      body: {
        expectedProfileToken: 'profile-token',
        confirm: 'MAX SOLO SPECIALIZATIONS',
      },
    })

    await solo.completeSoloFindTheFremen('profile-token')
    expect(last()).toEqual({
      url: '/api/solo/progression/find-the-fremen',
      method: 'POST',
      body: {
        expectedProfileToken: 'profile-token',
        confirm: 'COMPLETE FIND THE FREMEN',
      },
    })

    await solo.enableSoloAllSkills('profile-token')
    expect(last()).toEqual({
      url: '/api/solo/progression/skills/enable-all',
      method: 'POST',
      body: {
        expectedProfileToken: 'profile-token',
        confirm: 'ENABLE SOLO SKILLS',
      },
    })
  })
})
