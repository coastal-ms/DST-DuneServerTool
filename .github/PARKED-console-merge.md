# v11.3.0 — Merge backend + dune-admin into one combined console window

## Decision

User picked "merge into one combined console window" when asked how to handle the multiple console windows that pop up when DST + dune-admin run side by side. Currently:

- `DuneServer.exe` — visible console (minimized at startup, owned by PS2EXE-wrapped backend)
- `dune-admin.exe` — separate console window when launched
- `DuneShell.exe` — main WPF window (the DST UI)

Goal: one combined console window showing both backend AND dune-admin output, interleaved with `[backend]` / `[admin]` line prefixes.

## Approach (parked design)

The cleanest implementation that avoids re-architecting elevation:

1. **Hide dune-admin's own console window.** Change the scheduled-task launch in `dune-server.ps1` (around line 2260) from `New-ScheduledTaskAction -Execute $duneAdminExe` to a `cmd.exe` wrapper that redirects stdout/stderr to a known log file:
   ```powershell
   $logPath = Join-Path $env:LOCALAPPDATA 'DuneServer\logs\dune-admin.log'
   $wrappedCmd = "/c `"`"$duneAdminExe`" 1>>`"$logPath`" 2>&1`""
   $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $wrappedCmd -WorkingDirectory $duneAdminDir
   $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
   ```

2. **Tail the log file from the main DuneServer process.** Add a helper in `app/server/lib/ConsoleHost.ps1` that creates a dedicated runspace which runs `Get-Content -Wait` on the dune-admin log file and calls `[Console]::WriteLine("[admin] $_")` for every new line. `[Console]` is process-static so writes from the runspace land in DuneServer's existing console window.

3. **Lifecycle.** Start the mirror runspace from `Start-DuneHttpServer` (right after the listener is bound, alongside `Start-DuneConsoleLifecycle`). Tear it down from `Stop-DuneConsoleLifecycle` the same way the watcher + tray runspaces are torn down.

4. **Prefix the backend's own output too.** Wrap `Write-DuneLog` (or `Write-Host`) calls so they print `[backend] ...` to console, matching the `[admin]` prefix. Optional but makes the merged stream readable.

## Why this approach

- No elevation surgery. dune-admin still runs unelevated via scheduled task; DuneServer stays elevated.
- No need to restructure the spawn/IPC architecture.
- Both streams visibly merge in ONE existing console window (DuneServer's). Zero extra windows. dune-admin's console is gone.
- Log file at `%LOCALAPPDATA%\DuneServer\logs\dune-admin.log` is also durable for diagnostics.

## Out of scope

- True multiplexed-pipe approach with prefix-per-line in real time (would require dropping the scheduled-task launch and re-architecting elevation; not worth it for the marginal UX win over file-tail).
- An in-app web console page (separate idea — could be a v11.4.0 add-on layered on top of this).

## Files to touch (when ready)

- `dune-server.ps1` ~line 2260: scheduled-task action change
- `app/server/lib/ConsoleHost.ps1`: add `Start-DuneAdminLogMirror` + `Stop-DuneAdminLogMirror`
- `app/server/HttpServer.ps1`: call mirror start/stop alongside existing lifecycle hooks

## Status

**PARKED** as of 2026-06-05. Branch exists; not implemented. To pick up: branch off `coastal-ms/console-merge`, follow the plan above, ship as v11.3.0.
