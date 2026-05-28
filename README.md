# Simple Dune Server Management Tool

> By Coastal (Discord `@allcoast`). A Windows management portal for your
> self-hosted **Dune: Awakening** dedicated server — without ever opening a
> raw SSH shell or hand-editing YAML.

[![Lint PowerShell](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/actions/workflows/lint.yml/badge.svg)](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coastal-ms/Simple-Dune-Server-Management-Tool?sort=semver)](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/latest)

**v6.1.x** runs as a single-window Windows app that serves a local web portal
(React + Vite + Tailwind) over `127.0.0.1` and opens your default browser to
a per-launch tokenized URL. No WPF window, no embedded browser engine — just
a tiny PowerShell HTTP server and a static asset bundle. Same battle-tested
SSH + Hyper-V + battlegroup automation under the hood as the legacy CLI.
The launcher window is start-minimized; close it to exit.

![Server Health](docs/img/v6-server-health.png)

See [`CHANGELOG.md`](CHANGELOG.md) for the full release history and
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the change-control workflow.

---

## Quick install

1. Download **`DuneServerSetup.exe`** from the
   [latest GitHub release](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/latest).
2. Double-click. The installer walks you through it (one UAC prompt — Hyper-V
   needs admin). The Start Menu shortcut and the launcher EXE are placed in
   `C:\Program Files\Dune Server\`.
3. Launch from **Start Menu → Dune Server**. The launcher binds a free local
   port (47823+), starts minimized in the taskbar, and pops your default
   browser at `http://127.0.0.1:<port>/?t=<token>`. The first launch opens
   the **Setup Wizard** page, which asks for your server install folder,
   SSH key, and optional dune-admin path. All answers are saved to
   `%APPDATA%\DuneServer\` and preserved across reinstalls.

> The launcher is single-instance — clicking the desktop shortcut again just
> reopens the existing portal in your browser. No duplicate UAC prompt, no
> second window.

> 📱 **Install as App** — once the portal is open, your browser's address-bar
> install button (or `⋮ → Install Dune Server`) turns the portal into a
> standalone PWA window with its own taskbar/Start-menu entry. No reinstall
> needed; uninstall from the browser at any time.

---

## What you need

- **Windows 10/11** with **Hyper-V** enabled (Pro / Enterprise / Education).
- **PowerShell 7** (`pwsh`) — [download](https://github.com/PowerShell/PowerShell/releases). The launcher prompts you with this link if it's missing.
- **A modern default browser** (Chrome, Edge, Firefox). The portal is served
  to your existing browser — there is no embedded WebView2 component to
  install or update.
- **Dune: Awakening Self-Hosted Server** installed via Steam (gives you the
  `battlegroup-management` folder and the Hyper-V VM image).
- **SSH private key** for connecting to your VM — created automatically
  during Funcom's official self-hosted setup; usually in
  `%LOCALAPPDATA%\DuneAwakeningServer\sshKey`.
- **(Optional)** [dune-admin](https://github.com/icehunter/dune-admin) — a
  community admin panel for player/inventory tooling. Launches from the
  Commands page if you provide its path.

---

## The portal — a page tour

The browser window is split into a **left nav rail** (grouped under Server
Health, Terminal, Game Data, System) and a **page surface** on the right.
The persistent **header status bar** at the top shows live VM / battlegroup
/ port status, a **Refresh** button, and a prominent red **Shut down**
button that gracefully stops the local `DuneServer.exe` portal process.

### 🩺 Server Health

![Server Health page](docs/img/v6-server-health.png)

The default landing page. Cards for everything you usually want to glance at:

- **Battlegroup + VM** — combined running / stopped state and uptime.
- **TCP Ports Open** — live verdict for each public TCP port (Game first,
  Game last, RabbitMQ).
- **Battlegroup Info** — typed view of `kubectl get bg` (BG state, DB,
  Gateway, Director, Uptime).
- **Game Servers** — per-pod phase, readiness, player count, age.
- **Active Spice** — per-map / per-size-class active vs primed counts,
  pulled live from `dune.public_spicefields` over psql. Tiered colors
  (Large = amber, Medium = blue, Small = muted) and at-cap highlighting.
- **Public Port Status** — open / closed / skipped badges for Game (UDP)
  and RabbitMQ (TCP), with a primary + fallback port-check provider.
- **Web Interfaces** — one-click launchers for File Browser and
  Battlegroup Director (URLs visible and copyable).
- **Map pod cards** — Deep Desert, Arrakeen, Harko Village with **Spin
  up** / **Shut down** / **Refresh** controls. Shutdown is guarded by a
  player-online check.
- **Log Exports** — pull logs from any pod or the operator with one click.

### ⚡ Commands

![Commands page](docs/img/v6-commands.png)

Quick-action cards grouped by **VM**, **Battlegroup**, and **Tools**. Each
card shows whether the command runs **InApp** (in the embedded terminal)
or **Console** (in a popup window for interactive commands). Click the
keyboard hint to fire the card; cards self-disable with a hint when the
action wouldn't make sense right now (e.g. *start* greyed out with
"Battlegroup already running").

Drag the grip on any card to reorder commands within their section — the
order auto-saves to `%APPDATA%\DuneServer\button-order.json` and persists
across launches. The header has a **Reset layout** button to revert to
the default arrangement.

### 🖥️ PowerShell

![Terminal page](docs/img/v6-terminal.png)

Embedded PowerShell session backed by xterm.js. Runs locally on your
Windows host — use it for `kubectl`, `ssh dune@vm '...'`, and other
one-shot commands. Persistent working directory across commands. Each
WebSocket session owns a dedicated runspace; **Cancel** stops the current
command, **Clear** wipes the buffer, **Reconnect** spins up a fresh
runspace. Note: this is an exec model, not a real PTY — `vim` and `htop`
won't work, but everything else does.

### 📣 Broadcasts

In-game notifications and shutdown countdowns pushed to every connected
player via the battlegroup's `mq-game` RabbitMQ pod. Two cards:

- **Message** — Header + Message + on-screen duration → **Send**. A pop-up
  appears instantly on every client.
- **Server Alert** — Type (Restart / Shutdown / Maintenance / Update) and
  delay in minutes → **Broadcast** (confirm dialog) or **Cancel** an
  in-flight countdown. Mirrors what the official Funcom client shows when
  the live servers are about to come down.

Transport is `ssh dune@<vm-ip>` → `sudo kubectl exec` →
`rabbitmqctl eval`. No extra setup required beyond the SSH key you
already configured for the rest of the portal.

### 👤 Characters

![Characters page](docs/img/v6-characters.png)

Live editor for every character on your server, talking directly to the
Postgres pod over SSH. Pick a character from the rail, then tab through
**Stats**, **Tech**, **Specs**, **Economy**, **Faction**, **Inventory**,
**Cosmetics**. All edits are written back through `psql` with
transactional safety. Specs and Faction Rep pull live from
`dune.specialization_tracks` and `dune.player_faction_reputation` so
you always see the current numbers.

### ⚙️ Game Config

![Game Config page](docs/img/v6-gameconfig.png)

A grouped editor for `UserGame.ini` and `UserEngine.ini`, with every
setting labeled, typed, and showing its underlying key in fine print.
Groups: Combat Rules, World & Weather, Shai-Hulud, Resources & Loot,
Players, Spicefields, Performance, and more. A dedicated **Spicefield
Types** card edits `dune.spicefield_types` directly with at-cap row
highlighting and a live status badge that refreshes every 10s. Save
flushes the files back to the VM and invalidates the Server Health port
cache so any port change is reflected immediately.

### 🗄️ Database

![Database page](docs/img/v6-database.png)

- **Take Backup** / **Restore Backup** for the BG PostgreSQL database
  without remembering pod names. A banner reminds you to stop the BG
  first for a consistent backup.
- **SQL Editor** powered by Monaco. Read-only by default; toggle the
  switch to enable writes. Filterable table list sidebar, configurable
  max-rows cap, **Ctrl+Enter** to run.

### 🕸️ Sietches *(experimental)*

![Sietches page](docs/img/v6-sietches.png)

Experimental page for adding or removing additional Survival_1 shards
(sietches). Each sietch costs ~12 GB of RAM and requires the UDP port
range 7777–7900 to be open on the host. Gated behind an
**I UNDERSTAND** confirmation prompt — patches the battlegroup CRD
directly. Unsupported by Funcom; you're on your own if something breaks.

### 🗺️ DD Map

Pan/zoom map of the Deep Desert grid with per-cell controls and live pod
status. Click a cell to spin it up, shut it down, or refresh — same
guardrails as the Server Health map-pod cards (player-online check on
shutdown). Replaces the per-map startup cards that used to live on
Server Health.

### 🔧 Settings

![Settings page](docs/img/v6-settings.png)

All the things the Setup Wizard asked you, but editable any time:

- Steam install path (where Funcom dropped the dedicated server)
- SSH key path (private key into the dune-awakening VM)
- `dune-admin.exe` path (optional)
- Windows username (used for desktop shortcut creation)
- **Port-check mode** — `builtin` (yougetsignal + canyouseeme fallback),
  `yougetsignal` only, `canyouseeme` only, `custom` (your own URL), or
  `disabled`
- Port-check URL template (when mode is `custom`)

Changes save on-click — no restart needed.

Two collapsible cards live at the top of the page (both minimized by
default, both auto-check on mount):

- **Updates** — current vs. latest Dune Server Tool version pulled from
  the GitHub Releases API. **Check now** to refresh, **Install** to
  download `DuneServerSetup.exe` and silently re-run it.
- **dune-admin.exe** — current vs. latest from
  [Icehunter/dune-admin](https://github.com/Icehunter/dune-admin). **Check
  now** to refresh, **Install** to download the Windows zip, extract it,
  and swap the binary in-place. Refuses to install while dune-admin is
  running (the file lock check returns *423 Locked*). The current version
  is read from a sidecar `<exe>.version` file written by the installer
  (Go binaries built with goreleaser don't embed a Win32 FileVersionInfo).

### 🧙 Setup Wizard

![Setup Wizard](docs/img/v6-setup-wizard.png)

Six-step linear flow that runs automatically on first launch:

1. **Pre-flight** — admin check, Hyper-V module, disk space, OS, config
2. **Configuration** — confirm tool settings
3. **Installing** — import the Hyper-V VM
4. **Security** — SSH + firewall
5. **Networking** — ports + DNS
6. **Finalize** — wrap-up

Re-runnable any time from the nav rail for a clean reset.

---

## Where things live

| Item                           | Path                                                       |
| ------------------------------ | ---------------------------------------------------------- |
| Install dir                    | `C:\Program Files\Dune Server\`                            |
| Config / state                 | `%APPDATA%\DuneServer\`                                    |
| Setup config                   | `%APPDATA%\DuneServer\dune-server.config`                  |
| Commands layout                | `%APPDATA%\DuneServer\button-order.json`                   |
| Server log (taskbar console)   | `%LOCALAPPDATA%\DuneServer\dune-server.log`                |
| Last portal URL                | `%LOCALAPPDATA%\DuneServer\last-url.txt`                   |
| SSH key (created by Funcom)    | `%LOCALAPPDATA%\DuneAwakeningServer\sshKey`                |
| Start Menu shortcut            | *Start → Dune Server → Dune Server*                        |
| Live logs                      | Click the minimized **Dune Server** entry in your taskbar  |

Uninstalling removes the install dir but **never touches
`%APPDATA%\DuneServer\`** — your config is preserved if you ever reinstall.

---

## Auto-update

The portal polls the public GitHub Releases API on a 6-hour cadence (also
cached for 1h server-side). When a newer tag is published with an attached
`DuneServerSetup*.exe`, an amber banner appears above the status bar with
**Update now** / **Later** buttons. **Update now** downloads the asset to
`%TEMP%\DuneServerUpdate\` and launches it silently — the installer kills
the running `DuneServer.exe`, lays down the new files, and the Start Menu
shortcut keeps working. Your config in `%APPDATA%\DuneServer\` is preserved.

You can also check manually from **Settings → Updates → Check now**.

---

## CLI launcher *(`dune-server.bat`)*

The repo also ships a menu-driven PowerShell CLI for scripting one-off
commands without launching the portal (e.g. from a scheduled task). Clone
the repo (or download the source zip), then double-click `dune-server.bat`
or invoke it with `-Cmd <name>`:

```powershell
.\dune-server.bat              # interactive menu
.\dune-server.bat -Cmd version # print installed version
```

The portal and the `.bat` file both call into the same `dune-server.ps1`
business logic — they're not separate codebases.

---

## Reporting issues

Hit a bug, error, or unexpected behavior? **Please open a GitHub issue**
so it can be tracked and fixed:

> 👉 [**Open an issue**](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/issues/new/choose) &nbsp;·&nbsp;
> [Browse existing issues](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/issues)

The bug report form asks for:

- **Tool version** — shown in the portal footer (`v6.1.x · coastal-ms`).
- **Surface** — which portal page (Server Health, Commands, Terminal,
  Characters, Game Config, Database, Sietches, Settings, Setup Wizard)
  or whether it was the CLI / installer / auto-updater.
- **Page / button / command** — the specific thing you clicked or typed.
- **Environment** — OS build, PowerShell version, browser.
- **Diagnostics** — recent lines from the server log
  (`%LOCALAPPDATA%\DuneServer\dune-server.log`).

The **Report Issue** action (CLI: `dune-server -Cmd report-issue`)
pre-fills most of this for you and opens the GitHub form in your browser.
**Sanitize first** — remove IPs, hostnames, usernames, and any key file
contents before submitting.

Discord pings to `@allcoast` are fine for quick questions, but use the
issue tracker for anything that needs a fix — it keeps the history public
so other admins can find the same answer.

---

## Troubleshooting

### "pwsh is not recognized"
PowerShell 7 isn't installed. Download it from
[github.com/PowerShell/PowerShell/releases](https://github.com/PowerShell/PowerShell/releases)
and install. The launcher and the `.bat` CLI both require `pwsh`, not the
built-in Windows PowerShell 5.1.

### Browser didn't open / portal tab is blank
The launcher writes the current URL to
`%LOCALAPPDATA%\DuneServer\last-url.txt` — open it manually if the
browser didn't pop. If the tab opens but shows "Invalid or missing
token", close it, then close & relaunch DuneServer.exe — that error
means you have a stale URL from a previous run.

### "The script requires administrator privileges"
Hyper-V cmdlets need admin. The installer enables this for `DuneServer.exe`;
for the CLI, right-click `dune-server.bat` → **Run as administrator**, or
click Yes on the UAC prompt.

### Server Health: Game Port lookup failed
The portal couldn't read `UserEngine.ini` from the VM. Common causes:

- VM is stopped (the header pill will show "VM stopped").
- SSH key path is wrong (check Settings).
- Battlegroup hasn't been started yet, so the INI doesn't exist.
- Open the Terminal page and run `ssh dune@<vm-ip> 'cat ...UserEngine.ini'`
  to verify SSH manually.

The cache TTL is 10 minutes; saving the Game Config page clears it
immediately.

### Characters page shows "no characters"
Confirm the DB pod is `Running`:
- Server Health → Game Servers card should show all pods Running.
- Or open the Terminal page and run `kubectl get pods -A`.

If the pod is up but the list is empty, no players have ever logged in
yet — the player table only gets rows on first character creation.

### TCP Ports Open shows "unknown" for RabbitMQ
The primary port checker (yougetsignal.com) has a daily per-public-IP
rate limit. v6.1.5+ automatically falls back to canyouseeme.org when this
happens; if both are exhausted, try again tomorrow or switch to a single
provider via **Settings → Port-check mode**.

### dune-admin won't find my SSH key
dune-admin looks for keys in this order:
1. `./sshKey` (same folder as the exe)
2. `~/.ssh/dune`
3. `~/.ssh/id_ed25519`

You may also need to set `HOME`:
```powershell
[System.Environment]::SetEnvironmentVariable("HOME", $env:USERPROFILE, "User")
```

### Port check shows `[CLOSED]` but the game works
Many port-check services don't truly probe UDP — they report "closed"
when they really mean "no UDP response". Confirm with a UDP-aware tool
like `nmap -sU -p 7777 <public-ip>` from another network before assuming
your forwarding is broken.

### I want to start over
Open the **Settings** page and clear the fields you want re-asked, or
delete `%APPDATA%\DuneServer\dune-server.config` to re-run the Setup
Wizard from a clean slate. Your `button-order.json` and logs are kept.

---

## Notes

- The VM name is always `dune-awakening` and the SSH user is always `dune`
  — these match Funcom's official setup and can't be changed.
- The dune-admin web UI is at
  [https://dune-admin.layout.tools/#/players](https://dune-admin.layout.tools/#/players).
- This tool is **not affiliated with Funcom**. "Dune", "Dune: Awakening",
  and related trademarks are property of their respective owners.
