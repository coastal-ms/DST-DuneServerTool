import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from './router'
import './index.css'
import App from './App.tsx'
import RemoteApp from './pages/remote/RemoteApp'
import { ThemeProvider } from './theme/ThemeContext'
import { PortalAuthGate } from './auth/PortalAuthGate'

// Capture install prompt as early as possible so it's not lost before the
// React hook mounts. The hook checks window.__dunePwaPrompt on first render.
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault()
  ;(window as unknown as { __dunePwaPrompt?: Event }).__dunePwaPrompt = e
})

// Cache only the local static app shell. Live API and remote-portal traffic
// remains network-only and authoritative.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').then(async (registration) => {
      if (new URLSearchParams(window.location.search).get('shell-cache') === '1') return
      await navigator.serviceWorker.ready
      const assetUrls = Array.from(document.querySelectorAll<HTMLScriptElement | HTMLLinkElement>(
        'script[src], link[rel="stylesheet"][href], link[rel~="icon"][href]',
      )).map(element => element instanceof HTMLScriptElement ? element.src : element.href)
      registration.active?.postMessage({
        type: 'SEED_APP_SHELL',
        documentUrl: window.location.href,
        assetUrls,
      })
    }).catch(() => { /* cached startup is optional */ })
  })
}

// Top-level routing split (issue #74): /remote/* renders the mobile-first
// remote portal tree, everything else renders the desktop portal. The split
// happens HERE (not inside <App />) so the remote tree doesn't pull in the
// desktop <StatusProvider> / <AppShell> chrome and doesn't poll local-only
// status APIs that would 401 over the CF tunnel.
const isRemote = window.location.pathname === '/remote'
  || window.location.pathname.startsWith('/remote/')

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <BrowserRouter>
        {isRemote ? <RemoteApp /> : <PortalAuthGate><App /></PortalAuthGate>}
      </BrowserRouter>
    </ThemeProvider>
  </StrictMode>,
)
