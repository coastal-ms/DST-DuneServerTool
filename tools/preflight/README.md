# Dune Server Tool — Preflight Checker

Self-contained Windows checker that verifies every component the **Simple Dune
Server Management Tool** needs to run, then pops a GUI window with PASS / WARN
/ FAIL per check, color-coded, with a per-row Fix command.

## What it checks

- **Core**: elevation, OS build floor (Win10 1803+), Hyper-V Administrators group membership, host PowerShell version
- **Windows features**: Hyper-V (umbrella + Hypervisor + PS module + Services), Virtual Machine Platform, OpenSSH Client capability, WSL (informational)
- **Hyper-V cmdlets**: `Get-VM` works, `dune-awakening` VM presence
- **Runtime tools on PATH**: `pwsh.exe` (PS 7), `ssh.exe`, `tar.exe`, `curl.exe`, `git.exe`, `go.exe`, `kubectl.exe`
- **.NET / HTTP**: WinForms assembly loads, `HttpListener` can bind+release `127.0.0.1:47823`, no stale URL ACL
- **Security**: Windows Defender real-time, Dune-related AV exclusions, **Mark-of-the-Web on `DuneServer.exe`** (SmartScreen blocker), PowerShell execution policy, AppLocker enforcement
- **Install dir**: every required file under `C:\Program Files\Dune Server\`, EXE version
- **Local ports**: how many in `47823-47872` are free
- **Browser**: default `http://` association
- **State / log**: writable `%LOCALAPPDATA%\DuneServer\`, contents of `dune-server.log`, `last-url.txt`, any stray `DuneServer.exe` processes

Each FAIL/WARN row includes a copy-paste **Fix** command.

## How to use

1. Download both files (`DunePreflight.bat` + `DunePreflight.ps1`) and keep them in the **same folder**.
2. **Double-click `DunePreflight.bat`**.
3. Click **Yes** on the UAC prompt — Hyper-V cmdlets need admin.
4. The checker opens a window with a color-coded list.
5. Click any row for the full details + fix command in the bottom pane.
6. The full report is automatically saved to `Desktop\dune-preflight.txt` and copied to your clipboard — just paste it into a Discord DM / email to whoever's helping you.

## Buttons

- **Copy to clipboard** — full report on your clipboard
- **Save report** — choose a save location
- **Open dune log** — opens `%LOCALAPPDATA%\DuneServer\dune-server.log` in Notepad
- **Open install dir** — opens `C:\Program Files\Dune Server\` in Explorer
- **Re-run preflight** — re-runs all checks (after you've installed a missing tool, click this to see if it's resolved)
- **Close** — exit

## Distributing to a user

The two files are self-contained. Zip them and share, or drop them into a GitHub
release as `DunePreflight.zip`. The user only needs to:

1. Extract the zip.
2. Double-click `DunePreflight.bat`.
3. Click Yes on UAC.
4. Paste the report back.

## Notes

- Runs under **PowerShell 7 if `pwsh.exe` is on PATH**, else falls back to
  Windows PowerShell 5.1 (also works — only the GUI rendering differs slightly).
- The `.bat` automatically calls `Unblock-File` on the `.ps1` to strip the
  Mark-of-the-Web that ZIP extraction leaves behind, so SmartScreen does not
  block the script.
- All checks are read-only — the script never modifies system state. It only
  *reports* what's wrong and gives you the fix command to run yourself.
