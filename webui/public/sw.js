// Minimal service worker — required for PWA installability on Chromium.
// No caching: every request goes straight to the network so the user always
// gets the live server state (no stale dashboards).
self.addEventListener('install', (event) => {
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim())
})

self.addEventListener('fetch', (event) => {
  // Network-only passthrough.
  event.respondWith(fetch(event.request))
})
