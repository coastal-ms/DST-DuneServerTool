# Web UI

A browser-based button panel that mirrors the console menu of
`dune-server.ps1`. Built on [Pode](https://github.com/Badgerati/Pode),
serves on `http://127.0.0.1:8765` (localhost only, no auth).

## Quick start

From the console menu, pick option **`b. web`**. That will:

1. Verify Pode is installed (and tell you how to install it if not).
2. Start `web/Start-DuneWeb.ps1` minimized if it isn't already running.
3. Open your default browser at `http://127.0.0.1:8765`.

You can also start the server manually:

```powershell
pwsh -ExecutionPolicy Bypass -File .\web\Start-DuneWeb.ps1
```

## Prereqs

Install Pode once per user:

```powershell
Install-Module Pode -Scope CurrentUser
```

## How it works

- **Status** (`GET /api/status`) — returns JSON: VM existence/state/IP and the
  cached port-check results. The page polls this every 5 seconds.
- **Commands** (`GET /api/commands`) — returns the list of VM/Battlegroup/Tools
  buttons and per-command availability.
- **Execute** (`POST /api/exec/{name}`) — spawns a new console window running
  `dune-server.ps1 -Cmd <name>`. Interactive prompts (battlegroup picker,
  password entry, confirmations) appear in that console naturally, so no
  output streaming is required from the web side.

`graceful-reboot` and `graceful-shutdown` show a JS `confirm()` dialog before
the POST is issued.

## Files

- `Start-DuneWeb.ps1` — Pode server entry point.
- `public/index.html` — single-page UI.
- `public/app.js` — fetch + button state + click handlers.
- `public/styles.css` — dark theme.
