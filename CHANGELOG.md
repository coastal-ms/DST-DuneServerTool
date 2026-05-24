# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.1] - 2026-05-24

Patch release: better feedback during long boot waits, a real fix for the DB-pod readiness check that was silently lying about success, and a new menu option to power on the VM without touching battlegroup.

### Added

- **New menu option `c. start-vm`** (sits directly above `d. startup`). Powers on the
  Hyper-V VM and waits for it to acquire an IP, but does **not** run any battlegroup
  commands. Useful for maintenance, OS updates inside the VM, manual k3s pokes,
  or just bringing the host online without spinning up the game server. Pairs
  with the existing internal `stop-vm` handler. Shifts the menu keys: `startup`
  is now `d`, `shutdown` is `e`, `reboot` is `f`, `rotate-ssh-key` is `g`,
  `change-password` is `h`.

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

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.0.1...HEAD
[3.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v3.0.0
