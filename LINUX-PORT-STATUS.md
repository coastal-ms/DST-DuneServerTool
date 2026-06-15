# Linux port — handoff status

> **This is an untested scaffold, not a working Linux port.** It exists so
> someone other than the current Windows maintainer can pick the Linux build
> up without starting from a blank repo. Expect bugs on first run; some
> features will return graceful "not supported on Linux" responses and a few
> will straight up throw.

## Scope of this scaffold

What was asked for: enough Linux scaffolding to hand the project to a Linux
maintainer who wants to keep DST going on Ubuntu / Debian. Specifically:

- A Linux entrypoint that boots the existing PowerShell backend under `pwsh`.
- A POSIX launcher (`bin/dune-server`) and a systemd user unit so the backend
  can be started by hand or at login.
- A `.deb` packaging script (`packaging/linux/build-deb.sh`) that produces a
  single installable artifact for Debian / Ubuntu.

What is explicitly **out of scope** for the scaffold:

- No native shell (no Linux replacement for the WinForms + WebView2
  `DuneShell.exe`). The Linux entrypoint opens the user's default browser via
  `xdg-open`, full stop. A Tauri / WebKitGTK replacement is the obvious next
  step but is not done here.
- No CI matrix entry for Linux. The Windows-only `Build-Installer.ps1` and
  `Build-Exe.ps1` are untouched.
- No actual run on a Linux box. Nothing in this branch has been started.

## How the backend boots on Linux

Entry point: `app/DuneServer-Linux.ps1` (run by `bin/dune-server`).

The big simplification vs. `app/DuneServer.ps1`:

| Windows entry                         | Linux entry                       |
|---------------------------------------|-----------------------------------|
| Self-elevates for Hyper-V             | Skipped                           |
| Minimizes own console via Win32       | Skipped                           |
| Launches `DuneShell.exe` (WebView2)   | Opens browser via `xdg-open`      |
| Reads `%LOCALAPPDATA%\DuneServer\…`   | XDG shim — see "compat shim" below |
| Writes scheduled task for autostart   | systemd user unit                 |

### XDG compatibility shim

The PowerShell backend has dozens of references like
`Join-Path $env:APPDATA 'DuneServer'` and
`Join-Path $env:LOCALAPPDATA 'DuneServer'`. Refactoring every one of them
would touch most of `app/server/lib/` and `app/server/routes/` and risks
breaking the Windows build.

Instead, `DuneServer-Linux.ps1` rewrites the two env vars at startup so the
existing paths still resolve to sensible Linux locations:

```
$env:APPDATA       -> $XDG_CONFIG_HOME or ~/.config       (config, JSON state)
$env:LOCALAPPDATA  -> $XDG_STATE_HOME  or ~/.local/state  (logs, last-url)
```

That makes the on-disk layout end up as:

```
~/.config/DuneServer/dune-server.config
~/.config/DuneServer/item-packages.json
~/.config/DuneServer/gameplay-bot.json
~/.local/state/DuneServer/dune-server.log
~/.local/state/DuneServer/last-url.txt
```

A clean follow-up is to introduce `Get-DuneConfigDir` / `Get-DuneStateDir`
helpers and migrate callers off the env vars.

## What we expect to work

These are the parts that read as cross-platform-safe but **have not been run
on Linux**:

- `app/server/HttpServer.ps1` — `System.Net.HttpListener` works on
  PowerShell 7 / Linux. Bound to `127.0.0.1` only, so no Windows-only URL
  ACL setup is needed.
- Route handlers that do nothing more than read / write JSON files under the
  XDG dirs (item packages, gameplay bot config, broadcasts, links, catalog).
- Anything that shells out to `ssh` / `ssh-keygen` (the lib code calls
  `ssh-keygen` and `ssh` without an `.exe` suffix — Linux has both).
- `app/lib/Db-Postgres.ps1` — uses `psql` via `Invoke-Expression`, no
  Windows-specific path assumptions in the SQL paths themselves.
- The webui (Vite build) — no Windows ties.

## What we expect to fail or degrade

- **Hyper-V routes** (`Status.ps1` → `Get-VM`, `Sietch.ps1` → `Get-VM` /
  `Win32_ComputerSystem`, `Setup.ps1` preflight, etc.): on Linux the `Get-VM`
  cmdlet does not exist, the try/catch catches the missing-command error,
  and the routes return a "VM status unavailable" payload. The dashboard
  will show empty / unknown VM state. The right long-term fix is libvirt
  bindings or treating DST as a pure remote-SSH-only manager on Linux.
- **Autostart route** (`app/server/lib/Autostart.ps1`): the existing code
  already gates on `Test-DuneAutostartAvailable`, which returns `$false`
  whenever the process isn't the compiled `.exe`. On Linux that's always
  the case, so the Help → "Run at startup" toggle is reported as
  unavailable. Use the systemd user unit instead.
- **Backend-console show/hide** (`app/server/routes/Console.ps1`): same
  story — `$script:DuneIsCompiledExe` is never set on Linux, so the route
  reports `available: false`. Fine; there's no console window to manage.
- **In-app updater** (`app/server/routes/Update.ps1`): hard-coded to download
  and run `DuneServerSetup.exe`. On Linux it should be replaced with an
  `apt install --reinstall dune-server` call (or just disabled). Currently
  it will try to run the Inno installer and fail.
- **`app/server/lib/MapSpinUp.ps1`** — there's a comment about ssh.exe arg
  quoting; verify the same code path works when `ssh` is OpenSSH on Linux.
  Looks correct on inspection, but unverified.
- **`app/server/lib/Commands.ps1`** — invokes `pwsh.exe` by name in one
  error path. Replace with `pwsh`.
- **Diagnostics route** — the WebView2 registry probe in
  `app/server/routes/Diagnostics.ps1` reads `HKLM:`/`HKCU:` which will fail
  inside a `try`/`catch`. The diagnostic line will just be blank.

## How to install / run

### From source (quickest)

```bash
sudo apt install powershell openssh-client xdg-utils nodejs npm
cd webui && npm ci && npm run build && cd ..
./bin/dune-server
```

The first run will:

1. Create `~/.config/DuneServer/` and `~/.local/state/DuneServer/`.
2. Bind `http://127.0.0.1:8765/` (next free port if 8765 is taken).
3. Write the per-launch tokened URL to
   `~/.local/state/DuneServer/last-url.txt`.
4. `xdg-open` that URL.

### From a .deb

On a Debian / Ubuntu host (NOT Windows — `dpkg-deb` only):

```bash
./packaging/linux/build-deb.sh
sudo apt install ./packaging/linux/output/dune-server_12.0.24_all.deb
dune-server
```

### Run at login

```bash
mkdir -p ~/.config/systemd/user
cp /opt/dune-server/packaging/linux/systemd/dune-server.service \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dune-server.service
journalctl --user -u dune-server.service -f
```

## What I'd hand to the next maintainer

In rough priority order:

1. **Actually run it.** The scaffold has not been booted once. Expect at
   least one path / module-load surprise.
2. **Decide on the native shell story.** The Linux build is "open in default
   browser" today. Either accept that forever, or scaffold a Tauri shell so
   DST feels like an app on Linux too.
3. **Refactor the XDG shim out.** Replace
   `Join-Path $env:APPDATA 'DuneServer'` with a `Get-DuneConfigDir` helper
   that does the right thing on both OSes, and remove the env-var rewrite
   from `DuneServer-Linux.ps1`.
4. **Decide what to do about Hyper-V.** Either gate the routes behind
   `$IsWindows` and return a clean 501 with a "use a remote SSH-only
   deployment on Linux" message, or write a libvirt equivalent of the
   handful of `Get-VM` calls in `Status.ps1` / `Sietch.ps1`.
5. **Wire `DuneServer-Linux.ps1` into the version-sync check** in
   `app/installer/Build-Installer.ps1`. There are now six files that need to
   agree on the release version; the script only checks five.
6. **CI**: add an Ubuntu runner that at minimum dot-sources every `lib/*.ps1`
   and `routes/*.ps1` under pwsh — the cheapest possible smoke test that
   guards against future Windows-only top-level code creeping in.
