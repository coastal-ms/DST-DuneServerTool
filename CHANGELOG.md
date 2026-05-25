# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [5.0.0] - 2026-05-25

Major release: **embedded terminal pane**. The right pane is now a real
ConPTY-backed xterm.js terminal. Every command — including interactive ones
that previously required a popup PowerShell window — runs inside the app's
own window. The two-mode (InApp / Console) dispatch split is gone. The
legacy localhost web portal that shipped alongside the CLI is also gone now
that the desktop app covers every workflow.

### Added

- **Embedded terminal renderer** in the right pane, backed by a real
  ConPTY. Implemented with:
    - **Pty.Net** (0.1.16-pre) — managed wrapper over the Windows
      pseudoterminal API; what the VS Code PowerShell extension uses
    - **WebView2** + **xterm.js** (5.5.0) + **xterm-addon-fit** (0.10.0) —
      the same renderer stack VS Code uses for its integrated terminal
  All three are bundled with the installer (no internet at install time).
- **JS ↔ PowerShell bridge** over `CoreWebView2.WebMessageReceived` /
  `PostWebMessageAsJson`. Carries input keystrokes, viewport resizes,
  and clipboard-copy round-trips between xterm.js and the PowerShell host.
- **WebView2 runtime check** at startup. If the Evergreen runtime is
  missing (rare on Win11, possible on minimal Win10 / Windows Server),
  a friendly prompt links the user to the official Microsoft installer.

### Changed

- **Every command now runs inside the embedded terminal**, including
  commands that previously opened a separate PowerShell window:
  `startup`, `shutdown`, `reboot`, `rotate-ssh-key`, `change-password`,
  `start`, `restart`, `stop`, `update`, `edit`, `edit-advanced`,
  `enable-experimental-swap`, `backup`, `import`, `logs-export`,
  `operator-logs-export`, `shell-vm`, `shell-pod`, `ssh`,
  `initial-setup`. Interactive prompts, SSH sessions, TUI editors,
  spinners, and ANSI cursor moves all work — the PTY gives them a
  real TTY.
- **Output rendering matches a real terminal.** ANSI colors are now
  honored (the old InApp pane was stripping them); cursor-move
  sequences work; line wrapping respects the actual viewport.
- **App docstring** updated to reflect the new single-mode dispatch.
- **App and CLI READMEs** updated; install paths reduced from three
  (desktop app / .bat / web portal) to two.

### Removed

- **Legacy web portal** — the entire `web/` directory (`Start-DuneWeb.ps1`,
  `public/index.html`, `public/app.js`, `public/styles.css`, `web/README.md`)
  is gone. The desktop app covers every workflow the portal did, so
  maintaining two parallel UIs is no longer worth it. **Breaking change**
  for the (likely zero) users still launching `Start-DuneWeb.ps1`
  directly. The `Mode='Console'` / `Mode='InApp'` distinction in the
  command catalog is also functionally gone (the field is still tolerated
  for backward compat but ignored at dispatch time).
- **`Invoke-Command-InApp`** and **`Invoke-Command-Console`** are gone,
  replaced by a single **`Invoke-Command-Terminal`** that spawns pwsh
  under a PTY and pipes its byte stream into xterm.js.
- **Mouse-down swallow handler** on the output pane (only needed because
  the old `TextBox`-based pane needed to look non-interactive). The
  terminal handles its own mouse routing.

### Fixed (pre-release stabilization)

- **PTY data + exit handlers actually fire.** PowerShell scriptblocks
  bound to events that are raised from a non-runspace background thread
  (Pty.Net's reader thread) are silently dropped — `Register-ObjectEvent`,
  `[DelegateType]{...}.GetNewClosure()`, and ConcurrentQueue-capturing
  closures all returned 0 chunks despite the child process writing to
  the PTY. Replaced with a tiny `DuneServer.PtySink` C# helper
  (compiled at startup via `Add-Type`) whose `OnData`/`OnExit` methods
  are bound as real CLR delegates via
  `[Delegate]::CreateDelegate(...)`. These execute on any thread without
  needing PS runspace context. The DispatcherTimer drains a
  `ConcurrentQueue<string>` and an `int` Exited flag on the UI thread.
- **Battlegroup state parser now correctly disables redundant pod
  buttons.** Previously matched `STATUS: Running`, which the `bg status`
  command does not actually emit, so `LastBgState` stayed `unknown` and
  Startup/Start/Stop were always lit regardless of the real pod state.
  Rewrote `Get-BgStateFromStatusText` to recognise the actual output
  shape: `Phase: Ready`, `<Map>  Running` table rows, and
  `No resources found in <ns> namespace`.
- **Force-kill hung sessions** with a new **Kill** button next to
  Copy/Clear and a **Ctrl+\\** shortcut from inside the terminal.
  Targets `shell-vm`, `shell-pod`, and any other interactive command
  that doesn't cleanly exit on Ctrl+C. The "Ctrl+\\ to kill" hint sits
  next to the Output title so users don't forget it.
- **Atomic PTY teardown.** Stopping a session used to double-dispose
  when the drain timer re-entered during cleanup → crash. `Stop-CurrentPty`
  now nulls the script-scope refs first (so a re-entrant tick bails out
  immediately), drains remaining output, marks the sink exited via a
  method-level `MarkExited()` (avoids the `[ref]$obj.Field` marshaling
  pitfall in PS 5.1), then disposes.
- **TUI editors (`edit`, `edit-advanced`) launch in their own console
  window.** Embedding `xterm.js → ConPTY → ssh -t → remote vim` across
  five terminal-size negotiation layers corrupts the rendered display
  (SSH window-change forwarding to nested TUI apps is unreliable on
  Windows). Native conhost renders vim faithfully and the embedded
  terminal stays free for streaming output from other commands.
- **Mouse wheel works inside the popup vim** — `dune-server.ps1` now
  ensures `set mouse=a` is in `~/.vimrc` on the VM via an idempotent
  pre-flight check before any edit command. Without this, modern vim's
  default mouse-mode-enabled-but-wheel-unmapped state ate wheel events
  without scrolling anything.
- **Embedded terminal no longer corrupts itself on window resize.** The
  JS `ResizeObserver` debounce was firing mid-session and reshaping the
  terminal underneath running commands. Refits are now suppressed while
  a PTY session is active, and the resize message is de-duplicated so
  it's only sent when the dimensions actually change. The PTY is also
  re-synced to the authoritative xterm dimensions on `session-start`.

### Notes for developers

- The full dependency bundle adds ~2.7 MB to the installer (Pty.Net +
  WebView2 managed/native + xterm.js assets).
- ps2exe compiles `DuneServer.exe` as PowerShell 5.1 Desktop. Both DLL
  sets are netstandard2.0 / net46 and load cleanly there. `BackendOptions::ConPty`
  is passed explicitly when spawning PTYs.
- Pty.Net event handlers must NOT be bound as PowerShell scriptblocks
  (`Register-ObjectEvent`, `.GetNewClosure()`, or `[DelegateType]{...}`
  casts) — events fired from the reader thread are silently dropped.
  Bind a `DuneServer.PtySink` C# helper via
  `[Delegate]::CreateDelegate(...)` instead. See `Start-PtyDrainTimer`
  + `Stop-CurrentPty`.

## [4.5.2] - 2026-05-25

Patch on top of v4.5.1.

### Fixed

- **"Report an Issue" (and other URL-opening menu items) now open the
  user's default browser on Windows 11 24H2.** The previous pattern
  `Start-Process "$env:SystemRoot\explorer.exe" $url` stopped working
  correctly on 24H2 — `explorer.exe` now ignores the system default
  browser and either silently fails (from an elevated PowerShell host)
  or forces Microsoft Edge regardless of the user's preference. Switched
  every URL launch in `dune-server.ps1` to `Start-Process $url`, which
  dispatches through the registered `https://` protocol handler and
  honors the user's default browser. Affects: `report-issue`,
  `setup-guide`, `dune-admin` (web UI), `open-file-browser`,
  `open-director`.

## [4.5.1] - 2026-05-25

Patch on top of v4.5.0.

### Fixed

- **Separators (and any card) can now be reordered regardless of VM state.**
  Previously, when the VM was off, the greyed-out command buttons stopped
  receiving mouse events, which meant the user could not drag separators
  across them — the only valid drop targets were other separators and the
  few always-available commands. Now every card stays enabled for
  drag/drop at all times; unavailable commands are visually muted
  (foreground colors + reduced opacity) and the click handler short-circuits
  with a friendly message if the command can't run yet (e.g.
  `[Cannot run 'startup' - the VM is not running.]`).
- Tooltips on unavailable commands now mention that drag-reorder still
  works ("You can still drag this card to reorder the list.").

## [4.5.0] - 2026-05-25

Minor release: **draggable separators** in the command list, so the user can
visually group commands without changing what each command does.

### Added

- **Four draggable separators** (`Separator 1` … `Separator 4`) at the end of
  the command list. Each one renders as a slim horizontal divider chip with
  grip dots on either side.
- Separators **participate in the existing drag-reorder system**: drag any
  separator up into the list to insert a visual break between commands, and
  drag it back down (or onto another row) to move it. They share the same
  drop-indicator behavior as regular command cards.
- **Persistence**: separator positions are saved to
  `%APPDATA%\DuneServer\button-order.json` alongside the command order, so
  groupings survive restarts and updates.
- **Right-click → "Reset separator positions"** on any separator sends all
  four back to the bottom of the list without touching the user's command
  order. The existing "Reset button order to default" entry is also still
  available on every separator's context menu.

### Notes

- Separators are not clickable — they exist purely to organize the list.
- The 3-column layout still distributes items left-to-right, so a separator
  occupies one cell in whichever column it lands in. If you want a separator
  to fully span all three columns, drop one near the same position in each
  column (e.g., positions 6, 13, 20 in a 20-command catalog).

## [4.4.0] - 2026-05-24

Minor release: brings the **external port-check** feature from the CLI menu into the WPF app's top bar.

### Added

- **Port-check status line** in the header (above the battlegroup status
  pane). Shows external reachability for the forwarded ports as a single
  colored line with the public IP and a timestamp, e.g.
  `Ports (203.0.113.45): TCP 31982 RabbitMQ [OPEN]   updated 21:15:29`.
- **TCP 31982 (RabbitMQ)** is always checked via the built-in
  `yougetsignal.com` service (no UDP support there).
- **UDP 7777 and 7810 (game-server range first/last)** are only shown
  when the user pointed `initial-setup` at a UDP-capable checker (i.e.
  `PortCheckMode=custom` with a `PortCheckUrlTemplate` set in
  `dune-server.config`). Free public services don't support UDP, so
  there's no point showing placeholder rows in the default `builtin`
  case.
- **`PortCheckMode=disabled`** hides the line entirely (rendered as
  `Ports: (verification disabled in config — run 'initial-setup' to change)`).
- Each port renders with a colored status pill: `[OPEN]` (green),
  `[CLOSED]` (red), `[UDP - skipped]` (dim), `[UNKNOWN]` (amber).
- The check runs on a background runspace (each yougetsignal request
  takes 5-10s) so the UI never blocks. The **Refresh** button forces a
  fresh hit; the 30s auto-refresh paints from a 5-minute cache so we
  don't hammer the public service.

## [4.3.3] - 2026-05-24

Patch on top of v4.3.2.

### Added

- **"Latest: vX.Y.Z" header label is now clickable** — opens the matching
  GitHub release notes page in your browser. Hover gives a hand cursor,
  underline, and tooltip ("Open release notes for vX.Y.Z on GitHub").
  The link affordance is only shown after a successful update check
  populates a tag; the "Latest: checking..." and "Latest: check failed"
  states render as plain text.

### Fixed

- **Battlegroup status panel no longer renders a red `NativeCommandError`
  when the battlegroup is Stopped.** Funcom's `battlegroup status` writes
  kubectl's benign "No resources found in <namespace> namespace." line to
  stderr whenever there are no game-server pods (i.e. after a stop or
  fresh reboot before maps come up). The SSH wrapper merged stderr with
  `2>&1`, which arrives as `ErrorRecord` objects; `Out-String` then
  rendered each one with the full `At line:N char:M / CategoryInfo /
  FullyQualifiedErrorId : NativeCommandError` call-site dump.
  Both the snapshot helper (`Get-BattlegroupStatusSnapshot`) and the
  runspace status-fetch now flatten any `ErrorRecord` on the merged
  pipeline to plain strings before stringification, so the empty
  "Game Servers" section just shows the plain text line.

## [4.3.2] - 2026-05-24

Patch on top of v4.3.1.

### Fixed

- **Update check always said "update available", even on the latest
  version.** `$script:ToolVersion` was defined in `dune-server.ps1`
  but never in `app/DuneServer.ps1`, which is a separate script.
  So `$current` was always `$null` inside `Check-ForUpdates`, and
  `[Version]"4.3.x" -gt $null` is true in PowerShell, which made the
  label perma-stuck on "update available" and the comparison
  always favor downloading. Fixed by defining `$script:ToolVersion`
  directly in `app/DuneServer.ps1` (kept in lock-step with the other
  three version constants).
- Added a defensive `if (-not $current)` arm to `Check-ForUpdates`
  so a future version-parse failure shows "(installed version
  unknown)" in red instead of silently falling through to
  "update available".

## [4.3.1] - 2026-05-24

Patch on top of v4.3.0.

### Fixed

- **Silent startup update check no longer nags.** The
  `Check-ForUpdates -Silent` path (run automatically on
  `Window.Loaded`) was still showing the YesNo "Update Available"
  prompt every launch. It now only paints the Latest label blue when
  a newer release is available; the download prompt only appears when
  you click the **Check for Updates** button explicitly.

## [4.3.0] - 2026-05-24

Minor release: drops the legacy web portal as a user-facing option.

### Removed

- **Web Portal menu entry** (`web` / key `b`) is gone from both the
  desktop app's button grid and the legacy CLI menu. The `web/`
  folder + `Start-DuneWeb.ps1` script still exist in the repo for
  archival reference but are no longer launchable from the app.
- Dead handler for the `web` command in `dune-server.ps1` (the
  Pode-bootstrap block) removed.
- `web` -> `Web Portal` entry removed from the app's `LabelOverrides`
  hashtable.

## [4.2.0] - 2026-05-24

Minor release: in-app update checking.

### Added

- **"Check for Updates" button** in the status header. Hits the GitHub
  Releases API for `coastal-ms/Simple-Dune-Server-Management-Tool`,
  compares the latest release tag to the installed version, and offers
  to download + launch the installer if a newer build is available.
- **Installed / Latest version labels** next to the new button, so the
  user can see at a glance which version they're on and what's current
  upstream.
- **Silent update check on launch** — the Latest label is populated
  automatically when the window opens, and a prompt is shown only when
  a newer release actually exists. Errors are swallowed silently on
  startup; explicit button clicks still surface failures via dialog.

## [4.1.0] - 2026-05-24

Minor release: installer can now download dune-admin for you, and the
top/right status panes are no longer click-into text boxes.

### Added

- **"Download Latest from GitHub..." button** on the Dune Admin Tool
  page of the installer. Pick a folder, and the installer fetches the
  latest `windows_amd64.zip` from
  [Icehunter/dune-admin](https://github.com/Icehunter/dune-admin/releases),
  extracts it, and auto-fills the path field with the resulting
  `dune-admin.exe`. The chosen folder is what gets saved as
  `DuneAdminExe` in `dune-server.config`.

### Changed

- Help text on the Dune Admin Tool page now points at the download
  button instead of asking the user to grab a release manually.
- **Status pane (top)** is now a non-interactive `TextBlock` inside a
  `ScrollViewer`. No more caret, no more accidental text selection -
  it's purely informational. Mouse-wheel scrolling still works.
- **Output pane (right)** stays a `TextBox` (still needed for
  `AppendText`/`ScrollToEnd`) but is now `Focusable=False`,
  `IsTabStop=False`, with `PreviewMouseLeftButtonDown` and
  `PreviewMouseRightButtonDown` swallowed so no caret or text
  selection ever appears. A new `Set-OutputInputMode` helper toggles
  the pane back to a normal text-entry box for future InApp commands
  that need to collect input from the user.

## [4.0.8] - 2026-05-24

Patch release: the installer now collects all configuration up-front so
new users land in a fully working app on first launch.

### Added

- **Installer config wizard.** Five new pages in `DuneServerSetup.exe`
  collect everything the app needs using native Windows directory and
  file pickers (Browse buttons):
  1. Dune Awakening server folder (the one containing
     `battlegroup-management`)
  2. SSH private key for the Hyper-V VM
  3. `dune-admin.exe` (optional - leave blank to hide the Dune Admin
     button until you set it later)
  4. Windows username (for launching dune-admin un-elevated)
  5. Port-verification mode (built-in / custom URL / disabled)
- All values are written to `%APPDATA%\DuneServer\dune-server.config`
  at install time, so the app launches fully configured - no more
  "SSH key not configured" message on first run.
- **Smart defaults.** Each page is pre-filled by auto-detecting common
  paths (Steam library, `%LOCALAPPDATA%\DuneAwakeningServer\sshKey`,
  `Desktop\dune-admin\`, current Windows username).
- **Legacy import.** If a previous `dune-server.config` is found on the
  Desktop / OneDrive / Documents, the installer offers to use those
  values as the defaults on the new pages (still editable).

### Changed

- The post-install legacy-config copy prompt has been replaced by the
  new wizard flow described above.
- If `%APPDATA%\DuneServer\dune-server.config` already exists, the
  installer skips all five config pages (upgrade path - never
  overwrites an existing config).

## [4.0.7] - 2026-05-24

Patch release: dune-admin web UI opens directly to the Players page.

### Changed

- The "Dune Admin" command now opens its web UI to the **Players** route
  (`https://dune-admin.layout.tools/#/players`) instead of the landing
  page, since that's the screen most users actually want when they
  invoke this command.

## [4.0.6] - 2026-05-24

Patch release: precise drop-position indicator and exact-position
insertion semantics for drag-to-reorder.

### Added

- **Insertion-line indicator** on drag-over: a bright cyan bar appears
  at the **top** of the target button if you're dragging into its upper
  half (drop *before*), or at the **bottom** if you're in its lower
  half (drop *after*). The line glows with the Eyes-of-Ibad halo so the
  drop position is unambiguous at a glance.

### Changed

- `Move-Command` now takes a `-Position` parameter (`before` / `after`)
  so the dragged button lands on the exact side of the target the
  insertion line was showing, instead of always landing above.
- Drop-target whole-button glow + scale-up (added in v4.0.5) is
  replaced by the more precise insertion-line indicator. No more layout
  shift, no more flicker between adjacent buttons.
- Insertion-line `Rectangle`s are baked into the `CmdButton` control
  template with `IsHitTestVisible="False"` so they overlay the button
  edges without disturbing drag hit-testing.

## [4.0.5] - 2026-05-24

Patch release: drag-and-drop visual feedback and human-friendly button
labels.

### Added

- **Drag-source ghost effect**: the button you pick up drops to 35%
  opacity for the duration of the drag, so you can clearly see which
  card you're moving.
- **Drop-target halo + scale**: when you drag over a valid target, that
  button lights up with a bright Eyes-of-Ibad cyan glow and scales up
  6% to make the destination unambiguous.

### Changed

- **Button labels now render in normal English Title Case** instead of
  the raw kebab-case command names. A new `Format-CmdLabel` helper
  expands hyphenated command names and preserves standard acronyms in
  uppercase (`VM`, `SSH`, `BG`, `URL`, `API`, `JSON`, etc.). Examples:
  - `initial-setup` → `Initial Setup`
  - `start-vm` → `Start VM`
  - `rotate-ssh-key` → `Rotate SSH Key`
  - `enable-experimental-swap` → `Enable Experimental Swap`
  - `dune-admin` → `Dune Admin`
  - `report-issue` → `Report an Issue`
  - `web` → `Web Portal`
  - The raw command name is still passed to `dune-server.ps1 -Cmd` and
    appears in tooltips / saved button order JSON; only the visible
    label changes.

## [4.0.4] - 2026-05-24

Patch release: simplified flat menu layout with drag-to-reorder, larger
button labels, and per-user button-order persistence.

### Added

- **Drag-to-reorder**: any command button can be dragged onto any other
  command button to swap positions. The new order is persisted to
  `%APPDATA%\DuneServer\button-order.json` and is restored on next launch.
  - Right-click any button → "Reset button order to default" to wipe the
    saved order and fall back to the catalog default.
  - If a future release adds new commands, they're appended to the end of
    the saved order automatically (no migration needed).

### Changed

- **Menu layout simplified to a flat 3-column grid** with no section
  headers and no hotkey letter/number badges. The numbered/lettered hotkey
  badge column has been removed from the `CmdButton` template entirely -
  buttons now show only the command name + description.
- **Larger, more legible button text**: command name bumped from 12.5pt to
  15pt SemiBold; description from 10.5pt to 11.5pt with brighter foreground
  (`#F5EFE0` / `#B8A88F`) for better contrast against the dark Dune palette.
- Button padding increased (14,10,10,10) for more breathing room around the
  larger text.
- Window default size: `1840x900` → `1640x900` (menu area shrunk from 980px
  to 820px since no badge column is needed). MinWidth: 1540 → 1340.
- Tooltips include "(Drag any button to reorder. Right-click for options.)"
  hint so the drag feature is discoverable.

### Notes

- Hotkey-based dispatch from the underlying `dune-server.ps1` CLI still
  works (the `Key` field is preserved internally and used by `-Cmd <name>`
  invocation); the badges were only ever a visual aid in the desktop app
  and are gone from the UI but not from the data model.

## [4.0.3] - 2026-05-24

Patch release: four-column section-based menu layout + Dune-movie-themed
futuristic button styling.

### Changed

- **Left-pane menu reorganized into four section-based columns** mirroring
  the layout of the original `dune-server.bat` menu where each section was a
  labeled block:
  - Column 1: **VM** commands (initial-setup, start-vm, startup, etc.)
  - Column 2: **Battlegroup** commands part 1 (status, start, restart, ...)
  - Column 3: **Battlegroup** commands part 2 (database, logs, shells, ...)
  - Column 4: **Tools** (ssh, dune-admin, setup-guide, report-issue)

  Battlegroup is split across two columns because it has 16+ commands - more
  than the other two sections combined. Each column gets its own HUD-style
  section header (◆ glyph + uppercase + spice-gold text + bronze underline).
  Window default size widened to 1840×900 (min 1540) to fit four columns
  without crowding the output pane on the right.
- **Button visual style overhauled with a Dune-movie aesthetic** matching the
  Dune Awakening self-hosted server page color story (spice gold + bronze +
  warm bone-white on stillsuit black):
  - Spice-gold vertical accent bar on the left of each button (`#FFD9A0` →
    `#C28840` → `#6A4818` gradient).
  - Bronze gradient border + sand-shadow background gradient.
  - Recessed badge area on the inner-left for the hotkey number in Consolas
    Bold spice-copper (`#E8B872`).
  - Top hairline bronze highlight + right-edge diamond status pip.
  - Hover: Eyes-of-Ibad cyan-blue halo glow (`#4FC3F7`, 26px blur) -
    cool-tone highlight that pops against the warm Dune palette.
  - Press: deeper Eyes-of-Ibad blue treatment (32px blur halo + full blue
    gradient border/bg + white accent + text + pip).
  - Disabled: muted dust palette throughout.
- **New `UtilButton` style** for header/footer utility buttons (Refresh,
  Copy, Clear) - same Dune palette and accent bar as `CmdButton` but with
  no number-badge column, since those buttons don't have a hotkey letter
  or number associated with them. Smaller halo (20px) to match their lower
  visual weight.
- **Main window background** changed from `#1E1E1E` to `#14110D` (warm
  stillsuit black) for better contrast against the new spice palette.

### Fixed

- Resolved a WPF `KeyNotFoundException: 'haloEffect'` that crashed the app
  at startup. Cause: cannot apply `Setter TargetName=` to a `Freezable`
  (e.g. `DropShadowEffect`) nested inside a templated element's property -
  the name is not registered in the template's name scope. Fix: name the
  parent `Border` instead, and have hover/press triggers replace the entire
  `Effect` property via `<Setter.Value><DropShadowEffect .../></Setter.Value>`.
- Fixed silent failure of the menu builder where Battlegroup and Tools
  columns were left empty. The earlier implementation used a `segments`
  array-of-arrays with `+= ,@(...)` accumulation pattern that interacted
  badly with the inner loop. Rewrote with explicit per-section loops and
  inline scriptblocks for `addHeader`/`addButton`, which makes the column
  population direct and unambiguous.

## [4.0.2] - 2026-05-24

Patch release: fix two more desktop app crashes/bugs discovered immediately
after the v4.0.1 ship, plus UI polish.

### Fixed

- **App crashed on first stdout line from any in-app command** (clicking
  any `InApp`-mode button — Status, start-vm, open-file-browser, etc. —
  killed the process within milliseconds). Cause: `Process.add_OutputDataReceived(
  {...})`, `add_ErrorDataReceived({...})`, and `add_Exited({...})` callbacks
  fire on .NET ThreadPool threads, which in ps2exe-compiled binaries have
  no PowerShell runspace TLS context. The first invocation of any of those
  scriptblock-as-delegate handlers threw an unhandled
  `System.Management.Automation.PSInvalidOperationException` at
  `ScriptBlock.GetContextFromTLS()` → `InvokeAsDelegateHelper(...)`.
  Rewrote `Invoke-Command-InApp` to use `Register-ObjectEvent` (action runs
  in the PowerShell engine event pump, which has a valid runspace) feeding
  a `System.Collections.Concurrent.ConcurrentQueue[hashtable]`, drained by
  a `DispatcherTimer` running on the UI thread (UI thread is the script's
  main thread, so its TLS is intact — Tick handlers are safe). Output lines,
  error lines, and the exit code are tagged in the queue and rendered in
  order. SourceIdentifiers are unique per invocation and unregistered on
  process exit so subscriptions don't leak.
- **Top status header showed "Loading cluster status..." forever and never
  updated.** Cause: the `DispatcherTimer.Tick` scriptblock inside
  `Refresh-StatusHeader` referenced function-scoped variables
  (`$asyncResult`, `$ps`, `$rs`, `$timer`, `$vmInfo`) but was not wrapped
  in `.GetNewClosure()`. By the time the tick fired (250 ms later, after
  `Refresh-StatusHeader` had returned), those locals were out of scope and
  resolved as `$null`, so `$asyncResult.IsCompleted` was always false and
  the timer polled forever. Wrapping the handler in `.GetNewClosure()` and
  assigning via a captured `$tickHandler` variable preserves the closure.

### Changed

- **Removed redundant "Status" button (Battlegroup key `1`) from the
  desktop app command catalog.** The top header panel already displays
  live battlegroup status with a 30-second auto-refresh and a manual
  Refresh button, so a duplicate button that dumped the same text into
  the output pane was just noise. The underlying `status` CLI command
  still exists in `dune-server.ps1` for the legacy `.bat` / web-portal
  entry points.
- **Status header pane is ~2 inches taller** (`Height` 140 → 332 WPF DIPs)
  so the full multi-pod battlegroup status output fits without scrolling.
- **Window default size bumped** from 780×1180 to 900×1180 to accommodate
  the taller header; `MinHeight` raised 520 → 700.
- **`CmdButton` style overhauled** for better visual feedback:
    - Drop-shadow effect for a raised "card" look.
    - Hover: 2 px amber (`#E0B341`) border + amber glow.
    - Press: 2 px white border on a VS-blue (`#0E639C`) background + blue glow.
    - Slightly more padding (`10,7`) and margin (`4,3`); corner radius 4 px.
- Version string bumped: `4.0.1 → 4.0.2`.

## [4.0.1] - 2026-05-24

Patch release: fix two desktop app (v4.0.0) regressions discovered immediately
after ship.

### Fixed

- **Battlegroup status header never populated** ("not fetching VM info"). The
  background `Start-Job` used to call `Get-VM` spawned a child `powershell.exe`
  that did not reliably inherit the parent's elevation token when the parent
  was a ps2exe-compiled binary, surfacing as `Microsoft.HyperV.PowerShell.VirtualizationException:
  "You do not have the required permission..."` inside the job (the job state
  was Completed, so the UI just showed the static "Loading cluster status..."
  placeholder). Refactored `Refresh-StatusHeader` in `app/DuneServer.ps1` to
  call `Get-VM` synchronously on the (already-elevated) UI thread — it's
  ~200 ms, the dispatcher stays responsive — and only the slow SSH
  `battlegroup status` call runs on a background runspace (in-process,
  inherits the parent's token automatically). Hyper-V module now also
  imported explicitly at app startup since ps2exe auto-discovery is unreliable.
- **`setup-guide`, `open-file-browser`, `open-director`, `web`, and `report-issue`
  crashed/no-opped from the desktop app.** All five used bare
  `Start-Process "https://..."` to open a URL in the default browser. The
  default-browser association lives in the per-user `HKCU\Software\Classes`
  hive, which is not visible to an elevated process running under the SYSTEM
  hive view; the call either silently does nothing or throws `"This command
  cannot be run due to the error: The system cannot find the file specified"`.
  Switched all five to launch via Explorer instead
  (`Start-Process "$env:SystemRoot\explorer.exe" $url`), which is the same
  trick the existing `dune-admin` handler was already using. This is the
  standard Windows workaround for opening per-user shell associations from
  an elevated process.

### Changed

- Version string bumped: `4.0.0 → 4.0.1` (`$script:ToolVersion`, footer
  text, installer `MyAppVersion`, `Build-Exe.ps1 -Version` default).

## [4.0.0] - 2026-05-24

Major release: native Windows desktop app as the new primary entry point.

The `.bat` launcher and web portal still ship (parallel options, no breakage),
but new users are pointed at `DuneServerSetup.exe` for a normal Windows
installer experience.

### Added

- **Desktop app (`app/DuneServer.ps1` → `DuneServer.exe` → `DuneServerSetup.exe`).**
  PowerShell + WPF host that frames every existing CLI command in a
  single window:
    - Sticky **battlegroup status** panel at the top, auto-refreshed every
      30 seconds via direct SSH (same path the web portal uses)
    - Left panel: every command from the CLI menu rendered as a labeled
      button, grouped by section (VM / Battlegroup / Tools); buttons
      grey out when their requirements aren't met (e.g. "VM not running")
    - Right panel: live-streaming output from whichever command was clicked
    - Footer status bar: current operation, exit codes, app version
  - **Two dispatch modes per command** (chosen automatically per command):
    - `InApp` — hidden child `pwsh` process, stdout/stderr captured into
      the output pane (no console window pops up). Used for plain text
      commands like `status`, `start-vm`, `open-file-browser`, etc.
    - `Console` — visible elevated `pwsh` window. Used for any command that
      needs interactive input (`Read-Host`), a TTY (`ssh -t`), or fancy
      console manipulation (spinners, screen clears). Buttons that open
      in a console are labeled `[console]` for transparency.
  - **Admin enforced at every layer:** installer requires admin (Program
    Files writes), `DuneServer.exe` carries an embedded UAC manifest
    (ps2exe `-requireAdmin`), and `dune-server.ps1` keeps its existing
    `#Requires -RunAsAdministrator`. One UAC prompt at app launch; no
    per-button prompts after that.
  - **PowerShell 7 prerequisite check at startup** — if `pwsh.exe` isn't
    installed, the app shows a friendly dialog with the download URL and
    `winget install --id Microsoft.PowerShell` snippet, then exits.

- **Inno Setup installer (`app/installer/DuneServer.iss` → `DuneServerSetup.exe`).**
  Standard Windows installer (~2 MB) with:
    - Install dir: `C:\Program Files\Dune Server\`
    - Start Menu shortcut (always) + optional desktop shortcut
    - Add/Remove Programs entry, clean uninstaller
    - **Legacy config auto-detection:** during install, scans common
      locations (Desktop, OneDrive subfolders) for an existing
      `dune-server.config` and offers to copy it to
      `%APPDATA%\DuneServer\` so the new app picks up your existing
      settings.
    - **User data preserved on uninstall** — the uninstaller removes the
      install dir but never touches `%APPDATA%\DuneServer\`.

- **Build pipeline** under `app/build/` and `app/installer/`:
    - `Build-Exe.ps1` — wraps ps2exe with all the right flags
      (`-noConsole`, `-requireAdmin`, `-STA`)
    - `Build-Installer.ps1` — wraps `ISCC.exe`, auto-detects ISCC
      across Program Files / `%LOCALAPPDATA%`, auto-runs `Build-Exe.ps1`
      first by default
    - `app/assets/Build-Icon.ps1` — regenerates the 6-resolution
      `icon.ico` via System.Drawing (no external tools)

### Changed

- **`dune-server.ps1` writable files moved to `%APPDATA%\DuneServer\`.**
  Needed so the script can run from a read-only install location
  (Program Files via the new installer). Affects:
    - `dune-server.config`
    - `.boot-times.json`
    - `.logs\dune-server-*.log` transcripts
  - Backward-compatible: on first run after upgrade, legacy files next
    to the script auto-migrate to `%APPDATA%\DuneServer\` (legacy copies
    are left in place as a rollback safety net).
  - Version string bumped: `3.1.2 → 4.0.0`.

- **`README.md`** — installer is now the primary recommended install
  path, with the `.bat` and web portal explicitly called out as classic
  / legacy options.

### Notes

- `dune-server.bat` and `web/Start-DuneWeb.ps1` are **unchanged** and
  remain fully supported. Anyone preferring those paths can keep using
  them; nothing about this release breaks the existing workflow.
- The compiled `DuneServer.exe` is unsigned for now — Windows SmartScreen
  will warn on first run ("Unknown publisher"). Click "More info" → "Run
  anyway". Code signing is a separate decision.

## [3.1.2] - 2026-05-24

Internal cleanup release. No user-facing functional changes from v3.0.1.

### Internal

- Code organization tidy-up in `dune-server.ps1` and
  `web/Start-DuneWeb.ps1`. Tool command keys settled at 17/18/19/20
  (`ssh`, `dune-admin`, `setup-guide`, `report-issue`).

## [3.0.1] - 2026-05-24

Patch release: better feedback during long boot waits, a real fix for the DB-pod readiness check that was silently lying about success, and a new menu option to power on the VM without touching battlegroup.

### Added

- **New menu option `c. start-vm`** (sits directly above `d. startup`). Powers on the
  Hyper-V VM and waits for it to acquire an IP, but does **not** run any battlegroup
  commands. Useful for maintenance, OS updates inside the VM, manual k3s pokes,
  or just bringing the host online without spinning up the game server. Pairs
  with the existing internal `stop-vm` handler. Shifts the menu keys: `startup`
  is now `d`, `shutdown` is `e`, `reboot` is `f`, `rotate-ssh-key` is `g`,
  `change-password` is `h`. The web portal mirrors the new key layout and gets
  its own **start-vm** row above **startup**.

### Fixed

- **`shutdown` and `reboot` no longer hang forever on a stuck VM power-off.**
  The old code issued `Stop-VM -Force` synchronously and then polled
  `Get-VM` until state hit `Off` with no timeout and no visible counter,
  so a guest that wouldn't respond to the integration-services shutdown
  signal (e.g. Linux kernel stuck, networking dead) would freeze the
  script silently. The new `Stop-VmWithEscalation` helper issues the
  graceful stop as a background job, renders a live MM:SS counter with
  the current VM state, and automatically escalates to a hard
  `Stop-VM -TurnOff` if the VM is still not `Off` after 90s. Absolute
  ceiling of 240s before giving up with an error (shutdown reports it;
  reboot aborts so it doesn't try to start a VM that didn't fully stop).
- **DB-pod discovery awk script no longer fails with "Unexpected token".**
  The awk one-liner used to print `namespace/podname` with `print $1"/"$2`,
  but PowerShell mangled the embedded `\"` inside the double-quoted ssh
  command string, so awk received broken syntax and matched zero pods
  (silent fallback: "No DB pods detected"). The awk now emits
  `namespace podname` space-separated and the PowerShell side splits on
  whitespace - no embedded double quotes to mangle.
- **All duration displays are now MM:SS.** Every elapsed-time and
  estimate value across `startup`, `reboot`, `shutdown` (the live wait
  counter, the "(last: ~Xs, avg ~Ys of last N)" estimate, the per-phase
  "ready in" lines, and the "complete in" summaries) renders via
  `Format-Duration` as MM:SS instead of raw seconds. So
  `Startup complete in 99s` is now `Startup complete in 01:39`, and
  `(last: ~99s, avg ~156s of last 2)` is now
  `(last: ~01:39, avg ~02:36 of last 2)`.
- **Background helpers are now cleaned up on crash.** When the script
  exits abnormally (unhandled exception, Ctrl+C, window close), any
  `Start-Job` helpers spawned by the new live wait counters are stopped
  and removed via a `PowerShell.Exiting` engine event plus a top-level
  `trap` in the main loop. Previously a mid-wait crash could leave an
  orphaned background pwsh process holding the SSH connection. The
  `dune-server.bat` wrapper also now reports the PowerShell exit code
  before pausing so the user can see what went wrong.
- **`shutdown` now tracks timings and shows estimates** like `startup` and
  `reboot` do. The shutdown handler was never instrumented in the v2.0.5
  boot-time-tracking work, so subsequent shutdowns showed no
  `(last: ~Xs)` hint and no total-time print at the end. Now records
  `pods-terminate`, `vm-stop`, and `total-shutdown` to `.boot-times.json`,
  shows the estimated total up front, prints the actual total at the end,
  and gets the live in-place elapsed counter during the pod-termination wait.
- **DB-pod readiness check no longer waits on the wrong pods.** The previous
  logic ran `kubectl wait --all -n <db-namespace>`, which would happily block
  on completed backup `Jobs` (`...-dump-...`), the file-browser deploy
  (`...-fb-...`), and any other unrelated pod that happened to live in the
  battlegroup namespace. The wait would time out at the full 180s and the
  script still printed a green "DB pods Ready" success line because the
  `kubectl wait` exit code was never checked. The check now targets pods by
  name pattern (`-db-`, `postgres`, `pg-` minus the obvious noise) and
  honors the exit code &mdash; success is reported truthfully, and a
  timeout warns and proceeds instead of pretending nothing happened.

### Changed

- **Live "elapsed" counters on every long boot wait.** During `startup` and
  `reboot`, each "Waiting for..." line now updates in place once per
  second, showing how long the current phase has been running as a
  **MM:SS** playback timer alongside the existing
  `(last: ~Xs, avg ~Ys of last N)` estimate from boot-time history.
  No more wondering whether the script is stuck. Applies to: SSH
  readiness, k3s API, DB pods, operator pods, webhook endpoints, and the
  reboot's pod-termination wait. The non-polling waits
  (`kubectl wait` calls) now run in a background job so the foreground can
  paint the counter.
- **Web portal layout**: each menu item is now a labeled row with a
  dedicated **Go** button on the right, instead of the entire row being a
  single clickable button. Easier to read, easier to click intentionally.
- **Web portal: new always-visible Battlegroup Status panel.** Pinned at the
  top of the page (above the VM / Battlegroup / Tools command sections),
  the panel shows the live output of the battlegroup `status` command
  (option `1` from the console menu) in a monospace block. It auto-polls
  every 30 seconds and has a manual **Refresh** button. The backend caches
  the SSH result for 25 seconds so multiple browser tabs / quick polls
  don't repeatedly hit the VM. When the VM is off, the panel shows the
  reason (e.g. `VM not running (state: Off).`) in amber instead of an
  error. Powered by a new `GET /api/bg-status` endpoint in
  `web/Start-DuneWeb.ps1`.

## [3.0.0] - 2026-05-24

Consolidation release. Supersedes all prior 2.x releases &mdash; the
2.0.0 through 2.0.6 GitHub Releases were rolled into this single 3.0.0
entry. From here on, patch releases follow as `3.0.1`, `3.0.2`, etc.

### Added

- **Localhost web UI** (`b. web` menu option). [Pode](https://github.com/Badgerati/Pode)-based
  server on `http://127.0.0.1:8765` with a button panel that mirrors the
  console menu. Each click POSTs to `/api/exec/{name}`, which spawns
  `dune-server.ps1 -Cmd <name>` in a new console window so interactive
  prompts (battlegroup picker, password entry, confirmations) keep working.
  Status panel polls every 5 seconds. Confirmation dialog on
  `reboot` and `shutdown`. Lives under `web/`
  &mdash; `Start-DuneWeb.ps1` + `public/{index.html,app.js,styles.css}`.
- **`-Cmd <name>` parameter** on `dune-server.ps1` for non-interactive
  dispatch. Skips the menu, looks up the command by name, runs the handler
  once, and exits. Used by the web UI; also handy for shortcuts and scripts.
- **`dune-admin` install offer during setup** (step 3). Prompts to either
  download the latest release from
  [`Icehunter/dune-admin`](https://github.com/Icehunter/dune-admin)
  to a directory you choose (default `%USERPROFILE%\Desktop\dune-admin`),
  use an existing local install, or skip. The chosen `dune-admin.exe`
  path is stored in `dune-server.config`; this repo does not bundle the
  binary.
- **SSH key auto-copy to `dune-admin` folder.** Setup seeds the
  `dune-admin` install dir with the freshest SSH key (compares
  `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` &mdash; where
  `rotate-ssh-key` writes &mdash; against the path stored in
  `dune-server.config` and picks whichever is newer). `f. rotate-ssh-key`
  also refreshes that copy so it stays in sync after a rotation.
- **Optional "Run as Administrator" desktop shortcut.** End-of-setup prompt
  drops a `Dune Server (Admin).lnk` on your desktop targeting
  `dune-server.bat` with the elevated-launch flag set in the `.lnk` binary.
- **Per-phase boot-time tracking** for `c. startup` and `e. reboot`.
  Each wait (VM start, IP acquisition, SSH, k3s API, DB pods, operator
  pods, webhook endpoints, battlegroup start, map pods, pod termination)
  is now timed and persisted to `.boot-times.json` (last 20 runs per
  phase). Before each wait, the tool prints a `(last: ~Xs, avg ~Ys of N)`
  hint based on prior runs so you know roughly how long to wait.
- **Total elapsed time** displayed at the end of both `c. startup`
  and `e. reboot`, with an estimate line based on prior runs.
- **`23. report-issue` menu option.** Opens a prefilled GitHub bug-report
  form in your browser (tool version + OS/PowerShell auto-filled). The
  issue template + `.github/ISSUE_TEMPLATE/config.yml` scope the tracker
  to bugs in this tool's code; VM/network/Hyper-V/Funcom-server
  questions are redirected to Discord via the "blank issue" config.

### Changed

- **Menu rename + reorder.** `graceful-shutdown` is now just `shutdown`
  (menu key `d`, directly under `c. startup`), and `graceful-reboot`
  is now just `reboot` (menu key `e`). Behavior is unchanged &mdash; same
  safety checks, same phases, same boot-time tracking. Headings and
  status messages updated accordingly (e.g. `=== Reboot complete in Xs ===`).
  Web UI mirrors the rename and reorder.

  **Breaking:** anyone driving the tool with `-Cmd graceful-shutdown` or
  `-Cmd graceful-reboot` must update to `-Cmd shutdown` / `-Cmd reboot`.
- **`c. startup` no longer prompts for confirmation.** The "Type YES to
  continue" gate after selecting startup was redundant; the user already
  chose to start the server by picking the menu option. Cold-start now
  runs immediately. Other destructive commands (`reboot`, `shutdown`,
  etc.) keep their confirmations.
- **VM section re-lettered sequentially** so it ends cleanly at
  `g. change-password` before the numbered Battlegroup commands:
  `a` initial-setup, `b` web, `c` startup, `d` shutdown,
  `e` reboot, `f` rotate-ssh-key, `g` change-password.

### Fixed

- **Web UI showed "Error fetching status" and rendered no command buttons.**
  Pode route scriptblocks run in isolated runspaces and can't see
  `$script:`-scoped variables defined at file scope. `Get-VmStatus` was
  calling `Get-VM -Name $null` (always returned NotFound), and the
  command-list routes iterated `$null`, returning `items: null`, which
  blew up the front-end. Refactored to publish shared state via
  `Set-PodeState` at server start and `Get-PodeState` inside the routes
  and helper functions. JSON arrays are also wrapped in `@(...)` so
  single-item lists don't get unrolled to scalars.
- **Interactive menu exited after a single command**, closing the console
  window on every selection. The dispatch loop's local `$cmd = $entry.Name`
  collided with the script's `$Cmd` parameter (PowerShell variables are
  case-insensitive), so the `if ($Cmd) { break }` at the bottom of the
  loop fired after every interactive command. Renamed the loop-local to
  `$cmdName` (using a case-sensitive replace, so the `if ($Cmd) { break }`
  guards survive intact). Web UI (`-Cmd` mode) is unaffected and still
  exits once per invocation via the `$cmdHasRun` flag.
- `-Cmd <name>` mode (used by every web UI button) would infinite-loop
  re-running the same command. Handlers use `continue` to skip the
  remaining loop body, which also skipped the bottom-of-loop `break`.
  Now gated at the top of the loop so exactly one handler runs per
  `-Cmd` invocation.
- `dune-server.bat` no longer pauses with "Press any key to continue"
  on a clean exit. The `pause` now only fires when the PowerShell script
  exits non-zero. Also forwards `%*` so `-Cmd <name>` works via the
  `.bat` too.
- Setup wizard is now wrapped in a top-level try/catch &mdash; failures
  print a readable error + stack trace and pause for Enter, instead of
  the console window vanishing.
- Port-check status in the menu header now refreshes after running any
  battlegroup CLI command (`1. status`, `2. start`, `3. restart`,
  `4. stop`). Previously the cached results were keyed only by public
  IP with no TTL, so the `[OPEN]` / `[CLOSED]` indicators would stick
  at their first observed values for the entire session.

### Removed

- `b. start-vm` and `c. stop-vm` menu entries. The graceful
  counterparts (`c. startup` cold-starts the full stack; `d. shutdown`
  stops battlegroup and powers off) cover everything they did without
  leaving pods in inconsistent state. The underlying handlers remain so
  existing automation calling them by name still works.

### Internal

- New helpers: `Install-DuneAdminLatest`, `Resolve-FreshSshKey`,
  `Copy-SshKeyToDir`, `New-DuneDesktopShortcut`, `Get-BootTimes`,
  `Format-PhaseEstimate`, `Save-PhaseTiming`.
- `web/` folder structure added.
- Boot-time history stored at `<scriptDir>\.boot-times.json` (rolling
  window of last 20 entries per phase).

[Unreleased]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.5.2...HEAD
[4.5.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.5.1...v4.5.2
[4.5.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.5.0...v4.5.1
[4.5.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.4.0...v4.5.0
[4.4.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.3.3...v4.4.0
[4.3.3]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.3.2...v4.3.3
[4.3.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.3.1...v4.3.2
[4.3.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.3.0...v4.3.1
[4.3.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.2.0...v4.3.0
[4.2.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.1.0...v4.2.0
[4.1.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.8...v4.1.0
[4.0.8]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.7...v4.0.8
[4.0.7]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.6...v4.0.7
[4.0.6]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.5...v4.0.6
[4.0.5]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.4...v4.0.5
[4.0.4]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.3...v4.0.4
[4.0.3]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.2...v4.0.3
[4.0.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.1...v4.0.2
[4.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.1.2...v4.0.0
[3.1.2]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.0.1...v3.1.2
[3.0.1]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/tag/v3.0.0
