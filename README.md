# Simple Dune Server Management Tool

> By Coastal (discord `@allcoast`). Menu-driven admin tool for a self-hosted
> Dune Awakening dedicated server.

[![Lint PowerShell](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/actions/workflows/lint.yml/badge.svg)](https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A menu-driven tool for managing your Dune Awakening self-hosted dedicated server. It wraps the official Funcom battlegroup scripts and adds extra utilities like SSH access and the dune-admin panel.

See [`CHANGELOG.md`](CHANGELOG.md) for release history and
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the change-control workflow.


---

## What You Need

Before using this tool, make sure you have the following:

- **Windows 10/11** with Hyper-V enabled
- **PowerShell 7** (`pwsh`) installed — [Download here](https://github.com/PowerShell/PowerShell/releases)
- **Dune Awakening Self-Hosted Server** installed via Steam
- **SSH private key** for connecting to your VM (created during the official battlegroup setup)
- **(Optional)** [dune-admin](https://github.com/icehunter/dune-admin) — a community admin panel for managing players, inventory, and more

---

## Files

| File | Purpose |
|------|---------|
| `dune-server.bat` | Double-click this to launch the tool |
| `dune-server.ps1` | The main script (don't run this directly — use the .bat) |
| `dune-server.config` | Your saved settings (created automatically on first run) |
| `readmez.md` | Ummm...... yeah.... |

---

## First-Time Setup

1. **Double-click `dune-server.bat`**

2. The script requires administrator privileges (needed for Hyper-V commands). Click **Yes** on the UAC prompt.

3. You'll see the setup wizard:

   ```
   ==========================================
     Dune Awakening Server — First-Time Setup
   ==========================================

   This will ask a few questions to configure the tool for your system.
   ```

4. Answer each question:

   | # | Question | What to enter |
   |---|----------|---------------|
   | 1 | **Server install folder** | The folder where Steam installed the Dune server. It contains a `battlegroup-management` subfolder. The script tries to auto-detect this. |
   | 2 | **SSH private key** | Path to your SSH private key for the VM. Usually in `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` or `~\.ssh\dune`. |
   | 3 | **dune-admin.exe path** | Path to `dune-admin.exe` if you use the community admin panel. Leave blank to skip — you can always add it later. |
   | 4 | **Windows username** | Your Windows login name (e.g., `Coastal`). Used to launch dune-admin without admin elevation. |
   | 5 | **Port verification** | Choose `1` (Built-in, default — uses [yougetsignal.com](https://www.yougetsignal.com/tools/open-ports/) for TCP), `2` (Custom URL — provide your own service that supports `{ip}`, `{port}`, `{protocol}` placeholders), or `3` (Disabled). The check runs once per launch and shows a color-coded status next to each required port in the menu header. |

5. Your answers are saved to `dune-server.config`. To change them later, delete that file and re-run the tool.

---

## Using the Menu

After setup, you'll see the main menu every time you launch:

```
==========================================
  Dune Awakening — Server Management
  Brought to you by Coastal (Discord @allcoast)
==========================================

  VM: Running (192.168.1.50)

  Required Port Forwarding:
    (checking against public IP 203.0.113.45 -> VM 192.168.1.50)
    UDP  7777-7810   Game servers (first port)     [OPEN]
    UDP  7777-7810   Game servers (last port)      [OPEN]
    TCP  31982       RabbitMQ                      [OPEN]

VM commands:

   a. initial-setup                Run the initial VM setup
   b. start-vm                     Start the VM
   c. stop-vm                      Stop the VM
   d. rotate-ssh-key               Generate a new SSH key
   e. change-password              Change the 'dune' user password
   f. shutdown                     Stop battlegroup -> power off VM (e.g. shut down for the night)
   g. reboot                       Stop battlegroup -> restart VM -> start battlegroup (clean cycle)

Battlegroup commands:

   1. status                       Shows the status of the battlegroup
   2. start                        Starts the battlegroup
   3. restart                      Restarts the battlegroup
   4. stop                         Stops the battlegroup
   5. update                       Checks for new versions and applies them
   6. edit                         Edit with the utilities interface
   7. edit-advanced                 Manually edit YAML directly
   8. enable-experimental-swap      Enable experimental swap memory
 Database:
   9. backup                       Take a database backup
  10. import                        Import a database backup
 Logs:
  11. logs-export                   Retrieve logs from all pods
  12. operator-logs-export          Retrieve operator logs
 Monitoring:
  13. open-file-browser             Open the file browser (ini configs, logs)
  14. open-director                 Open the director page (server status)
  15. shell-vm                      Connect to the VM via commandline
  16. shell-pod                     Connect to a pod via commandline

  --------------------------------------------------

Tools:

  20. ssh                           Open an SSH terminal to the VM
  21. dune-admin                    Launch dune-admin.exe + web UI
  22. setup-guide                   Open Funcom Self-Hosted Server Setup Instructions

   q. quit                         Exit this script
```

Type a letter or number and press **Enter** to run that option.

### What each section does

**VM commands (a–g)** — Control the Hyper-V virtual machine itself. Start it, stop it, rotate SSH keys, change the VM password, run a clean reboot, or shut down for the night.

> **Reboot (`e`)** — Use this when the server is misbehaving (lag, memory pressure, stuck pods) and you want a clean cycle without losing player data. It will:
> 1. Stop the battlegroup so all maps enter PreShutdown and persist player state to the database.
> 2. Wait for the game, RabbitMQ, gateway, traffic-router, and director pods to fully terminate (up to 6 minutes).
> 3. Hard-stop and restart the Hyper-V VM.
> 4. Wait for the VM to come back online, k3s API to be ready, database pods to be Ready, operator pods to be Ready, and the operator webhook service endpoints to be populated (this last step is critical — starting battlegroup before the webhook is reachable causes a `502 Bad Gateway` error).
> 5. Start the battlegroup again.
>
> The whole cycle typically takes 5–10 minutes. Warn your players in Discord first — there is no in-game broadcast mechanism.

> **Shutdown (`d`)** — Use this when you want to shut the server down for the night (or any extended period). It does the same first two phases as reboot — stop the battlegroup and wait for player data to fully persist to the DB — then powers off the VM and stops there. Bring it back up with `c. startup`.

**Battlegroup commands (1–16)** — Manage the game server running inside the VM. These are the same options from the official Funcom `battlegroup.bat`, including starting/stopping the server, updating, editing config, backups, logs, and connecting to pods.

**Tools (20–22)** — Extra utilities:
- **SSH** opens a direct terminal session to the VM
- **dune-admin** launches the admin panel exe and opens the web UI in your browser simultaneously
- **setup-guide** opens Funcom's official [Self-Hosted Server Setup Instructions](https://duneawakening.com/self-hosted-servers/) in your browser

Options appear **grayed out** when they can't be used (e.g., battlegroup commands are unavailable if the VM isn't running).

### Port verification

If you provided a port-check URL template during setup (question #5), the menu header will show a color-coded status for each required port every time you launch the tool:

- **`[OPEN]`** *(green)* — the port is reachable from the internet.
- **`[CLOSED]`** *(red)* — the port is unreachable. Check your router's port forwarding and the Windows Defender Firewall.
- **`[UNKNOWN]`** *(yellow)* — the check service returned an ambiguous response or timed out.

The tool calls your port-check URL with `{ip}`, `{port}`, and `{protocol}` placeholders substituted, and looks for `open` / `closed` (or the JSON keys `"open"`, `"reachable"`, `"status"`) in the response body. The check runs once per session and is cached, so it does not slow down subsequent menu renders. The public IP is fetched from `https://api.ipify.org`.

Sampled ports:
- **UDP 7777** — first port of the game-server range
- **UDP 7810** — last port of the game-server range
- **TCP 31982** — RabbitMQ

To change or remove the port-check URL later, edit `dune-server.config` (the `PortCheckUrlTemplate=` line) or delete the file to re-run the setup wizard.

---

## Troubleshooting

### "pwsh is not recognized"
PowerShell 7 is not installed. Download it from [https://github.com/PowerShell/PowerShell/releases](https://github.com/PowerShell/PowerShell/releases) and install. The `.bat` file uses `pwsh` instead of the built-in `powershell` (version 5.1).

### "The script requires administrator privileges"
Right-click `dune-server.bat` and select **Run as administrator**, or click Yes on the UAC prompt. Administrator access is required for Hyper-V VM management.

### dune-admin won't find my SSH key
The dune-admin app looks for keys in this order:
1. `./sshKey` (same folder as the exe)
2. `~/.ssh/dune` (as a file, not a folder)
3. `~/.ssh/id_ed25519`

Make sure your key is in one of those locations. You may also need to set the `HOME` environment variable:
```powershell
[System.Environment]::SetEnvironmentVariable("HOME", $env:USERPROFILE, "User")
```
Then restart dune-admin.

### dune-admin says "Access is denied" writing .env
This happens if dune-admin is running as administrator. The tool already handles this by launching it under your normal user account. If you still see the error, delete the existing `.env` file in the dune-admin folder and try again.

### Port check shows `[UNKNOWN]` for everything
- The tool could not reach your port-check service or the response didn't contain the expected keywords (`open`, `closed`, or JSON keys `"open"`/`"reachable"`/`"status"`).
- Test the URL manually in a browser with `{ip}` and `{port}` substituted by hand to confirm it returns something parseable.
- If `api.ipify.org` is blocked on your network, the check will silently fail — the menu will show `[check failed - no public IP]` instead.

### Port check shows `[CLOSED]` but the game is working
- Some port checkers don't actually probe UDP correctly (UDP has no handshake, so a "closed" response usually means "no reply" — not the same as closed). If TCP 31982 shows OPEN but the UDP ports show CLOSED, it's likely a limitation of the checker, not your port forwarding.
- Confirm with a UDP-aware tool (e.g. `nmap -sU -p 7777 <public-ip>` from another network).

### I want to disable port verification
- Delete or blank the `PortCheckUrlTemplate=` line in `dune-server.config`, or delete the config file and re-run setup leaving question #5 blank.

### Graceful reboot fails at "Starting battlegroup" with `502 Bad Gateway`
The mutating webhook from the battlegroup operator was not reachable when `battlegroup start` was called. The `reboot` option now waits for the webhook service endpoints to be populated before starting, but if you triggered `start` manually too soon you'll see:
```
failed calling webhook "mbattlegroup.kb.io": ... 502 Bad Gateway
```
Wait 30–60 seconds and try option `2. start` again, or just rerun option `e. reboot` from the beginning.

### I want to change my settings
Delete `dune-server.config` (in the same folder as the scripts) and run `dune-server.bat` again. The setup wizard will re-appear.

### Option 21 (dune-admin) doesn't show up
You left the dune-admin path blank during setup. Delete `dune-server.config` and re-run setup, providing the path this time.

---

## Notes

- All actions are logged to the `.logs` folder next to the script.
- The VM name is always `dune-awakening` and the SSH user is always `dune` — these match the official Funcom setup and cannot be changed.
- The web UI for dune-admin is at [https://dune-admin.layout.tools/](https://dune-admin.layout.tools/).
