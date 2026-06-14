# Simple Dune Server Management Tool

> By Coastal (Discord `@allcoast`). A Windows management portal for your
> self-hosted **Dune: Awakening** dedicated server — without ever opening a
> raw SSH shell or hand-editing YAML.

[![Lint PowerShell](https://github.com/coastal-ms/DST-DuneServerTool/actions/workflows/lint.yml/badge.svg)](https://github.com/coastal-ms/DST-DuneServerTool/actions/workflows/lint.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coastal-ms/DST-DuneServerTool?sort=semver)](https://github.com/coastal-ms/DST-DuneServerTool/releases/latest)

The current release is **v12.0.17**. The in-app version label and the
website show plain semver tags (e.g. `v12.0.17`) — the previous
Roman-numeral stylization has been removed.

> ## ✅ Confirmed compatible with Dune: Awakening **1.4.5.0**
> DST **v12.0.0** is verified working against the **latest Funcom release** —
> both the game **client** and the **self-hosted server** software — as of the
> **1.4.5.0** patch (June 10, 2026). Compatibility was checked live against a
> running self-hosted server on that build (server image `1988751-0-shipping`),
> covering battlegroup management, on-demand map spin-up, game-config and
> database editing, and backups. No update to DST is required for 1.4.5.0.

It runs as a single-window Windows app (native WebView2 shell) that hosts a
local web portal (React + Vite + Tailwind) on `127.0.0.1` with a per-launch
tokenized URL. Same battle-tested SSH + Hyper-V + battlegroup automation
under the hood as the legacy CLI. Closing the app window stops the server;
the sidebar's **Web Portal** button hands the portal off to your default
browser and keeps the server running in the background.

![Server Health](docs/img/server-health.png)

### New in v12.0.0

- **full Gameplay Admin build-out.** the Gameplay Admin portal lives
  natively inside DST as the **Gameplay Admin** tab — 54 player-management
  endpoints (currency, faction rep, char XP, items, vehicles, teleport,
  progression, contracts, jobs, codex, storage), an RMQ-backed
  `ServerCommand` channel with 11 live online-player handlers, a typed
  TypeScript client for every endpoint, and a bucketed **Actions** panel
  grouping all 28 player actions by intent (Lifecycle / Communication /
  Inventory / Progression / Punishment / Diagnostics).
- **Players tab polish.** A **Hide GM** toggle (Eye / EyeOff,
  localStorage-persisted) filters the GM player out of the list, the
  Online / Faction StatCards, and the Server Overview bucket counts in one
  click. Three new ways to deselect a player and return to Server Overview:
  click the selected row again, press Escape, or hit the new X Close
  button on the player card header. The **Items** actions (Give Item,
  Repair Equipped Gear, Fill Water, Clean Inventory) moved into the
  Inventory section so they sit between the player's name and inventory
  list rather than buried in a separate group.
- **Market + Market Bot.** **Seed market** bulk-lists every catalogued
  template across all 6 quality grades in one shot, with live progress
  bar, abort button, and bulk INSERT chunking that survives huge catalogs
  on the Windows argv limit. A 15s TTL cache on enriched listings kills
  sort lag, **Clear Duke listings** wipes orphan inventory rather than
  just the referenced ones, and a configurable per-template `price_floor`
  (default 50) keeps the bot from listing trivially-priced items.
- **Installer migration.** Upgrading from pre-12.0.0 wipes the legacy
  per-user autostart scheduled tasks (`\Dune Server\DuneServer-Autostart-<sid>`),
  but later v12.0.x → v12.0.y in-app updates preserve your autostart
  preference.

### Carried forward from v11

- **All default settings browser (Game Config).** A collapsible *All
  default settings* card reads the battlegroup's live `DefaultGame.ini` and
  `DefaultEngine.ini` from a running game-server pod and merges them with
  your `UserGame.ini` / `UserEngine.ini` overrides — every section is
  expandable, every key gets a type-aware editor, overrides are badged, and
  changes are saved through the existing managed-block writer (with a
  `.dstbak-<ts>` backup).
- **Risk-acknowledgement modal on Game Config.** A *"Use at your own
  risk"* modal greets first-time visitors to Game Config (and re-prompts
  once after every DST update) so a bad edit isn't a silent footgun.
- **Theming engine.** A Settings → **Appearance** card with six built-in
  presets — Eyes of Ibad, Sietch Tabr, Caladan, Giedi Prime, House Harkonnen,
  and Atreides — plus per-token color customization, JSON import/export, and
  live recoloring of the in-app terminal. Your choice is persisted locally and
  applied before React mounts (no flash of the default theme on launch).
- **PowerShell page is loopback-only.** The free-form terminal is hidden, and
  refused server-side, for any viewer that isn't on the host machine itself.
- **Run at Windows startup.** An opt-in **Help → Run at Windows startup**
  toggle keeps the server alive in the tray across sign-ins.

See [`CHANGELOG.md`](CHANGELOG.md) for the full release history and
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the change-control workflow.

### License & attribution

DST is released under the **Apache License 2.0** (see [`LICENSE`](LICENSE)
and [`NOTICE`](NOTICE)). You're welcome to use it, fork it, modify it, and
redistribute it. If you do redistribute or build on top of it, the license
requires you to preserve the `NOTICE` file and credit **Coastal** (Discord
`@allcoast`, project home <https://github.com/coastal-ms/DST-DuneServerTool>)
as the original author. Republishing this tool as your own work without
attribution violates the license — please don't.

---

## Quick install

1. Download **`DuneServerSetup.exe`** from the
   [latest GitHub release](https://github.com/coastal-ms/DST-DuneServerTool/releases/latest).
2. Double-click. The installer walks you through it (one UAC prompt — Hyper-V
   needs admin). The Start Menu shortcut and the launcher EXE are placed in
   `C:\Program Files\Dune Server\`.
3. Launch from **Start Menu → Dune Server**. The launcher binds a free local
   port (47823+), opens the **Dune Server Tool** native app window
   (WebView2) pointed at `http://127.0.0.1:<port>/?t=<token>`, and runs a
   minimized PowerShell console in the background. The first launch opens
   the **Setup Wizard** page, which asks for your server install folder
   and SSH key. All answers are saved to `%APPDATA%\DuneServer\` and
   preserved across reinstalls.

> The launcher is single-instance — clicking the desktop shortcut again just
> focuses the existing app window. No duplicate UAC prompt, no second window.

> 🌐 **Web Portal button** — the sidebar's **Web Portal** button (footer of
> the left nav, visible only inside the app window) hands the portal off to
> your default browser: it opens the tokenized URL in Chrome/Edge/Firefox,
> closes the app window, and **keeps the server running in the background**.
> Reopen Dune Server Tool any time to bring the app window back — the prior
> background server is stopped and a fresh one is started (one UAC prompt).

---

## What you need

- **Windows 10/11** with **Hyper-V** enabled (Pro / Enterprise / Education).
- **PowerShell 7** (`pwsh`) — [download](https://github.com/PowerShell/PowerShell/releases). The launcher prompts you with this link if it's missing.
- **Microsoft Edge WebView2 Runtime** — ships with Windows 11 and modern
  Windows 10; the installer falls back to your default browser if it's
  missing. The native app window uses WebView2; the **Web Portal** button
  hands off to a standalone browser tab whenever you prefer one.
- **Dune: Awakening Self-Hosted Server** installed via Steam (gives you the
  `battlegroup-management` folder and the Hyper-V VM image).
- **SSH private key** for connecting to your VM — created automatically
  during Funcom's official self-hosted setup; usually in
  `%LOCALAPPDATA%\DuneAwakeningServer\sshKey`.

---

## The portal — a page tour

The window is split into a **left nav rail** (grouped under Server Health,
PowerShell, Game Data, Database, and System) and a **page surface** on the
right. The persistent **header status bar** at the top shows live VM /
battlegroup / port status, a **Refresh** button, and a prominent red **Shut
down** button that gracefully stops the local `DuneServer.exe` portal process.

### 🩺 Server Health

![Server Health page](docs/img/server-health.png)

The default landing page. Cards for everything you usually want to glance at:

- **Battlegroup + VM** — combined running / stopped state and uptime.
- **TCP Ports Open** — live verdict for each public TCP port (Game first,
  Game last, RabbitMQ).
- **Battlegroup Info** — typed view of `kubectl get bg` (BG state, DB,
  Gateway, Director, Uptime). **BG state** reports a green **Healthy** while
  the operator is healthy *or* reconciling (the operator's normal steady
  state), so yellow/red only show for genuine transitions or faults; a
  per-visit **Show raw output** toggle reveals the raw `battlegroup status`
  text on demand.
- **Game Servers** — per-pod phase, readiness, player count, age.
- **Active Spice** — per-map / per-size-class active vs primed counts,
  pulled live from `dune.public_spicefields` over psql. Tiered colors
  (Large = amber, Medium = blue, Small = muted) and at-cap highlighting.
  Each row also has an **Active** checkbox (v6.1.30+) that toggles
  `dune.spicefield_types.is_spawning_active` live — clicking commits
  immediately through a guard-railed endpoint that only ever writes
  `TRUE`/`FALSE` to that single column. One shared 5-second click
  cooldown across all checkboxes prevents accidental DB hammering
  (live `(Ns)` countdown shown next to the disabled row).
- **Public Port Status** — open / closed / skipped badges for Game (UDP)
  and RabbitMQ (TCP), with a primary + fallback port-check provider.
- **Web Interfaces** — one-click launchers for File Browser and
  Battlegroup Director (URLs visible and copyable).
- **Log Exports** — pull logs from any pod or the operator with one click.

Per-map spin-up / shut-down controls for Deep Desert, Arrakeen, and Harko
Village live on the dedicated **Map SpinUp** page (see below).

### ⚡ Commands

![Commands page](docs/img/commands.png)

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

Embedded PowerShell session backed by xterm.js. Runs locally on your
Windows host — use it for `kubectl`, `ssh dune@vm '...'`, and other
one-shot commands. Persistent working directory across commands. Each
WebSocket session owns a dedicated runspace; **Cancel** stops the current
command, **Clear** wipes the buffer, **Reconnect** spins up a fresh
runspace. Note: this is an exec model, not a real PTY — `vim` and `htop`
won't work, but everything else does.

**Loopback-only.** Because this page runs arbitrary commands as the
DuneServer service user on your host, it's hidden from the nav for any viewer
that isn't on the host machine itself, the `/terminal` route redirects them to
Server Health, and the `/ws/terminal` socket is refused server-side for
non-loopback callers. The curated **Commands** page stays available either way.

### ⚙️ Game Config *(BETA)*

![Game Config page](docs/img/game-config.png)

A grouped editor for `UserGame.ini` and `UserEngine.ini`, with every
setting labeled, typed, and showing its underlying key in fine print.
Groups: Server Identity, Combat Rules, World & Weather, Shai-Hulud,
Resources & Loot, Players, Spicefields, Performance, and more. The page
**scans the live INIs on load** and shows each setting's **Funcom default**
until you override it; your edits are written into a clearly-marked
**DST-managed block** that DST owns (whole-section relocation, dedup, and
migration of any legacy Gameplay Admin block), and the original file is **backed
up on the server before every write**. A prominent BETA banner reminds you to
hit **Backup settings** first — and a **View backups** button lists the recent
`.dstbak-*` restore points next to each file. Save flushes the files back to
the VM and invalidates the Server Health port cache so any port change is
reflected immediately.

### 🎮 Gameplay Admin

![Gameplay Admin page](docs/img/gameplay-admin.png)

The open-source **Gameplay Admin portal, rebuilt natively inside DST** — one
console, one theme, no second program to install. A tabbed surface
(**Overview, Market, Market Bot, Players, Bases, Storage, Blueprints**) sits
on top of the same SSH + psql bridge the rest of DST uses, and v12.0.0
completes the port:

- **Market / Exchange** aggregates every active listing by item (lowest
  price, stock, bot vs. player split, recent sales). The enriched list is
  cached for 15 seconds so sort/filter on big catalogs stays instant.
- **Market Bot ("Duke")** both *buys* player listings and *lists* its own
  NPC stock via sane-pricing rules (tier × category × rarity × vendor ×
  grade, 100,000 Solari hard cap, per-template overrides with an inline
  typeahead picker). Three sub-tabs (**Buy / List / Pricing rules**), a
  vendor-snapshot preview, per-actor-class listing breakdown, and a
  safety net that detects leftover listings from any prior bot deployment
  (e.g. Revy from the old external Go market-bot) and offers a one-click
  wipe before Duke starts ticking.
- **Seed market** bulk-lists every catalogued template across all six
  quality grades in one shot with a live progress bar, abort button, and
  bulk-INSERT chunking that survives huge catalogs.
- **Players** ships the full 54-endpoint admin surface: a bucketed
  **Actions** panel covering all 28 player actions (Lifecycle /
  Communication / Inventory / Progression / Punishment / Diagnostics), a
  **Hide GM** toggle that filters the GM out of the list *and* the
  Online / Faction StatCards and Server Overview bucket counts, the
  **Items** actions (Give Item online + offline-safe, Repair Equipped
  Gear, Fill Water, Clean Inventory) folded into the Inventory section
  between the player's name and item list, and three ways to deselect a
  player (click the row again, Esc, or the new X Close button) to return
  to Server Overview.

When the battlegroup is offline the page falls back to a realistic **demo
dataset** (clearly badged) so the tools are explorable out of the box and flip
to live data automatically once the battlegroup is running.

### 🗄️ Database

![Database page](docs/img/database.png)

- **Take Backup** / **Restore Backup** for the BG PostgreSQL database
  without remembering pod names. A banner reminds you to stop the BG
  first for a consistent backup.
- **Backup Schedule** (v10.1.8+) — install a recurring `battlegroup backup`
  cron on the VM directly from the UI, with optional auto-pruning of dump
  files older than N days. Presets cover hourly, every six hours, daily 04:00,
  twice daily (04:00 and 16:00), and weekly Monday. The schedule lives in a
  clearly-marked managed block inside root's `/etc/crontabs/root`, is read
  back and verified after each save, and is shown alongside recent backup
  files plus a tail of `/var/log/dune-backup.log`. If a hand-installed
  `battlegroup backup` cron already exists (e.g. the legacy `0 4 * * *` line
  from the backup guide), the card preselects the matching preset and a
  single Save migrates it into the managed block — without leaving duplicate
  schedules behind. Backups land in `/funcom/artifacts/database-dumps/<bg>/`
  alongside Funcom's own ~3-hourly auto-backups. The schedule lives on the
  VM, so reprovisioning the VM loses it and it must be re-installed from the
  card.
- **Fix on-demand maps** (v10.0.4+) — one click clears the drifted
  `igwsss.spec.partitions` pin that intermittently stops DeepDesert,
  Arrakeen and Harko Village from launching on demand, then shows the last
  10 lines of the cleanup log inline. Idempotent and skips any map that
  already has a running pod, so it's safe to run repeatedly. Also available
  as the **fix-on-demand-maps** card in the Battlegroup section of the
  Commands page and the CLI Battlegroup menu.
- **SQL Editor** powered by Monaco. Read-only by default; toggle the
  switch to enable writes. Filterable table list sidebar, configurable
  max-rows cap, **Ctrl+Enter** to run.

### 🕸️ Sietches *(experimental)*

Experimental page for adding or removing additional Survival_1 shards
(sietches). Each sietch costs ~12 GB of RAM and requires the UDP port
range 7777–7900 to be open on the host. Gated behind an
**I UNDERSTAND** confirmation prompt — patches the battlegroup CRD
directly. Unsupported by Funcom; you're on your own if something breaks.

### 🗺️ DD Map

Two link cards (method.gg + dune.gaming.tools) for the interactive Deep
Desert maps the community maintains. Both target sites send
`X-Frame-Options: SAMEORIGIN`, so we can't embed them directly — clicking
**Open in new tab** launches each in your browser.

### 🌍 Map SpinUp

Per-map on-demand control for the three scale-to-zero maps — **Deep Desert**,
**Arrakeen**, and **Harko Village**. Each card shows the map's current pod
state with **Spin up** / **Spin down** buttons that patch the battlegroup's
`ServerSetScale` so the map comes up (or releases its RAM) without an SSH
session. Always-on maps (Hagga / Survival_1 and Overmap) are listed for
reference but not toggled here.

A header **Fix partitions** button clears the drifted
`igwsss.spec.partitions` pin that occasionally stops an on-demand map from
launching after a reboot, then shows the last ~10 lines of the cleanup log
inline. It's idempotent and skips any map with a running pod, so it's safe to
click repeatedly (the same action as the **fix-on-demand-maps** Command).

### 🔧 Settings

![Settings page](docs/img/settings.png)

All the things the Setup Wizard asked you, but editable any time:

- Steam install path (where Funcom dropped the dedicated server)
- SSH key path (private key into the dune-awakening VM)
- Windows username (used for desktop shortcut creation)
- **Port-check mode** — `builtin` (yougetsignal + canyouseeme fallback),
  `yougetsignal` only, `canyouseeme` only, `custom` (your own URL), or
  `disabled`
- Port-check URL template (when mode is `custom`)

Changes save on-click — no restart needed. The Steam path and SSH key fields
each have a **Browse** button that opens a native Windows folder/file picker.

The Updates card lives at the top of the page (minimized by default and
auto-checks on mount):

- **Updates** — current vs. latest Dune Server Tool version pulled from
  the GitHub Releases API. **Check now** to refresh, **Install** to
  download `DuneServerSetup.exe` and launch the installer wizard
  (interactive — the running portal is killed by PID before the wizard
  copies files, and the wizard's *Launch Dune Server* checkbox handles
  the relaunch).
### 🧙 Setup Wizard

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
`%TEMP%\DuneServerUpdate\` and launches the installer **wizard** — the
detached relauncher kills the current `DuneServer.exe` by PID, the wizard
walks through the standard pages, and the *Launch Dune Server* checkbox on
the Finished page brings the portal back up. As of v6.1.30 the relauncher
runs in a visible window (with a brief "Installing update..." banner) and
explicitly raises the wizard's main window so it appears in the foreground
instead of being hidden behind the browser or other windows. Your config
in `%APPDATA%\DuneServer\` is preserved across upgrades. As of v11.4.4 the
whole sequence is ~7–10s faster (lighter installer compression and trimmed
relauncher waits).

You can also check manually from **Settings → Updates → Check now**.

---

## Run at Windows startup *(optional)*

The **Help** menu (top toolbar) has a **Run at Windows startup** toggle.
Turn it on and DuneServer launches automatically every time you sign in to
Windows — in the system tray with no app window — and **closing the
DuneShell window no longer stops the server**.

- Reopen the portal any time from the **tray icon → Open Web Portal**, or
  just launch the Start Menu shortcut again (the running background server
  stays where it is; the shortcut brings the app window back).
- Toggling on or off takes effect at the **next launch**. Flipping mid-
  session doesn't change the current session's close behavior — that's
  intentional, so closing the app window always does what you just saw it
  do, not what a setting says it should do.
- **Loopback-only**: remote viewers (Tailscale / LAN / the SSH-tunneled
  co-admin pattern below) cannot enable autostart on your host. The menu
  entry is hidden for non-local viewers and the backend route refuses
  non-loopback callers.
- Implemented as a per-user Task Scheduler "at logon" job named
  `DuneServer-Autostart-<sid>` under the `Dune Server` folder. The
  uninstaller removes it automatically.

**Off by default — opt-in only.** If the toggle is missing from the Help
menu you're either viewing remotely (expected) or running from a dev
`pwsh` shell rather than the installed `DuneServer.exe` (also expected —
the feature needs the .exe path to schedule).

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

## Remote access *(advanced — no third-party software)*

DST binds its web portal to `127.0.0.1` only — there is **no** built-in
remote login, and exposing the port to the public internet would be unsafe
(the per-launch token is the only credential). If you want a trusted
co-admin to reach your portal from elsewhere, the supported pattern uses
only software that ships with Windows 10 / 11 — no Cloudflare, Tailscale,
ngrok, VPN service, or other third-party install required.

> ⚠️ **Read this first.** Anyone with your DST URL + token has full admin:
> they can restart your battlegroup, edit `ServerSetup.ini`, drop the
> database, or kick players. Only share access with people you trust at
> that level. The token resets on every DST launch and lives in
> `%LOCALAPPDATA%\DuneServer\last-url.txt`.

### How it works

The remote user opens an **SSH local port-forward** (a feature built into
`ssh.exe` on every Windows 10 / 11 install) that tunnels their machine's
`127.0.0.1:47823` to your machine's `127.0.0.1:47823`. They then browse to
the DST URL on their own loopback. The portal itself never accepts a
non-loopback connection, so it stays as locked down as if they were
sitting at your desk.

### One-time host setup (your machine)

1. **Install OpenSSH Server** (Microsoft component, no third-party install):

   ```powershell
   # Run as Administrator
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Set-Service -Name sshd -StartupType Automatic
   Start-Service sshd
   New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (TCP)' `
     -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
   ```

2. **Force key-only authentication** — edit `C:\ProgramData\ssh\sshd_config`:

   ```
   PasswordAuthentication no
   PubkeyAuthentication yes
   PermitRootLogin no
   AllowUsers <your-windows-username>
   ```

   Then `Restart-Service sshd`.

3. **Add your co-admin's public SSH key** to your authorized list:

   ```powershell
   # If your Windows account is in the Administrators group:
   $key = 'ssh-ed25519 AAAA... them@laptop'   # paste their public key
   Add-Content -Path 'C:\ProgramData\ssh\administrators_authorized_keys' -Value $key
   icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r `
     /grant 'Administrators:F' /grant 'SYSTEM:F'
   ```

   For a non-admin Windows account, use `C:\Users\<you>\.ssh\authorized_keys`
   instead (create the `.ssh` folder if missing; lock to user-only ACLs).

4. **Open a port on your router** — forward an arbitrary public TCP port
   (e.g. `52222`) → your PC's `22`. Use a non-standard external port to
   cut log noise from internet scanners. If your ISP gives you a rotating
   public IP, use a free dynamic-DNS hostname (e.g. DuckDNS, No-IP) — but
   that's still your DNS provider, not a tunnel service.

5. **(Recommended)** Rename the `sshd` Windows service log to flag brute
   force, or disable IPv6 on the router rule.

### One-time co-admin setup (their machine)

1. They generate a keypair on their Windows / macOS / Linux box:

   ```bash
   ssh-keygen -t ed25519 -C "them@laptop"
   ```

2. They send you `~/.ssh/id_ed25519.pub` (public key only — never the
   private one). You paste it into step 3 above.

### Every time the co-admin wants to connect

1. **You** launch DST normally, then send them the current token from
   `%LOCALAPPDATA%\DuneServer\last-url.txt` (it rotates on every launch).
   Use a secure channel — Signal, encrypted email, Discord DM — not a
   public channel.

2. **They** open an SSH tunnel from their machine:

   ```bash
   ssh -N -L 47823:127.0.0.1:47823 <your-windows-user>@<your-public-ip> -p 52222
   ```

   - `-N` = "don't run a remote command, just hold the tunnel"
   - `-L 47823:127.0.0.1:47823` = "forward my local 47823 to your loopback 47823"
   - Replace `52222` with whatever external port you forwarded on the router

3. **They** open the DST URL in their own browser, but pointed at *their*
   loopback:

   ```
   http://127.0.0.1:47823/?t=<token-you-sent-them>
   ```

4. When done, they `Ctrl+C` the SSH session to tear down the tunnel.

### Notes / gotchas

- **DST's port is dynamic.** It prefers `47823` but probes up to `+50`
  if busy. Check `%LOCALAPPDATA%\DuneServer\last-url.txt` for the real
  port and adjust the `-L 47823:127.0.0.1:<actual-port>` accordingly.
- **The DuneShell window holds the listener.** If you close it without
  using **Web Portal** (sidebar footer), the server stops and the
  tunnel returns 502s. Click **Web Portal** first if you want the
  server to keep running in the background after you close the window.
- **Token rotates on every DST launch.** If you restart DST while the
  co-admin is connected, re-send the new token from `last-url.txt`.
- **PowerShell page is loopback-only by design.** Even over the tunnel,
  the PowerShell terminal is intentionally restricted so a remote admin
  can't get a shell on your host. Server-side commands still work.

---

## Reporting issues

Hit a bug, error, or unexpected behavior? **Please open a GitHub issue**
so it can be tracked and fixed:

> 👉 [**Open an issue**](https://github.com/coastal-ms/DST-DuneServerTool/issues/new/choose) &nbsp;·&nbsp;
> [Browse existing issues](https://github.com/coastal-ms/DST-DuneServerTool/issues)

The bug report form asks for:

- **Tool version** — shown in the portal footer (e.g. `v11.4.8 · coastal-ms`).
- **Surface** — which portal page (Server Health, Commands, PowerShell,
  Game Config, DD Map, Map SpinUp, Database, Sietches, Settings, Setup
  Wizard) or whether it was the CLI / installer / auto-updater.
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

### TCP Ports Open shows "unknown" for RabbitMQ
The primary port checker (yougetsignal.com) has a daily per-public-IP
rate limit. v6.1.5+ automatically falls back to canyouseeme.org when this
happens; if both are exhausted, try again tomorrow or switch to a single
provider via **Settings → Port-check mode**.

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
- This tool is **not affiliated with Funcom**. "Dune", "Dune: Awakening",
  and related trademarks are property of their respective owners.
