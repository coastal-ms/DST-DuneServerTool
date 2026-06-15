# Copilot / AI agent instructions — DST (Dune Server Tool)

Authoritative, repo-local guidance for AI agents working on this repository.
**Everything an agent needs lives in this repo — do not rely on machine-local
notes, chat transcripts, or paths outside the checkout.** If a rule is missing
here, add it here in the same change.

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

## Git workflow

- **Never commit directly to `main`.** Branch (`coastal-ms/<short-slug>`),
  commit, push, open a PR, and merge through GitHub. Tag releases from the merge
  commit on `main`.
- Keep changes surgical and scoped to the request.
