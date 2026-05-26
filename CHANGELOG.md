# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Patch releases within a major series are rolled up under the major's entry
(e.g. `6.0.x` lives under **[6.0.0]**, `5.0.x` lives under **[5.0.0]**, all
`4.x.y` lives under **[4.0.0]**, all `3.x.y` lives under **[3.0.0]**). Tags
on GitHub still exist for each individual release; the consolidated entries
here cover everything those tags shipped.

## [Unreleased]

## [6.1.6] - 2026-05-26

Patch: **Max primed mirrors Max active on the Game Config / Spicefields card,
plus two new on-demand map pod cards (Arrakeen + Harko Village) and extra
port-check provider choices.**

Added
- **Two new on-demand map pod cards on the Dashboard**: **Arrakeen**
  (`SH_Arrakeen`) and **Harko Village** (`SH_HarkoVillage`), alongside
  the existing Deep Desert card. Each card has the same controls
  (Spin up / Shut down / Refresh), player-online safeguard on shutdown,
  set/replica/partition diagnostics, and CRD-presence pill.
- Settings → Port-check mode now offers two extra providers
  (`yougetsignal` only, `canyouseeme` only) for users whose IP is
  rate-limited by one provider.

Changed
- On the **Game Config → Spicefields** editor, changing **Max active**
  now automatically sets **Max primed** to the same value. Max primed
  remains independently editable afterward if you need to set it lower.
- The Deep Desert card was extracted into a reusable
  `pages/dashboard/MapPodCard.tsx` component. Adding more on-demand
  maps in the future is now a one-line change in
  `app/server/lib/Maps.ps1` (`$script:DuneOnDemandMaps`) plus a single
  `<MapPodCard …/>` in `pages/Dashboard.tsx`.

## [6.1.5] - 2026-05-26

Patch: **Public port-check now falls back to canyouseeme.org when
yougetsignal.com rate-limits the request.**

Fixed
- **TCP Ports Open card showed "0/1" with status "unknown" for RabbitMQ
  (31982) even when the port was actually open.** Root cause: the primary
  port checker (yougetsignal.com) has a daily per-public-IP rate limit;
  once hit, it returns the message `"Daily open port check limit reached
  for <ip>..."` with a 200 status. The body didn't match the open/closed
  regex, so the checker returned `unknown` and the dashboard counted it
  as "not open". `app/server/lib/Ports.ps1` now:
  - explicitly recognises the rate-limit response,
  - falls back to `canyouseeme.org` (POST `port` + `IP` form fields)
    when yougetsignal returns `ratelimit` or `unknown`,
  - parses the canyouseeme verdict (`<b>Success:</b> I can see your
    service` → open; `<b>Error:</b> I could not see...` → closed).


## [6.1.4] - 2026-05-26

Patch: **drag-and-drop reorder on the Commands page**, plus a fix for a
relaunch-after-Shutdown race that briefly showed every panel as "Unknown"
with "Invalid or missing token" until the user closed and reopened the
portal a second time.

Added
- **Drag-to-reorder commands.** Each card on the Commands page now has a
  grip handle on the left. Drag to rearrange commands within their section
  (VM, Battlegroup, Tools). The order auto-saves to
  `%APPDATA%\DuneServer\button-order.json` (`PUT /api/commands/order`,
  400ms debounce) and persists across launches.
- **Reset layout** button on the Commands page header — clears the saved
  order and reverts to the default arrangement.
- `@dnd-kit/core`, `@dnd-kit/sortable`, `@dnd-kit/utilities` added to
  `webui/` for the drag-and-drop machinery. The grip is the only drag
  source (6px activation distance), so clicks on the rest of the card
  still launch commands as before.

Fixed
- **"Invalid or missing token" after using Shutdown then relaunching.**
  When the in-portal Shutdown button stopped the EXE and the user
  immediately clicked the desktop shortcut to relaunch, the new EXE's
  browser-launcher background job would win a race against the new HTTP
  server's `last-url.txt` write, read the *previous* run's URL (with the
  *previous* run's token), and open the browser at that stale URL. The
  new listener (now bound on the same port) rejected every `/api/*` call
  as "Invalid or missing token" until the user closed the tab and
  reopened the shortcut a second time. Fixes:
  - `app/DuneServer.ps1` now deletes any stale `last-url.txt` before
    spawning the polling jobs, so the browser can only ever read the
    fresh URL written by the new listener.
  - The shutdown `finally` block now wipes `last-url.txt` and explicitly
    releases the single-instance mutex, rather than relying on OS
    process-exit cleanup (which is racy under fast reopen).


## [6.1.3] - 2026-05-26

Patch: **silence Write-DuneLog popup modals on startup**, plus a new
in-portal **Shutdown** button.

Added
- **Shutdown button** in the top status bar (next to Refresh). One-click,
  with confirmation, gracefully stops the local `DuneServer.exe` portal
  process — same effect as the tray menu's "Quit" item, no need to dig
  in the system tray. New `POST /api/shutdown` route writes the response,
  flags the tray runspace as quitting, then stops the HTTP listener after
  a 400ms delay so the response flushes cleanly before the EXE exits.

Fixed
- **Startup MessageBox spam** — every `Write-DuneLog` INFO line ("Dune Server
  v6.1.x starting", "Serving from…", "Tray icon initialized…", "HTTP listening
  on…") was firing a modal `MessageBox.Show` dialog at app launch. Cause:
  `app/server/lib/DuneLog.ps1` mirrored every log line to `Write-Host` with the
  comment "no-op in ps2exe -noConsole" — that claim was **wrong**. ps2exe's
  `-noConsole` mode actually *redirects* `Write-Host` to `MessageBox.Show` by
  default, which is why each log line popped a modal that blocked startup
  until clicked. Fix: probe the host once via `[System.Diagnostics.Process]::`
  `GetCurrentProcess().ProcessName` and only mirror to `Write-Host` when the
  process is `pwsh` / `powershell` / `powershell_ise` (real consoles). When
  running as the compiled `DuneServer.exe`, log lines now go to the log file
  only — no popups.

## [6.1.2] - 2026-05-26

Patch: **single-instance gate** (clicking the desktop shortcut multiple times
no longer spawns multiple servers or UAC prompts) and **`dune-admin` self-heal**
when the bundled `dune-admin.exe` is missing.

Fixed
- **Multi-instance bug** — every click of the desktop shortcut spawned a
  brand-new `DuneServer.exe` (new port, new tray icon, **new UAC prompt**).
  Added a named-mutex gate (`Global\DuneServer-Portal-v6`): if the portal
  is already running, subsequent launches just open the existing portal
  URL (`%LOCALAPPDATA%\DuneServer\last-url.txt`) in the default browser
  and exit silently — no second listener, no second tray icon, no UAC.
- **UAC-on-every-click** — `DuneServer.exe` no longer ships a `requireAdmin`
  manifest. The single-instance check runs *first*; elevation happens
  *in-script* only when this is the canonical instance (so first launch
  prompts once, subsequent clicks never prompt). Hyper-V cmdlets still get
  admin via the in-script self-elevate (`Start-Process -Verb RunAs`); CLI
  commands still get admin via `dune-server.ps1`'s
  `#Requires -RunAsAdministrator`.
- Command 18 (`dune-admin`) silently registered a scheduled task
  pointed at a missing executable when `DuneAdminExe` in
  `dune-server.config` pointed nowhere — the spawned console window
  flashed and closed, dune-admin.exe never started, and the
  `dune-admin.layout.tools` web UI loaded but showed no data because
  its local backend wasn't running.
- The `dune-admin` handler now `Test-Path`s the configured EXE
  first. If missing or unset it offers to download the latest
  release from `github.com/Icehunter/dune-admin` (reuses the
  existing `Install-DuneAdminLatest` helper), persists the new
  path back to `dune-server.config`, and seeds the install
  directory with the current SSH key — same flow as
  `initial-setup`. Errors and the first-time install path now
  pause with **"Press Enter to close this window"** so the user
  actually sees what happened before the console disappears.

## [6.1.1] - 2026-05-26

Patch: **headless launcher with system-tray icon**. The console window
that v6.1.0 showed ("Dune Server v… / Serving from … / [dune-http]
Listening on …") is gone — the EXE now runs as a tray app.

Changed
- `DuneServer.exe` compiled with `-noConsole -STA` (ps2exe). No console window.
- New `NotifyIcon` (system tray) with menu: **Open Portal**,
  **Copy URL**, **View Server Log**, **Open Data Folder**,
  **About**, **Quit**. Double-click the tray icon to reopen the portal.
- Server log redirected to `%LOCALAPPDATA%\DuneServer\dune-server.log`
  (rolls at 1 MB). Tray menu's "View Server Log" opens it in Notepad.
- Self-elevation fallback uses `MessageBox` instead of `Read-Host`
  (no console to read from).
- Web portal favicon refreshed: three-layer sand-dune silhouette on
  warm sand (#d4a574). New `favicon.ico`, `favicon.png`,
  `apple-touch-icon.png`, plus `<meta name="theme-color">`.

Existing v6.1.0 users will see the **auto-update banner** within ~6h
and can apply v6.1.1 in-place from Settings → Updates.

## [6.1.0] - 2026-05-26

Major release: **web portal rewrite**. The WPF UI is gone — replaced
by a local HTTP server (`System.Net.HttpListener`) bound to
`127.0.0.1` that serves a React/Vite/Tailwind SPA. The launcher EXE
starts the server, picks a free port (47823+), and opens the default
browser to a per-launch tokenized URL. The app runs as a normal
console process so the live HTTP log is visible while it serves.

Why: WPF + WebView2 + Pty.Net was heavy, fragile across
.NET runtime versions, and impossible to iterate on without
rebuilding. The new stack is a single static asset bundle plus a
tiny PowerShell HTTP server — no native deps, no XAML, no embedded
browser engine.

### Added

- **Web portal frontend** in `webui/` (Vite + React + TypeScript +
  Tailwind), built into `webui/dist/` and bundled by the installer.
  Pages: Server Health, Commands, Terminal, Characters, Game Config,
  Database, Sietches, Settings, Setup Wizard.
- **PowerShell HTTP server** in `app/server/`:
  `HttpServer.ps1` (listener + routing + WebSocket upgrade + runspace
  pool dispatch), `lib/*.ps1` (Config, Status, Ports, Commands,
  Characters, GameConfig, Database, Sietch, Setup, Maps, Links),
  `routes/*.ps1` (one per API surface).
- **Per-launch token auth** — random GUID in the URL,
  accepted via `?t=` query or `X-Dune-Token` header on all
  `/api/*` and `/ws/*` calls. Defends against cross-origin
  browser tabs.
- **Terminal page** with `xterm.js` (`@xterm/xterm`) front-end and
  a runspace-based exec model on the server. Each WS session owns
  one runspace; PS streams polled at 30 ms; one shared `ReceiveAsync`
  in a 1-element box keeps the .NET WebSocket happy. Protocol:
  `{init,exec,cancel,resize} ↔ {ready,output,done,error}`. Persistent
  cwd across commands.
- **Server Health page** — Web Interfaces card (File Browser + Director
  URLs), Log Export buttons, **Deep Desert spin-up button** (patches
  the maps CRD partition).
- **Sietches page** — list / add / remove-last with "I UNDERSTAND"
  confirmation gate and RAM-exceed warning.
- **Database page** — backup/restore via the existing console commands,
  plus a new Monaco SQL editor (read-only by default, max-rows, CSV
  export, Ctrl+Enter, table list sidebar).
- **Setup Wizard page** — 6-step linear flow with preflight checks,
  config summary, install, security/networking review, finalize.

### Changed

- **Installer payload** — removed `app/pages/`, `app/styles/`,
  `app/web/`, `app/lib/WebView2/`, `app/lib/Pty.Net/`. Added
  `app/server/*` and `webui/dist/*`.
- `Build-Installer.ps1` now runs `npm run build` in `webui/` before
  invoking ISCC (skippable via `-SkipWebBuild`).
- `Build-Exe.ps1` no longer passes ps2exe flags `-NoConsole`, `-STA`,
  `-NoOutput`, `-NoError` — v6.1 wants a real console window.

### Removed

- All v6.0.x WPF UI source (`app/pages/*.ps1`,
  `app/styles/Theme.xaml`).
- `app/web/` (xterm host HTML + assets — now an npm dep in webui).
- `app/lib/Pty.Net/` and `app/lib/WebView2/` native DLLs.

### Added (post-rewrite refinements)

- **Server Health: structured Battlegroup Info + Game Servers cards** —
  splits the raw `kubectl get bg` text into typed fields (name, state,
  map churn, generation, online), and renders each game server with a
  state badge, partition, and online count.
- **Server Health: Active Spice readout** — new `BgSpiceSummary` widget
  pulls `dune.public_spicefields` over psql and shows active vs primed
  fields **per map**, **per size class**, sorted **large-first**.
  Tiered color rules: size column tinted by tier (Large = amber,
  Medium = ibad-blue, Small = muted), active count tinted by fill
  ratio (warning at-cap, amber ≥ 75 %, blue ≥ 25 %), primed count
  brightens to accent when populated.
- **Game Config: Spicefield Types card** — first-class editor backed
  directly by `dune.spicefield_types`. At-cap rows highlighted; per-row
  Spicefield status promoted to a prominent inline badge with 10 s
  refresh.
- **Maps: Deep Desert graceful shutdown** — checks for online players
  before scaling the map down; refuses with a structured error
  otherwise.
- **Characters: specialization tracks** — Specs tab now pulls live data
  from `dune.specialization_tracks`.
- **Characters: faction reputation** — Faction Rep tab now pulls live
  data from `dune.player_faction_reputation`.

### Fixed (post-rewrite)

- **Maps: on-demand spin-up** — bind partitions and clear
  `dedicatedScaling` when patching the maps CRD, so on-demand maps
  (notably Deep Desert) actually come up instead of stalling the
  operator in `Reconciling`.
- **HTTP: JSON request bodies on PowerShell 5.1** — `ConvertFrom-Json`
  output coerced into `[hashtable]` so PS 5.1 route handlers can
  index into the payload without `PSCustomObject` quirks.
- **Commands page crash on PS 5.1** — `ConvertTo-Json` `-Depth`
  default returns an array wrapper for single objects under PS 5.1;
  routes now force-wrap explicitly so the React client sees a
  consistent shape.
- **Characters: Specs / Faction Rep table key** — both tables key on
  the **controller id**, not the pawn id, so per-character rows now
  resolve correctly.
- **`Get-DuneConfigPath`** — always uses the canonical
  `%APPDATA%\DuneServer\` location, regardless of how the EXE was
  launched.

### Changed (post-rewrite)

- **Dashboard: "Status" → "BG state"** under Battlegroup Info, with
  a "map churn" hint so operators can tell whether a reconcile is
  caused by deliberate map spin-up vs a real fault.
- **Battlegroup Info / Game Servers cards** — spacing tightened so
  more fits above the fold on a 1080p screen.
- **Installer: clean upgrade from v4–v6.0.x.** Setup now silently
  uninstalls the previous version (via the registered Inno Setup
  uninstaller) before laying down v6.1 files. Removes orphaned
  WPF/WebView2 binaries, the old `web\` / `pages\` / `styles\` /
  `lib\Pty.Net\` / `lib\WebView2\` directories, and any running
  `DuneServer.exe` process. **User config in `%APPDATA%\DuneServer\`
  is preserved.** First launch after upgrade goes straight to the
  new web portal — no manual cleanup, no config wizard prompts.
- **In-app auto-updater.** The portal now polls the public GitHub
  Releases API for newer versions (`GET /api/update/check`, cached
  1 h, refreshed every 6 h in the SPA). When a newer tag is found
  with an attached `DuneServerSetup*.exe` asset, an amber banner
  appears above the status bar with **Update now** / **Later**
  buttons. The Settings page also has a manual "Check now" /
  "Update to v…" card. Clicking **Update now** hits
  `POST /api/update/install`, which downloads the asset to
  `%TEMP%\DuneServerUpdate\` and launches it silently
  (`/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS`). The installer's
  `PrepareToInstall` hook (added above) handles the rest — kills
  this very `DuneServer.exe`, runs the old uninstaller, lays down
  the new files, and the Start Menu shortcut now points at the new
  web-portal launcher. This is the last manual installer download
  v6.1+ users will ever need.

## [6.0.0] - 2026-05-26

**6.0.1 hotfix (2026-05-26):** Fixed startup crash _"XAML load failed:
Provide value on 'System.Windows.StaticResourceExtension' threw an
exception"_ that hit every fresh install of the v6.0.0 EXE. Three v6
path lookups (`styles\Theme.xaml`, `pages\`, `lib\`) were resolving
against `$PSScriptRoot` — which is `$null` when the script is compiled
with ps2exe — so the Theme.xaml splice silently produced no resources
and the inline `{StaticResource …}` references failed at parse time.
Switched those lookups to the existing `$script:AppDir` fallback (uses
the executing assembly's directory). No data or settings impact.

Major release: **page-based UI**. The left rail of buttons + single output
pane is gone — replaced by a navigable workspace where each major workflow
gets its own purpose-built page. This is the biggest UX change since the
desktop app was introduced in v4.0.0.

The window now opens at ~75% of your working area (centered, with a small
width margin for ultrawides) and is fully resizable; the header strip
holding the dashboard tiles is itself splitter-resizable so you can give
the active page more room.

All v6 dev iterations (page scaffolding, theme unification, layout polish,
async-loading overlays, character/game-config wiring, port lookup, etc.)
are consolidated into this single 6.0.0 entry.

### Added

- **Page-based navigation surface** in `app/pages/`. Each page is a
  self-contained module exposing `New-*Page` / `Show-*Page` /
  `Hide-*Page` and inherits the unified theme from
  `app/styles/Theme.xaml`. Loaded via dot-sourcing by
  `app/DuneServer.ps1` at startup.
- **🏠 Dashboard page.** Tile-based at-a-glance view: VM state, battlegroup
  phase + per-map pods, public IP / port-check badges, **Game Port** (live
  read from `UserEngine.ini` on the VM, cached for 10 minutes and
  invalidated whenever Game Config is saved), plus quick Restart / Start /
  Stop buttons.
- **📈 Monitoring page.** Live status log tail, log-export buttons
  (operator + any pod), and a Web Interfaces card with one-click launchers
  for the File Browser and Director URLs (both visible and copyable).
- **👤 Characters page.** Live editor talking directly to the Postgres pod
  over SSH. Tabbed editor with Stats / Tech / Specs / Economy / Faction /
  Inventory / Cosmetics. Loads asynchronously via PowerShell runspaces
  with a loading overlay so the UI never blocks on a slow VM. All edits
  are written back through `psql` with transactional safety.
- **⚙️ Game Config page.** Safe in-app editor for `UserEngine.ini` and
  related server tuning files, with a **spice fields readout** in the
  header (Hagga + Deep Desert lines with primed counts) for at-a-glance
  spawn density.
- **🗄️ Database page.** Backup / Import without remembering pod names;
  browse common tables (read-only by default with an explicit Edit-mode
  toggle); one-click "Open psql shell" into the embedded terminal.
- **🔧 Settings page.** Everything the old setup wizard asked, but
  editable any time: server install folder, SSH key path, dune-admin
  path, Windows username, port-check URL template, theme, log retention.
  Changes save on the fly — no restart needed.
- **🧙 Setup Wizard page.** Runs automatically on first launch; re-runnable
  any time from Settings for a clean reset.
- **🏜️ Additional Sietches page (experimental).** Preview of multi-VM /
  multi-battlegroup management from a single window. Surfaced as
  "experimental" in the UI; included so power users can poke at it and
  file feedback.
- **Resizable header splitter.** Drag the splitter under the dashboard
  tiles to grow or shrink them; the active page reflows into the
  reclaimed space.
- **Auto-sized window on launch.** The window opens at ~75% of the
  working area (clamped to sensible min/max, ~240 px width margin for
  ultrawides) and centers itself on the active monitor.
- **Update checker** wired to GitHub Releases (`coastal-ms/Simple-Dune-Server-Management-Tool`).
  Surfaces the installed-vs-latest version in the header and offers a
  one-click "What's new" link to the release notes.
- **Async character loading** with a loading overlay; the character rail
  shows a spinner while the DB pod query is in flight, and a clear
  "no characters yet" empty state when the table is empty.
- **WebView2 debug log** at `%APPDATA%\DuneServer\webview2-debug.log` for
  diagnosing WebView2 / xterm.js / page-render issues.
- **Issue template overhaul** for v6:
    - New `surface` dropdown listing every v6 page + CLI + installer +
      updater + Other.
    - Scope blurb rewritten around v6 page names + symptoms.
    - WebView2 runtime version field.
    - Updated transcript / log path hints, including the WebView2 debug log.

### Changed

- **Default window dimensions** computed from `SystemParameters.WorkArea`
  at `Window.Add_Loaded` time (75% × 75% minus a ~240 px width margin,
  clamped to MinWidth..2200 / MinHeight..1300), then centered.
- **Header strip default height** trimmed from 430 → 345 px so the
  dashboard tiles sit closer to the splitter (less wasted empty space
  under "Game Servers").
- **Monitoring Web Interfaces cards** restructured from `DockPanel` to
  vertical `StackPanel` so the URL `Border` no longer collapses to 0
  height when the parent row is squeezed by header resizing.
- **Save in Game Config** now invalidates the Dashboard's port cache so
  any port change is reflected immediately on the next dashboard render.
- **Installer legacy-config detection** no longer scans personal-folder
  paths (OneDrive subfolders, GH project mirrors, etc.) — only generic
  locations like Desktop and Documents. Public-facing strings in
  `app/installer/DuneServer.iss` were scrubbed to match.
- **Public author surface** locked in: `coastal-ms` GitHub org throughout,
  Discord `@allcoast`, LICENSE copyright `Coastal`. No personal-path
  artifacts in shipped binaries.

### Removed

- **Single output pane / left-rail-of-buttons layout** from v4.x / v5.x —
  replaced wholesale by the page-based navigation surface. The embedded
  terminal still exists (used by the Database page's psql shell and by
  any CLI command spawned from a page), but it's no longer the
  centerpiece of the UI.

### Fixed

- **Monitoring File Browser + Director URLs** disappearing when the
  header row was resized (cards used `DockPanel.LastChildFill=True` and
  the URL `Border` was the fill child → squeezed to 0 height). Both
  cards converted to top-down `StackPanel` so each child sizes
  naturally.
- **Game Port tile** now shows reason text in the subtitle when a lookup
  fails (instead of a silent "lookup failed"), making it diagnosable
  from the dashboard without opening a shell.
- **Dashboard tiles** no longer flicker on refresh — async fetches write
  into a cache and the tick handler only re-renders when the cached
  values actually change.

### Notes for developers

- **Page module contract** (`app/pages/<Page>.ps1`):
    - `New-<Page>Page` returns the root `Border` (an instance of
      `PageRootStyle` from `app/styles/Theme.xaml`).
    - `Show-<Page>Page` wires events and kicks off background polling.
    - `Hide-<Page>Page` tears down timers / runspaces.
- **Runspace + `Invoke-Expression $LibSrc` pattern** for cross-thread
  database work. Ship `Db-Postgres.ps1` source via
  `SessionStateProxy.SetVariable('LibSrc', $libSrc)` then
  `Invoke-Expression $LibSrc` inside the script block. Use
  `.GetNewClosure()` on `DispatcherTimer` Tick handlers to capture
  result/runspace/UI refs.
- **`$script:` scope does not cross runspaces.** Return values from
  `EndInvoke()` are assigned in the main UI thread tick (see
  `_V6DashUpdatePortTile` for the canonical pattern).
- **Version sync points** (must move together):
    - `app/DuneServer.ps1` — `$script:ToolVersion`
    - `dune-server.ps1` — `$script:ToolVersion`
    - `app/installer/DuneServer.iss` — `MyAppVersion`
    - `app/build/Build-Exe.ps1` — `$Version` default
- **Page surface field** in the new bug-report form is `id: surface`.
  Add new values to both the YAML enum and any in-app "where did the
  bug happen?" picker.

## [5.0.0] - 2026-05-25

Major release: **embedded terminal pane**. The right pane is now a real
ConPTY-backed xterm.js terminal. Every command — including interactive
ones that previously required a popup PowerShell window — runs inside
the app's own window. The two-mode (InApp / Console) dispatch split is
gone. The legacy localhost web portal that shipped alongside the CLI is
also gone now that the desktop app covers every workflow.

Consolidates **5.0.0**, **5.0.1**, and **5.0.2** — the initial-setup
guard and the public-documentation PII scrub shipped as point releases
are folded in here under their respective sections.

### Added

- **Embedded terminal renderer** in the right pane, backed by a real
  ConPTY. Implemented with:
    - **Pty.Net** (0.1.16-pre) — managed wrapper over the Windows
      pseudoterminal API; what the VS Code PowerShell extension uses
    - **WebView2** + **xterm.js** (5.5.0) + **xterm-addon-fit** (0.10.0) —
      the same renderer stack VS Code uses for its integrated terminal
  All three are bundled with the installer (no internet at install time).
- **JS ↔ PowerShell bridge** over `CoreWebView2.WebMessageReceived` /
  `PostWebMessageAsJson`. Carries input keystrokes, viewport resizes,
  and clipboard-copy round-trips between xterm.js and the PowerShell host.
- **WebView2 runtime check** at startup. If the Evergreen runtime is
  missing (rare on Win11, possible on minimal Win10 / Windows Server),
  a friendly prompt links the user to the official Microsoft installer.

### Changed

- **Every command now runs inside the embedded terminal**, including
  commands that previously opened a separate PowerShell window:
  `startup`, `shutdown`, `reboot`, `rotate-ssh-key`, `change-password`,
  `start`, `restart`, `stop`, `update`, `edit`, `edit-advanced`,
  `enable-experimental-swap`, `backup`, `import`, `logs-export`,
  `operator-logs-export`, `shell-vm`, `shell-pod`, `ssh`,
  `initial-setup`. Interactive prompts, SSH sessions, TUI editors,
  spinners, and ANSI cursor moves all work — the PTY gives them a
  real TTY.
- **Output rendering matches a real terminal.** ANSI colors are now
  honored (the old InApp pane was stripping them); cursor-move
  sequences work; line wrapping respects the actual viewport.
- **`initial-setup` greys out once the game server is live.** When the
  battlegroup status shows both core game-server pods (**Overmap** and
  **Survival_1**) in a `Running` phase, the button is disabled and
  reports `[Cannot run 'initial-setup' - Overmap and Survival_1 pods are
  running.]`. Buttons stay clickable on `unknown` state (cold-start /
  SSH timeout) so the command isn't gated out before the first status
  poll completes. _(originally 5.0.1)_
- **App docstring** updated to reflect the new single-mode dispatch.
- **App and CLI READMEs** updated; install paths reduced from three
  (desktop app / .bat / web portal) to two.
- **Public documentation PII scrub** — sanitized example IPs, usernames,
  and stale URLs across `LICENSE`, `README.md`, `CHANGELOG.md`, and
  `app/installer/DuneServer.iss`. README example-output now uses
  RFC1918 (`192.168.1.50`); the v4.4.0 entry uses RFC5737
  (`203.0.113.45`); installer `MyAppURL` points to the correct
  `coastal-ms` GitHub org. _(originally 5.0.2)_

### Removed

- **Legacy web portal** — the entire `web/` directory (`Start-DuneWeb.ps1`,
  `public/index.html`, `public/app.js`, `public/styles.css`,
  `web/README.md`) is gone. The desktop app covers every workflow the
  portal did, so maintaining two parallel UIs is no longer worth it.
  **Breaking change** for the (likely zero) users still launching
  `Start-DuneWeb.ps1` directly. The `Mode='Console'` / `Mode='InApp'`
  distinction in the command catalog is also functionally gone (the
  field is still tolerated for backward compat but ignored at dispatch
  time).
- **`Invoke-Command-InApp`** and **`Invoke-Command-Console`** are gone,
  replaced by a single **`Invoke-Command-Terminal`** that spawns pwsh
  under a PTY and pipes its byte stream into xterm.js.
- **Mouse-down swallow handler** on the output pane (only needed because
  the old `TextBox`-based pane needed to look non-interactive). The
  terminal handles its own mouse routing.

### Fixed

- **PTY data + exit handlers actually fire.** PowerShell scriptblocks
  bound to events that are raised from a non-runspace background thread
  (Pty.Net's reader thread) are silently dropped. Replaced with a tiny
  `DuneServer.PtySink` C# helper (compiled at startup via `Add-Type`)
  whose `OnData` / `OnExit` methods are bound as real CLR delegates via
  `[Delegate]::CreateDelegate(...)`. These execute on any thread without
  needing PS runspace context.
- **Battlegroup state parser** now correctly disables redundant pod
  buttons. Previously matched `STATUS: Running`, which `bg status` does
  not emit; rewrote `Get-BgStateFromStatusText` to recognise the actual
  output shape (`Phase: Ready`, `<Map>  Running` table rows, and
  `No resources found in <ns> namespace`).
- **Force-kill hung sessions** with a new **Kill** button and a
  **Ctrl+\\** shortcut from inside the terminal.
- **Atomic PTY teardown.** `Stop-CurrentPty` now nulls the script-scope
  refs first (so a re-entrant tick bails out), drains remaining output,
  marks the sink exited via `MarkExited()`, then disposes.
- **TUI editors (`edit`, `edit-advanced`) launch in their own console
  window.** Embedding `xterm.js → ConPTY → ssh -t → remote vim` across
  five terminal-size negotiation layers corrupts the rendered display.
- **Mouse wheel works inside the popup vim** — `dune-server.ps1` ensures
  `set mouse=a` is in `~/.vimrc` on the VM via an idempotent pre-flight
  check before any edit command.
- **Embedded terminal no longer corrupts itself on window resize.** The
  JS `ResizeObserver` refits are suppressed while a PTY session is
  active, and the resize message is de-duplicated.
- **"Report an Issue" and other URL-opening menu items open the user's
  default browser on Windows 11 24H2.** Switched every URL launch in
  `dune-server.ps1` from `Start-Process explorer.exe $url` to
  `Start-Process $url`, which dispatches through the registered
  `https://` protocol handler. _(carried in from v4.5.2's fix; restated
  here because v5.0.0 inherits the same launch paths)_

### Internal

- New `Test-CorePodsRunningFromText` parser + `$script:LastCorePodsRunning`
  state mirror, wired into the same status-callback path as `Set-BgState`
  and synced through the click-handler closure shim. _(originally 5.0.1)_

### Notes for developers

- The full dependency bundle adds ~2.7 MB to the installer (Pty.Net +
  WebView2 managed/native + xterm.js assets).
- ps2exe compiles `DuneServer.exe` as PowerShell 5.1 Desktop. Both DLL
  sets are netstandard2.0 / net46 and load cleanly there.
  `BackendOptions::ConPty` is passed explicitly when spawning PTYs.
- Pty.Net event handlers must NOT be bound as PowerShell scriptblocks —
  events fired from the reader thread are silently dropped. Bind a
  `DuneServer.PtySink` C# helper via `[Delegate]::CreateDelegate(...)`
  instead.

## [4.0.0] - 2026-05-24

Major release: **native Windows desktop app** as the new primary entry
point — packaged as `DuneServerSetup.exe` (Inno Setup installer wrapping
a ps2exe-compiled `DuneServer.exe`). The `.bat` launcher and (at the
time) the web portal remained as parallel options.

Consolidates **4.0.0** through **4.5.2** — every point release across
the v4 lifecycle (in-app installer config, drag-to-reorder, Dune-themed
button styling, update checker, port-check status line, draggable
separators, and assorted ship-day stabilization patches) is folded into
this single 4.0.0 entry.

### Added

- **Desktop app (`app/DuneServer.ps1` → `DuneServer.exe` →
  `DuneServerSetup.exe`).** PowerShell + WPF host wrapping every CLI
  command in a single window: sticky battlegroup status panel (30s
  auto-refresh via SSH), left panel of section-grouped command buttons,
  right panel for streaming command output, footer with current
  operation + exit code + version.
- **Two dispatch modes per command** (chosen automatically): `InApp`
  (hidden child `pwsh`, output captured into the pane) and `Console`
  (visible elevated `pwsh` window for interactive / TTY-requiring
  commands; labeled `[console]` in the UI for transparency).
- **Admin enforced at every layer.** Installer requires admin (Program
  Files writes); `DuneServer.exe` carries an embedded UAC manifest
  (ps2exe `-requireAdmin`); `dune-server.ps1` keeps
  `#Requires -RunAsAdministrator`. One UAC prompt at app launch.
- **PowerShell 7 prerequisite check at startup** with a friendly dialog
  + download URL if `pwsh.exe` isn't installed.
- **Inno Setup installer** (~2 MB): install dir `C:\Program Files\Dune
  Server\`, Start Menu shortcut (always) + optional desktop shortcut,
  clean Add/Remove Programs entry, **legacy-config auto-detection**
  during install, **user data preserved on uninstall** (uninstaller
  never touches `%APPDATA%\DuneServer\`).
- **Installer config wizard** (5 pages): server folder, SSH key, dune-admin
  exe, Windows username, port-verification mode. Native Browse pickers
  with smart auto-detected defaults. Values written to
  `dune-server.config` at install time so the app launches fully
  configured. Skipped on upgrade if the config already exists.
  _(originally 4.0.8)_
- **"Download Latest from GitHub..." button** on the installer's Dune
  Admin Tool page that fetches the latest `windows_amd64.zip` from
  [Icehunter/dune-admin](https://github.com/Icehunter/dune-admin),
  extracts it, and auto-fills the path field. _(originally 4.1.0)_
- **"Check for Updates" button** + **Installed / Latest version labels**
  in the status header. Hits the GitHub Releases API for
  `coastal-ms/Simple-Dune-Server-Management-Tool`, compares against the
  installed version, offers a one-click download + launch of the new
  installer. Silent check runs on `Window.Loaded`; explicit clicks
  surface failures via dialog. **Latest label is clickable** — opens the
  matching release notes page in your browser. _(originally 4.2.0,
  refined in 4.3.3)_
- **Drag-to-reorder** any command button onto any other to swap
  positions. Persisted to `%APPDATA%\DuneServer\button-order.json`. New
  commands in future releases auto-append to the end. Right-click →
  "Reset button order to default" available on every button.
  _(originally 4.0.4)_
- **Drag-source ghost** (35% opacity) + **insertion-line indicator**
  (cyan bar at top or bottom of target depending on drop side) so drop
  position is unambiguous. `Move-Command` takes `-Position before|after`.
  _(originally 4.0.5 / 4.0.6)_
- **Four draggable separators** (`Separator 1` … `Separator 4`) at the
  end of the command list. Render as slim horizontal divider chips with
  grip dots; participate in the existing drag-reorder system; positions
  persisted alongside command order. Right-click → "Reset separator
  positions" sends all four back to the bottom without touching command
  order. _(originally 4.5.0)_
- **Port-check status line** in the header, above the battlegroup pane.
  Shows external reachability per forwarded port (TCP 31982 always; UDP
  7777 / 7810 only when a UDP-capable checker is configured) with
  colored status pills (`[OPEN]` green, `[CLOSED]` red, `[UDP - skipped]`
  dim, `[UNKNOWN]` amber). Runs on a background runspace; manual
  Refresh button forces a fresh hit; 30s auto-refresh paints from a
  5-minute cache. _(originally 4.4.0)_

### Changed

- **`dune-server.ps1` writable files moved to `%APPDATA%\DuneServer\`**
  (`dune-server.config`, `.boot-times.json`,
  `.logs\dune-server-*.log`) so the script can run from a read-only
  install location (Program Files). Backward-compatible auto-migration
  from any legacy location on first run.
- **`README.md`** — installer is now the primary recommended install
  path; the `.bat` and (then-still-present) web portal are called out
  as classic / legacy options.
- **Status pane (top)** is now a non-interactive `TextBlock` inside a
  `ScrollViewer` — no caret, no accidental text selection. **Output
  pane (right)** stays a `TextBox` but is `Focusable=False`,
  `IsTabStop=False`, with mouse-down handlers swallowed so no caret
  ever appears. New `Set-OutputInputMode` helper toggles it back to a
  normal text-entry box when a future InApp command needs input.
  _(originally 4.1.0)_
- **Menu layout simplified to a flat 3-column grid** (then later
  reorganized into four section-based columns: VM / Battlegroup pt 1 /
  Battlegroup pt 2 / Tools) with HUD-style section headers. Hotkey
  badges removed from the visual — the underlying `Key` field still
  drives `-Cmd <name>` dispatch from the CLI. _(originally 4.0.3 /
  4.0.4)_
- **Button labels render in normal English Title Case** instead of raw
  kebab-case (e.g. `rotate-ssh-key` → `Rotate SSH Key`). A new
  `Format-CmdLabel` helper expands hyphens and preserves standard
  acronyms (VM / SSH / BG / URL / API / JSON, etc.) in uppercase.
  Raw command names still flow to `-Cmd` and tooltips. _(originally
  4.0.5)_
- **Dune-movie-themed button styling**: spice-gold accent bar, bronze
  gradient border, sand-shadow background, hotkey badge in Consolas
  spice-copper, Eyes-of-Ibad cyan-blue hover/press halo. New
  `UtilButton` style for header/footer utility buttons (Refresh /
  Copy / Clear). Main window background changed to warm stillsuit
  black `#14110D`. _(originally 4.0.3)_
- **`status` button removed from the command catalog** (the header
  panel already displays live status with 30s auto-refresh); the
  underlying `status` CLI command remains for `.bat` and `-Cmd` users.
  _(originally 4.0.2)_
- **Dune-admin "Web UI" launch** now opens directly to the **Players**
  route (`https://dune-admin.layout.tools/#/players`). _(originally
  4.0.7)_
- **All "open this URL" menu items now use `Start-Process $url`**
  (registered protocol handler) instead of `Start-Process explorer.exe
  $url`, which stopped working correctly on Windows 11 24H2. Affects
  `report-issue`, `setup-guide`, `dune-admin` web UI,
  `open-file-browser`, `open-director`. _(originally 4.5.2)_
- **Cards stay enabled for drag/drop even when greyed out.** Previously
  greyed-out commands couldn't receive drag events, so separators
  couldn't be moved across them. Now every card stays draggable;
  unavailable commands show a friendly message on click and a tooltip
  hint that drag-reorder still works. _(originally 4.5.1)_

### Removed

- **Web Portal menu entry** (`web` / key `b`) from both the desktop app
  and the legacy CLI menu. The `web/` folder and `Start-DuneWeb.ps1`
  still existed in the repo for archival reference but were no longer
  launchable from the app. (Fully removed in v5.0.0.) _(originally
  4.3.0)_

### Fixed

- **Battlegroup status header never populated** in the v4.0.0 ship —
  background `Start-Job` calling `Get-VM` from a ps2exe binary lost its
  elevation token. Refactored `Refresh-StatusHeader` to call `Get-VM`
  synchronously on the (already-elevated) UI thread; only the slow SSH
  call runs on a background runspace. Hyper-V module imported
  explicitly at startup. _(originally 4.0.1)_
- **`setup-guide`, `open-file-browser`, `open-director`, `web`,
  `report-issue`** crashed on first launch — bare
  `Start-Process "https://..."` doesn't work from an elevated process.
  Switched to Explorer launch (later switched again to bare
  `Start-Process $url` in 4.5.2 for the 24H2 default-browser fix).
  _(originally 4.0.1)_
- **App crashed on first stdout line from any InApp command.**
  `Process.add_OutputDataReceived` callbacks fire on .NET ThreadPool
  threads with no PowerShell runspace TLS, throwing inside the
  scriptblock-as-delegate. Rewrote `Invoke-Command-InApp` to use
  `Register-ObjectEvent` feeding a `ConcurrentQueue[hashtable]`, drained
  by a `DispatcherTimer` on the UI thread. _(originally 4.0.2)_
- **Top status header stuck on "Loading cluster status..."** — the
  `DispatcherTimer.Tick` scriptblock referenced function-scoped
  variables but wasn't wrapped in `.GetNewClosure()`. Captured via a
  closure and assigned via a captured `$tickHandler`. _(originally
  4.0.2)_
- **WPF `KeyNotFoundException: 'haloEffect'` crashing the app at
  startup.** Cannot `Setter TargetName=` a `Freezable` (DropShadowEffect)
  nested in a templated element's property — the name isn't in the
  template's name scope. Fixed by naming the parent Border and having
  hover/press triggers replace the entire `Effect` property.
  _(originally 4.0.3)_
- **Battlegroup status panel no longer renders a red
  `NativeCommandError`** when the battlegroup is Stopped. Funcom's
  `battlegroup status` writes kubectl's benign "No resources found..."
  to stderr; both the snapshot helper and the runspace fetch now
  flatten any `ErrorRecord` on the merged pipeline before
  stringification. _(originally 4.3.3)_
- **Update check always said "update available", even on the latest
  version.** `$script:ToolVersion` was defined in `dune-server.ps1` but
  not in `app/DuneServer.ps1`; `[Version]"4.3.x" -gt $null` is true,
  perma-sticking the label. Defined `$script:ToolVersion` directly in
  `app/DuneServer.ps1` (now one of four version sync points). Added a
  defensive `if (-not $current)` arm. _(originally 4.3.2)_
- **Silent startup update check no longer nags.** The
  `Check-ForUpdates -Silent` path now only paints the Latest label
  blue when an update exists; the YesNo "Update Available" prompt only
  appears on explicit Check-for-Updates clicks. _(originally 4.3.1)_

### Notes for developers

- The compiled `DuneServer.exe` is unsigned — Windows SmartScreen will
  warn on first run ("Unknown publisher"). Click "More info" → "Run
  anyway". Code signing remains deferred.
- **Version sync points introduced this major** (must move together
  for every release): `dune-server.ps1`, `app/DuneServer.ps1`,
  `app/installer/DuneServer.iss`, `app/build/Build-Exe.ps1`.

## [3.0.0] - 2026-05-24

Consolidation release. Supersedes all prior 2.x releases — the 2.0.0
through 2.0.6 GitHub Releases were rolled into this single 3.0.0 entry
at the time. Also folds in the v3.0.1 / v3.1.2 patches.

### Added

- **Localhost web UI** (`b. web` menu option).
  [Pode](https://github.com/Badgerati/Pode)-based server on
  `http://127.0.0.1:8765` with a button panel mirroring the console
  menu. Each click POSTs to `/api/exec/{name}`, which spawns
  `dune-server.ps1 -Cmd <name>` in a new console window so interactive
  prompts keep working. Status panel polls every 5 seconds.
  Confirmation dialog on `reboot` and `shutdown`. Lives under `web/`.
- **`-Cmd <name>` parameter** on `dune-server.ps1` for non-interactive
  dispatch. Skips the menu, runs one handler, exits. Used by the web
  UI; also handy for shortcuts and scripts.
- **`dune-admin` install offer during setup** (step 3). Prompts to
  download the latest release from
  [`Icehunter/dune-admin`](https://github.com/Icehunter/dune-admin) to
  a folder you choose, use an existing local install, or skip. Stored
  path goes into `dune-server.config`.
- **SSH key auto-copy to `dune-admin` folder.** Setup and
  `rotate-ssh-key` keep the dune-admin install dir's key file in sync
  with the freshest copy (compares
  `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` against the path stored
  in `dune-server.config`).
- **Optional "Run as Administrator" desktop shortcut.** End-of-setup
  prompt drops a `Dune Server (Admin).lnk` on your desktop targeting
  `dune-server.bat` with the elevated-launch flag set.
- **Per-phase boot-time tracking** for `c. startup` and `e. reboot`.
  Each wait is timed and persisted to `.boot-times.json` (last 20 runs
  per phase). Before each wait, a `(last: ~Xs, avg ~Ys of N)` hint is
  printed based on history. Total elapsed shown at the end.
- **`23. report-issue` menu option.** Opens a prefilled GitHub bug-report
  form in your browser (tool version + OS/PowerShell auto-filled). The
  issue template + `.github/ISSUE_TEMPLATE/config.yml` scope the
  tracker to bugs in this tool's code; VM/network/Funcom-server
  questions are redirected to Discord.
- **New menu option `c. start-vm`** (above `d. startup`). Powers on the
  Hyper-V VM and waits for IP without running any battlegroup
  commands. Useful for maintenance, OS updates inside the VM, or just
  bringing the host online. Web portal mirrors the new key layout.
  _(originally 3.0.1)_

### Changed

- **Menu rename + reorder.** `graceful-shutdown` is now just `shutdown`
  (`d.`), `graceful-reboot` is just `reboot` (`e.`). Behavior unchanged
  — same safety checks, phases, boot-time tracking. **Breaking** for
  anyone driving with `-Cmd graceful-shutdown` / `-Cmd graceful-reboot`.
- **`c. startup` no longer prompts for confirmation.** The "Type YES"
  gate was redundant; selecting the menu option is the confirmation.
  Other destructive commands keep their gates.
- **VM section re-lettered sequentially** so it ends cleanly at
  `g. change-password` before the numbered Battlegroup commands.
- **Live "elapsed" MM:SS counters on every long boot wait** during
  `startup` and `reboot` (SSH readiness, k3s API, DB pods, operator
  pods, webhook endpoints, pod-termination wait). Non-polling waits
  (`kubectl wait`) run in a background job so the foreground can paint
  the counter. _(originally 3.0.1)_
- **All duration displays are MM:SS** across `startup`, `reboot`,
  `shutdown`, including the live counter, the
  `(last: ~Xs, avg ~Ys of last N)` estimate, per-phase "ready in"
  lines, and "complete in" summaries. _(originally 3.0.1)_
- **Web portal layout**: each menu item is now a labeled row with a
  dedicated **Go** button on the right (instead of the whole row being
  the button). _(originally 3.0.1)_
- **Web portal: always-visible Battlegroup Status panel** pinned at
  the top, auto-polling every 30s, with a 25s SSH cache and a manual
  Refresh button. Powered by a new `GET /api/bg-status` endpoint in
  `web/Start-DuneWeb.ps1`. _(originally 3.0.1)_

### Fixed

- **Web UI showed "Error fetching status" and rendered no command
  buttons.** Pode route scriptblocks run in isolated runspaces and
  can't see `$script:`-scoped variables defined at file scope.
  `Get-VmStatus` was calling `Get-VM -Name $null`; the command-list
  routes iterated `$null`. Refactored to publish shared state via
  `Set-PodeState` at server start and `Get-PodeState` inside the
  routes. JSON arrays wrapped in `@(...)` so single-item lists don't
  unroll to scalars.
- **Interactive menu exited after a single command.** The dispatch
  loop's local `$cmd = $entry.Name` collided with the script's `$Cmd`
  parameter (PowerShell is case-insensitive), so the
  `if ($Cmd) { break }` at the bottom of the loop fired after every
  interactive command. Renamed the loop-local to `$cmdName`.
- **`-Cmd <name>` mode would infinite-loop** re-running the same
  command. Handlers use `continue` to skip the rest of the loop body,
  which also skipped the bottom-of-loop `break`. Now gated at the top
  of the loop so exactly one handler runs per `-Cmd` invocation.
- **`dune-server.bat`** no longer pauses with "Press any key to
  continue" on a clean exit — the `pause` now only fires when the
  PowerShell script exits non-zero. Also forwards `%*` so `-Cmd <name>`
  works via the `.bat` too.
- **Setup wizard wrapped in a top-level try/catch** — failures print a
  readable error + stack trace and pause for Enter, instead of the
  console window vanishing.
- **Port-check status in the menu header refreshes after running any
  battlegroup CLI command** (`status`, `start`, `restart`, `stop`).
  Previously the cached results were keyed only by public IP with no
  TTL, so the `[OPEN]` / `[CLOSED]` indicators stuck at their first
  observed values for the entire session.
- **`shutdown` and `reboot` no longer hang forever on a stuck VM
  power-off.** New `Stop-VmWithEscalation` helper issues graceful stop
  as a background job, renders a live MM:SS counter, auto-escalates to
  `Stop-VM -TurnOff` after 90s, with a 240s absolute ceiling.
  _(originally 3.0.1)_
- **DB-pod discovery awk script no longer fails with "Unexpected
  token".** Awk now emits space-separated `namespace podname` instead
  of `namespace/podname` (no embedded double quotes for PowerShell to
  mangle). _(originally 3.0.1)_
- **DB-pod readiness check no longer waits on the wrong pods.**
  Previous `kubectl wait --all` blocked on completed backup `Jobs` and
  unrelated deployments. Now targets pods by name pattern (`-db-`,
  `postgres`, `pg-` minus the obvious noise) and honors the exit code.
  _(originally 3.0.1)_
- **`shutdown` now tracks timings and shows estimates** like `startup`
  and `reboot` do (`pods-terminate`, `vm-stop`, `total-shutdown`
  recorded to `.boot-times.json`). _(originally 3.0.1)_
- **Background helpers are cleaned up on crash** — any `Start-Job`
  spawned by the live wait counters is stopped and removed via a
  `PowerShell.Exiting` engine event plus a top-level `trap`. The
  `dune-server.bat` wrapper also reports the PowerShell exit code
  before pausing. _(originally 3.0.1)_

### Removed

- **`b. start-vm` and `c. stop-vm` menu entries.** The graceful
  counterparts (`c. startup` cold-starts the full stack; `d. shutdown`
  stops battlegroup and powers off) cover everything they did without
  leaving pods inconsistent. (Underlying handlers remain for
  existing automation calling them by name. `start-vm` was later
  re-added as a real menu entry in 3.0.1.)

### Internal

- New helpers: `Install-DuneAdminLatest`, `Resolve-FreshSshKey`,
  `Copy-SshKeyToDir`, `New-DuneDesktopShortcut`, `Get-BootTimes`,
  `Format-PhaseEstimate`, `Save-PhaseTiming`.
- `web/` folder structure added.
- Boot-time history stored at `<scriptDir>\.boot-times.json` (rolling
  window of last 20 entries per phase).
- Code organization tidy-up in `dune-server.ps1` and
  `web/Start-DuneWeb.ps1`. Tool command keys settled at 17/18/19/20
  (`ssh`, `dune-admin`, `setup-guide`, `report-issue`). _(originally
  3.1.2)_

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v6.1.2...HEAD
[6.1.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v6.0.1...v6.1.2
[6.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v5.0.2...v6.0.1
[5.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.5.2...v5.0.2
[4.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.1.2...v4.5.2
[3.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v3.1.2
