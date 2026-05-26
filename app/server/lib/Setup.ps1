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
    }) | Out-Null

    # 2. Hyper-V module
    $hvOk = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    $checks.Add(@{
        key      = 'hyperv'
        label    = 'Hyper-V PowerShell module'
        ok       = $hvOk
        severity = if ($hvOk) { 'ok' } else { 'error' }
        detail   = if ($hvOk) { 'Get-VM cmdlet is available.' } else { 'Hyper-V module not installed. Enable Hyper-V via Windows Features.' }
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
