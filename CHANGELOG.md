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

## [11.1.0] - 2026-06-05

### Added
- **Remote portal — mobile-friendly subset of DST behind Cloudflare Tunnel + Access.**
  A new top-level SPA tree under `/remote/*` (Dashboard + Maps) lets you
  view VM/battlegroup state, check the last 3 backups, and run safe
  one-click actions (spin-up / spin-down on-demand maps, fix partitions)
  from a phone — without ever exposing console, edit, shell, or DB
  surfaces. **DST still binds 127.0.0.1**; cloudflared proxies the
  Cloudflare edge to your loopback, so no port-forwarding or inbound
  firewall changes are required. Per-email ACL gate
  (`%APPDATA%\DuneServer\remote-acl.json`) on top of CF Access magic-link
  / IdP auth — owner sees everything, admins get reads + safe writes.

- **Settings → Remote Access card.** Toggle the remote portal,
  configure owner + admin allowlist, see cloudflared status, view the
  audit log. cloudflared installation/setup itself is documented (see
  the `/remote` page on the marketing site) — this card focuses on
  managing access once the tunnel is up.

- **Audit log** at `%APPDATA%\DuneServer\.logs\remote-audit.log` — every
  remote write action is appended with timestamp, role, email, path,
  and HTTP status, plus every auth denial. Visible in the Settings card.

- **Setup guide** at <https://coastal-ms.github.io/DST-DuneServerTool/remote>
  covering cloudflared install, tunnel create, hostname mapping, and
  CF Access policy setup.

### Security
- The remote portal requires **both** Cloudflare Access (per-email or
  IdP allowlist enforced at the edge) **and** the existing DuneToken
  (injected into the served `index.html` for `/remote/*` paths so a
  same-Windows-box CF-header-spoofing attempt still hits a token wall).
  Fail-closed: missing CF header, malformed ACL, or empty `owner`
  field all return 401 and the remote portal stays disabled.

### Deferred to v11.2.0
- `restart-bg`, `backup-now`, player-kick, WebSocket live-log tail,
  desktop push notifications, browser-side CF Access JWT validation.

## [11.0.3] - 2026-06-05

### Fixed
- **Windows Defender false positive on `DuneServerSetup.exe` (`Trojan:Script/Wacatac.H!ml`).**
  v11.0.1 introduced `Sync-DunePartitionAutomation`, which delivered an
  install payload to the VM via `ssh ... "echo <b64> | base64 -d | sudo sh"`.
  That `base64 → pipe → sh` shape is shape-identical to `powershell -enc <b64>`
  malware and tripped Defender's ML classifier on the PS2EXE-wrapped installer.
  v11.0.3 removes the `Sync-DunePartitionAutomation` helper entirely — the
  partition-clear script is no longer installed to `/etc/local.d/` on the VM
  and the 15-min `/etc/periodic/15min/dune-clear-partitions` cron watchdog is
  no longer created. The script is now staged inline to `/tmp` via `scp`, run
  once with `sudo`, and removed on every Start / Restart / fix-on-demand-maps
  invocation — same UX, no remote install, no Defender bait. (Existing VMs
  that had the boot script + cron installed by v11.0.1 / v11.0.2 keep working
  harmlessly until the VM is rebuilt.)

### Changed
- **Partition-clear now fires on the click, not on the clock.** The 15-min
  cron watchdog is gone; partitions are cleared inline whenever DST issues
  a Start, Restart, `startup`, `reboot`, or `fix-on-demand-maps` command —
  which is the only path a player-facing on-demand map ever needs.

## [11.0.1] - 2026-06-05

### Fixed
- **Auto-clear pinned on-demand map partitions on every battlegroup start.**
  Previously, after a Commands-menu `startup`, `reboot`, `start`, or `restart`,
  the Funcom server-operator would re-pin `igwsss.spec.partitions:[N]` for
  DeepDesert / SH_Arrakeen / SH_HarkoVillage, blocking the director from
  triggering on-demand spawn — players hit "failed to launch" until the next
  15-min cron pass or until you manually clicked **Fix partitions**.
  DST now runs the idempotent clear script automatically after each of those
  commands (best-effort — never aborts a successful battlegroup start, just
  warns), with a short settling delay so the operator has time to reconcile
  before the clean-up pass.

### Added
- **VM-side partition automation is now versioned and self-healing.** The
  installer ships `app/resources/remote-scripts/dune-clear-partitions.start`,
  and every start / restart / reboot calls a new `Sync-DunePartitionAutomation`
  that pushes the script to `/etc/local.d/` and a wrapper to
  `/etc/periodic/15min/` on the VM whenever the on-disk copy is missing or
  the sha256 differs. The OpenRC `local` service is added to the default
  runlevel idempotently. This means VM rebuilds, snapshot restores, or a
  fresh-from-Funcom Alpine image all get the boot script + 15-min watchdog
  installed automatically — no SSH-and-paste required.

## [11.0.0] - 2026-06-04

### Added
- **Theming engine — full preset picker + custom color overrides + import/export.**
  Settings → Appearance now lets you swap the portal palette without rebuilding
  or editing CSS. Ships with 6 built-in presets:
  - **Eyes of Ibad** — the original. Desert amber on warm dark, cyan glow.
  - **Sietch Tabr** — daytime light theme. Aged-parchment tan with deep
    amber text — dim enough to live in.
  - **Caladan** — Atreides homeworld. Muted slate-blue on stormcloud grey.
  - **Giedi Prime** — Harkonnen homeworld. Dark slate-grey with blood-red
    accents.
  - **House Harkonnen** — heraldic. Bone-white sigil on blood-crimson
    and oxidized black.
  - **Atreides** — house colors. Forest green and royal gold on midnight.

  Beyond the presets, every one of the 18 theme tokens (page background,
  card surfaces, border, all 3 text shades, accent + its foreground +
  bright/dim variants, highlight, and all four status colors) is editable
  via a native `<input type="color">` with hex text field. Per-token reset
  and a single "Revert all overrides" button. **Reset to default** restores
  Eyes of Ibad with no customizations.

  Themes export to JSON (download via the browser) and import back from a
  picked file — so you can share a theme between machines or with someone
  else. Schema is forward-compatible (versioned); unknown keys in an
  imported file are reported in the status banner rather than silently
  dropped.

  Implementation: themes are CSS variable overrides applied to `:root`,
  persisted to `localStorage["dst-theme"]` as `{presetId, overrides,
  resolved}`. An inline `<script>` in `index.html` reads the persisted
  resolved map and applies it BEFORE React mounts, so there is no flash
  of the default palette on reload. The embedded xterm in the Terminal
  page also recolors live (background, foreground, cursor, ANSI palette)
  when the theme changes — no Terminal-page refresh required.

### Changed
- **`.btn-primary` text-color bug fixed.** The primary-button class was
  previously declared as `bg-accent text-base` — `text-base` is the
  Tailwind font-size utility (1rem) and never set a text color, so the
  button's text inherited from `<body>`. That happened to look OK on
  the original Eyes of Ibad palette (light cream text on amber) but
  produced unreadable buttons on light themes. Replaced with a new
  `--color-accent-fg` token and `text-accent-fg` utility so every preset
  can declare a sensible button-text color.
- **Body radial-gradient glows tint with the active theme.** The two
  ambient radial gradients on `<body>` previously used hardcoded
  `rgba(217, 119, 6, 0.12)` (amber) and `rgba(56, 189, 248, 0.05)`
  (cyan) — fine for Eyes of Ibad, wrong for every other theme.
  Replaced with `color-mix(in oklab, var(--color-accent) 12%,
  transparent)` and the same for `--color-ibad`, so the body glow now
  follows whatever palette is active.
- **Version display reverted to plain semver.** Previous releases
  stylized the major version as a Roman numeral (e.g. `XI` for `11.0.0`,
  `XI (0.1)` for `11.0.1`). That mapping has been removed from both the
  portal (`fmtToolVersion`) and the marketing site (`formatDisplayVersion`);
  both now render `v<major>.<minor>.<patch>` to match the git tags.

## [10.2.8] - 2026-06-04

### Added
- **Map SpinUp page: "Fix partitions" button.** New action in the page header
  invokes the existing `POST /api/maps/fix-partitions` endpoint (which runs
  the remote `/etc/local.d/dune-clear-partitions.start` script) to clear the
  stuck `igwsss.spec.partitions=[N]` pin that occasionally re-appears on the
  on-demand maps (Deep Desert, Arrakeen, Harko Village) after a VM/BG reboot
  or operator reconcile. Without clearing, the director can't trigger
  scale-up on player entry and the map silently refuses to launch even with
  its SpinUp checkbox enabled. The button shows a confirmation dialog
  explaining what will happen, then renders the script's log tail in the
  result card so the operator can see exactly which maps were cleared or
  skipped. Safety guards (already enforced server-side by the remote script):
  only the 3 on-demand maps are ever touched — Overmap and Survival_1 are
  excluded by suffix matching — and any map with a running pod is skipped
  so live sessions are never disturbed.

### Changed
- **Boot script `/etc/local.d/dune-clear-partitions.start` hardened on the
  VM** (manual install — not part of this app release, documented here for
  history). The pre-existing script waited for the K3s API and the `igwsss`
  CRD to be reachable before proceeding, but in some boot scenarios the CRD
  is registered seconds before the Funcom server-operator finishes
  reconciling the battlegroup and creating the per-map `ServerSetScale`
  instances. The script would log "no igwsss objects found; nothing to do"
  and exit, leaving DD/Arrakeen/Harko with `partitions:[N]` pre-pinned by
  the operator a few moments later. Added a second wait loop (up to 5 min)
  that polls for at least one expected map igwsss object to actually exist
  before deciding the BG has nothing to clean. Old version preserved at
  `/etc/local.d/dune-clear-partitions.start.bak.20260604`. Cron watchdog
  (`/etc/periodic/15min/dune-clear-partitions`) is unchanged and continues
  to act as belt-and-suspenders.

## [10.2.7] - 2026-06-04

### Changed
- **In-app updater is now silent.** Clicking *Install update* now closes the
  Dune Server app and console after a 3-second grace period, then runs the
  Inno installer with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL` in
  a hidden PowerShell host. No wizard window appears, no UAC re-prompt fires
  (the relauncher inherits the already-elevated DuneServer.exe token), and
  the new DuneServer.exe + DuneShell.exe come up automatically on completion
  via the installer's existing `[Run] WizardSilent` entry. Total visible UX
  is the *Updater launched* toast in the portal, the 3-second pause, then
  the new app window comes back. The 30-second wait-for-wizard-window loop
  and the `ShowWindowAsync` / `BringWindowToTop` / `SetForegroundWindow`
  cascade are gone -- they only mattered for the visible wizard.
- **Update failures now surface a topmost WinForms `MessageBox`** with the
  installer exit code, the relauncher log path, and the original installer
  path so the user can reinstall manually. Without this, a silent-mode
  failure would just leave the app gone with no feedback (the hidden
  PowerShell host can't print to a console the user sees).
- **Console / tray choice is now sticky across updates.** The first-run
  "Keep console / Send to system tray" dialog persists the user's pick
  forever and never re-prompts on subsequent version bumps. Previously
  `Resolve-DuneConsoleMode` gated on `ConsolePresenceVersion == currentVersion`
  and re-asked after every install, which was noisy with the silent updater
  flipping the version stamp under their feet. Re-prompt is now gated on a
  separate `ConsolePresenceSchema` constant that only changes when the
  semantics of console/tray meaningfully change in a future release.
  Existing v10.2.6 configs are grandfathered (blank schema + valid
  ConsolePresence → use it and backfill schema=1).

### Fixed
- **Apostrophe-in-username crash in the updater relauncher.** Paths embedded
  into the generated `DuneRelaunch-*.ps1` are now escaped (`'` → `''`)
  before being interpolated into single-quoted PowerShell literals, so usernames
  like `C:\Users\O'Brien\AppData\...` no longer break the relauncher with a
  parse error on the first sleep.

## [10.2.6] - 2026-06-04

### Fixed
- **Dune-admin pricing patch: rebuild now survives upstream file-to-directory
  refactors.** After Icehunter/dune-admin v0.24.0 refactored
  `web/src/tabs/WelcomePackageTab.tsx` into `web/src/tabs/WelcomePackageTab/`
  (`index.tsx` + `views/` + `types.ts`), every "Reinstall + keep sane-pricing
  patch" failed with `pnpm build` errors:
  `src/App.tsx(20,10): error TS2614: ... has no exported member 'WelcomePackageTab'`
  and `src/tabs/WelcomePackageTab.tsx(138,13): error TS2741: Property 'active_versions' is missing`.
  Root cause was in **our** overlay step, not upstream: `Sync-DuneAdminSourceTarball`
  uses `robocopy /E`, which is additive — it never deletes files that were
  removed in the new release. The deleted flat `WelcomePackageTab.tsx`
  stayed on disk as an orphan from the prior v0.23.x install, and
  TypeScript/Vite module resolution prefers a bare `.tsx` over a sibling
  `dir/index.tsx`, so the stale file shadowed the new directory and `tsc`
  saw the wrong export shape. Go build succeeded (the patched
  `dune-admin.exe` was replaced cleanly with v0.24.0), but the embedded
  web UI never compiled, so the build wrapper failed with exit 1 and the
  marketplace bot panel was effectively unbuildable.
- `app/resources/dune-admin-patches/build-patched.ps1` now scans
  `web/src/` for any `Foo.tsx` / `Foo.ts` that has a sibling `Foo/`
  directory containing `index.tsx` / `index.ts`, and deletes the flat
  file before running `pnpm install` / `pnpm build`. The check is safe
  by construction (you never legitimately ship a flat component file
  next to a sibling barrel directory of the same name; the collision is
  always a refactor leftover) and only fires on the exact shadow
  pattern. Any removal also invalidates `.dst-web-build-stamp` so the
  cached `web/dist/` (which may have been compiled from the stale file)
  gets rebuilt instead of reused. Fixes future upstream refactors of
  this shape without needing per-release patches.

## [10.2.5] - 2026-06-03

### Added
- **Help → Create GitHub Issue + Save Logs** in the top menu bar — one
  click opens the prefilled `bug_report.yml` issue form **and** drops a
  redacted `dst-diagnostics-<timestamp>.zip` on the user's Desktop with
  Explorer popped to it, so reporters can drag-and-drop attach all
  relevant logs to the new issue comment in one motion. Bundle contains
  `env.txt` (tool/PS/OS/WebView2 versions), a sanitized copy of
  `dune-server.config`, the tail of `webview2-debug.log` (last 200 KB),
  the last 3 CLI `dune-server-*.log` files (tails, 50 KB each), and a
  `manifest.txt` listing what's inside and any sanitization warnings.
- New `POST /api/diagnostics/bundle` route + `Invoke-DstRedaction`
  helper that scrubs IPv4 / IPv6 (loopback preserved), Windows
  user-profile paths, `?t=<token>` query params, and INI `key=value`
  secrets for `SshKey`, `WindowsUser`, `SteamPath`, `DuneAdminExe`,
  `PortCheckUrlTemplate` from every text file written into the bundle.

### Changed
- **Bug report template (`bug_report.yml`)** updated for the v10.2.x
  app layout — surface dropdown now lists Server Health, Commands,
  PowerShell, Characters, Game Config, DD Map, Database, Sietches, Map
  SpinUp, Settings (split into 3 sub-areas), Setup Wizard, the top
  menu bar/Help dropdown, sidebar/chrome, desktop shell, CLI, and the
  installer — and the intro callout + Transcript field now point
  reporters at the new diagnostic bundle button as the easiest way to
  attach logs.
- **CLI `report-issue`** prints a hint pointing CLI users at the
  desktop app's Help → Create GitHub Issue + Save Logs flow for the
  one-click attachable ZIP. URL-prefilled diagnostics are unchanged.

### Removed
- Legacy `bug_report.md` issue template (duplicate on the issue
  chooser; the YAML form supersedes it).

## [10.2.4] - 2026-06-03

### Changed
- **Help dropdown** in the top menu bar moved from the right edge to
  immediately right of `System` (the last sidebar group). Removed the
  flex spacer that pushed it to the far right; the dropdown panel now
  anchors `left-0` so it opens directly under the Help button.

## [10.2.3] - 2026-06-03

### Changed
- **Map SpinUp icon** changed from `Power` to `Globe` in both the
  sidebar and the Database menubar dropdown — more representative of
  what the page does (spawn a region/map server) and stops it from
  looking like a generic on/off control.

## [10.2.2] - 2026-06-03

### Removed
- **Native WinForms `MenuStrip`** (the thin strip directly under the
  Windows title bar with `Server Health · Settings · View`). Redundant
  with the React top menu bar shipped in v10.2.0 — it duplicated nav
  targets and produced two menu rows stacked on top of each other.
  `BuildMenu()` and the unused `NavigateRoute` helper in `MainForm.cs`
  are gone.

## [10.2.1] - 2026-06-03

### Changed
- **Top menu bar and its dropdowns are now fully opaque.** Removed the
  semi-transparent surface tint + `backdrop-blur-md` (menubar strip) and
  the `card` translucency + `backdrop-blur-sm` (dropdown panels) so page
  content underneath no longer bleeds through. Solid `bg-surface` on both.

## [10.2.0] - 2026-06-03

### Added
- **Top menu bar** above the StatusBar (classic desktop-app layout). One
  dropdown per nav group — **Server Health**, **PowerShell**, **Game Data**,
  **Database**, **System** — plus a rightmost **Help** dropdown for
  cross-cutting commands. Works identically in the DuneShell.exe app window
  and in a normal web-browser tab.
- **Help menu** items:
  - `Create GitHub Issue` — opens the prefilled bug-report template (same
    URL the old `?` icon used; the icon itself is removed from the sidebar
    brand strip).
  - `Collapse Sidebar` / `Expand Sidebar` — toggles the new icon-rail mode.
- **Collapsible sidebar.** New icon-only rail (width 56px) with thin
  separator lines between groups instead of textual headers. State persists
  per surface in `localStorage` (`dst.sidebar.collapsed`).
- **`Database` nav group** (both in the menubar dropdown and the left
  sidebar). Houses Database, Sietches, and Map SpinUp.

### Changed
- **Sidebar regrouping.** **Database**, **Sietches**, and **Map SpinUp**
  moved out of `Game Data` and into the new `Database` group. `Game Data`
  now contains Characters, Game Config, and DD Map.
- Extracted `useLaunchDuneAdmin` so the sidebar's Characters item and the
  new menubar's Characters item share one launch implementation (no
  behavior change — same skip-if-running + port-resolve fallback).

## [10.1.15] - 2026-06-03

### Changed
- **HTTP API handlers now run on a runspace pool instead of inline on the
  listener thread** (closes the v10.1.14 _Known limitation_; issue #47). The
  single-threaded `HttpListener` loop used to run every `/api/*` handler
  inline, so any slow handler — a hung SSH/kubectl call, a backup, a
  dependency install — head-of-line-blocked every other request and could
  freeze the whole backend UI (the 2026-06-03 incident). API handlers are now
  dispatched onto a 2..16 runspace pool (mirroring the existing WebSocket
  pool); the accept loop returns immediately and keeps serving. Static file
  serving and two control routes (`/api/shutdown`, `/api/portal/open-in-browser`)
  intentionally stay inline because they mutate main-runspace lifecycle state.
  The change addresses all four design blockers from the issue:
  - **Shared state injection.** Worker runspaces dot-source every `lib/*.ps1`
    + `routes/*.ps1` (once per runspace, pooled) and receive an immutable
    server context (`DuneToken`, `DunePrefixUrl`, `DuneListener`, `AppDir`,
    `PwshExe`, `MainScript`, `DuneToolVersion`, log path, …) injected per
    request, so handlers that read those `$script:` vars keep working.
  - **Per-resource locks.** New `Invoke-WithDuneLock` / `Get-DuneLock`
    serialize read-modify-write mutations behind named `SemaphoreSlim`s
    shared across all workers. Applied to Map SpinUp (`director.ini`),
    config save, backup-schedule, on-demand map start/stop/fix-partitions,
    and the update + dune-admin install flows — so two concurrent toggles
    can no longer clobber each other's writes.
  - **Backpressure.** A `SemaphoreSlim(16,16)` gate caps in-flight handlers;
    when saturated, new requests get an immediate **503** instead of queuing
    forever behind hung handlers.
  - **Async cleanup.** Each worker always closes its response (so a throwing
    handler can never hang the client), request bodies are read off the
    listener thread (a slow upload can't stall the accept loop, with a 25 MB
    cap), and the accept loop reaps finished pipelines each iteration. If the
    pool fails to initialize for any reason, the server falls back to the
    legacy inline dispatch rather than failing to start.
### Fixed
- **Pricing patch now applies cleanly on dune-admin v0.23.2** (and absorbs
  future minor upstream context drift automatically). v0.23.2 added a
  `gameNow int64` parameter to `Exchange.buyPlayerListings`, which broke a
  context line in the bundled `0001-sane-pricing-100k-cap.patch` and caused
  the patched build to abort with *"patch does not apply cleanly"* (exit 1)
  in the **Pricing** screen. The patch has been updated to match the new
  `buyPlayerListings(ctx, orderExpiry, gameNow, snap)` signature.

### Added
- **Fuzz-tolerant patch fallback in `build-patched.ps1`.** When `git apply`
  refuses a hunk (typically because upstream changed a context line), the
  build script now falls back to GNU `patch.exe` (shipped with Git for
  Windows) with a conservative two-tier fuzz strategy: try `--fuzz=2` first,
  escalate to `--fuzz=3` only if the dry-run rejects. After any fuzz-mode
  apply, the script runs an **invariants check** — verifying that the key
  sane-pricing symbols (`maxAnyPrice`, `tierBasePrice`, `capPrice`,
  `saneDefaultsRevision`, the d12 gamble-buy block, `rand.Intn`, the
  `math/rand` import) are present *and* that the removed `BuyThreshold`
  gate is gone from `buyPlayerListings`. If invariants fail, the working
  tree is restored byte-for-byte from a pre-patch snapshot and the build
  aborts — no silent half-applied build. Loud `COMPATIBILITY MODE` logging
  surfaces in the UI log when the fallback fires so the bundled patch can
  be refreshed against the new upstream.

### Internal
- Bumped version to 10.1.15.

## [10.1.14] - 2026-06-03

### Fixed
- **`Invoke-V6Ssh -TimeoutSec` is now actually enforced.** The function
  accepted a `-TimeoutSec` parameter but completely ignored it — the only
  OpenSSH-level timeout being set was `ConnectTimeout=8`, which caps the
  TCP handshake but lets a connected remote command hang indefinitely.
  When a Map SpinUp toggle triggered an ssh-over-kubectl call that hung
  (~2026-06-03 morning), the child `ssh.exe` lived 12+ minutes with 0.02 s
  of CPU. Because every HTTP API handler runs inline on the listener
  thread (see _Known limitations_ below), that one stuck handler froze
  the entire backend UI — Map SpinUp, Web Interfaces, Active Spice, the
  dune-admin Check button, and any other VM-touching panel all showed
  `Loading…` forever until the orphaned ssh process was killed manually.
  The function now spawns ssh as a managed `System.Diagnostics.Process`,
  drains stdout/stderr asynchronously to avoid pipe-buffer deadlock, and
  calls `WaitForExit($TimeoutSec * 1000)` followed by `Kill()` past the
  deadline. On timeout it returns the line
  `ERROR: ssh timed out after Ns` so callers (which all already join the
  output and pattern-match it) see a clear failure mode instead of a
  silent `$null`.
- Added `ServerAliveInterval=10` + `ServerAliveCountMax=3` as
  belt-and-suspenders defense — even if the host-side `Kill()` ever
  fails, OpenSSH itself will now tear down a silent session within
  ~30 s instead of clinging to it forever.

### Known limitations (deferred to v10.1.15)
- The HTTP listener still dispatches API route handlers inline on a
  single thread (`app/server/HttpServer.ps1:298-327`); only WebSocket
  upgrades are pushed onto a runspace pool. A slow handler still blocks
  the queue for up to its `Invoke-V6Ssh` timeout window, just no longer
  forever. Proper concurrent dispatch — with shared-state injection,
  per-resource locks (so two simultaneous Map SpinUp toggles can't
  clobber each other's `director.ini` patches), backpressure (return
  503 when the pool is saturated), and async response cleanup — is
  designed for v10.1.15 in a follow-up issue.

## [10.1.13] - 2026-06-03

### Fixed
- **In-app updater no longer silently reports "up to date" when a newer
  release has no installer attached.** Previously the `available` flag on
  `/api/update/check` was gated on **both** "newer tag exists" **and** "a
  `DuneServerSetup.exe` asset is uploaded to the release." If a release was
  ever published without the installer asset (as v10.1.12 was), the UI
  flipped to a green **up to date** pill and the update banner stayed
  hidden, even though a newer tag was live on GitHub. That bug now has two
  fixes layered on top of each other:
  1. `available` now means "newer release exists" - asset-independent.
  2. A new `installable` flag is the strict version (newer tag **and**
     installer asset present). The Update banner and Settings card use
     `installable` to decide between an in-app **Update now / Update to X**
     button and a **View release** link that opens the release page in a
     new tab. The header pill still flips to amber **X (N.N) available**
     either way - so the user always knows there's an update.
- **MapSpinUp fix from v10.1.12 carried forward** (see [10.1.12] entry for
  the full root-cause writeup). v10.1.12 was tagged but shipped without an
  installer asset and without the version-stamp bumps in the four release
  files, so the auto-updater couldn't deliver it. v10.1.13 ships both the
  MapSpinUp fix and the updater-honesty fix together, with a proper
  installer attached.

### Changed
- Release-readiness rule (now enforced by checklist): **every** DST GitHub
  release must upload `DuneServerSetup.exe` as its sole asset. Code-only
  releases are forbidden - the asset-less v10.1.12 broke this rule and
  triggered the silent "up to date" regression above.
- `Build-Installer.ps1` now runs a **version-stamp sync check** before any
  of the long build steps. It reads the five files that must agree
  (`dune-server.ps1`, `app\DuneServer.ps1`, `app\build\Build-Exe.ps1`,
  `app\installer\DuneServer.iss`, `app\desktop\DuneShell\DuneShell.csproj`)
  and aborts the build with a per-file listing if they disagree. This is
  what should have caught the v10.1.12 mistake (forgotten stamp bumps).
  Pass `-SkipVersionCheck` for deliberate intermediate test builds.
- `app\server\routes\Update.ps1` asset detection is now strict: requires
  an asset named exactly `DuneServerSetup.exe`. The old `*.exe` fallback
  was removed - it masked malformed releases and conflicts with the
  one-asset rule.

## [10.1.12] - 2026-06-03

> **Note:** v10.1.12 was tagged and a GitHub release was published, but
> the release was missing its `DuneServerSetup.exe` asset and the four
> version-stamp files were never bumped from `10.1.11`. As a result the
> in-app auto-updater couldn't deliver this version and the UI showed
> "up to date" while v10.1.12 was the latest release. The fix it contained
> has been carried forward into v10.1.13, which ships with a working
> installer. **Use v10.1.13 instead.**

### Fixed
- **MapSpinUp no longer no-ops on DeepDesert_1, SH_Arrakeen, and
  SH_HarkoVillage after the Funcom director image update
  (`1973075-0-shipping` → `1979201-0-shipping`).** The new director only
  honors `MinServers = N` when the same section also contains
  `EnableAutomaticInstanceScaling = true`. Funcom ships that flag on the
  Story/DLC sections but not on Deep Desert or the Sietches. DST now
  writes both keys together on spin-up (and only drops `MinServers` on
  spin-down, leaving the auto-scaling flag in place so travel-to spawn
  still works). `MinServers` is now strictly validated to `0` or `1` and
  written with no spaces (Funcom-strict format).
  (coastal-ms/DST-DuneServerTool#44)

## [10.1.11] - 2026-06-03

### Fixed
- **Battlegroup no longer shows a bare "Unknown" when SSH fails — the Dashboard
  now tells you _why_.** The status snapshot runs `battlegroup status` over a
  non-interactive (`BatchMode=yes`) SSH session. Previously, if that SSH call
  failed (auth rejected, key passphrase-protected, VM still booting) the error
  was swallowed (`LogLevel=QUIET`, stderr merged into stdout) and the UI just
  showed **Unknown** with no explanation. `Get-DuneBattlegroupSnapshot` now
  captures ssh's stderr separately, checks the exit code, and surfaces an
  actionable `reason` that the Dashboard already renders under the battlegroup
  status. (coastal-ms/DST-DuneServerTool#38)
- **Passphrase-protected SSH keys are now detected and called out.** This is the
  classic "I can open an SSH terminal and restart the battlegroup, but the
  dashboard / Server Health / game-data all show nothing" trap: an interactive
  SSH session can prompt for the key passphrase, but the tool's background
  checks run non-interactively and can't. The Setup preflight **"SSH key
  authorized on VM"** check and the Dashboard status message now explicitly say
  the key is passphrase-protected and how to fix it (Rotate SSH Key, or
  `ssh-keygen -p`). New helpers `Test-DuneSshKeyEncrypted` and
  `Get-DuneSshFailureReason` in `app/server/lib/Status.ps1`.

### Changed
- **Bug-report template (the in-app **?** help button) now covers VM/SSH
  diagnostics and tells you exactly where to find them.** The template used to
  tell users *not* to report any SSH/VM-connectivity problem — which hid the
  very class of issue the tool now diagnoses. It now: (1) says to report when the
  Dashboard shows the battlegroup as **Unknown** with a message or the Setup
  "SSH key" check fails; (2) adds a **Connection / VM status message** field with
  step-by-step "where to find it" pointers (Dashboard card, Setup "Re-run
  checks", Settings → SSH Key); and (3) adds a one-click **"Does an interactive
  SSH terminal still work?"** question that distinguishes a passphrase-protected
  key from an unauthorized one. The CLI `report-issue` wording and the legacy
  Markdown template were updated to match.

## [10.1.10] - 2026-06-02

### Fixed
- **"Web Portal" sidebar button now actually opens the browser.** Clicking the
  button in 10.1.9 set the server-side detach flag but the WebView2 host
  silently dropped the "open URL and close" message — the React UI posts a JS
  object via `chrome.webview.postMessage(obj)`, but the C# bridge was reading
  it with `TryGetWebMessageAsString()`, which only succeeds for raw-string
  payloads and throws (then swallowed) for objects. The bridge now reads
  `WebMessageAsJson` first and falls back to the string accessor, so both
  object and stringified payloads work and the app window closes + the
  default browser opens to the live portal URL as intended.
- **"Open in web browser" confirm dialog was clipped off-screen.** The dialog
  is rendered inside the sidebar `<aside>`, which uses `backdrop-blur` —
  applying a `backdrop-filter` to an element makes it a containing block for
  `position: fixed` descendants, so the modal centered itself inside the
  240px sidebar instead of the viewport and the **Cancel** button was cut
  off at the screen edge. The dialog is now mounted at `document.body` via a
  React portal so it centers in the viewport regardless of sidebar styling.
- **Dialog buttons are now stacked full-width** (primary on top, Cancel
  below) so they read cleanly on narrow layouts.

## [10.1.9] - 2026-06-02

### Changed
- **Sidebar "Install as app" button is gone, replaced by "Web Portal".**
  Dune Server Tool now ships as a real native app window (WebView2), so the
  old PWA-install affordance was redundant. The new **Web Portal** button
  (sidebar footer, visible only inside the native shell) opens the portal
  in your default web browser, closes the app window, and **leaves the
  server running in the background** so the browser tab keeps working with
  no restart and no token rotation.

### Added
- **Detach + restore lifecycle.** A new `/api/portal/open-in-browser`
  endpoint sets a detach flag the app-window watcher honors (so closing the
  shell after "Web Portal" no longer stops the listener). Reopening Dune
  Server Tool while a detached console is still running cleanly stops the
  prior server and starts a fresh one (one UAC prompt, fresh token, fresh
  app window) — no orphaned headless processes pile up across the day.

### Fixed
- WebView2 host bridge (`chrome.webview.postMessage`) is now wired into the
  React portal so the page can ask the native shell to open URLs in the
  default browser. Previously the shell only consumed `window.open`
  intercepts via `NewWindowRequested`, which couldn't reach loopback URLs.

## [10.1.8] - 2026-06-02

### Added
- **Backup Schedule card on the Database page.** The portal now installs a
  recurring `battlegroup backup` cron on the VM directly from the UI, with
  optional auto-pruning of dump files older than N days. Presets cover hourly,
  every six hours, daily 04:00, twice daily (04:00 and 16:00), and weekly
  Monday 04:00. The schedule lives in a clearly-marked managed block inside
  root's `/etc/crontabs/root`, is read back and verified after each save, and
  is shown alongside recent backup files plus a tail of the cron log.
- **Adopts the old hand-installed cron line automatically.** If a
  `battlegroup backup` cron line is already on the VM (e.g. the legacy
  `0 4 * * *` line from the backup guide) and its schedule matches a known
  preset, the card preselects that preset and offers a one-click migration
  into the managed block. The first Save also strips any other stray
  `battlegroup backup` lines so two schedules can't run at once.
- The existing manual **Take Backup** and **Restore Backup** controls are
  unchanged. Note that the schedule lives on the VM, so reprovisioning the VM
  loses it and it must be re-installed from the card.

## [10.1.7] - 2026-06-01

### Removed
- **The "Wipe all listings" testing tool was removed from the Settings page.**
  dune-admin now ships its own **Wipe Listings** control in its market-bot
  panel, which owns that job directly. The portal's `POST /api/db/wipe-bot-listings`
  route and the Settings-page wipe panel (checkbox + button) are gone, removing a
  duplicate, destructive DB action from the tool.

## [10.1.6] - 2026-06-01

### Changed
- **The portal no longer wastes time reinstalling dune-admin when it's already
  patched.** When sane-pricing auto-apply is enabled and the dune-admin binary
  on disk is already the patched build for the exact upstream version *and* the
  same gamble-die config, the install route now detects this up front (via the
  patched stamp written next to the exe) and no-ops instead of downloading,
  overwriting with the upstream binary, and recompiling to a byte-identical
  result. This also removes the brief window where the unpatched upstream exe
  sat in place mid-rebuild. A full reinstall can still be forced by passing
  `force: true`.
- The Settings page now reports "already up to date and patched" instead of
  running a redundant reinstall, and re-checks update status afterward.

## [10.1.5] - 2026-05-31

### Fixed
- **The portal no longer kills its own server right after an update/relaunch.**
  The app-window watcher (which stops the server when you close the window) was
  armed on the specific DuneShell window the server launched. Because DuneShell
  is single-instance, a freshly launched window can exit immediately when an
  older window still owns the global mutex — and the watcher took that instant
  exit as "the user closed the window" and tore down the brand-new HTTP listener.
  The surviving window was then left retrying forever ("Connecting to Dune Server
  Tool… (attempt N)"), and dashboard panels flashed "Failed to fetch" / "spice:
  Failed to fetch" while a zombie server lingered. The watcher now only stops the
  server if **no** DuneShell window survives a short grace period; if one does, it
  re-arms on it and keeps serving. Closing the last window still stops the server.

## [10.1.4] - 2026-05-31

### Added
- **Map SpinUp page** — spin native maps up or down on the live battlegroup by
  patching `director.ini` via a base64-piped `kubectl patch --patch-file` (no
  fragile embedded quoting).

### Fixed
- **dune-admin gets its own loopback port when another app squats 8080.** When a
  foreign process (e.g. CubeCoders AMP) already holds the configured dune-admin
  port, the launcher now moves dune-admin to a free `127.0.0.1` port instead of
  surfacing an unreachable `[::1]` URL.
- **Auto-update no longer gets stuck reporting the old version.** The runtime
  version constant compiled into `DuneServer.exe` is now bumped together with the
  installer metadata, so the update banner clears correctly after installing.

## [10.1.3] - 2026-05-31

### Added
- **The installer now offers to install the pricing-patch build tools.** The
  optional "sane pricing" market patch compiles a patched `dune-admin.exe` from
  source, which needs Node.js, Go and Git. At install time DST checks whether
  those are present and, if any are missing, offers to install them via winget
  (your choice — skip it if you don't use the patch). If the install can't be
  done on your PC, it shows what to install manually and where to get it; the
  Dune Server Tool itself installs and works regardless. This avoids the patch
  build trying to bootstrap a toolchain on-demand later.
- **Deferred sane-pricing patch when you delete `~/.dune-admin` on reinstall.**
  Rebuilding the patched `dune-admin.exe` requires the on-disk source/config to be
  present, and the exe is locked while the first-run setup wizard is open. If you
  elect to delete your `.dune-admin` folder during a reinstall, the portal no
  longer tries to rebuild mid-setup (which failed with exit 1). Instead it records
  a pending marker, tells you the pricing patch will not deploy until dune-admin is
  reconfigured, and then automatically polls. Once setup finishes and dune-admin is
  listening, the patch applies on its own (it briefly stops dune-admin to swap in
  the patched build).

### Fixed
- **The desktop window no longer gets stuck on "Hmmm… can't reach this page".**
  DuneShell (the WebView2 app window) revealed the page on the first navigation
  regardless of whether it succeeded, so if it started a moment before the portal's
  HTTP listener was accepting (a timing race), it showed a permanent connection-error
  page with no recovery. It now retries the navigation (up to ~12s) on any
  transport-level failure and only gives up — showing the error page so you can F5 —
  after that, eliminating the intermittent "console says listening but the window
  can't reach it" symptom.
- **Pricing-patch build no longer dies on a stale pnpm shim.** A standalone-pnpm
  self-update can orphan the `pnpm.ps1` shim on `PATH` (it points at a versioned
  global exe that pnpm deleted), so `& pnpm install` failed with "pnpm.exe is not
  recognized" at build time even though `pnpm --version` worked interactively. The
  build wrapper now probes each pnpm candidate with `--version` and falls back to
  `corepack pnpm`, so the web-UI build resolves a working pnpm reliably.

## [10.1.2] - 2026-05-31

### Fixed
- **dune-admin now opens on the correct per-user port instead of a hardcoded
  `8080`.** dune-admin's listen port is configurable (`listen_addr` in
  `~/.dune-admin/config.yaml`): it defaults to `:8080`, but its setup wizard
  writes whatever you choose — notably `:18080` when the `amp` control plane is
  selected, since CubeCoders AMP commonly squats `8080`. The portal was assuming
  `8080` everywhere, so AMP users (and anyone on a custom port) had the
  **Characters** link land on the wrong app's panel. DST now resolves the real
  port from `listen_addr` and opens that exact URL.
- **The browser no longer opens before dune-admin is actually ready.** Clicking
  **Characters** previously launched dune-admin and opened the web UI after a
  fixed 1-second wait — so if dune-admin was still running first-time setup (or
  its port was taken), the browser opened prematurely onto a dead port or
  another app. DST now waits (up to ~30s) until dune-admin is listening on its
  configured port **and** verifies the process holding that port is dune-admin
  itself (not AMP) before opening. If dune-admin isn't set up yet, or the port
  is owned by something else, it shows clear guidance instead of opening the
  wrong thing.
- **dune-admin now opens correctly even when it shares port 8080 with AMP on a
  different IP family.** When CubeCoders AMP already holds the IPv4 wildcard
  (`0.0.0.0:8080`), dune-admin can only bind the IPv6 wildcard (`[::]:8080`).
  In that split, `localhost` resolves to `127.0.0.1` first and lands on AMP's
  panel — even though dune-admin *is* listening on the same port number. DST now
  inspects the actual listeners and, when there's a cross-family conflict, opens
  the loopback literal that dune-admin owns exclusively (`http://[::1]:<port>`),
  so the **Characters** link reliably opens dune-admin instead of AMP. The
  readiness probe was also fixed to test the dune-admin-owned address, so it can
  no longer report AMP as "dune-admin is listening."

### Added
- `GET /api/dune-admin/web-url` — single source of truth for dune-admin's
  effective URL/port (`configured`, `port`, `listenAddr`, `url`, `listening`,
  `ownerProcess`, `listeningIsDuneAdmin`). The UI reads this instead of guessing
  `8080`, so fallbacks never open a non-dune-admin panel.

### Changed
- **The sane-pricing patch no longer re-downloads the dune-admin web UI's whole
  dependency tree on every reinstall.** The web UI is identical across
  pricing-patch rebuilds (the patch only touches Go), so the patched build now
  skips `pnpm install` + `pnpm build` when the prerequisites are already in
  place — `node_modules` present, a prior `web\dist` exists, and the build
  inputs (upstream `VERSION` + `pnpm-lock.yaml`) are unchanged since the last
  successful build. Any version or lockfile change still forces a fresh build,
  so correctness is preserved. When a rebuild *is* needed, `pnpm install` now
  runs with `--prefer-offline` to reuse the local package store. Result:
  reapplying the patch to an already-built version is near-instant instead of a
  multi-minute re-download.



### Fixed
- **Hotfix: the app failed to start ("Dune Server bootstrap failed").** Two
  diagnostics strings shipped in 10.1.0 used syntax that Windows PowerShell 5.1
  (the engine the packaged `DuneServer.exe` runs under) could not parse, so
  `DuneAdmin.ps1` / `System.ps1` failed to load and the whole portal aborted at
  startup. Specifically: an em-dash (`—`) inside a double-quoted string in a
  no-BOM file (5.1 mis-decodes it via the ANSI code page into a quote-like
  character, unbalancing the string), and a `??` null-coalescing operator
  (PowerShell 7 only). Both replaced with 5.1-safe equivalents; all dot-sourced
  `lib/`/`routes/` files now verified to parse under 5.1.

## [10.1.0] - 2026-05-31

### Added
- **"DST needs X — install it?" dependency popup.** When a feature needs a build
  tool that's missing (Go, Git, Node.js), DST now detects it and offers to
  install it for you via `winget` from a single modal, instead of failing the
  build with a cryptic error. Detection probes both `PATH` and standard install
  locations (`%ProgramFiles%\Go\bin`, `%ProgramFiles%\Git\cmd`,
  `%ProgramFiles%\nodejs`, `%LOCALAPPDATA%\Microsoft\WinGet\Links`) so a
  freshly-installed tool is found without restarting DST. Installs run detached
  (machine scope first, user-scope fallback) so they never freeze the portal.
  New endpoints: `GET /api/system/dependencies`,
  `POST /api/system/dependencies/install`,
  `GET /api/system/dependencies/install-status`.

### Changed
- **dune-admin links now open the LOCAL instance** (`http://localhost:<port>/#/...`,
  port derived from `listen_addr`, default 8080) instead of the hosted
  `dune-admin.layout.tools` site. The hosted UI is a different origin from your
  local dune-admin API, which caused "Failed to fetch" and a sign-in wall; the
  embedded, same-origin UI dune-admin serves needs neither. Updated the launcher,
  sidebar "Characters" link, setup-wizard link, and README.

### Fixed
- **Market Bot diagnostic false "not configured".** The troubleshooter inferred
  "configured" from two legacy `config.yaml` keys (`market_bot_addr` /
  `market_bot_container`) that modern dune-admin leaves empty, so a perfectly
  healthy running bot showed as "not configured." It now trusts the cache DB
  (`market-bot-cache.db` exists **and** is locked = the bot process holds it
  open = running), and the panel reports "running" accordingly.
- **HTTP-probe 404 meaning corrected.** A 404 at dune-admin's root no longer
  reads as benign — it specifically means the binary was built **without the
  embedded web UI** (`-tags embed`). The diagnostic now flags this as a warning
  and points at updating DST / reinstalling to get an embed build, rather than
  suggesting unrelated workarounds.

## [10.0.12] - 2026-05-31

### Fixed
- **Patched dune-admin builds served no web UI ("can't access dune-admin / the
  Market Bot panel").** The local pricing-patch build ran a plain `go build`,
  which omits the `embed` build tag and never built the SPA — so the rebuilt
  `dune-admin.exe` served the API and market bot but returned 404 for the entire
  web portal. The patched build now builds the web UI (`pnpm install && pnpm
  build`), stages it into `cmd/dune-admin/dist`, and compiles with
  `go build -tags embed`, matching upstream's release binary. Adds a build-time
  Node.js + pnpm requirement (pnpm auto-enabled via corepack); the build now
  fails fast with guidance if Node is missing instead of producing a UI-less
  binary. To unblock immediately on an older build, uncheck "Keep Coastal's
  sane-pricing patch" and reinstall to use the upstream prebuilt binary.

## [10.0.11] - 2026-05-31

### Fixed
- **Crash on close when the console is sent to the system tray.** Picking "Send to
  system tray" then closing the app window could pop a .NET "Unhandled exception …
  The pipeline has been stopped" dialog. Shutdown force-stopped the tray runspace
  while its WinForms message pump was still running, injecting a
  `PipelineStoppedException` into the pump. The tray pump now traps thread
  exceptions and exits cleanly, and teardown waits for the watcher/tray helpers to
  self-terminate instead of stopping their pipelines.
- **dune-admin diagnostics: "Cannot overwrite variable HOME …" error.** The sidecar
  resolver assigned to `$home`, a read-only automatic variable in the compiled-exe
  host, so the diagnostics report errored on machines running the installed build
  (it happened to work in a dev PowerShell session). Renamed the local variable.

## [10.0.10] - 2026-05-31

### Added
- **dune-admin diagnostics.** Settings → dune-admin card now has a "Troubleshoot
  dune-admin" panel that runs a one-shot health report: backend reachability on
  the SPA's expected port, config.yaml vs environment-variable precedence, stale
  `~/.dune-admin` sidecar shadowing, duplicate-instance detection (which locks
  the market-bot cache DB), and pricing-patch build state. Surfaces colour-coded
  findings with hints plus a "Copy report" button so issues like the dune-admin
  portal's "Failed to fetch" can be self-diagnosed or shared for support.

### Removed
- **"Use local config files" feature.** The `%APPDATA%\DuneServer\configFiles`
  store, its "Refresh config files" / "Use local config files" controls, and the
  `UseLocalConfigFiles` config key have been removed — they added maintenance
  overhead and could shadow the configured SSH key. The SSH key is still copied
  into the dune-admin folder automatically whenever dune-admin is installed or
  updated, and the `rotate-ssh-key` command continues to re-copy the freshly
  rotated key there, so no functionality is lost.

### Changed
- **Console + app-window share one lifecycle.** Closing the DuneShell app window
  now stops the server/console, and closing the console (or picking "Quit" from
  the tray) closes the app window — symmetric cleanup, one console + one app
  window per machine. On first run the user chooses how the console presents
  itself while the app window is open (minimized vs. system tray); the choice is
  remembered. No-op in browser-fallback mode.



### Fixed
- `startup` and `reboot` no longer abort before starting the battlegroup when a
  pre-start readiness check is slow. Previously, if the k3s API, operator pods,
  or operator webhook endpoints didn't report Ready within their (already
  generous) budgets, the command stopped after powering on the VM and the
  battlegroup had to be started manually. These checks now warn and proceed to
  start the battlegroup anyway, matching the existing database-wait behavior. The
  VM-IP and SSH checks remain hard prerequisites because the battlegroup is
  started over SSH and cannot run without them.

## [10.0.8] - 2026-05-31

### Fixed
- Clicking the desktop shortcut while the server is already running now
  re-opens (and focuses) the standalone app window instead of opening the
  portal in a web browser. The single-instance handler predated the app
  window and always fell back to the browser; it now respects the
  `OpenInAppWindow` setting (default on) and launches `DuneShell.exe`,
  only using the browser when the app window is disabled or unavailable.
- The app window (`DuneShell.exe`) is now itself single-instance: repeated
  launches focus the existing window rather than stacking duplicates. This
  also prevents the "both the app and a browser tab opened" behavior seen
  right after an in-app update.

## [10.0.7] - 2026-05-31

### Fixed
- Standalone app window can no longer restore off-screen. The saved
  position is now clamped onto a currently-connected monitor with the
  title bar always reachable: it snaps to the display it overlaps most
  (or the primary monitor if the previous monitor was unplugged) and is
  nudged fully inside that screen's working area. Previously a window
  saved on a secondary monitor that was later disconnected — or parked
  far off the primary display — could open where it couldn't be seen.

## [10.0.6] - 2026-05-31

### Changed
- **License switched from MIT to Apache 2.0** to add explicit
  notice-preservation (Section 4) and trademark-protection (Section 6)
  clauses. You can still use, fork, and modify freely; redistributors must
  now preserve the `NOTICE` file and credit the original author. Added new
  top-level `NOTICE` file and README "License & attribution" section.

### Fixed
- App launcher now closes any stale `DuneShell` window from a previous run
  (e.g. left over after an in-app update, where the relauncher restarted
  `DuneServer.exe` but the prior WebView2 window kept pointing at the
  now-dead server). Guarantees exactly one app window after launch.



## [10.0.5] - 2026-05-31

Displayed in-app as **X (0.5)**.

### Added

- **Standalone app window.** The portal now opens in its own desktop window
  (DuneShell, a self-contained WebView2 host) instead of a browser tab, for a
  clean app-like feel. A slim native menu at the top provides **Server Health**
  and **Settings** navigation (plus **View → Reload / Open in browser**).
  External links (websites, the dune-admin web UI) still open in your default
  browser, and console commands still spawn their own windows.
  - The window is freely resizable and opens at 2000×1196 by default; its size,
    position and maximized state are remembered between launches.
  - New `OpenInAppWindow` setting in `dune-server.config` (default **on**).
    Set it to `false` to fall back to opening the portal as a browser tab.
    If `DuneShell.exe` is missing, the launcher automatically falls back to the
    browser.

## [10.0.4] - 2026-05-30

Displayed in-app as **X (0.4)**.

### Added

- **"Fix on-demand maps" action.** Re-runs the VM's partition-cleanup script
  (`/etc/local.d/dune-clear-partitions.start`) to clear the drifted
  `igwsss.spec.partitions` pin that intermittently stops DeepDesert,
  SH_Arrakeen and SH_HarkoVillage from launching on demand, then tails the
  last 10 lines of `/var/log/dune-clear-partitions.log` so you can see what
  happened. The remote script is idempotent and skips any map that already
  has a running pod, so it's safe to run repeatedly.
  - CLI: new **fix-on-demand-maps** entry in the Battlegroup menu.
  - Portal: new **Battlegroup** command button, plus a dedicated tool card on
    the **Database** page with an inline output pane
    (`POST /api/maps/fix-partitions`).

### Changed

- **Reinstalling dune-admin now reopens it after wiping the stale config
  folder.** When you confirm "delete" on the stale `.dune-admin` preflight
  prompt during an install, the market bot's config and DB pointers are gone —
  so DST now launches dune-admin once the install (and any pricing-patch
  rebuild) finishes, letting you re-run market-bot setup right away. The launch
  is deferred until the rebuild completes so the running exe can't lock it.


## [10.0.3] - 2026-05-30

Displayed in-app as **X (0.3)**. Cosmetic rebrand — no functional changes.

### Changed

- **Rebranded the app to "Dune Server Tool"** across all user-visible surfaces:
  browser tab title, web app manifest, Settings page, Dashboard elevation hint,
  and the update banner.
- **Installer now presents as "Dune Server Tool"** — Start Menu group, Add/Remove
  Programs entry, and the default folder for **new** installs
  (`C:\Program Files\Dune Server Tool`).
- **GitHub repository renamed** to `coastal-ms/DST-DuneServerTool` ("DST - Dune
  Server Tool"). Updated all in-code repo references (update checker, issue links,
  badges). Old URLs continue to redirect automatically.

### Notes

- **Existing installs upgrade in place** — they keep their current install folder
  (`C:\Program Files\Dune Server`) and only the display name changes.
- **On-disk identifiers are unchanged** by design: `DuneServer.exe`, the Windows
  process name, the installer asset (`DuneServerSetup.exe`), the Inno AppId, and
  the user-data directories (`%APPDATA%\DuneServer`, `%LOCALAPPDATA%\DuneServer`)
  all stay the same, so auto-update and existing configuration are preserved.


## [10.0.2] - 2026-05-30

Displayed in-app as **X (0.2)**. Patch release.

### Changed

- **Server Health now refreshes every 10 seconds** (was 30s) so the Game Ready
  State heartbeat and game-server pod status reflect the live server much faster.


## [10.0.1] - 2026-05-30

Displayed in-app as **X (0.1)**. Bug-fix release.

### Fixed

- **dune-admin reinstall/setup no longer deletes the `~/.dune-admin` config
  folder without asking.** The stale-folder preflight used `window.confirm()`,
  which is fired after an `await` (the folder-existence check). Browsers expire
  the click's user-activation across the `await` and then suppress the dialog,
  silently returning `true` — so the folder was deleted with no prompt ever
  shown. The preflight now uses an in-app modal (Cancel / Keep & continue /
  Delete & continue) that always renders and defaults to non-destructive;
  Cancel aborts the reinstall/setup entirely.

### Changed

- **Server Health heartbeat now reflects login readiness.** The heartbeat sensor
  (relabeled **"Game Ready State"**) is driven by the `Survival_1` map pod — the
  map players actually connect to. Green + "Ready" when it reports ready, yellow +
  "Starting" while it's in a startup phase, red + "Not Ready" when it's down,
  missing, or failed (you can't log in). Previously it tracked the Battlegroup
  operator's reconcile state, which could read healthy before the map was joinable.
- Refreshed all README portal screenshots (PII scrubbed).


## [10.0.0] - 2026-05-30

Displayed in-app as **X**. Feature release rolling up everything since 6.3.2. Focus: dune-admin
operability (config-files handling, SSH-key rotation, folder picker, reliable
reinstall) plus market-bot pricing correctness and a testing-only listings wipe.

### Added

- **Local config-files support.** A new "Use local config files" toggle (Settings)
  switches the server between the effective merged config and a raw local file,
  and the installer now seeds `UseLocalConfigFiles=true` on fresh installs
  (existing configs are preserved). Backend splits raw-vs-effective config.
- **DST config-files store.** `Sync-DstConfigFiles` maintains a backup snapshot
  under `%APPDATA%\DuneServer\configFiles\` (sshKey + .pub, dune-server.config,
  a dune-admin `config.yaml` backup) and re-dumps the SSH key into the dune-admin
  folder. Backup/re-dump only — normal paths always win; opt-in, never required.
  New endpoints `GET /api/config-files` and `POST /api/config-files/sync`, with a
  "Local config files" panel + Refresh button in Settings.
- **Generate new SSH key button** next to the SshKey field. Runs `rotate-ssh-key`,
  waits for completion, then `Sync-DstConfigFiles` propagates the new key
  everywhere. New `POST /api/config/rotate-ssh-key`.
- **dune-admin folder picker.** The dune-admin path field is now a folder picker
  (the tool installs `dune-admin.exe`, so the exe doesn't exist at config time).
  Backend normalizes folder vs. exe paths transparently.
- **VM heartbeat sensor** on the Game-servers card — an animated liveness pulse
  pinned to the bottom of the card, driven by the VM probe.
- **"Wipe all listings" testing button** (Settings → dune-admin updates). Guarded
  by an "I approve" checkbox + confirm dialog; clears the market bot's exchange
  orders/items so it re-lists from scratch. Testing only. New
  `POST /api/db/wipe-bot-listings`.
- **Market-bot pricing defaults re-seed.** The sane-pricing dune-admin patch now
  carries a one-time defaults migration: when an older persisted config is loaded,
  the Grade/Rarity/Vendor multiplier defaults are re-seeded once to the current
  sane values, then operator edits afterward stick. Fixes bots that were stuck on
  stale multiplier defaults from earlier patch versions. The pricing-logic patch
  sets bot-level defaults at patch time; operators can still adjust them later.

### Changed

- **Header port pills** split into individual green/neutral indicators driven by
  per-port probes instead of one combined pill.
- **Reinstalling dune-admin now always offers to delete a stale `.dune-admin`
  folder** (not just on first install / folder change). A stale dotfolder was the
  real cause behind "bot won't start / no market"; the prompt is context-aware
  (setting up / changing folder / reinstalling) and never auto-deletes.
- Single-instance enforcement: any running `dune-admin` is stopped before launch.

### Removed

- **Characters page** removed. The sidebar entry now launches dune-admin and opens
  the players URL (guarded so it only fires when the server is running).
- **Market-bot database health check** (added in 6.3.1) removed. It TCP-probed
  `127.0.0.1:15432`, but the embedded bot dials Postgres over dune-admin's own
  in-process pool with no local listener, so the probe was a persistent false
  negative even while the bot listed thousands of items. The `.dune-admin`
  reinstall delete-prompt addresses the real "bot won't start" cause.


## [6.3.2] - 2026-05-30

### Added

- **Auto-stop running dune-admin instances before an update.** The install/update
  route now proactively kills any running `dune-admin` process (matched by name
  and by the configured exe path) before overwriting `dune-admin.exe`, then waits
  for the file lock to release. This fixes the case where dune-admin is running
  with **no visible window** (e.g. launched detached / by the embedded bot) and
  the user has no way to close it by hand — previously the update bailed with a
  "file is locked" error (HTTP 423). Stopped PIDs are reported back in the install
  response (`stoppedPids`).



Diagnostic follow-up to the recurring "No market bot connected" reports. The
embedded market bot dials Postgres (`db_host:db_port` from dune-admin's
`config.yaml`) at startup; in kubectl/k3s setups that DB is reached over a
tunnel, and if the tunnel is down when dune-admin launches the bot fails
silently and dune-admin just shows an empty market with no explanation.

Thanks to **Techtonic** for the legwork that pinned this to an unreachable
`127.0.0.1:15432` at runtime.

### Added

- **Market-bot database health check** (Settings → dune-admin updates). Reads
  `db_host` / `db_port` / `market_bot_enabled` from dune-admin's `config.yaml`
  and does a short TCP probe (1.5s timeout) against that host:port, surfacing one
  of: **reachable** (bot should start), **unreachable** (tunnel/DB down — the bot
  will fail and the market will be blank, with guidance to bring the tunnel up
  before launching dune-admin), **disabled**, or **not set up yet**. A **Recheck**
  button re-runs the probe after fixing the tunnel.
  - New endpoint `GET /api/dune-admin/market-bot-health`.
  - Purely diagnostic — reads config and probes a port; changes nothing.



Adds player-facing control over how aggressively the sane-pricing market bot
buys. The patch has always rolled a die per candidate listing and only bought
on one winning number (a d12, buy-on-5 — roughly a 1-in-12 chance per listing);
those values are now configurable from the Settings page instead of being
hard-coded in the patch.

### Added

- **Gamble die config for the pricing patch** (Settings → dune-admin updates).
  Two new inputs — **Die size (N)** and **Buy on roll** — let you tune the bot's
  buy frequency. The bot rolls a 1–N die per candidate listing and only buys when
  it hits the target number, so a larger die means fewer buys. Defaults (12 / 5)
  reproduce the original patch behaviour exactly, so existing installs are a
  byte-identical no-op until you change them.
  - Persisted to `dune-server.config` as `GambleDieSize` / `GambleTarget`.
  - Validated both client- and server-side: die size ≥ 2, and buy-on-roll
    between 1 and the die size.
  - Baked into the patched `dune-admin.exe` at **build time** via the
    `-GambleDie` / `-GambleTarget` parameters on `build-patched.ps1`, written with
    LF endings and reverted from the working tree after the build (tree stays
    clean). Non-default values rewrite the gamble-roll in `exchange.go`; the build
    fails loudly if the expected pattern isn't found rather than silently shipping
    stock odds.
  - The UI notes that changes take effect on the **next** patch (re)apply — i.e.
    click Install with the pricing-patch box checked to rebuild with the new odds.



Hotfix on top of 6.2.3: the CRLF fix let the pricing-patch rebuild get past
`git apply` for the first time — which immediately exposed a second bug that had
always been lurking right behind it.

Thanks again to **Techtonic** for catching this the moment 6.2.3 unblocked his build.

### Fixed

- **Pricing-patch rebuild failed with "You cannot call a method on a null-valued
  expression" right after `go build` started** (`fatal: not a git repository`).
  The installer rebuild flow overlays an upstream **source tarball**, which has no
  `.git` directory. `git apply` doesn't need a repo, but the version-stamping step
  called `git rev-parse --short HEAD` and then `.Trim()`'d the result — which is
  `$null` outside a repo. `build-patched.ps1` now treats the git commit (and a
  missing `VERSION` file) as **best-effort**: it stamps `commit=unknown` instead of
  crashing, so the rebuild completes.

## [6.2.3] - 2026-05-30

Hardens the dune-admin pricing-patch rebuild against line-ending corruption,
polishes the in-app updater messaging, and fixes a couple of UI papercuts.

Big thanks to **Techtonic** on Discord for surfacing the patch-apply failure that
led to the root-cause fix below.

### Fixed

- **Pricing-patch rebuild failed with "Patch does not apply cleanly" / "Patch is
  stale relative to current source."** The bundled `0001-sane-pricing-100k-cap.patch`
  had been silently rewritten with **CRLF** line endings (cross-tree/OneDrive sync).
  `git apply` matches context lines byte-for-byte, so a CRLF patch never applies to
  the LF Go source — against **any** upstream dune-admin version. This masqueraded as
  a "stale baseline" problem. Three-layer fix:
  - The committed patch is normalized back to **LF**.
  - `build-patched.ps1` now **self-heals**: it detects CR bytes in any patch and
    applies an LF-normalized temp copy, so a re-corrupted patch still applies.
  - A repo `.gitattributes` forces `*.patch`/`*.diff`/`*.go` to `eol=lf` so git can
    never re-introduce CRLF.
- **Database "Take Backup" button could stay greyed out even while the battlegroup
  was running.** Availability came from a one-shot `/api/commands` fetch whose own
  SSH `battlegroup status` call could latch a stale `stopped`/error result that never
  refetched. Backup/restore availability is now derived from the **live** status poll.
- **Misleading "SSH error: No resources found in <ns> namespace" on Server Health.**
  An empty battlegroup namespace now reads **"Battlegroup not started (namespace is
  empty)."**

### Changed

- **In-app updater messaging.** Replaced the modal/redirect dance with a clear
  full-screen status that tells you plainly to **close all leftover Dune Server
  browser tabs and console windows** once the new window opens. No more scripted
  tab-closing promises the browser can't keep.

## [6.2.2] - 2026-05-30

Makes cold first boots reliable: raises the cluster-readiness timeouts and stops
SSH key-auth failures from silently hanging the startup flow.

Big thanks to **Techtonic** on Discord for patiently working through a cold
first-boot bring-up and surfacing both of these issues.

### Fixed

- **Startup could hang indefinitely on "Waiting for DB pod(s) Ready…" when SSH
  key auth wasn't working.** The DB / operator readiness phases run their `ssh`
  calls inside a background runspace (so the live counter can tick). If the key
  wasn't authorized on the VM, `ssh` silently fell back to a **password prompt**
  that the background runspace has no console to answer — so it waited forever.
  All non-interactive `ssh` calls now pass **`-o BatchMode=yes`**, so a key-auth
  failure fails fast instead of hanging. The SSH-readiness gate now also prints
  clear guidance (run `rotate-ssh-key`, or how to append the key's `.pub` to
  `~/.ssh/authorized_keys`) when it can't connect.

### Changed

- **Cold-boot cluster-readiness timeouts raised.** A fresh battlegroup's *first*
  boot can take 10–30 min (k3s + funcom-operators initializing, `metrics-server`
  restarting until its serving cert is up, images still pulling). The old
  180s/120s caps aborted healthy-but-slow boots. New budgets: VM IP 5 min, SSH
  5 min, k3s API 10 min, DB pods 15 min, operators 15 min, webhook endpoints
  5 min. Startup/reboot now also warn up front that "first boot can take 10–30
  min." Both the `startup` and `reboot` readiness blocks were updated.


## [6.2.1] - 2026-05-30

Fixes the sane-pricing patch build, adds new pre-flight checks, and lets the
updater actually close the old window.

### Fixed

- **`build-patched.ps1` failed with `The term 'git' is not recognized…` when the
  sane-pricing patch was applied from Settings.** The patch builder is launched by
  a background wrapper spawned from `DuneServer.exe` (a ps2exe binary), whose
  inherited `PATH` can be missing entries an interactive shell would have — most
  commonly **Git**. The builder now resolves `git` and `go` via `PATH` first, then
  falls back to their standard install locations (`Program Files\Git`,
  `Program Files\Go`, per-user installs, and WinGet `Links` shims), prepends the
  resolved directory to `PATH` (so Go's own internal Git calls also work), and
  fails fast with an actionable **"Install Git for Windows (winget install Git.Git)"**
  message if neither can be found.

### Added

- **Pre-flight wizard now checks for Git and SSH-key authorization, with
  copy-paste fixes.** Each failing check shows the exact PowerShell command (with a
  one-click **Copy** button) to resolve it — aimed at users who are tech-smart but
  not CLI-smart. New checks:
  - **Git** (warning) — needed only for the optional sane-pricing patch; offers
    `winget install --id Git.Git -e`.
  - **SSH key authorized on VM** (warning) — verifies the *configured* key actually
    authenticates to `dune@<vm>`. If the key was generated outside the tool and
    never authorized, it explains the cause and offers two fixes: use the tool's
    **Rotate SSH Key** action (generates *and* authorizes a fresh key), or
    authorize the existing key from a machine with working SSH access.
  - Existing **Administrator**, **Hyper-V**, and **disk-space** checks now also
    carry copy-paste fix commands.

### Changed

- **The portal now opens as an app-mode window (Edge/Chrome `--app=`) when
  available.** App windows are script-closable, so the in-app updater's
  "this window is offline" takeover can now **actually auto-close** the stale
  window after an update finishes. Falls back to a normal default-browser tab when
  no Chromium browser is found (where the browser still blocks auto-close, and the
  takeover screen + manual Close button remain).


## [6.2.0] - 2026-05-30

Feature: **updater "this window is offline" takeover**, plus a release-history cleanup.

### Added

- **Update flow now takes over the whole portal when an update launches.** Clicking
  **Update now** previously left a small banner while the old window stayed fully
  usable — so after the server restarted, someone could keep clicking around a
  **stale, disconnected window** and think the tool was broken. The portal now shows
  a full-screen "Updating Dune Server Tool…" screen the moment the installer
  launches, **polls the server**, and the instant it goes offline flips to a clear
  **"This window is now offline — safe to close"** state with a **Close this window**
  button. It also makes a **best-effort auto-close** (works for PWA / app-mode
  windows; normal browser tabs block programmatic close, so the screen plus the
  button cover that case). The updated tool still relaunches in a fresh window
  automatically when the installer finishes. _(This screen ships inside the new
  build, so it appears on the **next** update onward.)_

### Changed

- **Pruned GitHub releases** from 32 entries down to a clean set: one release per
  major for **v1–v5**, split by minor for v6 (**v6.0**, **v6.1**, **v6.2**). Each
  consolidated release keeps the newest installer of its group; per-release git tags
  are preserved.

Fix: **Setup Wizard Step 3 (initial-setup) opened a console that "ran one thing and closed."**

### Fixed

- **Setup Wizard Step 3 / `initial-setup` console closing instantly:** the tool
  dot-sourced Funcom's `initial-setup.ps1` directly into `dune-server.ps1`, so the
  script inherited the tool's own `$scriptDir` (its install dir, e.g.
  `C:\Program Files\Dune Server`) instead of the `battlegroup-management` folder.
  It then looked for the VM image at `...\..\Virtual Machines` under the wrong path
  and failed with `No .vmcx file found`. Because Funcom's script calls `exit 1` on
  every error, dot-sourcing it killed the entire console window with no readable
  message — the reported "runs 1 thing and closes." The tool now runs
  `initial-setup.ps1` in a **child PowerShell** that replicates Funcom's own
  environment (sets `$scriptDir` to `battlegroup-management` and loads
  `vm-utilities.ps1`, exactly like their `battlegroup.ps1`), so every path resolves
  correctly and any `exit` only ends the child. The window now stays open and shows
  any error. A guard also reports a clear message if **Steam Path** in Settings does
  not point at the Self-Hosted Server install (the folder containing
  `battlegroup-management`).

Feature: **dune-admin market bot "d12 gamble buy" pricing mode**, plus Settings quality-of-life.

### Added

- **dune-admin market bot — d12 gamble buy:** the bundled sane-pricing patch now
  replaces the market bot's price-threshold buy gate with a dice roll. On every
  buy tick, each candidate player listing rolls a 12-sided die; only a **5**
  buys the item — **regardless of price** — otherwise it is skipped. The
  per-tick `MaxBuys` cap and the unknown / non-buyable / disabled-item safety
  skips still apply; only the price comparison is replaced by the gamble. This
  ships inside `0001-sane-pricing-100k-cap.patch` (now also patches
  `internal/marketbot/exchange.go`) and is applied automatically when you
  install/rebuild dune-admin with the pricing patch enabled.
- **Settings — folder/file locator buttons:** each path field (Steam path, SSH
  key, dune-admin.exe) now has a **Browse** button that opens a native
  Windows folder/file picker via `POST /api/browse-path`.
- **Settings — Icehunter branding:** the dune-admin.exe card header and the
  updater pointer text now carry the "by Icehunter" badge / live repo link,
  matching the Commands page.

### Fixed

- **Native path picker:** fixed an "Argument type cannot be System.Void" error
  in the new browse route by using `$null = $ps.AddArgument(...)` instead of a
  `[void]…| Out-Null` call chain.


## [6.1.31] - 2026-05-30

Patch: **dune-admin install now auto-copies your SSH key into the dune-admin folder.**

### Fixed

- **dune-admin install / setup wizard:** every call to `POST /api/dune-admin/install`
  and `POST /api/dune-admin/setup` now copies the user's SSH private key (and
  `.pub` if present) into the dune-admin install folder as `sshKey` /
  `sshKey.pub`. dune-admin's SSH/kubectl-over-SSH layer reads `./sshKey`
  first, so this is what makes the binary actually able to authenticate
  against the VM right after install — previously the user had to copy the
  file in by hand or `dune-admin server start` would fail to reach the VM.
  The CLI `rotate-ssh-key` flow already did this (since v6.0.x); the web
  install paths now match.
  - Source-of-truth selection: newest mtime between the configured
    `SshKey` (from `dune-server.config`) and
    `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` (where the CLI's
    `rotate-ssh-key` writes new keys). Always lands as `sshKey` in the
    target dir regardless of source filename.
  - Non-fatal: a copy failure (missing key, ACL issue, target dir
    perms) does not break the binary install. The result is surfaced
    as `sshKeyCopy: { ok, skipped, source, dest, message }` in the
    `/install` and `/setup` JSON response and the Settings page now
    shows a "SSH key copied next to dune-admin.exe" confirmation or
    a "WARNING: SSH key was NOT copied" toast with the underlying
    reason.
  - New helper `Copy-DuneAdminSshKey` in `app/server/routes/DuneAdmin.ps1`;
    mirrors the CLI's `Resolve-FreshSshKey` + `Copy-SshKeyToDir` pattern
    from `dune-server.ps1` so both code paths stay consistent.


## [6.1.30] - 2026-05-29

Patch: **Auto-updater wizard now appears in foreground; Server Health "Active spice" card has per-row spawning checkboxes.**

### Added
- **Server Health → Active spice card — new "Active" column with
  per-row spawning checkboxes.** A checkbox is rendered to the right
  of the Primed column for every spicefield row, reflecting and
  toggling `is_spawning_active` live. Clicking commits immediately
  via the same guard-railed `PUT /api/gameconfig/spicefields/{id}/spawning`
  endpoint introduced in 6.1.29 (only ever writes `TRUE`/`FALSE` to
  that single column). Optimistic UI with rollback on failure. One
  shared 5-second click cooldown across **all** checkboxes on the
  card (clicking any of them locks every checkbox for 5s, with a
  live `(Ns)` countdown shown next to the disabled row).
- This replaces the previous read-only red "OFF" indicator — the
  checkbox state itself now conveys ON/OFF, and the row is editable.

### Fixed
- **Installer wizard hidden behind other windows after clicking "Update".**
  The relauncher script that bridges the running `DuneServer.exe` to the
  Inno installer was running in a hidden powershell window. Hidden
  parents have no foreground rights, so when the relauncher spawned the
  installer, Windows demoted the wizard behind whatever window the user
  had focus on (browser, file explorer, IDE, etc.). The result:
  clicking Update appeared to do nothing, then the wizard would be
  discovered minutes later buried behind everything. Now:
  - The relauncher window is **visible** and shows a brief
    "Update in progress — installer wizard will appear in a few
    seconds" banner, so the user has clear feedback during the 4-5s
    handoff.
  - The relauncher calls `AllowSetForegroundWindow(ASFW_ANY)` before
    spawning the installer, granting the new process foreground rights.
  - After launching, the relauncher polls for the installer's
    `MainWindowHandle` (up to 30s, covering the UAC consent delay) and
    explicitly raises it via `ShowWindowAsync(SW_RESTORE)` +
    `BringWindowToTop` + `SetForegroundWindow`.
  - Net effect: the wizard is the **first window the user sees** after
    clicking Update, not buried behind the browser.


## [6.1.29] - 2026-05-29

Patch: **Spicefields live-commit toggle + 5-second click rate limiter; dune-admin Icehunter credit.**

### Added
- **Spicefields card — live-commit "spawning" toggle.** Each row's spawning
  checkbox now writes to Postgres the moment you click it, no Save needed.
  Backed by a dedicated guard-railed endpoint
  `PUT /api/gameconfig/spicefields/{id}/spawning` that only ever writes
  `TRUE` or `FALSE` to the single `is_spawning_active` column — no other
  columns are touched even if the body contains extra fields. New
  PowerShell function `Set-V6SpicefieldSpawning` enforces this in three
  layers (strict `[bool]` param, explicit TRUE/FALSE literal, paranoid
  post-compute check). Optimistic UI with rollback on failure.
- **5-second per-button click cooldown.** Both the spawning toggle and the
  Save button on each row are rate-limited to one click every 5 seconds,
  with a live `(Ns)` countdown shown next to the disabled button. Cooldowns
  are per-row and per-button independent (toggling row A doesn't cool down
  row B's Save). Defense-in-depth: the cooldown is also enforced inside the
  click handler so a stale render can't bypass it.
- **Commands page — `dune-admin` button shows an "Icehunter" credit badge.**
  Small inline badge in the bottom-right of the dune-admin command tile
  linking to https://github.com/Icehunter (clicking the badge does not
  launch the command — `stopPropagation` on the link).

### Changed
- Spicefields `isDirty` no longer considers `isSpawningActive` (it's
  committed live now, so it should never make the row "dirty").


## [6.1.28] - 2026-05-29

Patch: **Idempotent reinstall — pre-patch snapshot/restore instead of git restore.**

### Fixed
- **Back-to-back reinstalls now succeed.** `build-patched.ps1` used to clean
  up after a successful build by running `git restore` on each patched file.
  That reverted the file to the user's *local* git HEAD, which on a typical
  install machine is whatever commit the user happened to be sitting on
  (often an older release than the one the installer just overlaid). The
  next reinstall would then see a stale baseline and either fail
  `git apply --check` (`Patch is stale relative to current source`) or
  build a broken binary (`undefined: LoadState`, `OnChange undefined`,
  etc., from `bot.go` referencing symbols a stale `config.go` no longer
  exposes). Now the script snapshots the raw bytes of each touched file
  *before* applying the patch and writes those exact bytes back in the
  `finally` block — so the working tree returns to the **upstream-tarball
  baseline that was just overlaid**, not the user's old git HEAD. Repeated
  Install clicks are now true no-ops on disk and each rebuild starts from
  a clean v0.15.0 baseline.


## [6.1.27] - 2026-05-29

Patch: **Fix v6.1.26 wrapper-script regression that broke every install.**

### Fixed
- **Pricing-patch wrapper now actually executes.** v6.1.26's
  `Start-DuneAdminPricingRebuild` here-string template emitted `""..""`
  (two literal double-quotes around the value) instead of `"..."` for two
  string literals inside the generated wrapper script. The result was a
  syntactically invalid `rebuild-{stamp}.ps1` that pwsh refused to parse,
  so every Install click left status stuck at `running`, no log file was
  ever produced, and the chip in the UI spun forever. With the template
  corrected the wrapper parses, runs `build-patched.ps1`, writes the log,
  and transitions to `success`/`failed` like it did in v6.1.24/v6.1.25.

## [6.1.26] - 2026-05-29

Patch: **Make dune-admin pricing-patch reinstalls reliably succeed.**

### Fixed
- **Sane-pricing patch is now in sync with dune-admin v0.14.2.** The previous
  patch was authored against a v0.13.x baseline whose `defaultConfig()` block
  only had `common/unique/memento` rarities. v0.14.2 added a `rare` rarity
  and shipped different stock multiplier values, so `git apply --check`
  failed on every install attempt — and the recovery path silently
  corrupted the working tree (see below). Regenerated the patch against
  the current v0.14.2 source so `git apply` succeeds cleanly on a fresh
  overlay. Pricing semantics preserved: 100k hard cap, geometric tier
  ladder (T1 50 → T6 30k base), grade compounding (Standard 1.0 →
  Flawless 3.3), small per-rarity premiums (`common` 1.0, `rare` 1.03,
  `unique` 1.05, `memento` 1.08), and 0.95 vendor undercut floor across
  all rarities.
- **`build-patched.ps1` no longer corrupts the source tree on patch
  conflicts.** When `git apply --check` failed, the old recovery path
  ran `git restore` on the touched files — but `git restore` reverts to
  whatever the user's *local* git HEAD happens to be, not to the
  upstream-tarball overlay we just dropped in. In the installer flow
  the local HEAD was typically an older release (v0.13.x), so the
  restore stripped the v0.14.x `LoadState` / `SaveState` / `OnChange` /
  `isDisabled` symbols out of `config.go`. The patch then force-applied
  cleanly against the old code, but the still-v0.14.x `bot.go` and
  `exchange.go` references those missing symbols and `go build` failed
  with confusing `undefined: LoadState` errors. New behaviour: when a
  patch is already applied, leave it as-is (no restore + reapply
  cycle); when neither forward nor reverse apply works, fail fast with
  a clear "patch is stale — update the Dune Server Tool" diagnostic
  instead of mangling the tree.

### Changed
- **Install button is fully idempotent — reinstall as many times as you
  want.** If a previous pricing-patch rebuild is still running when you
  click Install again, the new wrapper now walks `Win32_Process` for any
  child PIDs (go.exe, link.exe, git.exe), kills them, then kills the
  prior wrapper PID, and starts a fresh background build that overwrites
  the status JSON immediately. Repeated clicks no longer orphan
  background work or leave the UI stuck on a stale "running" chip.

### Removed
- **HEAD-clone fallback experiment removed.** Briefly considered shipping
  a "if the v0.14.x tarball build fails with marketbot symbol errors,
  fall back to cloning dune-admin HEAD and patching that" safety net.
  Investigation showed the tarball wasn't actually incomplete — the bug
  was our stale patch + the corrupting `git restore` path described
  above. With both of those fixed, the HEAD fallback would never trigger
  in practice, and HEAD requires Go 1.26.3 and a pnpm/Vite frontend
  build that v0.14.2 does not need, so the added complexity earned its
  way out.


## [6.1.25] - 2026-05-29

Patch: **Fix install hang when pricing-patch is enabled.**

### Fixed
- **dune-admin install button no longer freezes the entire server.** When
  `AutoApplyPricingPatch=true`, the v6.1.22-v6.1.24 install route ran
  `build-patched.ps1` synchronously with `Process.WaitForExit(15 min)` on
  the HTTP listener thread. PowerShell's HttpListener handles one request
  at a time, so every other API call (`/healthz`, `/api/ports`,
  `/api/dune-admin/check`, etc.) would stall for the entire Go build —
  the UI's polling loops would all time out, the Install button would
  appear stuck on "Installing...", and impatient re-clicks compounded
  the jam by queueing more requests behind the build. After ~3-15 minutes
  the build finished, but by then DuneServer.exe was holding 1000+ open
  handles from the queued+abandoned requests and often had to be killed
  manually.

### Changed
- **Pricing-patch rebuild now runs fully detached.** The install route
  returns 200 as soon as the binary swap completes, with
  `pricingPatch: { status: 'running', logFile, statusFile, pid }`. The
  background `pwsh.exe` process writes its terminal state to a JSON
  status file at
  `%LOCALAPPDATA%\DuneServer\dune-admin-pricing\rebuild-status.json`.
- **New `GET /api/dune-admin/pricing-patch-status` endpoint** returns
  `{ status, startedAt, finishedAt, exitCode, error, logFile, logTail }`.
  Falls back to `'failed'` if the wrapper PID is dead but no terminal
  status was written (catches mid-build crashes).
- **Settings page polls the status endpoint every 2s** while
  `status === 'running'`, shows a separate "Rebuilding patched dune-admin"
  chip with elapsed time + the last 40 lines of build log. The Install
  button reactivates immediately after the binary swap — operators can
  navigate away or trigger other actions while the rebuild completes.
- On Settings mount, the page also picks up any rebuild that was already
  in-flight from a previous tab/session, so refreshing the page doesn't
  hide a still-running build.


## [6.1.24] - 2026-05-29

Patch: **One-button dune-admin first-run setup wizard.**

### Added
- **New "Install + run setup wizard" button in Settings → dune-admin update card.**
  Aimed at users who've never set up dune-admin before. Click once, and the
  Dune Server Tool will:
  1. Download + extract the latest `dune-admin_windows_amd64.zip` into the
     `DuneAdminExe` parent folder (if the binary isn't already there).
  2. Open a **visible cmd.exe console window** running
     `dune-admin.exe -setup` — the interactive wizard that walks through
     control-plane choice (amp / kubectl / docker / local), SSH host / user
     / key, DB credentials, broker addresses, and backup directory.
  3. When the wizard exits successfully AND
     `%USERPROFILE%\.dune-admin\config.yaml` was written, auto-launch
     `dune-admin.exe` in a separate window so the server starts listening
     on `http://localhost:8080` immediately.
  4. Leave the setup window open ("Press any key to close") so wizard
     errors stay visible.

  The button is shown whenever the binary is missing OR `config.yaml`
  doesn't exist — once both are in place it disappears and the regular
  Reinstall / Update flow takes over. We deliberately do NOT pre-fill the
  wizard: every user's deployment is different (their VM IP, SSH key path,
  BG namespace, DB password, broker addresses are unique to their setup).

  New API route: `POST /api/dune-admin/setup`. The existing
  `GET /api/dune-admin/check` response now also returns `configYamlPath`
  and `configYamlExists` so the frontend can hide the button after a
  successful first-run setup.


## [6.1.23] - 2026-05-29

Patch: **Fix silent startup crash on Restricted-policy / MOTW-tagged machines, plus preflight checker.**

### Fixed
- **Launcher silently died on Windows machines with `ExecutionPolicy=Restricted`
  OR with Mark-of-the-Web on the installer's unpacked files** (window opened,
  UAC fired, window closed, no log, no popup, no portal). Two root causes
  fixed in tandem:

  1. The compiled `DuneServer.exe` dot-sources its bundled (unsigned) `.ps1`
     modules at startup. Under `Restricted`, every dot-source is blocked;
     the first `. DuneLog.ps1` threw before `Initialize-DuneLog` could even
     open the log file, so users had nothing to send us. **Fix:**
     `app/DuneServer.ps1` now sets process-scope `ExecutionPolicy=Bypass`
     as the very first action (no admin needed, no machine state change —
     only affects this one process).

  2. Even with `CurrentUser=RemoteSigned` (the standard dev-machine policy)
     the launcher *still* failed if `DuneServerSetup.exe` was downloaded
     from the internet, because Windows propagates **Mark-of-the-Web** to
     every file unpacked from a downloaded installer. RemoteSigned treats
     MOTW-tagged files as "remote" → blocks them. **Fix:** the installer
     now runs `Get-ChildItem -Recurse '{app}' | Unblock-File` as a [Run]
     step before launching the app, stripping the Zone.Identifier from
     every shipped file.

- **Silent crashes are now impossible.** Added an emergency startup logger
  at `%LOCALAPPDATA%\DuneServer\dune-startup.log` that is opened BEFORE
  the main logger and a global `trap` that catches any uncaught bootstrap
  exception, writes the full stack to the emergency log, AND shows a
  WinForms `MessageBox` so the user always sees what failed.
- **Re-saved 4 `.ps1` files with UTF-8 BOM** per the v6.1.16 permanent
  rule: `app/DuneServer.ps1`, `dune-server.ps1`,
  `app/server/routes/DuneAdmin.ps1`,
  `app/resources/dune-admin-patches/build-patched.ps1`. Two of them
  (`dune-server.ps1` and `build-patched.ps1`) had parse errors under
  Windows PowerShell 5.1 because of em-dashes mis-decoded as Windows-1252.

### Added
- **`tools/preflight/` — drop-in checker users can run when something is
  wrong.** `DunePreflight.bat` (launcher) + `DunePreflight.ps1` (WinForms
  results window) + `README.md`. Verifies elevation, OS build floor,
  Hyper-V features + cmdlets, `pwsh.exe` / `ssh.exe` / `tar.exe` / `git.exe`
  / `go.exe` on PATH, **`Get-ExecutionPolicy` per scope (detects the
  pre-v6.1.23 silent-crash conditions)**, Defender exclusions,
  **Mark-of-the-Web on every bundled .ps1 file** (not just the EXE),
  AppLocker enforcement, install-dir completeness, port 47823 bind test,
  default-browser registration, and writability of the state dir. Each
  PASS / WARN / FAIL row is colour-coded with a per-row Fix command.
  Bundled with the installer as `{app}\tools\preflight\` and gets its own
  Start Menu shortcut "Dune Preflight (run as admin)". Saves a redacted
  report to `Desktop\dune-preflight.txt` and copies it to the clipboard
  for sharing with the maintainer. **PII (username, hostname, IPs,
  user-profile paths, battlegroup IDs) is scrubbed from the saved /
  clipboard report** but kept in the live GUI rows so the user can act
  on it locally.


## [6.1.22] - 2026-05-28

Patch: **Fold sane-pricing into the dune-admin updater (with opt-in checkbox).**

### Added
- **Auto-apply Coastal's sane-pricing patch on every dune-admin update.**
  New checkbox in Settings → dune-admin update card:
  *"Keep Coastal's sane-pricing patch applied after each update."* When
  checked, every dune-admin Install/Update also pulls the matching
  source tarball, overlays it onto the user's dune-admin source dir,
  then rebuilds `dune-admin.exe` locally with the 100k-cap pricing patch.
  Uncheck and click Install again to revert to the pristine upstream
  binary. Persists as `AutoApplyPricingPatch=true|false` in
  `dune-server.config`.
- **dune-admin updater now syncs source.** Every Install action now
  downloads two assets from the GitHub release: the Windows binary zip
  (as before) AND the `*_source.tar.gz` tarball. The tarball is
  extracted with `tar.exe` and overlaid onto the source repo via
  `robocopy`, with `.git/`, the running `dune-admin.exe`, sidecar
  versions, and any "market bot cache/" directory excluded. This keeps
  the user's source in lockstep with the running binary version, so the
  patch always rebuilds against the source it was generated against.
- **Reinstall anytime.** The Install button in Settings is no longer
  gated on `available=true` from the release check. The user can
  reinstall the current version at will (button reads "Reinstall vX.Y.Z"
  when already on latest). This is what lets the "uncheck and reupdate
  to revert" flow work without waiting for a new release.
- **Regenerated `0001-sane-pricing-100k-cap.patch` for dune-admin
  v0.13.0.** Phase 0 refactor (Icehunter/dune-admin#52) changed the
  context lines around the patched regions, so the old patch refused
  to apply on fresh upstream. The new patch is functionally identical
  (same numerical targets, same 100k hard cap, same tier-driven model)
  and was verified by `go vet` + `go test ./internal/marketbot/...`
  against current upstream.

### Removed
- **Manual sane-pricing card on the Database page** (`SanePricingCard.tsx`,
  `duneAdminPricing.ts`, `DuneAdminPricingPatch.ps1` routes). Replaced
  entirely by the auto-apply checkbox above — one source of truth, one
  knob, no separate apply/restore dance.

### Fixed
- **Build deadlock + handle-leak in build-patched.ps1.** The previous
  apply path redirected the child build script's stdout/stderr through
  .NET pipes, but the script ends by launching the rebuilt dune-admin
  (a long-lived server) which inherited those handles and held them
  open forever. The auto-rebuild path in the updater now uses
  file-based logging (no .NET pipe redirection) plus a 15-minute hard
  timeout. `build-patched.ps1` itself was also switched from
  `cmd /c start "" "$exe"` to `Start-Process $exe` for the final
  relaunch, so no inherited handles ever leak.


## [6.1.21] - 2026-05-28

Patch: **Hide the Broadcasts feature from the UI.**

### Removed
- **Broadcasts** nav item and `/broadcasts` route removed from the
  sidebar / app. The page is no longer reachable from the portal.
  Backend routes (`/api/broadcasts/generic`, `/api/broadcasts/shutdown`)
  and the `Broadcast.ps1` helper remain in the installed app as dormant
  code in case the feature is brought back later.


## [6.1.20] - 2026-05-28

Feature: **Apply Coastal's sane-pricing patch to dune-admin from the Database page.**

### Added
- **Database → "dune-admin Sane-Pricing Patch (Coastal)" card.** One-click
  installs Coastal's tier-driven market-bot pricing model (with hard 100k
  cap per listing) into the user's local dune-admin v0.13.0+ source repo.
  Bundles `0001-sane-pricing-100k-cap.patch` + `build-patched.ps1` with
  the installer; the card stages them into the user's
  `<dune-admin>\scripts\patches\` and `\scripts\` then runs
  `build-patched.ps1 -Restart` to rebuild dune-admin.exe in place and
  relaunch it. Restore button swaps `dune-admin.exe.upstream` back over
  the patched binary.
- **Preconditions checklist** displayed inline beside the buttons so the
  user can see exactly what needs to be in place before applying:
  - DuneAdminExe set in Settings + file exists
  - dune-admin v0.13.0+ source repo detected at the parent dir of DuneAdminExe
  - `git` and `go` available on PATH (with `winget install` commands shown
    for one-click PowerShell copy)
  - Bundled patch file present in the install
  - dune-admin reachable on `localhost:8080` with `market-bot` mode `embedded`
  Each unmet row shows a tailored "Fix:" line and (where applicable) a
  copyable PowerShell command. The dune-admin-not-running command is
  parameterized with the user's actual DuneAdminExe path and also
  stops `AMP-ADS01` first when that's the cause of the :8080 conflict.
- **Help (?) button** in the top-left of the portal sidebar, next to the
  title. Opens a prefilled GitHub bug-report template (tool version
  auto-filled). Restores discoverability of the issue tracker the CLI's
  `report-issue` command already targeted.
- New API routes: `GET /api/dune-admin/pricing-patch/status`,
  `POST /api/dune-admin/pricing-patch/apply`,
  `POST /api/dune-admin/pricing-patch/restore`.

### Changed
- Sidebar title renamed **Dune Server** → **Dune Server Tool** (also in
  the PWA-install tooltip + the Chrome/Edge install instruction).
- `.github/ISSUE_TEMPLATE/bug_report.yml` surfaces refreshed for the v6.1
  web portal layout: added Database (Sane-Pricing Patch card), Bot Control
  / Market, Broadcasts, Settings (dune-admin updater / self-updater),
  PWA install / desktop-app shell, and Sidebar / help button entries.
  Removed legacy "Desktop app — *" prefixes.

### Notes
- Apply succeeds only when every precondition is met (HTTP 412 otherwise).
- A sidecar marker `dune-admin.exe.coastal-sane-pricing` is written next to
  the patched exe so the card can detect that the patch is already applied
  across restarts of Dune Server Tool.

## [6.1.19] - 2026-05-28

Patch: **Fix Settings page silently dropping all configuration changes.**

### Fixed
- **Settings page edits were silently discarded.** Saving any field
  (e.g. `DuneAdminExe`, `SteamPath`, `SshKey`, port-check mode) appeared
  to succeed but the value reverted on the next load. Root cause: the
  `PUT /api/config` handler treated the request body as a flat
  hashtable when it was actually `{ values: { ... } }`, so the inner
  values dict was passed straight to `Save-DuneConfig` whose key
  whitelist then filtered out the lone `values` key — no fields ever
  reached the persisted file. Handler now unwraps the `values` wrapper
  first, then merges into the on-disk `dune-server.config`.

## [6.1.18] - 2026-05-27

Patch: **dune-admin updater in Settings** + **Broadcasts shutdown fix**.

### Added
- **dune-admin.exe updater** in Settings. A new collapsible card under
  the Dune Server self-updater shows the installed version vs. the
  latest [`Icehunter/dune-admin`](https://github.com/Icehunter/dune-admin)
  release and one-click installs the `dune-admin_windows_amd64.zip`
  asset over the configured `DuneAdminExe` path. Writes a
  `<exe>.version` sidecar file so the installed version persists across
  checks (Go binaries built with goreleaser have no Win32
  FileVersionInfo). New routes: `GET /api/dune-admin/check`,
  `POST /api/dune-admin/install`. Refuses to overwrite a running EXE
  (returns 423 Locked).

### Changed
- Settings page restructured: **Updates** card and **dune-admin.exe**
  card now live at the top of the page, both minimized by default with
  compact status pills shown in the collapsed header. Both auto-check
  on mount so the pills are populated without expanding.

### Fixed
- Broadcasts → Server Alert: shutdown timestamp is now computed
  host-side (`[DateTimeOffset]::UtcNow.AddMinutes(...)`) instead of
  via `ssh ... date -d '+N minutes' +%s`. The SSH round-trip
  occasionally returned an empty string (single-quote handling through
  PowerShell → ssh → remote bash), which surfaced as
  *"Could not compute shutdown timestamp on the VM."* Both clocks are
  NTP-synced so there's no meaningful drift.

### Notes
- README brought current: added Broadcasts, DD Map, dune-admin updater,
  and PWA install sections; removed stale tray-icon references that
  v6.1.7 had already retired.
- Scrubbed real VM/public IPs out of `tools/Redact-Screenshots.ps1`
  comments.


## [6.1.17] - 2026-05-27

Minor: **Broadcasts feature** + **Install as App** (PWA) + **DD Map**.

### Added
- **Broadcasts page** under the Terminal nav group. Two cards (Message,
  Server Alert) let the operator push in-game notifications and
  shutdown/restart countdowns to every connected player.
  - *Message*: Header, Message, on-screen duration → Send. Pop-up appears
    instantly on every client.
  - *Server Alert*: Type (Restart / Shutdown / Maintenance / Update) and
    delay in minutes → Broadcast (confirm dialog) or Cancel an in-flight
    countdown.
- Backend: `app/server/lib/Broadcast.ps1` publishes through the same
  RabbitMQ path Funcom's `send-dune-broadcast` uses (kubectl exec →
  `rabbitmqctl eval` of an Erlang `basic.publish` to the `heartbeats`
  exchange, routing key `notifications`). Auto-detects the `mq-game-sts-0`
  pod (cached 120 s). Routes: `POST /api/broadcasts/generic`,
  `POST /api/broadcasts/shutdown`.
- **Install as App** button at the bottom of the sidebar. The portal now
  ships a web app manifest (`/manifest.webmanifest`) and a no-op service
  worker (`/sw.js`) so Chrome and Edge will install it as a standalone
  windowed app (no tabs, no address bar) when the button is clicked.
  Falls back to an in-app instructions modal if the browser hasn't
  surfaced an install prompt yet.
- **DD Map page** under Game Data. Two reference cards (Method.gg and
  Dune Gaming Tools) link out to interactive Deep Desert map companions
  in a new tab. Both sites block iframe embedding, so the portal surfaces
  the links in a consistent card layout instead.

### Changed
- Static file server now serves `.webmanifest` with
  `application/manifest+json` so browsers recognize the PWA manifest.

### Removed
- Deep Desert / Arrakeen / Harko Village on-demand map-pod startup cards
  from Server Health. The dashboard now focuses on battlegroup, port,
  and component health.


## [6.1.16] - 2026-05-27

Patch: **Critical startup fix — restore the server's ability to launch.**

After installing v6.1.13/14/15, clicking the desktop icon silently failed:
log header was written but the server never reached the "starting" banner
and the portal never came up. Root cause: `app/server/lib/PlayerGuard.ps1`
(new in v6.1.13) contains an em-dash (—) and was saved as UTF-8 *without*
BOM. The ps2exe-compiled `DuneServer.exe` hosts Windows PowerShell 5.1,
whose default file-encoding is Windows-1252 — it mis-decoded the em-dash
as `â€"` and the parser died. Standalone `pwsh` 7 defaults to UTF-8, so
this never surfaced during dev / interactive testing.

### Fixed
- Re-saved 7 `.ps1` files with UTF-8 BOM so the ps2exe-hosted runtime
  parses them correctly: `PlayerGuard.ps1`, `Commands.ps1` (route),
  `Shutdown.ps1` (route), `Update.ps1` (route), `app/DuneServer.ps1`,
  `app/build/Build-Exe.ps1`, `dune-server.ps1`. The em-dash in
  `PlayerGuard.ps1`'s "players online" message was the actual crasher;
  the rest had non-ASCII in comments / string literals that hadn't yet
  triggered a parse error but would have eventually.

### Notes
- Permanent rule: any `.ps1` that will be dot-sourced by the
  ps2exe-compiled `DuneServer.exe` **must** be saved with a UTF-8 BOM if
  it contains any non-ASCII byte. Pure-ASCII files are fine without BOM.
- v6.1.15's interactive auto-update path is preserved.


## [6.1.15] - 2026-05-27

Patch: **Auto-update goes interactive.**

Background: v6.1.13 and v6.1.14's auto-updaters both used `/VERYSILENT`
flags on the installer, relying on Inno Setup's silent-mode `[Run]`
behaviour to relaunch `DuneServer.exe`. That relaunch turned out to be
unreliable in practice (even with `Check: WizardSilent` and a fallback
WMI relauncher), so the portal kept going dark after updates. Per the host's
direction, the updater now drops silent mode entirely and runs the
installer as a normal interactive wizard.

Changed
- `/api/update/install` no longer passes `/VERYSILENT` or
  `/SUPPRESSMSGBOXES` to the installer. Only `/SP-` (skip "are you sure?"
  prompt) and `/NORESTART` remain.
- The detached relauncher script now explicitly `Stop-Process`es the
  running `DuneServer.exe` by PID *before* launching the installer, so
  the installer doesn't have to do its own `taskkill /T` (which was
  killing the relauncher itself in earlier builds).
- The installer wizard handles the relaunch naturally via its standard
  "Launch Dune Server" checkbox on the Finished page - no silent-mode
  edge cases to worry about.

Notes
- The user experience is now: click "Update now" → portal disconnects →
  installer wizard pops up → click Next/Install/Finish → the new
  `DuneServer.exe` starts from the Finished-page checkbox.
- The silent-mode `[Run]` entry added in v6.1.14 is kept for safety
  (anyone running the installer manually with `/VERYSILENT` still gets a
  relaunch), but it is no longer on the auto-update path.


## [6.1.14] - 2026-05-27

Patch: **Auto-update relaunch fix.**

Background: v6.1.13's auto-updater shipped a regression — the UI hung on
"Installing…" and the portal went dead (`ERR_CONNECTION_REFUSED`) after the
upgrade completed. Two bugs were responsible:

1. `app/installer/DuneServer.iss` had `skipifsilent` on its `[Run]` entry,
   so silent installs (which is what the in-app updater uses) skipped the
   "launch DuneServer.exe" step entirely. The installer killed the running
   server, copied new files, and exited without ever relaunching it.
2. `app/server/routes/Update.ps1` wrote its JSON success response *after*
   launching the installer, racing the installer's own
   `taskkill /F /IM DuneServer.exe /T` step. The kill won → response never
   flushed → browser fetch hung.

Fixed
- Installer `[Run]` now has a second silent-mode entry (`Check:
  WizardSilent`) so the new EXE relaunches whether the install was
  interactive or silent.
- `/api/update/install` writes the success JSON *before* spawning anything,
  so the browser confirmation arrives before the kill.
- `/api/update/install` now stages a relauncher PowerShell script in
  `%TEMP%\DuneServerUpdate` and starts it via
  `Win32_Process.Create` (WMI). That detaches the relauncher from
  DuneServer.exe's process tree, so `taskkill /T` can't reach it. The
  relauncher waits for the installer to finish, then starts
  `DuneServer.exe` from `Program Files\Dune Server\` only if it isn't
  already running.
- Relauncher writes a transcript to
  `%TEMP%\DuneServerUpdate\relaunch-<tag>.log` for post-mortem if a future
  upgrade misbehaves.

Notes
- If you are stuck on v6.1.13 with the portal dead, manually launch
  **Dune Server** from the Start Menu (or run
  `"C:\Program Files\Dune Server\DuneServer.exe"`). v6.1.13's installer
  shipped the broken `[Run]` flag, so the v6.1.13 → v6.1.14 upgrade may
  hang the same way; if it does, relaunch manually one more time. From
  v6.1.14 onward, auto-update will relaunch correctly without manual
  intervention.


## [6.1.13] - 2026-05-27

Patch: **Players-online guard on mutating endpoints.**

Background: On 2026-05-27 a player lost their entire crafting recipe library
(482 → 29 entries) after a save was applied while their character was in the
middle of logging in. Root cause was a Funcom game-side partial-load race
(actor loaded with empty `m_PersistentName`, then auto-saved that empty state
back over the real character). The tool didn't initiate it, but writing to
`actors.properties` while a player is connected can race the same way. This
release adds a server-side guard so the tool refuses to write while anyone
is online unless the operator confirms.

Added
- New server helper `Get-V6OnlinePlayers` queries
  `encrypted_player_state.online_status` (any value other than `Offline`,
  including `LoggingOut`) and returns the connected player names via
  `decrypt_user_data()`.
- New shared route helper `Test-DunePlayerGuard` in `app/server/lib/PlayerGuard.ps1`.
  Returns HTTP **409** with `{ conflict: 'players_online', playersOnline,
  playerNames, players, message }` when any player is connected. Bypass with
  `?force=1|true|yes` once the operator confirms.
- All 11 mutating `/api/characters/*` endpoints and the 2 mutating
  `/api/gameconfig*` endpoints (game settings PUT, spicefield row PUT) call
  the guard before touching the DB.
- Client-side `withOnlinePlayerGuard()` wrapper in `webui/src/api/client.ts`.
  On 409 it shows a `window.confirm` listing the online player names, and on
  confirmation retries the same call with `?force=true`. Every save in the
  Characters tabs (Stats, Tech, Specs, Economy, Cosmetics, Inventory) and the
  Game Config page (settings, spicefields) flows through the wrapper
  automatically — tab UI code is unchanged.

Notes
- The guard **fails open** on DB errors: a transient SSH/psql blip won't lock
  editing.
- The existing `/api/maps/{key}/stop` endpoint already had its own 409 +
  `?force=true` flow; this release adopts the same pattern across the rest
  of the mutating surface.
- The Database page SQL editor is intentionally not gated — it already
  defaults to read-only and requires an explicit toggle + `window.confirm`
  for arbitrary SQL.


## [6.1.12] - 2026-05-27

Patch: **Buttons no longer word-wrap.**

Fixed
- Added `whitespace-nowrap` to `.btn`, `.btn-primary`, `.btn-secondary`,
  `.btn-ghost`, and `.btn-danger`. Two-word labels like *Reset layout* were
  wrapping onto two lines in narrow header layouts (most visible on the
  Commands page action bar). Affects every button in the app.


## [6.1.11] - 2026-05-27

Patch: **"Terminal" renamed to "PowerShell" everywhere it's user-visible.**

Changed
- **Sidebar nav item** *Terminal* → *PowerShell*. (The group header above it
  was already renamed in v6.1.9; this catches the leaf item too.)
- **Page title** on the embedded shell page is now **PowerShell** instead of
  *Terminal*. Description text was already accurate.

The URL (`/terminal`) and route handlers (`app/server/routes/Terminal.ps1`)
are unchanged — this is a label-only rename.


## [6.1.10] - 2026-05-27

Patch: **Commands page rebuilt around three first-class sections — renamable,
dynamically sized, with a deterministic default layout.**

This release replaces the v6.1.9 "order + section overrides" model, which had
a regression where dragging a command across sections would visually snap back
(sections always reverted to their original sizes once the layout reloaded).

Added
- **Three sections, each user-renamable.** Section headers are click-to-edit
  inline: click the title (or its pencil icon), type a new name, press Enter
  or click away to save. Esc cancels. Max 40 chars; empty input falls back to
  the default name ("VM", "Battlegroup", "Tools").
- **Sections grow and shrink with their contents.** A section's height is
  driven by the number of cards inside it — there is no fixed per-section
  capacity. Moving three commands from "Tools" into "VM" enlarges VM by
  three rows and shrinks Tools by three. Empty sections render a dashed
  drop placeholder so they remain valid drop targets.
- **Deterministic default layout.** On first run (or after *Reset layout*),
  commands are sorted with startup commands first (`start`, `start-vm`,
  `startup`), shutdown commands next (`reboot`, `shutdown`, `stop`), then
  the remainder alphabetically — and distributed left-to-right, top-to-bottom
  across the three sections.

Changed
- **`button-order.json` v3 shape.** Now stores
  `{ version: 3, sectionNames: [a,b,c], sections: [[…],[…],[…]] }`. Sections
  are first-class arrays of command names; there is no longer a separate
  "default section" + "override" layer to disagree with itself. Legacy
  v6.1/v6.1.9 layout files are ignored on read (users get the new default);
  the old layout couldn't have been mapped cleanly to renamable sections
  anyway.
- **API surface.** `GET /api/commands` now returns
  `{ state, sectionNames, sections, commands }` instead of
  `{ state, order, sectionOverrides, commands }`. `PUT /api/commands/order`
  is replaced by `PUT /api/commands/layout`
  (body: `{ sectionNames, sections }`). `POST /api/commands/order/reset` is
  replaced by `POST /api/commands/layout/reset`. The server normalizes
  payloads on save: trims/caps names, drops unknown commands, dedupes
  globally, and parks any catalogue commands missing from the payload into
  section 0 so they remain reachable.

Fixed
- **Cross-section drag no longer snaps back.** With sections-as-arrays there
  is no override layer to disagree with the order layer, so a command's
  section is unambiguous and survives the round trip to the server.


## [6.1.9] - 2026-05-27

Patch: **Commands page restyled as raised buttons + cross-section drag, and
the sidebar "Terminal" section header renamed to "PowerShell".**

Added
- **Commands — cross-section drag.** The drag handle on any command card now
  lets you move that command into a different section (VM ↔ Battlegroup ↔
  Tools), not just reorder within its current section. Cross-section moves
  persist as per-command "section overrides" alongside the existing order
  array. Empty target sections display a dashed "Drop commands here…"
  placeholder so they remain valid drop targets. The active drag now shows
  a floating overlay clone of the card following the cursor, and the
  hovered section gets a subtle accent ring while a drag is in flight.
- **Commands — persisted section overrides** (`button-order.json` now
  written as `{ "order": [...], "sections": {"name":"section"} }`). The
  reader still accepts the legacy bare-array and `{"order":[...]}` shapes
  so existing installs keep working with no migration step. *Reset layout*
  clears both order and section overrides.

Changed
- **Commands — every command card is now a raised "button" instead of a flat
  card.** New look: subtle vertical gradient, thicker bottom border for
  depth, layered drop shadow, lift-on-hover, press-down-on-active. Drag
  handle, keystroke chip, mode pill, description, and warning row all
  preserved; only the surface chrome changed.
- **Sidebar — "Terminal" section header renamed to "PowerShell".** The
  group above *Commands* and *Terminal* in the navigation now reads
  **PowerShell** to better describe what the embedded session actually is.
  Individual nav item labels (*Commands*, *Terminal*) are unchanged.


## [6.1.8] - 2026-05-27

Patch: **Sandworm-enable confirmation gate, dashboard shutdown button removed,
Arrakeen card layout fix, Terminal SSH launch button, and a `jsonb_set`
NULL-wipe safety guard in the currency / cosmetics / tech helpers.**

Added
- **Game Config — confirmation gate on enabling Sandworms.** Switching the
  "Sandworm Enabled" toggle from Off → On now opens a modal that warns
  *"When this is enabled, all sandworm areas should be clear of items you
  want to keep. Irreversible."* and requires the user to type **`i confirm`**
  before the change is staged. Disabling, or selecting On when it's already
  On, does not prompt. The toggle is only applied to the form state after
  confirmation — Cancel / Esc / clicking the backdrop leaves the previous
  value unchanged.
- **Terminal — SSH button.** New primary-styled `SSH` button to the left of
  `Cancel` on the Terminal page, visually separated from the existing
  Cancel / Clear / Reconnect cluster. Clicking it dispatches the same
  `Invoke-DuneCommandExternal` path the Commands page uses for the `ssh`
  entry, spawning a real native console window running
  `ssh dune@<vm-ip>` with the configured key. The button is disabled when
  the VM isn't running, shows a spinner while launching, and writes
  `[ssh] Launched external console (PID N) → dune@<ip>` (or a red error
  line) back into the embedded xterm pane for feedback. The embedded
  PowerShell terminal is an exec model — it cannot host an interactive
  PTY — so spawning an external console is the only way SSH works
  end-to-end without input hangs.

Changed
- **Dashboard — Arrakeen "Spin up" card header no longer wraps.** All three
  map-pod cards (Arrakeen / Hagga Basin / Deep Desert) now use a compact
  `Spin up` button label instead of `Spin up {map name}`, plus
  `whitespace-nowrap` on the start/stop buttons, `shrink-0` on the action
  cluster, and `min-w-0` + `truncate` on the title. This guarantees the
  title-row controls stay inline at any card width rather than wrapping
  the buttons below the title on narrow viewports.

Removed
- **Dashboard "Shut down" button (top-right of the status bar) removed.**
  The button was originally added in v6.0 alongside the system-tray icon,
  pairing with the tray's *Quit* menu so the portal could be exited from
  either surface. Since the tray icon was removed in v6.1.7 and closing
  the (now-visible, minimized) console window is the documented exit
  gesture, the dashboard button is redundant. The server-side
  `POST /api/shutdown` route is unchanged — `Stop-DuneHttpServer` still
  uses it as the graceful-shutdown signal during in-place upgrades and
  programmatic stops.

Fixed
- **Hardened `jsonb_set` calls against the NULL-wipe failure mode.** Three
  helpers in `app/lib/Db-Postgres.ps1` — `Add-V6Cosmetic`,
  `Invoke-V6TechUnlockAll`, and `Invoke-V6TechLockAll` — built the new JSONB
  value from a subexpression that could return SQL `NULL` when the source
  path was missing or empty on the actor (e.g. a brand-new character with no
  `TechKnowledgeData` yet, or a `CustomizationLibraryActorComponent` block
  that was never initialised). `jsonb_set(target, path, NULL)` returns NULL
  for the whole expression, which would wipe the entire `actors.properties`
  column for that row — taking cosmetics, stats, tech, and every other
  component-block with it. Each call now wraps the inner subexpression in
  `COALESCE(..., '[]'::jsonb)` and gates the UPDATE with a
  `jsonb_typeof(...) = 'array'` / `IS NOT NULL` precondition so the
  operation is a no-op rather than a row-wipe when the path is absent. No
  behavioural change on the happy path; this is purely a safety guard.


## [6.1.7] - 2026-05-26

Patch: **Fix per-refresh popup-window flash on the dashboard; remove the
tray icon (workaround no longer needed).**

Fixed
- **Dashboard refresh no longer flashes a popup window.** The compiled
  `DuneServer.exe` was previously built as a windowless (`-noConsole`)
  application, which caused Windows to briefly allocate a fresh console
  window for every child `kubectl` / `ssh` process invoked while the
  dashboard polled for status, port checks, and links. On every refresh
  this looked like a small white box flashing on-screen.
  v6.1.7 rebuilds the EXE as a console-subsystem application and
  minimizes its own console window at startup via the Win32
  `ShowWindow(SW_SHOWMINNOACTIVE)` API. Child processes now inherit
  the (minimized, off-screen) parent console — no per-child window
  allocation, no flash.
- Desktop / Start-Menu / post-install shortcuts now carry the
  `runminimized` flag as belt-and-suspenders so they launch the EXE
  minimized from the first click.
- Source-mode self-elevation relaunch now uses `-WindowStyle Minimized`
  instead of `-WindowStyle Hidden` for consistency.

Removed
- **System tray (NotifyIcon) icon removed.** The tray icon was added in
  v6.1.2 only as a workaround for the windowless EXE not having any
  visible UI surface. With v6.1.7's minimized-console design, the
  taskbar entry for the console IS that surface — click it to bring
  the live log into view, close the window to exit. Having both a
  taskbar entry AND a notification-area entry for the same single
  process was redundant clutter. `app/server/lib/TrayIcon.ps1`
  deleted; `Start-DuneTrayIcon` / `Stop-DuneTrayIcon` calls removed
  from `DuneServer.ps1`; `-TrayState` parameter dropped from
  `Start-DuneHttpServer`; the URL-publish job that only existed to
  feed the tray menu is gone.

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
- **Update checker** wired to GitHub Releases (`coastal-ms/DST-DuneServerTool`).
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
  `coastal-ms/DST-DuneServerTool`, compares against the
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

[Unreleased]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v6.1.2...HEAD
[6.1.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v6.0.1...v6.1.2
[6.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v5.0.2...v6.0.1
[5.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v4.5.2...v5.0.2
[4.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v3.1.2...v4.5.2
[3.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/releases/tag/v3.1.2
