# app/pages/

Per-page WPF module files for v6.0 "Server Manager" release.

Each page is a single `.ps1` that exposes:
- `New-XxxPage` — builds the page's XAML and returns the root `Border` (an instance of `PageRootStyle` from `app/styles/Theme.xaml`).
- `Show-XxxPage` — called when the page becomes active in the page-host. Wires events, kicks off any background polling, etc.
- `Hide-XxxPage` — called when the page is leaving; tear down timers/runspaces.

Loaded by `app/DuneServer.ps1` via dot-sourcing on startup. Page modules
must not assume the WPF UI tree has been created — that lives in the host.
