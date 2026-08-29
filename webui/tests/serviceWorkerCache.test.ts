import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { runInNewContext } from 'node:vm'
import { describe, expect, it, vi } from 'vitest'

type WorkerRequest = {
  method: string
  url: string
  mode: string
  destination: string
}

type FetchHandler = (event: {
  request: WorkerRequest
  respondWith: (response: Promise<Response> | Response) => void
}) => void

function loadWorker(cachedResponse?: Response) {
  const handlers = new Map<string, (event: never) => void>()
  const match = vi.fn(async () => cachedResponse)
  const put = vi.fn(async () => undefined)
  const fetch = vi.fn(async () => new Response('network', { status: 200 }))
  const deleteCache = vi.fn(async () => true)
  const context = {
    URL,
    fetch,
    caches: {
      open: vi.fn(async () => ({ match, put })),
      keys: vi.fn(async () => ['dst-local-app-shell-v1', 'dst-local-app-shell-v2']),
      delete: deleteCache,
    },
    self: {
      location: { origin: 'http://127.0.0.1:47823' },
      skipWaiting: vi.fn(),
      clients: { claim: vi.fn() },
      addEventListener: (name: string, handler: (event: never) => void) => {
        handlers.set(name, handler)
      },
    },
  }

  const source = readFileSync(resolve(__dirname, '../public/sw.js'), 'utf8')
  runInNewContext(source, context)
  return { deleteCache, fetch, handlers, match, put }
}

function runFetch(handler: FetchHandler, request: WorkerRequest) {
  let response: Promise<Response> | Response | undefined
  handler({
    request,
    respondWith: value => { response = value },
  })
  return response
}

describe('local app-shell service worker', () => {
  it('seeds the successful document and its static assets', async () => {
    const worker = loadWorker()
    const handler = worker.handlers.get('message') as unknown as (event: {
      data: unknown
      waitUntil: (work: Promise<void>) => void
    }) => void
    let work: Promise<void> | undefined

    handler({
      data: {
        type: 'SEED_APP_SHELL',
        documentUrl: 'http://127.0.0.1:47823/?t=fresh',
        assetUrls: ['http://127.0.0.1:47823/assets/app.js'],
      },
      waitUntil: value => { work = value },
    })
    await work

    expect(worker.fetch).toHaveBeenCalledTimes(2)
    expect(worker.put).toHaveBeenCalledWith('/', expect.any(Response))
    expect(worker.put).toHaveBeenCalledWith(
      'http://127.0.0.1:47823/assets/app.js',
      expect.any(Response),
    )
  })

  it('serves the cached frontend immediately for shell startup', async () => {
    const worker = loadWorker(new Response('cached-shell', { status: 200 }))
    const response = runFetch(worker.handlers.get('fetch') as unknown as FetchHandler, {
      method: 'GET',
      url: 'http://127.0.0.1:47823/?t=old&shell-cache=1',
      mode: 'navigate',
      destination: 'document',
    })

    expect(await (await response)?.text()).toBe('cached-shell')
    expect(worker.fetch).not.toHaveBeenCalled()
    expect(worker.match).toHaveBeenCalledWith('/')
  })

  it('keeps API traffic network-only', async () => {
    const worker = loadWorker(new Response('cached-shell'))
    const request: WorkerRequest = {
      method: 'GET',
      url: 'http://127.0.0.1:47823/api/status',
      mode: 'cors',
      destination: '',
    }
    const response = runFetch(worker.handlers.get('fetch') as unknown as FetchHandler, request)

    expect(await (await response)?.text()).toBe('network')
    expect(worker.fetch).toHaveBeenCalledWith(request)
    expect(worker.match).not.toHaveBeenCalled()
  })

  it('refreshes the canonical shell cache after an online navigation', async () => {
    const worker = loadWorker()
    const response = runFetch(worker.handlers.get('fetch') as unknown as FetchHandler, {
      method: 'GET',
      url: 'http://127.0.0.1:47823/?t=fresh',
      mode: 'navigate',
      destination: 'document',
    })

    expect(await (await response)?.text()).toBe('network')
    expect(worker.put).toHaveBeenCalledWith('/', expect.any(Response))
  })
})
