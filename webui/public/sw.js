// Keep the local frontend available while the PowerShell backend starts.
// API, WebSocket, remote-portal, and update traffic always stays network-only.
const CACHE_NAME = 'dst-local-app-shell-v1'
const APP_SHELL_KEY = '/'

self.addEventListener('install', (event) => {
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim())
})

self.addEventListener('fetch', (event) => {
  const request = event.request
  if (request.method !== 'GET') return

  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  const networkOnly = url.pathname.startsWith('/api/')
    || url.pathname.startsWith('/ws/')
    || url.pathname.startsWith('/remote')
    || url.pathname === '/sw.js'
  if (networkOnly) {
    event.respondWith(fetch(request))
    return
  }

  const isAppShellNavigation = request.mode === 'navigate'
    && (url.pathname === '/' || url.pathname === '/index.html')
  if (isAppShellNavigation) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE_NAME)
      if (url.searchParams.get('shell-cache') === '1') {
        const cached = await cache.match(APP_SHELL_KEY)
        if (cached) return cached
      }

      try {
        const response = await fetch(request)
        if (response.ok) await cache.put(APP_SHELL_KEY, response.clone())
        return response
      } catch (error) {
        const cached = await cache.match(APP_SHELL_KEY)
        if (cached) return cached
        throw error
      }
    })())
    return
  }

  const cacheableAsset = ['script', 'style', 'image', 'font', 'manifest'].includes(request.destination)
  if (!cacheableAsset) {
    event.respondWith(fetch(request))
    return
  }

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME)
    const cached = await cache.match(request)
    if (cached) return cached

    const response = await fetch(request)
    if (response.ok) await cache.put(request, response.clone())
    return response
  })())
})
