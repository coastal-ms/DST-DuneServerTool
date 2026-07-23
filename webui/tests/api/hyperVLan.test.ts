import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  testHyperVLan,
  getHyperVLanCredential,
  saveHyperVLanCredential,
  deleteHyperVLanCredential,
  getHyperVLanHostResources,
  startHyperVLanInstall,
} from '../../src/api/setup'

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
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'Content-Type': 'application/json' } })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

// Fences the Hyper-V over LAN credential endpoints against URL/body drift.
// The password is a real field here (it has to reach the backend to be
// tested/saved) but must never be added to a GET/DELETE query string or URL.
describe('Hyper-V LAN credential API', () => {
  it('tests a candidate host with no credential (falls back to any saved one)', async () => {
    await testHyperVLan('192.168.1.50')
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/test',
      method: 'POST',
      body: { hostIp: '192.168.1.50', user: undefined, password: undefined },
    })
  })

  it('tests a candidate host WITH an explicit credential, without saving it', async () => {
    await testHyperVLan('192.168.1.50', 'HOST\\Administrator', 'hunter2')
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/test',
      method: 'POST',
      body: { hostIp: '192.168.1.50', user: 'HOST\\Administrator', password: 'hunter2' },
    })
  })

  it('reads credential info via GET with the host IP as a query param, no body', async () => {
    await getHyperVLanCredential('192.168.1.50')
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/credential?hostIp=192.168.1.50',
      method: undefined,
      body: undefined,
    })
  })

  it('omits the query param when no host IP is given (server falls back to configured host)', async () => {
    await getHyperVLanCredential()
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/credential',
      method: undefined,
      body: undefined,
    })
  })

  it('saves a credential over POST', async () => {
    await saveHyperVLanCredential('192.168.1.50', 'HOST\\Administrator', 'hunter2')
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/credential',
      method: 'POST',
      body: { hostIp: '192.168.1.50', user: 'HOST\\Administrator', password: 'hunter2' },
    })
  })

  it('removes the credential over DELETE with no body', async () => {
    await deleteHyperVLanCredential()
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/credential',
      method: 'DELETE',
      body: undefined,
    })
  })

  it('probes host resources without requiring user/password', async () => {
    await getHyperVLanHostResources('192.168.1.50')
    expect(calls.at(-1)).toEqual({
      url: '/api/setup/hyperv-lan/host-resources',
      method: 'POST',
      body: { hostIp: '192.168.1.50', user: undefined, password: undefined },
    })
  })

  it('starts an install without requiring user/password (falls back to saved credential)', async () => {
    await startHyperVLanInstall({
      hostIp: '192.168.1.50',
      destDrive: 'D:',
      memoryGB: 20,
      switchName: 'DuneExternal',
      vmPassword: '',
      replaceExisting: false,
    })
    expect(calls.at(-1)?.body).toMatchObject({
      hostIp: '192.168.1.50',
      destDrive: 'D:',
      memoryGB: 20,
    })
  })
})
