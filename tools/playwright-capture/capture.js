// Captures the v6 Dune Server portal pages as PNG screenshots with PII
// masked at the DOM level (more robust than pixel-coord black rectangles).
//
// Usage:
//   node capture.js [--url <full-url-with-token>] [--out <dir>]
// Defaults: reads %LOCALAPPDATA%\DuneServer\last-url.txt for the URL,
//           writes to ../../docs/img/v6-*.png
//
// Viewport: 1600 x 1000 — fits in a normal browser window without horizontal
// scroll and matches the README's display aspect. Pages that overflow get
// captured as fullPage so the full content is visible.

const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')
const os = require('os')

function arg(name, fallback) {
  const i = process.argv.indexOf(name)
  return i >= 0 ? process.argv[i + 1] : fallback
}

const lastUrlPath = path.join(os.homedir(), 'AppData', 'Local', 'DuneServer', 'last-url.txt')
const defaultUrl = fs.existsSync(lastUrlPath) ? fs.readFileSync(lastUrlPath, 'utf8').trim() : null
const baseUrl = arg('--url', defaultUrl)
if (!baseUrl) {
  console.error('No portal URL. Pass --url <url> or ensure last-url.txt exists.')
  process.exit(2)
}
const outDir = path.resolve(arg('--out', path.join(__dirname, '..', '..', 'docs', 'img')))
fs.mkdirSync(outDir, { recursive: true })

// SPA routes — hash fragment because the portal uses HashRouter
const pages = [
  { route: '/',           file: 'v6-server-health.png', label: 'Server Health', wait: 2500, fullPage: true },
  { route: '/commands',   file: 'v6-commands.png',      label: 'Commands',      wait: 1200, fullPage: true },
  { route: '/terminal',   file: 'v6-terminal.png',      label: 'PowerShell',    wait: 1500 },
  { route: '/characters', file: 'v6-characters.png',    label: 'Characters',    wait: 5000, fullPage: true },
  { route: '/gameconfig', file: 'v6-gameconfig.png',    label: 'Game Config',   wait: 3000, fullPage: true },
  { route: '/database',   file: 'v6-database.png',      label: 'Database',      wait: 2000, fullPage: true },
  { route: '/sietches',   file: 'v6-sietches.png',      label: 'Sietches',      wait: 1500, fullPage: true },
  { route: '/dd-map',     file: 'v6-dd-map.png',        label: 'DD Map',        wait: 2000, fullPage: true },
  { route: '/settings',   file: 'v6-settings.png',      label: 'Settings',      wait: 2000, fullPage: true },
  { route: '/setup',      file: 'v6-setup-wizard.png',  label: 'Setup Wizard',  wait: 1500, fullPage: true },
]

// CSS injected into every page to mask PII at the DOM layer.
// Matches anything that looks like an IP address, a battlegroup ID, an SSH
// hostname, or a character name. The masks are solid black bars that overlay
// the underlying text (we keep layout intact by using `text-shadow` to
// flatten + `color: transparent` + a `::after` pseudo with same width).
const piiScrubCss = `
  /* Generic PII text helpers — applied via JS by data attribute */
  [data-pii="ip"], [data-pii="bgid"], [data-pii="hostname"], [data-pii="charname"], [data-pii="username"] {
    color: transparent !important;
    background: #000 !important;
    border-radius: 2px;
  }
  /* Character-rail name rows in Characters page */
  .char-row-name, .character-list-item span {
    /* fallback for any class-based names */
  }
`

// JS injected into every page after navigation. Walks visible text nodes and
// masks anything matching PII patterns (IPv4, BG hashes like
// sh-<32hex>-<6alphanum>, hostnames containing dune-awakening, etc.).
const piiScrubJs = `
(() => {
  const IP_RX = /\\b(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\b/g
  const BG_RX = /\\bsh-[0-9a-f]{16,}-[0-9a-z]{4,}\\b/gi
  const HOST_RX = /\\bdune-awakening\\b/gi
  const NAMESPACE_RX = /\\bfuncom-seabass-sh-[0-9a-f]{16,}-[0-9a-z]{4,}\\b/gi

  // Real names + identifiers we want scrubbed wherever they appear (case-insensitive).
  // Add to this list if a new PII string surfaces in a screenshot.
  const NAME_REPLACEMENTS = [
    [/\\bCoastal\\b/g, '<user>'],
    [/\\bHawk-i5\\b/gi, '<character>'],
    [/\\ballcoast\\b/gi, '<discord>'],
  ]

  function mask(s) {
    let out = s
      .replace(NAMESPACE_RX, 'funcom-seabass-<bg-id>')
      .replace(BG_RX, 'sh-<bg-id>')
      .replace(IP_RX, '<ip>')
      .replace(HOST_RX, '<host>')
    for (const [rx, rep] of NAME_REPLACEMENTS) out = out.replace(rx, rep)
    return out
  }

  function walk(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      const original = node.nodeValue
      const masked = mask(original)
      if (masked !== original) node.nodeValue = masked
      return
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return
    if (node.tagName === 'SCRIPT' || node.tagName === 'STYLE') return
    // Mask input/textarea VALUES (the input.value property, not just the attribute)
    if (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA') {
      if (node.value) {
        const m = mask(node.value)
        if (m !== node.value) {
          // Set via property assignment so the browser actually shows the new text
          const proto = Object.getPrototypeOf(node)
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set
          setter.call(node, m)
          // Fire input event so React state syncs (in case any controlled-input logic re-renders)
          node.dispatchEvent(new Event('input', { bubbles: true }))
        }
      }
      return
    }
    for (const c of Array.from(node.childNodes)) walk(c)
  }
  walk(document.body)

  // Also mask the Windows-user path: C:\\Users\\<name>\\...
  document.body.innerHTML = document.body.innerHTML.replace(/C:\\\\Users\\\\[^\\\\<>"' ]+/g, 'C:\\\\Users\\\\<user>')
})()
`

;(async () => {
  const browser = await chromium.launch({ headless: true })
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    deviceScaleFactor: 1.5,  // crisper screenshots
  })
  const page = await ctx.newPage()

  const u = new URL(baseUrl)
  // Initial load: hit the root with the token. The token sets a session cookie
  // so subsequent navigations within the same context don't need it.
  const initialUrl = `${u.origin}/${u.search}`
  console.log('Initial load:', initialUrl)
  await page.goto(initialUrl, { waitUntil: 'networkidle', timeout: 15000 })
  try {
    await page.waitForSelector('nav, [class*="sidebar"], [class*="Sidebar"]', { timeout: 8000 })
  } catch {
    console.warn('  app shell selector not found, proceeding with timed wait')
    await page.waitForTimeout(2000)
  }

  for (const p of pages) {
    console.log(`\n→ ${p.label}  (${p.route})`)
    // BrowserRouter: navigate to the real path. Append token as belt-and-suspenders
    // in case the session cookie isn't set yet (first navigation after token use).
    const target = `${u.origin}${p.route}${u.search}`
    await page.goto(target, { waitUntil: 'networkidle', timeout: 15000 }).catch(e => console.warn(`  goto: ${e.message}`))
    await page.waitForTimeout(p.wait)

    // Per-page hooks: expand collapsed cards, auto-select first row, etc.
    if (p.route === '/settings') {
      // Expand both collapsible update cards. Re-query buttons between clicks because
      // React re-renders after each toggle and detaches the previous DOM nodes.
      for (const label of ['Dune Server updates', 'dune-admin.exe']) {
        const clicked = await page.evaluate((needle) => {
          const buttons = Array.from(document.querySelectorAll('button, [role="button"]'))
          for (const b of buttons) {
            const txt = (b.textContent || '').trim()
            if (txt.includes(needle)) {
              // Only expand if currently collapsed (chevron rotation or aria-expanded)
              const expanded = b.getAttribute('aria-expanded')
              if (expanded === 'true') return false
              try { b.click() } catch {}
              return true
            }
          }
          return false
        }, label)
        if (clicked) await page.waitForTimeout(600)
      }
      await page.waitForTimeout(600)
    }
    if (p.route === '/characters') {
      // Auto-select the first character row so the editor surface is visible.
      // Rows aren't <button> — they're clickable <div>s in the rail. Match any
      // element whose text matches the "name + id NNN" pattern of a row.
      const clicked = await page.evaluate(() => {
        const all = Array.from(document.querySelectorAll('*'))
        // Find rows that are minimal text containers with both a name line and "id NNN"
        const candidates = all.filter(el => {
          if (el.children.length > 3) return false
          const t = (el.textContent || '').trim()
          return /\bid\s+\d+\b/.test(t) && t.length < 80
        })
        // Sort by depth (deeper = more specific = the row itself, not its container)
        candidates.sort((a, b) => {
          let da = 0, db = 0
          for (let n = a; n; n = n.parentElement) da++
          for (let n = b; n; n = n.parentElement) db++
          return db - da
        })
        if (candidates.length === 0) return false
        try { candidates[0].click() } catch { return false }
        return true
      })
      if (clicked) {
        await page.waitForTimeout(4500)  // wait for character data fetch
      }
    }

    // Inject scrubber + CSS AFTER the route renders and after per-page hooks
    await page.addStyleTag({ content: piiScrubCss })
    await page.evaluate(piiScrubJs)
    await page.waitForTimeout(400)

    const out = path.join(outDir, p.file)
    await page.screenshot({ path: out, fullPage: !!p.fullPage })
    const stat = fs.statSync(out)
    console.log(`  ✓ ${p.file}  (${(stat.size / 1024).toFixed(0)} KB)`)
  }

  await browser.close()
  console.log('\nDone. Output:', outDir)
})().catch(e => { console.error(e); process.exit(1) })
