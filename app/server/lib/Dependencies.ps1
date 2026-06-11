# Dependencies — generic optional third-party tool detection + install offer.
#
# No optional backend toolchains are currently registered. Keep this scaffold so
# future native DST features can ask for third-party tools without rebuilding the
# route/winget plumbing.

function Get-DstDependencyRegistry {
    return @()
}

# Look up a single dependency definition by name (case-insensitive). Returns
# $null if the name isn't a known/allowlisted dependency — the install route
# uses this as a security gate so only registry tools can ever be installed.
function Get-DstDependencyDef {
    param([string]$Name)
    if (-not $Name) { return $null }
    return (Get-DstDependencyRegistry | Where-Object { $_.name -ieq $Name.Trim() } | Select-Object -First 1)
}

# Resolve a dependency's executable path: PATH first (Get-Command), then the
# standard install locations. Returns the full exe path or $null.
function Resolve-DstDependencyPath {
    param([pscustomobject]$Dep)
    $cmd = Get-Command $Dep.command -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach ($c in $Dep.candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($c)
        if ($expanded -and (Test-Path -LiteralPath $expanded)) { return $expanded }
    }
    return $null
}

# Public state for one dependency: { name, display, command, wingetId, reason,
# found, path }.
function Get-DstDependencyState {
    param([pscustomobject]$Dep)
    $path = Resolve-DstDependencyPath -Dep $Dep
    return [pscustomobject]@{
        name     = $Dep.name
        display  = $Dep.display
        command  = $Dep.command
        wingetId = $Dep.wingetId
        reason   = $Dep.reason
        found    = [bool]$path
        path     = $path
    }
}

# State for a set of dependency names (defaults to all). Unknown names are
# skipped. Used by GET /api/system/dependencies.
function Get-DstDependenciesState {
    param([string[]]$Names)
    $reg = Get-DstDependencyRegistry
    if ($Names -and $Names.Count -gt 0) {
        $wanted = $Names | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
        $reg = $reg | Where-Object { $wanted -contains $_.name }
    }
    return @($reg | ForEach-Object { Get-DstDependencyState -Dep $_ })
}

# Is winget itself available? The install offer is meaningless without it.
function Test-DstWingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# --- Detached winget install + status file -----------------------------------
# winget install can take a minute+ (download + MSI). The PowerShell HttpListener
# processes one request at a time on the main thread, so we must NOT block on it
# (that froze the whole server during the Go-build work). Instead we launch a
# detached pwsh wrapper that runs winget, tees output to a log, and writes a JSON
# status file per dependency. The UI polls GET /api/system/dependencies/install-status.

function Get-DstDependencyStateDir {
    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer\dep-install'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}

function Get-DstDependencyStatusPath {
    param([string]$Name)
    $safe = ($Name -replace '[^A-Za-z0-9._-]','_')
    return (Join-Path (Get-DstDependencyStateDir) "install-$safe.json")
}

function Read-DstDependencyInstallStatus {
    param([string]$Name)
    $path = Get-DstDependencyStatusPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Write-DstDependencyInstallStatus {
    param([string]$Name, [hashtable]$Data)
    $path = Get-DstDependencyStatusPath -Name $Name
    try {
        $json = $Data | ConvertTo-Json -Depth 6 -Compress
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    } catch { }
}

# Launch a detached `winget install` for a registry dependency. Returns a
# pscustomobject { ok, status, logFile, statusFile, pid } or { ok=$false, error }.
function Start-DstDependencyInstall {
    param([string]$Name)

    $dep = Get-DstDependencyDef -Name $Name
    if (-not $dep) {
        return [pscustomobject]@{ ok = $false; error = "Unknown dependency '$Name'. No optional dependency installers are registered." }
    }

    # Already present? Report success without launching winget.
    $existing = Resolve-DstDependencyPath -Dep $dep
    if ($existing) {
        Write-DstDependencyInstallStatus -Name $dep.name -Data @{
            status   = 'success'
            name     = $dep.name
            display  = $dep.display
            wingetId = $dep.wingetId
            note     = 'Already installed.'
            path     = $existing
            finishedAt = (Get-Date).ToString('o')
        }
        return [pscustomobject]@{ ok = $true; status = 'success'; alreadyInstalled = $true; path = $existing; statusFile = (Get-DstDependencyStatusPath -Name $dep.name) }
    }

    if (-not (Test-DstWingetAvailable)) {
        $msg = "winget (the Windows Package Manager) was not found on this machine, so DST can't install $($dep.display) automatically. Install it manually — run in an elevated terminal: winget install --id $($dep.wingetId) -e — or update App Installer from the Microsoft Store, then try again."
        Write-DstDependencyInstallStatus -Name $dep.name -Data @{
            status     = 'failed'
            name       = $dep.name
            display    = $dep.display
            wingetId   = $dep.wingetId
            error      = $msg
            finishedAt = (Get-Date).ToString('o')
        }
        return [pscustomobject]@{ ok = $false; status = 'failed'; error = $msg }
    }

    $stateDir   = Get-DstDependencyStateDir
    $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile    = Join-Path $stateDir "install-$($dep.name)-$stamp.log"
    $wrapper    = Join-Path $stateDir "install-$($dep.name)-$stamp.ps1"
    $statusPath = Get-DstDependencyStatusPath -Name $dep.name

    # Kill a still-running previous install of the SAME dependency so repeated
    # clicks get a clean slate.
    $prev = Read-DstDependencyInstallStatus -Name $dep.name
    if ($prev -and $prev.PSObject.Properties.Name -contains 'status' -and $prev.status -eq 'running' -and
        $prev.PSObject.Properties.Name -contains 'pid' -and $prev.pid) {
        try {
            $p = Get-Process -Id ([int]$prev.pid) -ErrorAction SilentlyContinue
            if ($p) { Stop-Process -Id ([int]$prev.pid) -Force -ErrorAction SilentlyContinue }
        } catch { }
    }

    $wrapperBody = @"
`$ErrorActionPreference = 'Continue'
`$statusPath = '$statusPath'
`$logFile    = '$logFile'

function Write-Status {
    param([hashtable]`$Data)
    try {
        `$json = `$Data | ConvertTo-Json -Depth 6 -Compress
        Set-Content -LiteralPath `$statusPath -Value `$json -Encoding UTF8
    } catch { }
}

`$startedAt = (Get-Date).ToString('o')
Write-Status @{
    status    = 'running'
    name      = '$($dep.name)'
    display   = '$($dep.display)'
    wingetId  = '$($dep.wingetId)'
    logFile   = `$logFile
    startedAt = `$startedAt
    pid       = `$PID
}

try {
    # --scope machine: DST runs elevated, so install for all users and land the
    # tool on the system PATH + standard install dir. --disable-interactivity so
    # winget never waits on a prompt in the hidden window. We accept agreements
    # non-interactively.
    & winget install --id '$($dep.wingetId)' -e --scope machine --accept-source-agreements --accept-package-agreements --disable-interactivity *> `$logFile
    `$code = `$LASTEXITCODE
    if (`$null -eq `$code) { `$code = 0 }
    # Some packages reject machine scope; retry without it (user scope) so the
    # install still succeeds rather than hard-failing.
    if (`$code -ne 0) {
        Add-Content -LiteralPath `$logFile -Value "``r``n[wrapper] machine-scope install exited `$code; retrying without --scope...``r``n"
        & winget install --id '$($dep.wingetId)' -e --accept-source-agreements --accept-package-agreements --disable-interactivity *>> `$logFile
        `$code = `$LASTEXITCODE
        if (`$null -eq `$code) { `$code = 0 }
    }
} catch {
    `$code = 1
    try { Add-Content -LiteralPath `$logFile -Value "``r``n[wrapper] winget threw: `$(`$_.Exception.Message)``r``n" } catch { }
}

`$finished = (Get-Date).ToString('o')
# winget exit code 0 = installed; other non-zero may still mean "already
# installed / no applicable upgrade". Treat success as exit 0 here; the UI
# re-probes the tool path to confirm regardless.
if (`$code -eq 0) {
    Write-Status @{
        status     = 'success'
        name       = '$($dep.name)'
        display    = '$($dep.display)'
        wingetId   = '$($dep.wingetId)'
        logFile    = `$logFile
        startedAt  = `$startedAt
        finishedAt = `$finished
        exitCode   = `$code
        pid        = `$PID
    }
    exit 0
} else {
    Write-Status @{
        status     = 'failed'
        name       = '$($dep.name)'
        display    = '$($dep.display)'
        wingetId   = '$($dep.wingetId)'
        logFile    = `$logFile
        startedAt  = `$startedAt
        finishedAt = `$finished
        exitCode   = `$code
        error      = "winget install exited with code `$code (see log)."
        pid        = `$PID
    }
    exit `$code
}
"@
    Set-Content -LiteralPath $wrapper -Value $wrapperBody -Encoding UTF8

    Write-DstDependencyInstallStatus -Name $dep.name -Data @{
        status    = 'running'
        name      = $dep.name
        display   = $dep.display
        wingetId  = $dep.wingetId
        logFile   = $logFile
        startedAt = (Get-Date).ToString('o')
    }

    try {
        $shell = $null
        foreach ($candidate in @('pwsh', 'powershell')) {
            $c = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($c) { $shell = $c.Source; break }
        }
        if (-not $shell) { throw 'Neither pwsh nor powershell found on PATH' }

        $proc = Start-Process -FilePath $shell `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$wrapper`"") `
            -WindowStyle Hidden -PassThru
        $bgPid = if ($proc) { $proc.Id } else { 0 }
        if ($proc) { try { $proc.Dispose() } catch { } }
        return [pscustomobject]@{
            ok         = $true
            status     = 'running'
            name       = $dep.name
            display    = $dep.display
            wingetId   = $dep.wingetId
            logFile    = $logFile
            statusFile = $statusPath
            pid        = $bgPid
            startedAt  = (Get-Date).ToString('o')
        }
    } catch {
        $err = $_.Exception.Message
        Write-DstDependencyInstallStatus -Name $dep.name -Data @{
            status     = 'failed'
            name       = $dep.name
            display    = $dep.display
            wingetId   = $dep.wingetId
            logFile    = $logFile
            startedAt  = (Get-Date).ToString('o')
            finishedAt = (Get-Date).ToString('o')
            error      = "Failed to launch winget: $err"
        }
        return [pscustomobject]@{ ok = $false; status = 'failed'; error = "Failed to launch winget: $err" }
    }
}
