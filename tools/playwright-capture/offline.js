// Capture the shipped UI without connecting to a backend, VM, save, or account.
// Serve webui/dist on loopback first; every API and WebSocket is intercepted.
const { chromium } = require('playwright')
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

function arg(name, fallback) {
  const index = process.argv.indexOf(name)
  return index < 0 ? fallback : process.argv[index + 1]
}

const origin = new URL(arg('--url', 'http://127.0.0.1:5415'))
if (origin.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(origin.hostname) || origin.search || origin.hash || origin.username || origin.password) {
  throw new Error('Offline captures require a token-free loopback static server.')
}
const out = path.resolve(arg('--out', path.join(__dirname, '..', '..', 'docs', 'img')))
const only = arg('--only', '').split(',').filter(Boolean)
const offline = 'Offline documentation preview: no server connected.'
// Evaluate reviewed literal demo data and the pure command availability helper only.
const demoSource = path.join(__dirname, '..', '..', 'app', 'server', 'lib', 'GameplayPlayers.ps1')
const demos = JSON.parse(execFileSync('pwsh', ['-NoProfile', '-Command', `
  $ErrorActionPreference = 'Stop'
  $ast = [System.Management.Automation.Language.Parser]::ParseFile('${demoSource.replace(/'/g, "''")}', [ref]$null, [ref]$null)
  foreach ($name in @('Get-DunePlayersDemo', 'Get-DunePlayerSummaryDemo')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $fn) { throw "Missing demo function $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
  }
  $catalogPath = '${path.join(__dirname, '..', '..', 'app', 'server', 'lib', 'Commands.ps1').replace(/'/g, "''")}'
  $catalog = [System.Management.Automation.Language.Parser]::ParseFile($catalogPath, [ref]$null, [ref]$null)
  $assignment = $catalog.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:DuneCommands' }, $true)
  if (-not $assignment) { throw 'Missing shipped command catalogue' }
  . ([scriptblock]::Create($assignment.Extent.Text))
  $availability = $catalog.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DuneCommandAvailability' }, $true)
  if (-not $availability) { throw 'Missing command availability helper' }
  . ([scriptblock]::Create($availability.Extent.Text))
  $state = @{ vmExists = $false; vmRunning = $false; bgState = 'unknown' }
  $commands = @($script:DuneCommands | ForEach-Object {
    $availability = Get-DuneCommandAvailability -Command $_ -State $state
    $row = @{}
    foreach ($key in $_.Keys) { $row[$key.Substring(0,1).ToLower() + $key.Substring(1)] = $_[$key] }
    $row.available = $availability.available
    $row.reason = $availability.reason
    $row
  })
  $solo = [System.Management.Automation.Language.Parser]::ParseFile('${path.join(__dirname, '..', '..', 'app', 'server', 'lib', 'SoloMode.ps1').replace(/'/g, "''")}', [ref]$null, [ref]$null)
  $fields = $solo.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:DuneSoloConsoleSettings' }, $true)
  if (-not $fields) { throw 'Missing shipped Solo console settings' }
  . ([scriptblock]::Create($fields.Extent.Text))
  @{ players = @(Get-DunePlayersDemo); summary = Get-DunePlayerSummaryDemo; commands = $commands; consoleSettings = $script:DuneSoloConsoleSettings } | ConvertTo-Json -Depth 10 -Compress
`], { encoding: 'utf8' }))
const versionSource = fs.readFileSync(path.join(__dirname, '..', '..', 'app', 'DuneServer.ps1'), 'utf8')
const currentVersion = versionSource.match(/\$script:DuneToolVersion\s*=\s*['"]([^'"]+)['"]/)?.[1]
if (!currentVersion) throw new Error('Missing source product version')
const fixtures = {
  '/api/installation': { mode: 'full' },
  '/api/portal-auth/status': { accountLoginEnabled: false, authenticated: true, mustChangePassword: false, account: null },
  '/api/update/migration-notice': { show: false },
  '/api/autostart': { enabled: false },
  '/api/service-mode': { installed: false, running: false },
  '/api/console': { visible: false },
  '/api/game/launch-preferences': { enabled: false },
  '/api/solo/status': {
    ok: true, supported: true, platform: 'Windows', connected: true,
    dataRoot: 'Example Solo save', dbPath: 'Example Solo save/game.db', profileToken: 'documentation-example',
    settingsPath: 'Example settings', adapter: 'retail-v1', channel: 'FLS_retail', legacyAdapter: false,
    profiles: [], gameRunning: false, processes: [], helperAvailable: true, inspectionError: '', backupRoot: 'Example backups',
    inspection: { ok: true, sourcePath: 'Example Solo save/game.db', wrappedBytes: 1048576, wrappedSha256: '', wrapperVersion: 1,
      declaredSqliteBytes: 1048576, actualSqliteBytes: 1048576, integrity: 'ok', foreignKeyViolations: 0,
      tableCount: 0, characterCount: 1, schemaFingerprint: '', mapSeed: 0, inventories: [], inventoryItems: [],
      rangedWeapons: [], currencies: { solari: 2500, scrip: 100 }, fillables: [],
      progression: { specializations: [], purchasedRewards: 0, fremenNodesTotal: 0, fremenNodesComplete: 0,
        npeNodesTotal: 0, npeNodesComplete: 0, npeTagPresent: false, spiceSystemStatus: 'Not started',
        spiceVisionStatus: 'Not started', skillsAtSeven: 0, moduleKeyCount: 0, totalSkillPoints: 12,
        unspentSkillPoints: 4, keystoneBonusSkillPoints: 0, intel: 8, characterXp: 1000 } },
  },
  '/api/solo/runtime': { ok: true, supported: true, platform: 'Windows', gameRunning: false, processes: [], helperAvailable: true },
  '/api/solo/settings': { ok: true, path: 'Example settings', exists: true, section: 'ServerSettings', entries: [] },
  '/api/solo/console-settings': { ok: true, supported: true, adapter: 'retail-v1', path: 'Example settings', exists: true, section: 'ConsoleVariables', entries: demos.consoleSettings.map(field => ({ ...field, value: field.default, present: false })) },
  '/api/solo/codex': { ok: true, profileToken: 'documentation-example', fragments: [], owned: 0, missing: 0, total: 0 },
  '/api/solo/backups': { ok: true, root: 'Example backups', backups: [] },
  '/api/solo/blueprint-settings': { ok: true, supported: true, enabled: false, canRestore: false, conflict: false },
  '/api/solo/blueprints': { ok: true, profileToken: 'documentation-example', blueprints: [] },
  '/api/status': {
    vm: { exists: false, name: '', state: 'Not configured', running: false, ip: null, uptime: 0 },
    bg: { available: false, reason: offline, state: 'unknown', gameServers: [] },
    ports: { mode: 'disabled', publicIp: null, results: [] },
    serverName: 'Documentation preview', ts: '',
  },
  '/api/config': { path: '', exists: false, complete: false, keys: [], values: {} },
  '/api/update/check': { currentVersion, latestVersion: null, available: false, checkedAt: '', error: offline, channel: 'stable' },
  '/api/gameplay/coriolis/seeds': { source: 'demo', liveError: offline, maps: [], farm_seed: null },
  '/api/gameplay/players': { source: 'demo', players: demos.players, total: demos.players.length },
  '/api/gameplay/players/summary': { source: 'demo', ...demos.summary },
  '/api/gameplay/blueprints': { source: 'demo', blueprints: [], total: 0 },
  '/api/commands': {
    state: { vmExists: false, vmRunning: false, bgState: 'unknown' },
    sectionNames: ['VM', 'Battlegroup', 'Tools'],
    sections: ['VM', 'Battlegroup', 'Tools'].map(section => demos.commands.filter(command => command.section === section).map(command => command.name)),
    commands: demos.commands,
  },
}
const captures = [
  { file: 'server-health.png', route: '/', deck: false },
  { file: 'command-deck.png', route: '/', deck: true },
  { file: 'game-config.png', route: '/server-settings', deck: true },
  { file: 'gameplay-admin.png', route: '/players', deck: true },
  { file: 'blueprints.png', route: '/bases?view=blueprints', deck: true },
  { file: 'solo-mode.png', route: '/solo', deck: true },
  { file: 'dd-seed-maps.png', route: '/map?view=atlas', deck: true },
  { file: 'database.png', route: '/database', deck: true },
  { file: 'settings.png', route: '/settings?section=settings.appearance', deck: true },
  { file: 'commands.png', route: '/commands', deck: true },
  { file: 'operations.png', route: '/operations', deck: false },
  { file: 'server-updates.png', route: '/commands?task=updates', deck: false },
  { file: 'solo-overview.png', route: '/solo', deck: false, solo: true },
  { file: 'solo-settings.png', route: '/solo', deck: false, solo: true, tab: 'Settings' },
  { file: 'solo-progression.png', route: '/solo', deck: false, solo: true, tab: 'Progression' },
  { file: 'browser-portal.png', route: '/', deck: false, phone: true, login: true },
]

async function redact(page) {
  await page.evaluate(() => {
    const clean = text => text
      .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '[address hidden]')
      .replace(/\bsh-[0-9a-z-]+\b/gi, '[identifier hidden]')
      .replace(/\b[A-Z]:\\[^\s<>"']+/gi, '[path hidden]')
      .replace(/\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g, '[email hidden]')
      .replace(/\b(?:2000[1-4]|3000[1-4]|900[1-4])\b/g, '[sample]')
      .replace(/Thank you [^\n]+/g, 'Community supported')
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
    while (walker.nextNode()) walker.currentNode.nodeValue = clean(walker.currentNode.nodeValue || '')
    for (const input of document.querySelectorAll('input, textarea')) {
      if (input.type === 'password') input.value = ''
      else input.value = clean(input.value)
    }
    for (const element of document.querySelectorAll('[title], [aria-label], [placeholder]')) {
      for (const attribute of ['title', 'aria-label', 'placeholder']) {
        const value = element.getAttribute(attribute)
        if (value) element.setAttribute(attribute, clean(value))
      }
    }
  })
}

async function main() {
  fs.mkdirSync(out, { recursive: true })
  const browser = await chromium.launch({ headless: true, channel: arg('--browser', 'msedge') })
  try {
    for (const shot of captures.filter(shot => !only.length || only.includes(shot.file))) {
      const context = await browser.newContext({
        viewport: shot.phone ? { width: 390, height: 844 } : { width: 1600, height: 1000 },
        deviceScaleFactor: 1, colorScheme: 'dark', reducedMotion: 'reduce',
        serviceWorkers: 'block',
      })
      await context.addInitScript(({ deck, file }) => {
        localStorage.setItem('dst.experience.command-deck.v1', deck ? '1' : '0')
        localStorage.setItem('dst.home.spatial.v1', deck ? '1' : '0')
        if (file.startsWith('solo-')) {
          localStorage.setItem('dst.card.solo-setup', '0')
          localStorage.setItem('dst.card.solo.codex', '0')
        }
        if (file === 'settings.png') {
          localStorage.setItem('dst.card.settings.installLocation', '0')
          localStorage.setItem('dst.card.settings.dashboardAlerts', '0')
        }
      }, shot)
      await context.routeWebSocket('**/*', socket => socket.close())
      const requested = new Set()
      await context.route('**/*', route => {
        const request = route.request()
        const url = new URL(request.url())
        if (!['GET', 'HEAD'].includes(request.method())) {
          return route.fulfill({ status: 403, json: { error: 'Read-only documentation capture: writes blocked.' } })
        }
        // Monaco's shipped loader normally uses a CDN; serve its installed files locally.
        const monaco = url.pathname.match(/\/monaco-editor@[^/]+\/min\/(vs\/.+)$/)
        if (url.hostname === 'cdn.jsdelivr.net' && monaco && !monaco[1].includes('..')) {
          const file = path.join(__dirname, '..', '..', 'webui', 'node_modules', 'monaco-editor', 'min', monaco[1])
          if (!fs.existsSync(file)) throw new Error(`Missing local Monaco asset: ${monaco[1]}`)
          return route.fulfill({ path: file })
        }
        if (url.origin !== origin.origin) return route.abort('blockedbyclient')
        if (url.pathname.startsWith('/api/')) {
          requested.add(`${request.method()} ${url.pathname}`)
          if (shot.login && url.pathname === '/api/portal-auth/status') {
            return route.fulfill({ json: { accountLoginEnabled: true, authenticated: false, mustChangePassword: false, account: null } })
          }
          if (shot.solo && url.pathname === '/api/installation') return route.fulfill({ json: { mode: 'solo' } })
          const fixture = fixtures[url.pathname]
          return route.fulfill(fixture ? { json: fixture } : { status: 503, json: { error: offline } })
        }
        return route.continue()
      })
      const page = await context.newPage()
      const errors = []
      page.on('pageerror', error => errors.push(error.message))
      await page.goto(new URL(shot.route, origin).href, { waitUntil: 'networkidle' })
      await page.waitForTimeout(800)
      if (shot.tab) {
        await page.getByRole('button', { name: shot.tab, exact: true }).click()
        await page.waitForTimeout(300)
      }
      await page.evaluate(() => document.fonts.ready)
      await redact(page)
      await page.evaluate(({ version, solo }) => {
        const note = document.createElement('div')
        note.textContent = `DST ${version} interface preview · ${solo ? 'Fictional Solo save' : 'No connected server'}`
        Object.assign(note.style, { position: 'fixed', bottom: '10px', right: '12px', zIndex: '9999',
          padding: '6px 10px', background: '#18120ef2', color: '#f5ebe0', border: '1px solid #5a4030',
          borderRadius: '5px', font: '12px Segoe UI, sans-serif', pointerEvents: 'none' })
        document.body.append(note)
      }, { version: currentVersion, solo: shot.solo || shot.route === '/solo' })
      if (errors.length) throw new Error(`${shot.file}: ${errors.join('; ')}`)
      await page.screenshot({ path: path.join(out, shot.file), animations: 'disabled', caret: 'hide' })
      console.log(JSON.stringify({ file: shot.file, requests: [...requested], text: (await page.locator('body').innerText()).slice(0, 10000) }))
      await context.close()
    }
  } finally {
    await browser.close()
  }
}

main().catch(error => { console.error(error); process.exitCode = 1 })
