# Friend — runs on your friend's PC

This is the half of the friend helper that ships **to your friend**. It's
a single self-contained Windows .exe with one tiny `config.json` next to it.
Double-click to launch.

## What it does

1. Reads `config.json` (in the same folder as the .exe).
2. Probes `http://<bridgeHost>:<bridgePort>/_dst/token` over Tailscale
   with a 5s timeout. If unreachable → friendly dialog, no stack trace.
3. On success, parses `{url, token}` and navigates an embedded WebView2
   window to the bridge URL with the token in the query string.
4. The bridge reverse-proxies into the current DST portal on Neil's
   loopback. You see exactly what Neil sees in his portal.

## What the friend needs

- **Windows 10/11 x64**
- **Microsoft Edge WebView2 Runtime** (most systems already have it; if
  not, helper shows a dialog with the install link).
- **Tailscale** signed in to the same tailnet as Neil's PC.
- The shipped `DSTConsole.exe` and `config.json`.

That's it. No .NET install required (self-contained publish bundles the
runtime), no admin rights required (manifest is `asInvoker`).

## Setup steps (give these to the friend)

1. Install Tailscale: <https://tailscale.com/download/windows>
2. Sign in with the account Neil added you to.
3. Drop `DSTConsole.exe` and `config.json` into any folder
   (e.g. `Documents\DstHelper`).
4. Open `config.json` in Notepad and set `bridgeHost` to the Tailscale
   hostname Neil sent you (something like `neilpc.tailXXXX.ts.net`).
5. Double-click `DSTConsole.exe`. Neil's portal opens in the
   window.

## Building from source (Neil side)

```powershell
# from the repo root
.\helper\friend\Build-DstConsole.ps1
```

This produces `helper\friend\dist\DSTConsole.exe` (+ a stub
`config.json`) as a self-contained single-file win-x64 publish. Hand
both files to the friend.

### Toolchain

The project file targets **`net8.0-windows`** with WPF. The .NET 10
SDK installed on Neil's machine cross-targets net8.0 fine — NuGet
auto-resolves the WindowsDesktop reference pack on first build. If
your environment can't reach that pack (offline / mirror), change the
`<TargetFramework>` in `DSTConsole.csproj` to `net10.0-windows`
and rebuild; the source compiles unchanged.

### Code-signing

The unsigned single-file .exe will trigger SmartScreen on the friend's
first launch (Windows defender + EV cert reputation kicks in over
time). For real-world distribution you'd code-sign with the same EV
cert used for `DuneServerSetup.exe` releases — out of scope for the
scaffold.

## Why WPF + WebView2 specifically (not ps2exe / Electron / Tauri)

- **Defender / SmartScreen FP avoidance.** The DST v11.0.1–v11.0.3
  saga showed that ANY binary that performs a base64-decode-then-pipe-
  to-cmdline (the classic ps2exe pattern) gets flagged as
  `Trojan:Win32/Wacatac.B!ml`. WPF is a normal compiled .NET app; the
  reputation curve is much friendlier.
- **No 100 MB Chromium download.** WebView2 reuses the system Edge
  installation (or auto-installs the lightweight Evergreen runtime
  once). Final .exe ≈ 90 MB (most of which is the self-contained
  .NET runtime).
- **First-party Microsoft stack.** Friend's antivirus is much less
  likely to quarantine a signed Microsoft WebView2 host than a
  random Electron build.

## Files

| File                      | Role                                              |
| ------------------------- | ------------------------------------------------- |
| `DSTConsole.csproj`       | WPF + WebView2 project, single-file publish.      |
| `app.manifest`            | `asInvoker` execution level.                      |
| `App.xaml` / `.xaml.cs`   | WPF application entry.                            |
| `MainWindow.xaml` / `.cs` | Window with WebView2 + status overlay.            |
| `Config.cs`               | `config.json` loader.                             |
| `config.sample.json`      | Template the build script copies as `config.json`.|
| `Build-DstConsole.ps1`    | `dotnet publish` wrapper.                         |
