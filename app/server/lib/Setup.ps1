# Setup — first-run preflight checks for the Setup Wizard.
#
# The wizard itself is a frontend-only state machine. The backend only owns:
#   - GET  /api/setup/preflight - environment checks (admin / Hyper-V / disk / OS)
#   - the existing POST /api/commands/run/initial-setup is used by Step 3.

function Get-DuneSetupPreflight {
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

    # 2. Hyper-V module
    $hvOk = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    $checks.Add(@{
        key      = 'hyperv'
        label    = 'Hyper-V PowerShell module'
        ok       = $hvOk
        severity = if ($hvOk) { 'ok' } else { 'error' }
        detail   = if ($hvOk) { 'Get-VM cmdlet is available.' } else { 'Hyper-V module not installed. Enable Hyper-V via Windows Features.' }
        fix      = if ($hvOk) { $null } else { "Run in an elevated PowerShell, then reboot when prompted:`nEnable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" }
    }) | Out-Null

    # 3. Disk space (system drive)
    $diskOk = $false
    $diskDetail = 'Could not query system drive.'
    $freeGB = 0
    try {
        $sysDrive = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
                    Where-Object { $_.Name -eq ($env:SystemDrive[0]) } |
                    Select-Object -First 1
        if ($sysDrive) {
            $freeGB = [math]::Round(($sysDrive.Free / 1GB), 1)
            $diskOk = ($freeGB -ge 60)
            $diskDetail = if ($diskOk) {
                "$freeGB GB free on system drive (recommend 60+ GB)."
            } else {
                "Only $freeGB GB free; battlegroup VM needs ~60 GB."
            }
        }
    } catch { }
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
                $errFile = [System.IO.Path]::GetTempFileName()
                $probe = ''
                try {
                    $probe = (& ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR `
                                -o ConnectTimeout=6 -o PreferredAuthentications=publickey `
                                -i $keyPath "dune@$ip" 'echo dune-ok' 2>$errFile) -join "`n"
                } catch { }
                $sshErr = if (Test-Path $errFile) { (Get-Content -Raw -ErrorAction SilentlyContinue $errFile) } else { '' }
                Remove-Item $errFile -ErrorAction SilentlyContinue

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
                            detail = "This SSH key is passphrase-protected, so the tool can't use it for background checks (battlegroup status, server health, game data) — those run non-interactively and can't answer a passphrase prompt. An interactive SSH terminal still works because it can prompt you, which is why the VM looks reachable while the dashboard shows Unknown. Fix it with the Rotate SSH Key action (VM menu, key 'g') to generate a passphrase-less key, or strip the passphrase from this one."
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
