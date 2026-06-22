import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import './index.css'
import App from './App.tsx'
import RemoteApp from './pages/remote/RemoteApp'
import { ThemeProvider } from './theme/ThemeContext'
import { isLocalViewer } from './util/viewer'
import { hasUsableToken } from './api/client'

// Capture install prompt as early as possible so it's not lost before the
// React hook mounts. The hook checks window.__dunePwaPrompt on first render.
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault()
  ;(window as unknown as { __dunePwaPrompt?: Event }).__dunePwaPrompt = e
})

// Register the no-op service worker — Chromium requires one for installability.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => { /* ignore */ })
  })
}

// Top-level routing split (issue #74): /remote/* renders the mobile-first
// remote portal tree, everything else renders the desktop portal. The split
// happens HERE (not inside <App />) so the remote tree doesn't pull in the
// desktop <StatusProvider> / <AppShell> chrome and doesn't poll local-only
// status APIs that would 401 over the CF tunnel.
const isRemote = window.location.pathname === '/remote'
  || window.location.pathname.startsWith('/remote/')

// A remote viewer who lands on the FULL portal ("/", etc.) with no auth token
// would see a broken dashboard where every call 401s ("Invalid or missing
// token"). That happens when a friend opens the Cloudflare hostname root
// instead of /remote/. Send them to the proper mobile-first remote portal,
// which is Cloudflare-Access-gated and receives an injected token. Local
// viewers and SSH co-admins (who carry a ?t= token) are unaffected.
if (!isRemote && !isLocalViewer() && !hasUsableToken()) {
  window.location.replace('/remote/')
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <BrowserRouter>
        {isRemote ? <RemoteApp /> : <App />}
      </BrowserRouter>
    </ThemeProvider>
  </StrictMode>,
)
