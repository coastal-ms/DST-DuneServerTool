---
name: Bug report
about: Something isn't working
labels: bug
---

## What happened

<!-- Clear description of the bug. Mention which page/button or CLI command triggered it. -->

## What you expected to happen

## Steps to reproduce

1.
2.
3.

## Where in the tool

<!-- Pick the closest: Dashboard / Server Health / Monitoring / Terminal /
     Characters / Game Config / Database / Settings / Setup Wizard /
     Additional Sietches / "Battlegroup shows Unknown / can't connect to VM" /
     CLI (dune-server.ps1) / Installer / Update checker -->

## Connection / VM status message (only if your bug involves the VM / SSH / battlegroup)

<!-- The tool tells you WHY it can't reach the battlegroup. Copy the exact text:
     - Dashboard → "Battlegroup + VM" card: the yellow line under the status
       (e.g. "SSH key is passphrase-protected…", "VM rejected the SSH key…").
     - Setup Wizard / Settings → "Re-run checks": the "SSH key authorized on VM" row.
     - Settings → SSH Key field: the key path the tool is using.
     Also note: does the in-app "Open an SSH terminal to the VM" (Commands / CLI
     option 17) still connect even though the Dashboard shows Unknown? -->

## Environment

- Tool version (header bar `Installed: x.y.z`, bottom-left of the web portal sidebar, or CLI menu header):
- Windows version:
- PowerShell version (`$PSVersionTable.PSVersion`):
- WebView2 runtime (if desktop app):
- Hyper-V VM OS:
- Battlegroup / k3s version (if known):

## Logs / error output

```
<!-- paste terminal-pane output, footer text, or relevant lines from
     %APPDATA%\DuneServer\webview2-debug.log / .logs\dune-server-*.log -->
```

## dune-server.config (sanitized — remove IPs, paths, usernames, key files)

```
<!-- paste here -->
```
