// Capture the seven screenshots used by the README and Astro feature tour.
// Live server data is preserved, but identifying values are replaced in the DOM
// with deterministic documentation-only examples before each screenshot.
//
// Usage:
//   node capture.js [--url <full-url-with-token>] [--out <dir>]
//
// Defaults:
//   URL:    %LOCALAPPDATA%\DuneServer\last-url.txt
//   Output: ../../docs/img

const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')
const os = require('os')

function arg(name, fallback) {
  const index = process.argv.indexOf(name)
  return index >= 0 ? process.argv[index + 1] : fallback
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

const pages = [
  { route: '/', file: 'server-health.png', label: 'Server Health', wait: 3500 },
  { route: '/gameconfig', file: 'game-config.png', label: 'Game Config', wait: 3000 },
  { route: '/gameplay', file: 'gameplay-admin.png', label: 'Gameplay Admin', wait: 3000, tab: 'Players' },
  { route: '/solo', file: 'solo-mode.png', label: 'Solo Mode', wait: 2500, tab: 'Settings', focus: 'PTC Engine settings' },
  { route: '/wick-maps', file: 'dd-seed-maps.png', label: 'DD Seed Maps', wait: 2500 },
  { route: '/database', file: 'database.png', label: 'Database', wait: 2500, focus: 'Backups' },
  { route: '/settings', file: 'settings.png', label: 'Settings', wait: 2500, focus: 'Remote Access' },
]

async function clickExact(page, label) {
  const control = page.getByRole('button', { name: label, exact: true }).first()
  if (await control.count()) {
    await control.click()
    await page.waitForTimeout(900)
    return true
  }
  return false
}

async function focusText(page, text) {
  const target = page.getByText(text, { exact: false }).first()
  if (!await target.count()) return
  await target.evaluate(element => {
    element.scrollIntoView({ block: 'start', behavior: 'instant' })
    const scroller = element.closest('main') ?? document.scrollingElement
    if (scroller) scroller.scrollTop = Math.max(0, scroller.scrollTop - 120)
  })
  await page.waitForTimeout(500)
}

async function replacePiiWithDemoData(page) {
  await page.evaluate(() => {
    const replacements = [
      [/C:\\Users\\[^\\<>"' ]+/gi, 'C:\\Users\\ServerAdmin'],
      [/\bfuncom-seabass-sh-[0-9a-z-]+\b/gi, 'funcom-seabass-sh-demo-sietch-01'],
      [/\bsh-[0-9a-f]{12,}-[0-9a-z]{4,}\b/gi, 'sh-demo-sietch-01'],
      [/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '203.0.113.42'],
      [/\b7656119\d{10}\b/g, '76561190000000001'],
      [/\bReapersDST\b/gi, 'Arrakis Sietch'],
      [/\bcoastal-ms\b/gi, 'desert-admin'],
      [/\bHawk(?:[-_]i5)?\b/gi, 'SpiceRunner'],
      [/\bCoastal\b/g, 'Sietch Keeper'],
      [/\ballcoast\b/gi, 'desert-admin'],
      [/\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g, 'admin@example.invalid'],
      [/\bdune-awakening\b/gi, 'dune-server-vm'],
    ]

    const replace = value => {
      let next = value
      for (const [pattern, demo] of replacements) next = next.replace(pattern, demo)
      return next
    }

    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode())) {
      const next = replace(node.nodeValue ?? '')
      if (next !== node.nodeValue) node.nodeValue = next
    }

    for (const element of document.querySelectorAll('input, textarea')) {
      const next = replace(element.value)
      if (next !== element.value) {
        const prototype = Object.getPrototypeOf(element)
        const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value')
        descriptor?.set?.call(element, next)
      }
    }

    for (const element of document.querySelectorAll('[title], [aria-label]')) {
      for (const attribute of ['title', 'aria-label']) {
        const value = element.getAttribute(attribute)
        if (value) element.setAttribute(attribute, replace(value))
      }
    }
  })
}

;(async () => {
  const browser = await chromium.launch({ headless: true })
  const context = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    deviceScaleFactor: 1.25,
    colorScheme: 'dark',
    reducedMotion: 'reduce',
  })
  const page = await context.newPage()
  const portal = new URL(baseUrl)

  const initialUrl = `${portal.origin}/${portal.search}`
  await page.goto(initialUrl, { waitUntil: 'networkidle', timeout: 30000 })
  await page.waitForSelector('nav, aside', { timeout: 10000 })

  for (const capture of pages) {
    console.log(`Capturing ${capture.label} (${capture.route})`)
    const target = `${portal.origin}${capture.route}${portal.search}`
    await page.goto(target, { waitUntil: 'networkidle', timeout: 30000 })
    await page.waitForTimeout(capture.wait)

    if (capture.tab) await clickExact(page, capture.tab)
    if (capture.focus) await focusText(page, capture.focus)

    await replacePiiWithDemoData(page)
    await page.waitForTimeout(300)

    const output = path.join(outDir, capture.file)
    await page.screenshot({
      path: output,
      fullPage: false,
      animations: 'disabled',
      caret: 'hide',
    })
    const size = fs.statSync(output).size
    console.log(`  ${capture.file} (${Math.round(size / 1024)} KB)`)
  }

  await browser.close()
  console.log(`Done. Output: ${outDir}`)
})().catch(error => {
  console.error(error)
  process.exit(1)
})
