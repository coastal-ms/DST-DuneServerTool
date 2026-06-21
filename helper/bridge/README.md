# Bridge — runs on the host's PC

This is the half of the friend helper that lives on the **host** PC (mine).
It exposes the locally running DST portal to a single trusted friend over
**Tailscale**, without exposing it to the LAN or the public internet, and
without modifying any released DST code.

## What it does

1. Listens on a stable port (default **47900/TCP**).
2. The Windows Firewall rule restricts inbound to the **Tailscale interface
   only**. Nothing on the LAN, nothing from the public internet, can reach
   this port.
3. On every request:
   - Re-reads `%LOCALAPPDATA%\DuneServer\last-url.txt` (DST rewrites this
     on every launch with `http://127.0.0.1:<port>/?t=<token>`).
   - For `GET /_dst/token`: returns the current `{url, token}` as JSON
     (the friend helper uses this to know where to navigate).
   - For `GET /_dst/health`: returns `{ok: true}` if DST is currently
     up and the token file parses.
   - For everything else: reverse-proxies the request to the current DST
     instance on `127.0.0.1:<DST port>` — method, headers, body, status,
     response body all carried through.

Because the URL is re-read per request, the bridge handles DST restarts
transparently. No restart needed when DST relaunches with a new port/token.

## Files

| File                       | Role                                             |
| -------------------------- | ------------------------------------------------ |
| `DstHelperBridge.ps1`      | The daemon. PS7 `HttpListener` + reverse proxy.  |
| `Install-Bridge.ps1`       | URL ACL + firewall rule + scheduled task setup.  |
| `Uninstall-Bridge.ps1`     | Reverses everything Install does.                |

## One-time setup

Requirements:

- **PowerShell 7** (`pwsh.exe`) on PATH. Install from <https://aka.ms/powershell>
- **Tailscale** installed and signed in. Windows interface alias must be
  `Tailscale` (the default). Verify with:
  ```powershell
  Get-NetIPInterface | Where-Object InterfaceAlias -eq 'Tailscale'
  ```
- An **admin** PowerShell to run `Install-Bridge.ps1` (URL ACL + firewall
  rule both require admin). The daemon itself runs **unelevated**.

Install:

```powershell
# from an elevated pwsh, in the repo root:
.\helper\bridge\Install-Bridge.ps1
```

This will:

1. Register `http://+:47900/` URL ACL for your user (so the unelevated
   daemon can bind it).
2. Create a Windows Firewall inbound rule allowing 47900/TCP **only on
   the Tailscale interface**.
3. Register a Scheduled Task `DST Friend Helper Bridge` that runs a
   supervisor loop at user logon. The supervisor relaunches the daemon
   within seconds if it crashes or is killed, so the bridge self-heals
   without waiting on a restart trigger. A 2-minute keepalive trigger is
   kept as a backstop in case the supervisor process itself is killed.
4. Start the task immediately.

Verify locally:

```powershell
curl http://127.0.0.1:47900/_dst/health
# -> {"ok":true}
```

Verify from the friend's PC (after they're on the tailnet):

```powershell
curl http://<your-machine-name>.<tailnet>.ts.net:47900/_dst/health
# -> {"ok":true}
```

## Tailscale ACL

Trust boundary = Tailscale ACL. In your Tailscale admin panel, lock
inbound to port 47900 to **only the friend's device tag**:

```jsonc
{
  "acls": [
    // Friend tag can only hit your bridge port, nothing else on your machine.
    { "action": "accept", "src": ["tag:dst-friend"], "dst": ["tag:dst-host:47900"] }
  ],
  "tagOwners": {
    "tag:dst-host":   ["autogroup:admin"],
    "tag:dst-friend": ["autogroup:admin"]
  }
}
```

Tag your own device `tag:dst-host` and the friend's device `tag:dst-friend`
in the admin panel.

## Uninstall

```powershell
# from an elevated pwsh:
.\helper\bridge\Uninstall-Bridge.ps1
```

Removes the scheduled task, firewall rule, and URL ACL. No leftover
state.

## Known limitations (MVP scaffold)

- **No WebSocket support.** The reverse proxy uses `HttpClient`, which
  doesn't speak the `Upgrade: websocket` handshake. The Terminal page
  in the DST portal will not work for the friend. Everything else (REST
  API, static assets, status polling) works fine.
- **Single concurrent request** (synchronous loop). Fine for one friend;
  not a public service.
- The daemon logs to stdout; redirect or pass `-LogPath` if you want a
  file. The scheduled-task action doesn't currently capture stdout to a
  log file — add `> $env:LOCALAPPDATA\DuneServer\.logs\bridge.log 2>&1`
  to the task action if you need persistent logs.
