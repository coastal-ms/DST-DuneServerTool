# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.2] - 2026-05-24

### Added
- Setup wizard now copies your SSH private key (and `.pub` if present)
  into the `dune-admin` install folder so `dune-admin.exe` can SSH to the
  VM out of the box without extra configuration. Always pulls the
  freshest key (compares `%LOCALAPPDATA%\DuneAwakeningServer\sshKey`
  &mdash; where `rotate-ssh-key` writes &mdash; against the path stored in
  `dune-server.config` and picks whichever is newer).
- `f. rotate-ssh-key` now also refreshes the copy of the key in the
  `dune-admin` folder so it stays in sync after a rotation.
- Setup wizard ends with an optional "create a desktop shortcut?" prompt.
  Answering yes drops a `Dune Server (Admin).lnk` on the desktop that
  targets `dune-server.bat` with the **Run as Administrator** flag set
  (so SSH-key file permissions and Hyper-V cmdlets work without extra
  prompts).

### Fixed
- Wrapped the setup wizard in a top-level try/catch so failures show a
  readable error + stack trace and pause for `Enter` before exiting,
  instead of vanishing in a closing console window.

### Internal
- New helpers: `Resolve-FreshSshKey`, `Copy-SshKeyToDir`,
  `New-DuneDesktopShortcut`.

## [1.2.1] - 2026-05-24

### Fixed
- `-Cmd <name>` mode (used by every web UI button) would infinite-loop
  re-running the same command. Handlers use `continue` to skip the
  remaining loop body, which also skipped the bottom-of-loop `break`
  intended to exit after one dispatch. Visible symptom: clicking
  `dune-admin` (or any other) button spawned launch attempts repeatedly
  until the process was killed. Now gated at the top of the loop so
  exactly one handler runs per `-Cmd` invocation.

## [1.2.0] - 2026-05-24

### Added
- **Localhost web UI** (`b. web` menu option). Spins up a [Pode](https://github.com/Badgerati/Pode)
  server on `http://127.0.0.1:8765` and opens your default browser to a
  button panel that mirrors the console menu. Each click POSTs to
  `/api/exec/{name}`, which spawns `dune-server.ps1 -Cmd <name>` in a new
  console window so interactive prompts (battlegroup picker, password entry,
  confirmations) keep working. Status panel polls every 5 seconds.
  Confirmation dialog on `graceful-reboot` and `graceful-shutdown`.
  Lives under `web/` &mdash; `Start-DuneWeb.ps1` + `public/{index.html,app.js,styles.css}`.
- **`-Cmd <name>` parameter** on `dune-server.ps1` for non-interactive
  dispatch. Skips the menu, looks up the command by name, runs the handler
  once, and exits. Used by the web UI; also handy for shortcuts and scripts.
- **`dune-admin` install offer during setup** (step 3). Prompts to either
  download the latest release from
  [`Icehunter/dune-admin`](https://github.com/Icehunter/dune-admin)
  to a directory you choose (default `%USERPROFILE%\dune-admin`), use an
  existing local install, or skip. The chosen `dune-admin.exe` path is stored
  in `dune-server.config` exactly as before; this repo does not bundle the
  binary.

### Changed
- VM section re-lettered sequentially so the section ends cleanly at
  `g. change-password` before the numbered Battlegroup commands begin:
  - `a. initial-setup`
  - `b. web` *(new)*
  - `c. startup` *(was `h`)*
  - `d. graceful-reboot` *(was `f`)*
  - `e. graceful-shutdown` *(was `g`)*
  - `f. rotate-ssh-key` *(was `d`)*
  - `g. change-password` *(was `e`)*
- Post-menu hint when the VM isn't running now reads "Press 'c' to run
  'startup'" instead of the removed "Press 'b' to start it".

### Removed
- `b. start-vm` and `c. stop-vm` menu entries. The graceful counterparts
  (`c. startup` cold-starts the full stack; `e. graceful-shutdown` stops
  battlegroup and powers off) cover everything they did without leaving
  pods in inconsistent state. The underlying handlers remain in the script
  so existing automation calling them by name still works.

## [1.1.1] - 2026-05-24

### Fixed
- Port-check status in the menu header now refreshes after running any
  battlegroup CLI command (`1. status`, `2. start`, `3. restart`, `4. stop`).
  Previously the cached results were keyed only by public IP with no TTL, so
  the `[OPEN]` / `[CLOSED]` indicators would stick at their first observed
  values for the entire session even when the server's actual port state
  changed.

## [1.1.0] - 2026-05-24

### Added
- New `h. startup` menu option (and matching handler) that orchestrates a clean
  cold-start of the server with timed gates at each step:
  1. Powers on the Hyper-V VM (skipped if already running) and waits for an IP.
  2. Waits for SSH, the k3s API (`/readyz`), the DB pod(s) Ready,
     `funcom-operators` pods Ready, and the
     `battlegroupoperator-webhook-svc` Service endpoints to be populated
     (the same gate `f. graceful-reboot` uses to avoid the `502 Bad Gateway`
     mutating-webhook race).
  3. Runs `battlegroup start`.
  4. Polls until the `overmap` and `survival` map pods are both
     `Running` with all containers Ready (timeout 300s each).
  Prints elapsed seconds for each phase and a total at the end.
- New `Wait-MapPodReady` helper used by step 4 above. Generic enough to be
  reused by any future "wait for a named pod" feature.

### Changed
- Menu UI is now visually compact (~14 fewer rows): merged the double `===`
  header bar into a single line, removed cosmetic blank lines between sections,
  dropped the redundant `(checking via ...)` preamble and the UDP-not-verifiable
  disclaimer from the port block, replaced the dashed separator before `Tools:`
  with just the section header, and removed the `Database:` / `Logs:` /
  `Monitoring:` sub-section headers (the entries are still numbered the same).
  All functionality, key bindings, and color coding are unchanged.

## [1.0.1] - 2026-05-24

### Fixed
- Menu option `21. dune-admin` is now correctly disabled (greyed out with a reason)
  when the Hyper-V VM does not exist or is not running, matching the behavior of
  every other VM-dependent menu item. Previously it was always shown as available.

## [1.0.0] - 2026-05-24

### Added
- Initial public release.
- Menu-driven launcher (`dune-server.bat` + `dune-server.ps1`) that wraps Funcom's
  `battlegroup.ps1` and adds extra utilities.
- First-time setup wizard (`Run-Setup`) that writes `dune-server.config`.
- VM management commands (a–g): start, stop, restart, hard-reset, status, console,
  graceful-reboot, graceful-shutdown.
- **Graceful reboot** (`f`): stops battlegroup, waits for game/mq/gateway/director
  pods to drain, hard-resets the VM, then restarts battlegroup with a strong
  readiness gate (k3s API `/readyz` + DB pods Ready + operator pods Ready +
  webhook service endpoints populated + settle delay). Fixes the
  `failed calling webhook "mbattlegroup.kb.io": 502 Bad Gateway` race.
- **Graceful shutdown** (`g`): stops battlegroup cleanly, then powers off the VM.
  Intended for nightly shutdowns; player data persists to the DB.
- **Online-player safety check**: graceful-reboot and graceful-shutdown query
  the Postgres `player_state` table over `kubectl exec`, list any online
  players by character name, and require a `YES` confirmation before
  disconnecting them.
- **Port verification** in the menu header: color-coded `[OPEN]` / `[CLOSED]` /
  `[UNKNOWN]` / `[UDP - skipped]` status for required game ports. Three modes
  selectable in setup: built-in (yougetsignal.com, TCP only), custom URL
  template with `{ip}` / `{port}` / `{protocol}` placeholders, or disabled.
- Public IP lookup via `api.ipify.org` with 5s timeout and per-session cache.
- DB namespace auto-discovery (matches pod names containing `-db-`, `postgres`,
  or `-pg-`); silently skips when not present.
- Setup wizard now records `PortCheckMode` and `PortCheckUrlTemplate` in
  `dune-server.config`. Existing installs default to `builtin` silently.

### Changed
- Hardened the post-reboot readiness check to verify webhook Service endpoints
  are populated (not just pods Running) before calling battlegroup start.

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.2.2...HEAD
[1.2.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v1.0.0
