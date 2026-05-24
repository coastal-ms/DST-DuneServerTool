# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.0.2] - 2026-05-24

Patch release: fix two more desktop app crashes/bugs discovered immediately
after the v4.0.1 ship, plus UI polish.

### Fixed

- **App crashed on first stdout line from any in-app command** (clicking
  any `InApp`-mode button — Status, start-vm, open-file-browser, etc. —
  killed the process within milliseconds). Cause: `Process.add_OutputDataReceived(
  {...})`, `add_ErrorDataReceived({...})`, and `add_Exited({...})` callbacks
  fire on .NET ThreadPool threads, which in ps2exe-compiled binaries have
  no PowerShell runspace TLS context. The first invocation of any of those
  scriptblock-as-delegate handlers threw an unhandled
  `System.Management.Automation.PSInvalidOperationException` at
  `ScriptBlock.GetContextFromTLS()` → `InvokeAsDelegateHelper(...)`.
  Rewrote `Invoke-Command-InApp` to use `Register-ObjectEvent` (action runs
  in the PowerShell engine event pump, which has a valid runspace) feeding
  a `System.Collections.Concurrent.ConcurrentQueue[hashtable]`, drained by
  a `DispatcherTimer` running on the UI thread (UI thread is the script's
  main thread, so its TLS is intact — Tick handlers are safe). Output lines,
  error lines, and the exit code are tagged in the queue and rendered in
  order. SourceIdentifiers are unique per invocation and unregistered on
  process exit so subscriptions don't leak.
- **Top status header showed "Loading cluster status..." forever and never
  updated.** Cause: the `DispatcherTimer.Tick` scriptblock inside
  `Refresh-StatusHeader` referenced function-scoped variables
  (`$asyncResult`, `$ps`, `$rs`, `$timer`, `$vmInfo`) but was not wrapped
  in `.GetNewClosure()`. By the time the tick fired (250 ms later, after
  `Refresh-StatusHeader` had returned), those locals were out of scope and
  resolved as `$null`, so `$asyncResult.IsCompleted` was always false and
  the timer polled forever. Wrapping the handler in `.GetNewClosure()` and
  assigning via a captured `$tickHandler` variable preserves the closure.

### Changed

- **Removed redundant "Status" button (Battlegroup key `1`) from the
  desktop app command catalog.** The top header panel already displays
  live battlegroup status with a 30-second auto-refresh and a manual
  Refresh button, so a duplicate button that dumped the same text into
  the output pane was just noise. The underlying `status` CLI command
  still exists in `dune-server.ps1` for the legacy `.bat` / web-portal
  entry points.
- **Status header pane is ~2 inches taller** (`Height` 140 → 332 WPF DIPs)
  so the full multi-pod battlegroup status output fits without scrolling.
- **Window default size bumped** from 780×1180 to 900×1180 to accommodate
  the taller header; `MinHeight` raised 520 → 700.
- **`CmdButton` style overhauled** for better visual feedback:
    - Drop-shadow effect for a raised "card" look.
    - Hover: 2 px amber (`#E0B341`) border + amber glow.
    - Press: 2 px white border on a VS-blue (`#0E639C`) background + blue glow.
    - Slightly more padding (`10,7`) and margin (`4,3`); corner radius 4 px.
- Version string bumped: `4.0.1 → 4.0.2`.

## [4.0.1] - 2026-05-24

Patch release: fix two desktop app (v4.0.0) regressions discovered immediately
after ship.

### Fixed

- **Battlegroup status header never populated** ("not fetching VM info"). The
  background `Start-Job` used to call `Get-VM` spawned a child `powershell.exe`
  that did not reliably inherit the parent's elevation token when the parent
  was a ps2exe-compiled binary, surfacing as `Microsoft.HyperV.PowerShell.VirtualizationException:
  "You do not have the required permission..."` inside the job (the job state
  was Completed, so the UI just showed the static "Loading cluster status..."
  placeholder). Refactored `Refresh-StatusHeader` in `app/DuneServer.ps1` to
  call `Get-VM` synchronously on the (already-elevated) UI thread — it's
  ~200 ms, the dispatcher stays responsive — and only the slow SSH
  `battlegroup status` call runs on a background runspace (in-process,
  inherits the parent's token automatically). Hyper-V module now also
  imported explicitly at app startup since ps2exe auto-discovery is unreliable.
- **`setup-guide`, `open-file-browser`, `open-director`, `web`, and `report-issue`
  crashed/no-opped from the desktop app.** All five used bare
  `Start-Process "https://..."` to open a URL in the default browser. The
  default-browser association lives in the per-user `HKCU\Software\Classes`
  hive, which is not visible to an elevated process running under the SYSTEM
  hive view; the call either silently does nothing or throws `"This command
  cannot be run due to the error: The system cannot find the file specified"`.
  Switched all five to launch via Explorer instead
  (`Start-Process "$env:SystemRoot\explorer.exe" $url`), which is the same
  trick the existing `dune-admin` handler was already using. This is the
  standard Windows workaround for opening per-user shell associations from
  an elevated process.

### Changed

- Version string bumped: `4.0.0 → 4.0.1` (`$script:ToolVersion`, footer
  text, installer `MyAppVersion`, `Build-Exe.ps1 -Version` default).

## [4.0.0] - 2026-05-24

Major release: native Windows desktop app as the new primary entry point.

The `.bat` launcher and web portal still ship (parallel options, no breakage),
but new users are pointed at `DuneServerSetup.exe` for a normal Windows
installer experience.

### Added

- **Desktop app (`app/DuneServer.ps1` → `DuneServer.exe` → `DuneServerSetup.exe`).**
  PowerShell + WPF host that frames every existing CLI command in a
  single window:
    - Sticky **battlegroup status** panel at the top, auto-refreshed every
      30 seconds via direct SSH (same path the web portal uses)
    - Left panel: every command from the CLI menu rendered as a labeled
      button, grouped by section (VM / Battlegroup / Tools); buttons
      grey out when their requirements aren't met (e.g. "VM not running")
    - Right panel: live-streaming output from whichever command was clicked
    - Footer status bar: current operation, exit codes, app version
  - **Two dispatch modes per command** (chosen automatically per command):
    - `InApp` — hidden child `pwsh` process, stdout/stderr captured into
      the output pane (no console window pops up). Used for plain text
      commands like `status`, `start-vm`, `open-file-browser`, etc.
    - `Console` — visible elevated `pwsh` window. Used for any command that
      needs interactive input (`Read-Host`), a TTY (`ssh -t`), or fancy
      console manipulation (spinners, screen clears). Buttons that open
      in a console are labeled `[console]` for transparency.
  - **Admin enforced at every layer:** installer requires admin (Program
    Files writes), `DuneServer.exe` carries an embedded UAC manifest
    (ps2exe `-requireAdmin`), and `dune-server.ps1` keeps its existing
    `#Requires -RunAsAdministrator`. One UAC prompt at app launch; no
    per-button prompts after that.
  - **PowerShell 7 prerequisite check at startup** — if `pwsh.exe` isn't
    installed, the app shows a friendly dialog with the download URL and
    `winget install --id Microsoft.PowerShell` snippet, then exits.

- **Inno Setup installer (`app/installer/DuneServer.iss` → `DuneServerSetup.exe`).**
  Standard Windows installer (~2 MB) with:
    - Install dir: `C:\Program Files\Dune Server\`
    - Start Menu shortcut (always) + optional desktop shortcut
    - Add/Remove Programs entry, clean uninstaller
    - **Legacy config auto-detection:** during install, scans common
      locations (Desktop, OneDrive subfolders) for an existing
      `dune-server.config` and offers to copy it to
      `%APPDATA%\DuneServer\` so the new app picks up your existing
      settings.
    - **User data preserved on uninstall** — the uninstaller removes the
      install dir but never touches `%APPDATA%\DuneServer\`.

- **Build pipeline** under `app/build/` and `app/installer/`:
    - `Build-Exe.ps1` — wraps ps2exe with all the right flags
      (`-noConsole`, `-requireAdmin`, `-STA`)
    - `Build-Installer.ps1` — wraps `ISCC.exe`, auto-detects ISCC
      across Program Files / `%LOCALAPPDATA%`, auto-runs `Build-Exe.ps1`
      first by default
    - `app/assets/Build-Icon.ps1` — regenerates the 6-resolution
      `icon.ico` via System.Drawing (no external tools)

### Changed

- **`dune-server.ps1` writable files moved to `%APPDATA%\DuneServer\`.**
  Needed so the script can run from a read-only install location
  (Program Files via the new installer). Affects:
    - `dune-server.config`
    - `.boot-times.json`
    - `.logs\dune-server-*.log` transcripts
  - Backward-compatible: on first run after upgrade, legacy files next
    to the script auto-migrate to `%APPDATA%\DuneServer\` (legacy copies
    are left in place as a rollback safety net).
  - Version string bumped: `3.1.2 → 4.0.0`.

- **`README.md`** — installer is now the primary recommended install
  path, with the `.bat` and web portal explicitly called out as classic
  / legacy options.

### Notes

- `dune-server.bat` and `web/Start-DuneWeb.ps1` are **unchanged** and
  remain fully supported. Anyone preferring those paths can keep using
  them; nothing about this release breaks the existing workflow.
- The compiled `DuneServer.exe` is unsigned for now — Windows SmartScreen
  will warn on first run ("Unknown publisher"). Click "More info" → "Run
  anyway". Code signing is a separate decision.

## [3.1.2] - 2026-05-24

Internal cleanup release. No user-facing functional changes from v3.0.1.

### Internal

- Code organization tidy-up in `dune-server.ps1` and
  `web/Start-DuneWeb.ps1`. Tool command keys settled at 17/18/19/20
  (`ssh`, `dune-admin`, `setup-guide`, `report-issue`).

## [3.0.1] - 2026-05-24

Patch release: better feedback during long boot waits, a real fix for the DB-pod readiness check that was silently lying about success, and a new menu option to power on the VM without touching battlegroup.

### Added

- **New menu option `c. start-vm`** (sits directly above `d. startup`). Powers on the
  Hyper-V VM and waits for it to acquire an IP, but does **not** run any battlegroup
  commands. Useful for maintenance, OS updates inside the VM, manual k3s pokes,
  or just bringing the host online without spinning up the game server. Pairs
  with the existing internal `stop-vm` handler. Shifts the menu keys: `startup`
  is now `d`, `shutdown` is `e`, `reboot` is `f`, `rotate-ssh-key` is `g`,
  `change-password` is `h`. The web portal mirrors the new key layout and gets
  its own **start-vm** row above **startup**.

### Fixed

- **`shutdown` and `reboot` no longer hang forever on a stuck VM power-off.**
  The old code issued `Stop-VM -Force` synchronously and then polled
  `Get-VM` until state hit `Off` with no timeout and no visible counter,
  so a guest that wouldn't respond to the integration-services shutdown
  signal (e.g. Linux kernel stuck, networking dead) would freeze the
  script silently. The new `Stop-VmWithEscalation` helper issues the
  graceful stop as a background job, renders a live MM:SS counter with
  the current VM state, and automatically escalates to a hard
  `Stop-VM -TurnOff` if the VM is still not `Off` after 90s. Absolute
  ceiling of 240s before giving up with an error (shutdown reports it;
  reboot aborts so it doesn't try to start a VM that didn't fully stop).
- **DB-pod discovery awk script no longer fails with "Unexpected token".**
  The awk one-liner used to print `namespace/podname` with `print $1"/"$2`,
  but PowerShell mangled the embedded `\"` inside the double-quoted ssh
  command string, so awk received broken syntax and matched zero pods
  (silent fallback: "No DB pods detected"). The awk now emits
  `namespace podname` space-separated and the PowerShell side splits on
  whitespace - no embedded double quotes to mangle.
- **All duration displays are now MM:SS.** Every elapsed-time and
  estimate value across `startup`, `reboot`, `shutdown` (the live wait
  counter, the "(last: ~Xs, avg ~Ys of last N)" estimate, the per-phase
  "ready in" lines, and the "complete in" summaries) renders via
  `Format-Duration` as MM:SS instead of raw seconds. So
  `Startup complete in 99s` is now `Startup complete in 01:39`, and
  `(last: ~99s, avg ~156s of last 2)` is now
  `(last: ~01:39, avg ~02:36 of last 2)`.
- **Background helpers are now cleaned up on crash.** When the script
  exits abnormally (unhandled exception, Ctrl+C, window close), any
  `Start-Job` helpers spawned by the new live wait counters are stopped
  and removed via a `PowerShell.Exiting` engine event plus a top-level
  `trap` in the main loop. Previously a mid-wait crash could leave an
  orphaned background pwsh process holding the SSH connection. The
  `dune-server.bat` wrapper also now reports the PowerShell exit code
  before pausing so the user can see what went wrong.
- **`shutdown` now tracks timings and shows estimates** like `startup` and
  `reboot` do. The shutdown handler was never instrumented in the v2.0.5
  boot-time-tracking work, so subsequent shutdowns showed no
  `(last: ~Xs)` hint and no total-time print at the end. Now records
  `pods-terminate`, `vm-stop`, and `total-shutdown` to `.boot-times.json`,
  shows the estimated total up front, prints the actual total at the end,
  and gets the live in-place elapsed counter during the pod-termination wait.
- **DB-pod readiness check no longer waits on the wrong pods.** The previous
  logic ran `kubectl wait --all -n <db-namespace>`, which would happily block
  on completed backup `Jobs` (`...-dump-...`), the file-browser deploy
  (`...-fb-...`), and any other unrelated pod that happened to live in the
  battlegroup namespace. The wait would time out at the full 180s and the
  script still printed a green "DB pods Ready" success line because the
  `kubectl wait` exit code was never checked. The check now targets pods by
  name pattern (`-db-`, `postgres`, `pg-` minus the obvious noise) and
  honors the exit code &mdash; success is reported truthfully, and a
  timeout warns and proceeds instead of pretending nothing happened.

### Changed

- **Live "elapsed" counters on every long boot wait.** During `startup` and
  `reboot`, each "Waiting for..." line now updates in place once per
  second, showing how long the current phase has been running as a
  **MM:SS** playback timer alongside the existing
  `(last: ~Xs, avg ~Ys of last N)` estimate from boot-time history.
  No more wondering whether the script is stuck. Applies to: SSH
  readiness, k3s API, DB pods, operator pods, webhook endpoints, and the
  reboot's pod-termination wait. The non-polling waits
  (`kubectl wait` calls) now run in a background job so the foreground can
  paint the counter.
- **Web portal layout**: each menu item is now a labeled row with a
  dedicated **Go** button on the right, instead of the entire row being a
  single clickable button. Easier to read, easier to click intentionally.
- **Web portal: new always-visible Battlegroup Status panel.** Pinned at the
  top of the page (above the VM / Battlegroup / Tools command sections),
  the panel shows the live output of the battlegroup `status` command
  (option `1` from the console menu) in a monospace block. It auto-polls
  every 30 seconds and has a manual **Refresh** button. The backend caches
  the SSH result for 25 seconds so multiple browser tabs / quick polls
  don't repeatedly hit the VM. When the VM is off, the panel shows the
  reason (e.g. `VM not running (state: Off).`) in amber instead of an
  error. Powered by a new `GET /api/bg-status` endpoint in
  `web/Start-DuneWeb.ps1`.

## [3.0.0] - 2026-05-24

Consolidation release. Supersedes all prior 2.x releases &mdash; the
2.0.0 through 2.0.6 GitHub Releases were rolled into this single 3.0.0
entry. From here on, patch releases follow as `3.0.1`, `3.0.2`, etc.

### Added

- **Localhost web UI** (`b. web` menu option). [Pode](https://github.com/Badgerati/Pode)-based
  server on `http://127.0.0.1:8765` with a button panel that mirrors the
  console menu. Each click POSTs to `/api/exec/{name}`, which spawns
  `dune-server.ps1 -Cmd <name>` in a new console window so interactive
  prompts (battlegroup picker, password entry, confirmations) keep working.
  Status panel polls every 5 seconds. Confirmation dialog on
  `reboot` and `shutdown`. Lives under `web/`
  &mdash; `Start-DuneWeb.ps1` + `public/{index.html,app.js,styles.css}`.
- **`-Cmd <name>` parameter** on `dune-server.ps1` for non-interactive
  dispatch. Skips the menu, looks up the command by name, runs the handler
  once, and exits. Used by the web UI; also handy for shortcuts and scripts.
- **`dune-admin` install offer during setup** (step 3). Prompts to either
  download the latest release from
  [`Icehunter/dune-admin`](https://github.com/Icehunter/dune-admin)
  to a directory you choose (default `%USERPROFILE%\Desktop\dune-admin`),
  use an existing local install, or skip. The chosen `dune-admin.exe`
  path is stored in `dune-server.config`; this repo does not bundle the
  binary.
- **SSH key auto-copy to `dune-admin` folder.** Setup seeds the
  `dune-admin` install dir with the freshest SSH key (compares
  `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` &mdash; where
  `rotate-ssh-key` writes &mdash; against the path stored in
  `dune-server.config` and picks whichever is newer). `f. rotate-ssh-key`
  also refreshes that copy so it stays in sync after a rotation.
- **Optional "Run as Administrator" desktop shortcut.** End-of-setup prompt
  drops a `Dune Server (Admin).lnk` on your desktop targeting
  `dune-server.bat` with the elevated-launch flag set in the `.lnk` binary.
- **Per-phase boot-time tracking** for `c. startup` and `e. reboot`.
  Each wait (VM start, IP acquisition, SSH, k3s API, DB pods, operator
  pods, webhook endpoints, battlegroup start, map pods, pod termination)
  is now timed and persisted to `.boot-times.json` (last 20 runs per
  phase). Before each wait, the tool prints a `(last: ~Xs, avg ~Ys of N)`
  hint based on prior runs so you know roughly how long to wait.
- **Total elapsed time** displayed at the end of both `c. startup`
  and `e. reboot`, with an estimate line based on prior runs.
- **`23. report-issue` menu option.** Opens a prefilled GitHub bug-report
  form in your browser (tool version + OS/PowerShell auto-filled). The
  issue template + `.github/ISSUE_TEMPLATE/config.yml` scope the tracker
  to bugs in this tool's code; VM/network/Hyper-V/Funcom-server
  questions are redirected to Discord via the "blank issue" config.

### Changed

- **Menu rename + reorder.** `graceful-shutdown` is now just `shutdown`
  (menu key `d`, directly under `c. startup`), and `graceful-reboot`
  is now just `reboot` (menu key `e`). Behavior is unchanged &mdash; same
  safety checks, same phases, same boot-time tracking. Headings and
  status messages updated accordingly (e.g. `=== Reboot complete in Xs ===`).
  Web UI mirrors the rename and reorder.

  **Breaking:** anyone driving the tool with `-Cmd graceful-shutdown` or
  `-Cmd graceful-reboot` must update to `-Cmd shutdown` / `-Cmd reboot`.
- **`c. startup` no longer prompts for confirmation.** The "Type YES to
  continue" gate after selecting startup was redundant; the user already
  chose to start the server by picking the menu option. Cold-start now
  runs immediately. Other destructive commands (`reboot`, `shutdown`,
  etc.) keep their confirmations.
- **VM section re-lettered sequentially** so it ends cleanly at
  `g. change-password` before the numbered Battlegroup commands:
  `a` initial-setup, `b` web, `c` startup, `d` shutdown,
  `e` reboot, `f` rotate-ssh-key, `g` change-password.

### Fixed

- **Web UI showed "Error fetching status" and rendered no command buttons.**
  Pode route scriptblocks run in isolated runspaces and can't see
  `$script:`-scoped variables defined at file scope. `Get-VmStatus` was
  calling `Get-VM -Name $null` (always returned NotFound), and the
  command-list routes iterated `$null`, returning `items: null`, which
  blew up the front-end. Refactored to publish shared state via
  `Set-PodeState` at server start and `Get-PodeState` inside the routes
  and helper functions. JSON arrays are also wrapped in `@(...)` so
  single-item lists don't get unrolled to scalars.
- **Interactive menu exited after a single command**, closing the console
  window on every selection. The dispatch loop's local `$cmd = $entry.Name`
  collided with the script's `$Cmd` parameter (PowerShell variables are
  case-insensitive), so the `if ($Cmd) { break }` at the bottom of the
  loop fired after every interactive command. Renamed the loop-local to
  `$cmdName` (using a case-sensitive replace, so the `if ($Cmd) { break }`
  guards survive intact). Web UI (`-Cmd` mode) is unaffected and still
  exits once per invocation via the `$cmdHasRun` flag.
- `-Cmd <name>` mode (used by every web UI button) would infinite-loop
  re-running the same command. Handlers use `continue` to skip the
  remaining loop body, which also skipped the bottom-of-loop `break`.
  Now gated at the top of the loop so exactly one handler runs per
  `-Cmd` invocation.
- `dune-server.bat` no longer pauses with "Press any key to continue"
  on a clean exit. The `pause` now only fires when the PowerShell script
  exits non-zero. Also forwards `%*` so `-Cmd <name>` works via the
  `.bat` too.
- Setup wizard is now wrapped in a top-level try/catch &mdash; failures
  print a readable error + stack trace and pause for Enter, instead of
  the console window vanishing.
- Port-check status in the menu header now refreshes after running any
  battlegroup CLI command (`1. status`, `2. start`, `3. restart`,
  `4. stop`). Previously the cached results were keyed only by public
  IP with no TTL, so the `[OPEN]` / `[CLOSED]` indicators would stick
  at their first observed values for the entire session.

### Removed

- `b. start-vm` and `c. stop-vm` menu entries. The graceful
  counterparts (`c. startup` cold-starts the full stack; `d. shutdown`
  stops battlegroup and powers off) cover everything they did without
  leaving pods in inconsistent state. The underlying handlers remain so
  existing automation calling them by name still works.

### Internal

- New helpers: `Install-DuneAdminLatest`, `Resolve-FreshSshKey`,
  `Copy-SshKeyToDir`, `New-DuneDesktopShortcut`, `Get-BootTimes`,
  `Format-PhaseEstimate`, `Save-PhaseTiming`.
- `web/` folder structure added.
- Boot-time history stored at `<scriptDir>\.boot-times.json` (rolling
  window of last 20 entries per phase).

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.2...HEAD
[4.0.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.1...v4.0.2
[4.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.1.2...v4.0.0
[3.1.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.0.1...v3.1.2
[3.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v3.0.0
