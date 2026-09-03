# Dune Server desktop app (`app/`)

Native Windows desktop app (PowerShell + WPF, compiled with ps2exe, packaged
with Inno Setup) that wraps the existing `dune-server.ps1` business logic in
a single window with point-and-click buttons instead of the menu-driven CLI.

This is the **v4.0.0+** entry point. The `dune-server.bat` launcher remains
available as a parallel option for users who prefer the CLI.

## What the app gives you

- **Sticky status header** at the top — battlegroup status auto-refreshed
  every 30 seconds via direct SSH
- **Left panel** — every command from the CLI menu as a labeled button,
  grouped by section (VM / Battlegroup / Tools); disabled buttons grey out
  when their requirements aren't met (e.g. "VM not running")
- **Right panel** — embedded xterm.js terminal driven by a real ConPTY
  (Pty.Net + WebView2). Every command runs here, including interactive
  ones (`ssh`, `shell-vm`, `shell-pod`, `edit`, `change-password`, Y/N
  prompts) — no popup PowerShell windows
- **Footer status bar** — current operation, version, exit codes

## Where things live

| Item                     | Path                                                       |
| ------------------------ | ---------------------------------------------------------- |
| Install dir              | `C:\Program Files\Dune Server\`                            |
| Config / logs / state    | `%APPDATA%\DuneServer\`                                    |
| Start Menu shortcut      | `Start > Dune Server > Dune Server`                        |
| Desktop shortcut         | (optional - chosen during install)                         |
| Add/Remove Programs      | "Dune Server 4.0.0"                                        |

Uninstalling removes the install dir but **never touches `%APPDATA%\DuneServer\`**
— your config and logs are preserved if you ever reinstall.

## Admin privileges

Required at every layer (Hyper-V cmdlets need it):

1. The installer itself runs elevated (`PrivilegesRequired=admin` in the .iss)
2. `DuneServer.exe` has an embedded UAC manifest (ps2exe `-requireAdmin`) —
   one UAC prompt at app launch, no per-button prompts after that
3. `dune-server.ps1` keeps `#Requires -RunAsAdministrator` at line 1 — child
   `pwsh` processes inherit elevation from the parent .exe

## Building the installer (developer use only)

End users don't need any of this — they just download `DuneServerSetup.exe`
from GitHub Releases and double-click. The build process is for releasing
new versions.

### One-time setup

```powershell
# 1. PowerShell 7 (host needs it too)
winget install --id Microsoft.PowerShell

# 2. ps2exe (compiles .ps1 -> .exe)
Install-Module ps2exe -Scope CurrentUser

# 3. Inno Setup 6 (builds the installer)
winget install --id JRSoftware.InnoSetup
```

### Building

```powershell
# Build the .exe only:
.\app\build\Build-Exe.ps1

# Build the installer (auto-runs Build-Exe.ps1 first):
.\app\installer\Build-Installer.ps1

# Skip the .exe rebuild if it's already current:
.\app\installer\Build-Installer.ps1 -SkipExeBuild
```

Outputs:
- `app\build\output\DuneServer.exe`        (~80 KB)
- `app\installer\output\DuneServerSetup.exe` (~2 MB)

### Releasing a new version

1. Keep the version stamps synchronized in `dune-server.ps1`,
   `app\DuneServer.ps1`, `app\build\Build-Exe.ps1`,
   `app\desktop\DuneShell\DuneShell.csproj`, and
   `app\installer\DuneServer.iss`.
2. Add the dated CHANGELOG entry and refresh the bug-report template.
3. Build the clean PR candidate locally, copy
   `DuneServerSetup.exe` to the primary checkout's canonical output path, and
   wait for live acceptance before merging.
4. After acceptance, merge the release change, then create and push an annotated
   tag at that exact merge commit:
   ```powershell
   git tag -a vX.Y.Z -m "vX.Y.Z: ..."
   git push origin vX.Y.Z
   ```
5. From a clean checkout of that tag, build the final installer locally with the
   exact 40-character commit, tag, and prerelease metadata. Copy it to the
   canonical output path and verify the embedded identity.
6. After the separate final publish gate, create the new release directly with
   the verified canonical installer as its sole asset.
7. Verify the published release has exactly one `DuneServerSetup.exe` asset.

The **Build & sign installer** Actions workflow is optional and must be used only
when explicitly requested. It never replaces the local pre-merge acceptance
build or becomes the default publication path. Existing release assets are never
uploaded again or replaced; publish a new version/tag for every correction.

## Regenerating the icon

```powershell
.\app\assets\Build-Icon.ps1
```

Generates a 6-resolution multi-size `.ico` from scratch via System.Drawing
(no external tools needed). Output goes to `app\assets\icon.ico`.

## File layout

```
app/
├── README.md                 (this file)
├── DuneServer.ps1            ← main app (compiled to DuneServer.exe via ps2exe)
├── assets/
│   ├── icon.ico              (shipped)
│   └── Build-Icon.ps1        (regen)
├── build/
│   ├── Build-Exe.ps1
│   └── output/               (gitignored)
│       └── DuneServer.exe
└── installer/
    ├── DuneServer.iss        (Inno Setup script)
    ├── Build-Installer.ps1
    └── output/               (gitignored)
        └── DuneServerSetup.exe
```

## Known limitations / future work

- **Unsigned** — Windows SmartScreen will warn on first install ("Unknown
  publisher"). User needs to click "More info" → "Run anyway". Code signing
  costs ~$80/yr; deferred.
- **AV false positives** — ps2exe-compiled binaries are sometimes flagged
  by aggressive AV. Whitelisting may be required.
- **Manual build** — no CI workflow yet. Add `.github/workflows/build-installer.yml`
  later to auto-build on tag push.
- **No auto-update** — Inno Setup supports it; not wired yet. Update path
  for now is download new installer + run it (in-place upgrades supported).
