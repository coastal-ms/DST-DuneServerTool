# Linux support — status

> **DST now runs on Linux.** The PowerShell backend runs under `pwsh`, the
> portal is served to your browser or a **native GTK window**, the Hyper-V layer
> is replaced by **libvirt/KVM** (or an SSH-reachable host), autostart uses
> **systemd**, and the build ships a **.deb**. Every change is OS-guarded, so the
> Windows build is unaffected — Windows and Linux run the same code.

This replaces the original "untested scaffold" handoff. What follows is the
current state, what's verified, and the few things that still need validation on
real hardware.

## How it runs

Same architecture as Windows: a PowerShell backend (`System.Net.HttpListener`)
hosts the React SPA on `127.0.0.1` with a per-launch tokenized URL. On Linux:

| Concern              | Windows                       | Linux                                            |
|----------------------|-------------------------------|--------------------------------------------------|
| Runtime              | ps2exe + `pwsh.exe`           | `pwsh` (PowerShell 7)                             |
| Entry point          | `app/DuneServer.ps1`          | `app/DuneServer-Linux.ps1` (via `bin/dune-server`)|
| UI surface           | WebView2 (`DuneShell.exe`)    | **GTK3 + WebKit2GTK** (`app/desktop/linux/dune-shell.py`), browser fallback |
| Server VM            | Hyper-V (`Get-VM`, `Start/Stop-VM`) | **libvirt/KVM** (`virsh`), or an SSH host via `ServerHost` |
| Host facts           | `Win32_ComputerSystem`        | `/proc/meminfo`                                  |
| Autostart            | Task Scheduler (`--headless`) | **systemd `--user`** unit                        |
| Config / state dirs  | `%APPDATA%` / `%LOCALAPPDATA%`| XDG (`~/.config`, `~/.local/state`) via env shim |
| In-app update        | Downloads `DuneServerSetup.exe` | Reports the `apt` upgrade path                 |

The cross-platform seam is `app/server/lib/Platform.ps1` (OS predicates) and
`app/server/lib/VmProvider.ps1` (the VM abstraction). Every Windows code path is
preserved verbatim behind `if (Test-DuneIsWindows) { … }`.

## Deployment models on Linux

The Dune dedicated server is Linux/k3s software. On Linux you have two ways to
let DST reach it:

1. **Local libvirt/KVM VM** — DST manages a KVM guest exactly like it manages a
   Hyper-V VM on Windows (power on/off, read IP/RAM via `virsh`). Install
   `libvirt-daemon-system libvirt-clients qemu-system-x86` and add yourself to
   the `libvirt` group. The VM name comes from `VmName` in `dune-server.config`
   (default `dune-awakening`); the libvirt URI from `LibvirtUri`
   (default `qemu:///system`).
2. **Existing / remote host over SSH** — set `ServerHost` in
   `dune-server.config` to an IP or hostname and DST skips VM discovery
   entirely, managing that host purely over SSH + kubectl. No local hypervisor
   needed. Good for a remote box or native k3s.

## Verified on Linux (Ubuntu 26.04, pwsh 7.6.3)

- All 84 backend `.ps1` files + the CLI parse clean under `pwsh`.
- The backend boots end-to-end: `bin/dune-server` binds `127.0.0.1`, serves the
  portal (HTTP 200 on `/`, the tokened URL, and `/api/status`), and the **API
  handler pool initializes** (2..16 runspaces) — concurrent requests succeed.
- `VmProvider` Linux paths: host RAM from `/proc/meminfo`; `virsh`
  domstate/domifaddr/dominfo parsers validated against real `virsh` output; the
  `ServerHost` static-override path; clean, actionable errors when `virsh` is
  absent.
- Setup-wizard preflight reports libvirt/KVM, the `libvirt` group, `/dev/kvm`,
  SSH, and disk correctly on Linux.
- systemd autostart: `available` is true when `systemctl` is present; the user
  unit is generated correctly; enable/disable wired to `systemctl --user`.
- The GTK shell compiles, its widgets construct (GTK3 + WebKit2GTK 4.1), and its
  URL/keep-alive helpers behave.
- `scripts/linux-smoke.ps1` (parse + dot-source the whole backend) passes; CI
  runs it on every PR (`.github/workflows/linux-smoke.yml`).

## Not yet validated on real hardware

- **libvirt VM power flows** (`Start-DuneVm`/`Stop-DuneVm` and the CLI's
  start/stop/restart with the live counter): implemented against `virsh`
  (`start` / graceful `shutdown` → forced `destroy`), but not exercised against
  a live KVM domain. Search the code for `[Linux path: UNTESTED]`.
- End-to-end battlegroup management over SSH against a real Dune server VM.
- The GTK shell against a live portal session on a desktop (rendered offscreen
  in CI only).

## Install / run

### From source

```bash
sudo apt install powershell openssh-client xdg-utils nodejs npm \
                 python3-gi gir1.2-webkit2-4.1 gir1.2-gtk-3.0
# optional, for a local KVM server VM:
sudo apt install libvirt-daemon-system libvirt-clients qemu-system-x86
sudo usermod -aG libvirt "$USER"   # then re-login

cd webui && npm ci && npm run build && cd ..
./bin/dune-server
```

### From a .deb (Debian / Ubuntu)

```bash
./packaging/linux/build-deb.sh
sudo apt install ./packaging/linux/output/dune-server_<version>_all.deb
dune-server
```

### Autostart at login

Toggle **Help → Run at startup** in the UI, or:

```bash
systemctl --user enable --now dune-server.service
journalctl --user -u dune-server.service -f
```

## Notes for maintainers

- Version is kept in lock-step across Windows and Linux: `Build-Installer.ps1`'s
  version gate now checks `DuneServer-Linux.ps1` and `packaging/linux/debian/control`
  too (7 stamps total).
- The XDG env-var shim (`DuneServer-Linux.ps1`) is deliberate: it lets the ~46
  `Join-Path $env:APPDATA 'DuneServer'` call sites resolve correctly on Linux
  without a risky 46-site refactor. New code should prefer
  `Get-DuneConfigDir` / `Get-DuneStateDir` from `Platform.ps1`.
