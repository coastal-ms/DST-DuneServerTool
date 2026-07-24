# Copilot / AI agent instructions — DST (Dune Server Tool)

Authoritative, repo-local guidance for AI agents working on this repository.
**Everything an agent needs lives in this repo — do not rely on machine-local
notes, chat transcripts, or paths outside the checkout.** If a rule is missing
here, add it here in the same change.

## What DST is (orientation)

DST (Dune Server Tool) is a **Windows admin application for running a private
*Dune: Awakening* dedicated server**. It is three parts that ship as one
installer: a **PowerShell backend** (`app/server`, compiled to `DuneServer.exe`)
exposing a localhost HTTP API, a **React + TypeScript web UI** (`webui`) served
to a **WebView2 desktop shell** (`app/desktop/DuneShell`), plus a top-level
launcher (`dune-server.ps1`). It manages the game server VM, its Postgres game
DB, game/INI config, and live gameplay admin (players, items, storage, specs,
Landsraad, market bot). The repo `coastal-ms/DST-DuneServerTool` is public and
forkable. Day-to-day work is: reproduce a reported bug, fix it across the
PS backend + webui, build the installer, ship a release.

## Work orchestration — planner / builder default

Apply this workflow in **every session** for any multi-step or multi-file task,
unless the maintainer explicitly chooses another approach:

- **Planner / thinker stays in the coordinating session.** Decompose the goal
  into independent, ordered tasks in the session `todos` table and record
  dependencies in `todo_deps`. Make design decisions, review executor results,
  reconcile conflicts, retry failures, and dispatch later waves only when their
  dependencies are complete. The planner does **not** write the implementation.
- **Builders / executors do the implementation.** Delegate each independent
  chunk to an isolated project session/worktree or a background sub-agent. Run
  independent chunks in parallel; keep dependent chunks blocked until their
  prerequisites finish. Builders must receive complete task context and own
  their assigned scope through implementation and validation.
- **Default models:** planner = GPT-5.6 Sol with long context and high reasoning;
  builder = Claude Sonnet 5. These are defaults, not locks. The maintainer may
  change either role's model at any time.
- **Model-change gate:** whenever either role's model changes, confirm the
  resulting planner model, builder model, and reasoning effort through a
  clickable `ask_user` confirmation before proceeding. Not needed on every
  sync — only when a model actually changes.
- **Trivial exception:** a genuinely straightforward, single-file task with no
  branching work may be completed directly without the split.

## Repository layout

- `app/server/` — PowerShell backend: `lib/` (business logic) + `routes/` (HTTP API).
- `app/DuneServer.ps1` — backend entrypoint; compiled to `DuneServer.exe` via PS2EXE.
- `app/build/Build-Exe.ps1` — builds `app/build/output/DuneServer.exe`.
- `app/installer/` — Inno Setup script (`DuneServer.iss`) + `Build-Installer.ps1`.
- `app/desktop/DuneShell/` — WebView2 desktop shell (.NET).
- `webui/` — React + TypeScript SPA (Vite). Built into `webui/dist/`.
- `dune-server.ps1` — top-level launcher.

## Building & testing — where the test build goes

Build the full installer with:

```powershell
pwsh app/installer/Build-Installer.ps1
```

Output (the artifact to install/test) is always:

```
app/installer/output/DuneServerSetup.exe
```

**Install and test from that path.** Do not scatter test builds into other
folders.

When you are working inside a **git worktree** (the CLI creates per-session
worktrees), the build lands in *that worktree's* `app/installer/output/`. The
maintainer installs/tests from the **primary checkout** instead, so after a
successful build **copy the resulting `DuneServerSetup.exe` into the primary
checkout's `app/installer/output/`** so it is in the expected, stable location.
Your session context exposes the primary checkout as `main_checkout_path`; the
target is `<main_checkout_path>/app/installer/output/DuneServerSetup.exe`. Never
deploy test builds anywhere else.

Fast inner-loop checks (no full build):

```powershell
# PowerShell parse-check a script:
pwsh -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('app/server/lib/Foo.ps1',[ref]$null,[ref]([System.Management.Automation.Language.ParseError[]]@()))"
# Web UI build + typecheck:
cd webui; npm run build
```

A session worktree may not have warm `webui/node_modules` — run `npm ci` in
`webui/` first if the build can't resolve modules.

## Encoding rules (these break the build / runtime if ignored)

- **`.ps1` files that contain any non-ASCII byte MUST be saved UTF-8 *with BOM*.**
  `DuneServer.exe` is compiled with PS2EXE, whose Windows PowerShell 5.1 host
  decodes BOM-less files as Windows-1252 and mojibakes em-dashes / arrows /
  box-drawing — which has broken startup before. `Build-Installer.ps1` has a
  pre-flight that fails the build if a bundled `.ps1` has non-ASCII bytes and no
  BOM. To fix: prepend bytes `EF BB BF`.
- Source files use **LF** line endings (see `.gitattributes`). Use plain
  `git add` (the repo's `core.autocrlf` normalization handles it); never stage
  with `core.autocrlf=false`, which bakes CRLF into the blob and causes
  whole-file diffs/merge conflicts. Note: adding/removing a BOM is a content
  change, not an EOL change, and is preserved through normal `git add`.

## Versioning & releases

- The release version is stamped in **five** files that must always match:
  1. `app/DuneServer.ps1` — `$script:DuneToolVersion`
  2. `app/build/Build-Exe.ps1` — default `$Version`
  3. `app/desktop/DuneShell/DuneShell.csproj` — `<Version>`
  4. `app/installer/DuneServer.iss` — `#define MyAppVersion`
  5. `dune-server.ps1` — `$script:ToolVersion`
  `Build-Installer.ps1` aborts if they disagree (override only with
  `-SkipVersionCheck` for deliberate intermediate builds).
- Roll the `## [Unreleased]` section of `CHANGELOG.md` into a dated
  `## [X.Y.Z] - YYYY-MM-DD` entry as part of the release change.
- **Every GitHub release MUST attach `DuneServerSetup.exe` as its sole asset.**
  Code-only releases break the in-app updater (it gates on an asset being
  present and silently reports "up to date"). After publishing, verify with
  `gh release view vX.Y.Z --json assets`.
- **Every release, refresh the bug-report issue template.** When a release adds
  or changes user-facing features, update
  `.github/ISSUE_TEMPLATE/bug_report.yml` so bug reports and the log-gathering
  guidance cover the new surfaces: add/adjust the **"Where did the bug happen?"**
  dropdown options, the **"Specific page / button"** examples, and any
  per-feature diagnostic section (e.g. Give Item/Kit, Game Config / Landsraad,
  Cheat Scripts). Bump the `tool_version` placeholder to the new version. This
  keeps diagnostics actionable so a hotfix can be triaged fast. If a new feature
  produces logs the diagnostic bundle (`app/server/routes/Diagnostics.ps1`)
  doesn't yet collect, extend the bundler too.

## Git workflow

- **Never commit directly to `main`.** Branch (`coastal-ms/<short-slug>`),
  commit, push, open a PR, and merge through GitHub. Tag releases from the merge
  commit on `main`.
- Keep changes surgical and scoped to the request.
