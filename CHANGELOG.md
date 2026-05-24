# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.5] - 2026-05-24

### Added

- **Per-phase boot-time tracking** for `c. startup` and `d. graceful-reboot`.
  Each wait (VM start, IP acquisition, SSH, k3s API, DB pods, operator
  pods, webhook endpoints, battlegroup start, map pods, pod termination)
  is now timed and persisted to `.boot-times.json` (last 20 runs per
  phase). Before each wait, the tool prints a `(last: ~Xs, avg ~Ys of N)`
  hint based on prior runs so you know roughly how long to wait.
- **Total elapsed time** is now displayed at the end of `graceful-reboot`
  too (already shown for `startup` since v2.0.0). Both totals are also
  tracked in the history so you see your typical end-to-end boot time.

## [2.0.4] - 2026-05-24

### Changed

- **`c. startup` no longer prompts for confirmation.** The "Type YES to
  continue" gate after selecting startup was redundant; the user already
  chose to start the server by picking the menu option. Cold-start now
  runs immediately. Other destructive commands (`graceful-reboot`,
  `graceful-shutdown`, etc.) keep their confirmations.

## [2.0.3] - 2026-05-24

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

## [2.0.2] - 2026-05-24

### Fixed

- **Script still exited after every interactive menu command (v2.0.1 hotfix
  was incomplete).** The v2.0.1 rename used a case-insensitive
  `-replace`, which also clobbered the five `if ($Cmd) { break }`
  param-guards down to `if ($cmdName) { break }`. Since `$cmdName` is
  set to the selected command name (e.g. `"status"`), those guards
  fired on every iteration and exited the loop. Restored the guards
  to `$Cmd` with a case-sensitive replace. Confirmed via parse +
  `Select-String -CaseSensitive` audit that every remaining
  `$cmdName` is either a parameter, an assignment, or an `-eq`
  comparison against a string literal.

## [2.0.1] - 2026-05-24

### Fixed

- **Script exited after a single menu command**, closing the console window
  on every selection. The dispatch loop's local `$cmd = $entry.Name`
  collided with the script's `$Cmd` parameter (PowerShell variables are
  case-insensitive), so the `if ($Cmd) { break }` at the bottom of the
  loop fired after every interactive command. Renamed the loop-local to
  `$cmdName`. Web UI (`-Cmd` mode) is unaffected and still exits once
  per invocation via the `$cmdHasRun` flag.

## [2.0.0] - 2026-05-24

Consolidation release. Supersedes all prior 1.x releases &mdash; the 1.x
GitHub Releases were rolled into this single 2.0.0 entry. From here on,
patch releases follow as `2.0.1`, `2.0.2`, etc.

### Added

- **Localhost web UI** (`b. web` menu option). [Pode](https://github.com/Badgerati/Pode)-based
  server on `http://127.0.0.1:8765` with a button panel that mirrors the
  console menu. Each click POSTs to `/api/exec/{name}`, which spawns
  `dune-server.ps1 -Cmd <name>` in a new console window so interactive
  prompts (battlegroup picker, password entry, confirmations) keep working.
  Status panel polls every 5 seconds. Confirmation dialog on
  `graceful-reboot` and `graceful-shutdown`. Lives under `web/`
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
- **VM section re-lettered sequentially** so it ends cleanly at
  `g. change-password` before the numbered Battlegroup commands:
  `a` initial-setup, `b` web (new), `c` startup, `d` graceful-reboot,
  `e` graceful-shutdown, `f` rotate-ssh-key, `g` change-password.

### Fixed

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
  counterparts (`c. startup` cold-starts the full stack; `e. graceful-shutdown`
  stops battlegroup and powers off) cover everything they did without
  leaving pods in inconsistent state. The underlying handlers remain so
  existing automation calling them by name still works.

### Internal

- New helpers: `Install-DuneAdminLatest`, `Resolve-FreshSshKey`,
  `Copy-SshKeyToDir`, `New-DuneDesktopShortcut`.
- `web/` folder structure added.

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v2.0.5...HEAD
[2.0.5]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v2.0.4...v2.0.5
[2.0.4]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v2.0.3...v2.0.4
[2.0.3]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v2.0.2...v2.0.3
[2.0.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v2.0.0
