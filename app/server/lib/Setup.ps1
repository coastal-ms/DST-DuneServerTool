# Setup — first-run preflight checks for the Setup Wizard.
#
# The wizard itself is a frontend-only state machine. The backend only owns:
#   - GET  /api/setup/preflight - environment checks (admin / Hyper-V / disk / OS)
#   - the existing POST /api/commands/run/initial-setup is used by Step 3.

function Get-DuneSetupPreflight {
    param(
        [ValidateSet('fresh','existing','lan')][string]$Mode = 'fresh'
    )
    $checks = [System.Collections.Generic.List[object]]::new()

    # 1. Administrator
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    $checks.Add(@{
        key      = 'admin'
        label    = 'Administrator privileges'
        ok       = [bool]$isAdmin
        severity = if ($isAdmin) { 'ok' } else { 'error' }
        detail   = if ($isAdmin) { 'Dune Server is running elevated.' } else { 'Hyper-V cmdlets require admin. Relaunch with elevation.' }
        fix      = if ($isAdmin) { $null } else { "Close the tool, then relaunch it elevated:`nStart-Process 'C:\Program Files\Dune Server\DuneServer.exe' -Verb RunAs" }
    }) | Out-Null

    # 2. Hyper-V module. Required in every mode — including 'lan', where DST needs
    #    the Hyper-V PowerShell module locally to manage the REMOTE host over
    #    -ComputerName. (The remote host's own reachability is checked separately
    #    on the Connect step via /api/setup/hyperv-lan/test, once the user has
    #    entered its IP.)
    $hvOk = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    $hvDetailOk = if ($Mode -eq 'lan') { 'Get-VM is available — DST can drive a remote Hyper-V host over the LAN.' } else { 'Get-VM cmdlet is available.' }
    $hvDetailNo = if ($Mode -eq 'lan') { 'Hyper-V PowerShell module not installed. It is required on THIS PC to manage a remote Hyper-V host. Enable it (or the Hyper-V Management Tools) via Windows Features.' } else { 'Hyper-V module not installed. Enable Hyper-V via Windows Features.' }
    $checks.Add(@{
        key      = 'hyperv'
        label    = 'Hyper-V PowerShell module'
        ok       = $hvOk
        severity = if ($hvOk) { 'ok' } else { 'error' }
        detail   = if ($hvOk) { $hvDetailOk } else { $hvDetailNo }
        fix      = if ($hvOk) { $null } else { "Run in an elevated PowerShell, then reboot when prompted:`nEnable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" }
    }) | Out-Null

    # 2b. OpenSSH client — DST shells out to ssh.exe for EVERY VM operation
    #     (status probes, server health, game data, key rotation). Missing on
    #     older Windows builds where the optional feature was never added. This
    #     is a hard DST prerequisite regardless of which setup path is chosen.
    $sshOk = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
    $checks.Add(@{
        key      = 'openssh'
        label    = 'OpenSSH client (ssh)'
        ok       = $sshOk
        severity = if ($sshOk) { 'ok' } else { 'error' }
        detail   = if ($sshOk) { 'ssh.exe is on PATH — DST can reach the VM.' } else { 'The OpenSSH client is required for DST to reach the server over SSH. Install the Windows "OpenSSH Client" optional feature.' }
        fix      = if ($sshOk) { $null } else { "Run in an elevated PowerShell:`nAdd-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" }
    }) | Out-Null

    # 3. Disk space (system drive)
    #    DST only checks what DST itself needs — the app plus room for logs and
    #    local DB backups/snapshots. It does NOT size the server VM here: on a
    #    fresh self-host install the user picks the VM's RAM during that flow and
    #    the install console reports if there isn't enough disk for the image.
    $DstDiskFloorGB = 5      # DST app + local backups headroom
    $reqGB = $DstDiskFloorGB
    $diskOk = $false
    $freeGB = 0
    $diskQueried = $false
    try {
        $sysDrive = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
                    Where-Object { $_.Name -eq ($env:SystemDrive[0]) } |
                    Select-Object -First 1
        if ($sysDrive) {
            $diskQueried = $true
            $freeGB = [math]::Round(($sysDrive.Free / 1GB), 1)
            $diskOk = ($freeGB -ge $reqGB)
        }
    } catch { }
    $diskDetail = if (-not $diskQueried) {
        'Could not query system drive.'
    } elseif ($diskOk) {
        "$freeGB GB free — enough for DST (app + local backups)."
    } else {
        "Only $freeGB GB free; DST needs ~$DstDiskFloorGB GB for the app and local backups."
    }
    $checks.Add(@{
        key      = 'disk'
        label    = 'Disk space (system drive)'
        ok       = $diskOk
        severity = if ($diskOk) { 'ok' } else { 'warning' }
        detail   = $diskDetail
        fix      = if ($diskOk) { $null } else { "Free up space, then re-run checks. Open Windows Disk Cleanup:`ncleanmgr" }
        freeGB   = $freeGB
    }) | Out-Null

    # 4. Operating system
    $osDesc = [System.Environment]::OSVersion.VersionString
    $checks.Add(@{
        key      = 'os'
        label    = 'Operating system'
        ok       = $true
        severity = 'info'
        detail   = $osDesc
    }) | Out-Null

    # 5. dune-server.config readability
    $cfgPath = Get-DuneConfigPath
    $cfgOk = (Test-Path -LiteralPath $cfgPath)
    $checks.Add(@{
        key      = 'config'
        label    = 'dune-server.config'
        ok       = $cfgOk
        severity = if ($cfgOk) { 'ok' } else { 'info' }
        detail   = if ($cfgOk) { "Found: $cfgPath" } else { "Will be created on first save: $cfgPath" }
    }) | Out-Null

    # 6. SSH key authorized on the VM
    #    Generating a new SSH key by hand (outside the tool) is the #1 reason the
    #    VM rejects the connection: the new key's public half was never added to
    #    dune@VM:~/.ssh/authorized_keys. We verify the *configured* key actually
    #    authenticates, and if not, hand back copy-paste steps to fix it.
    try {
        $cfg     = Read-DuneConfig
        $keyPath = $cfg.SshKey
        if (-not $keyPath) {
            $checks.Add(@{
                key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'info'
                detail = 'No SSH key configured yet — this is set during setup.'
            }) | Out-Null
        }
        elseif (-not (Test-Path -LiteralPath $keyPath)) {
            $checks.Add(@{
                key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'warning'
                detail = "Configured SSH key file not found: $keyPath. Set the correct path on the Settings page, or re-run setup. To make a brand-new key that is also authorized on the VM, use the tool's Rotate SSH Key action (VM menu, key 'g')."
            }) | Out-Null
        }
        else {
            $vm = Get-DuneVmStatus
            if (-not $vm.running -or -not $vm.ip) {
                $checks.Add(@{
                    key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'info'
                    detail = 'VM is not running yet, so the key cannot be verified. Re-run checks once the battlegroup is up.'
                }) | Out-Null
            }
            else {
                $ip = $vm.ip
                $probe  = ''
                $sshErr = ''
                try {
                    # Same hidden-window routing as the battlegroup status probe
                    # (Get-DuneBattlegroupSnapshot). The Settings/Setup wizard
                    # re-runs this check on each panel open + every preflight
                    # poll, so spawning a visible conhost per call is the most
                    # frequent flash source on the dashboard.
                    $r = Invoke-DuneSshHidden -Ip $ip -KeyPath $keyPath -TimeoutSec 10 -SshOptions @(
                        '-o','BatchMode=yes'
                        '-o','StrictHostKeyChecking=no'
                        '-o','LogLevel=ERROR'
                        '-o','ConnectTimeout=6'
                        '-o','PreferredAuthentications=publickey'
                    ) -RemoteCommand 'echo dune-ok'
                    $probe  = ($r.Stdout -join "`n")
                    $sshErr = $r.Stderr
                } catch { }

                if ($probe -match 'dune-ok') {
                    $checks.Add(@{
                        key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $true; severity = 'ok'
                        detail = "Authenticated to dune@$ip with $keyPath."
                    }) | Out-Null
                }
                elseif ($sshErr -match 'Permission denied|no supported methods|authentication fail|publickey') {
                    $pubPath = "$keyPath.pub"
                    if ((Test-DuneSshKeyEncrypted -KeyPath $keyPath) -eq $true) {
                        $checks.Add(@{
                            key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'warning'
                            detail = "This SSH key is passphrase-protected, so the tool can't use it for background checks (battlegroup status, server health, game data) — those run non-interactively and can't answer a passphrase prompt. An interactive SSH terminal still works because it can prompt you, which is why the VM looks reachable while the dashboard shows Unknown. Fix it in Settings - SSH key with the 'Remove passphrase' button (keeps this same key, no VM changes), or rotate to a passphrase-less key with the Rotate SSH Key action (VM menu, key 'g')."
                            fix    = "Remove the passphrase from the existing key (press Enter when asked for the new passphrase to leave it empty):`nssh-keygen -p -f `"$keyPath`""
                        }) | Out-Null
                    }
                    else {
                        $checks.Add(@{
                            key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'warning'
                            detail = "The VM rejected this key (its public half isn't in dune@${ip}:~/.ssh/authorized_keys). This usually means a new key was generated outside the tool. Fix it one of two ways: (A) generate a properly-authorized key with the tool's Rotate SSH Key action (VM menu, key 'g'), or (B) if another key already has working SSH access, authorize this one with the command below."
                            fix    = "Run from a machine that already has working SSH access (replace <working-key>):`ntype `"$pubPath`" | ssh -i `"<working-key>`" dune@$ip `"cat >> ~/.ssh/authorized_keys`""
                        }) | Out-Null
                    }
                }
                else {
                    $checks.Add(@{
                        key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'info'
                        detail = "Couldn't reach the VM over SSH at ${ip}:22 — it may still be booting. Re-run checks once the battlegroup is up." + $(if ($sshErr) { " (ssh: $($sshErr.Trim()))" } else { '' })
                    }) | Out-Null
                }
            }
        }
    } catch {
        $checks.Add(@{
            key = 'sshkey'; label = 'SSH key authorized on VM'; ok = $false; severity = 'info'
            detail = "Could not run the SSH key check: $($_.Exception.Message)"
        }) | Out-Null
    }

    $errors   = @($checks | Where-Object { $_.severity -eq 'error' })
    $warnings = @($checks | Where-Object { $_.severity -eq 'warning' })

    return @{
        ok          = ($errors.Count -eq 0)
        checks      = @($checks)
        errorCount  = $errors.Count
        warningCount= $warnings.Count
    }
}

function Get-DuneSetupConfigSummary {
    $cfg = Read-DuneConfig
    return @{
        windowsUser   = $cfg.WindowsUser
        sshKey        = $cfg.SshKey
        sshKeyExists  = ($cfg.SshKey -and (Test-Path -LiteralPath $cfg.SshKey))
        steamPath     = $cfg.SteamPath
        portCheckMode = $cfg.PortCheckMode
        vmName        = 'dune-awakening'
        sshPort       = 22
    }
}
