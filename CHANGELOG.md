# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v1.0.0
