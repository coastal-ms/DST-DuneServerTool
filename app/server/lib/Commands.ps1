# Commands — catalogue of actions the Dune Server tool can dispatch.
# Mirrors $script:Commands from app/DuneServer.ps1 (v6.0.x WPF), preserved
# verbatim so v6.1's web UI keeps the exact same command set + key bindings.
#
# Each entry:
#   Section      - 'VM' | 'Battlegroup' | 'Tools' | 'Separator'
#   Key          - shortcut (CLI carryover)
#   Name         - canonical id; matches the bat command (dune-server.bat <Name>)
#   Mode         - 'InApp' (capture stdout) | 'Console' (visible elevated)
#   Requires     - 'none' | 'exists' | 'running'
#   DisabledWhen - optional state predicate
#   Desc         - human description (shown in tooltip / card)
#   IsSeparator  - true for the 4 draggable visual dividers

$script:DuneCommands = @(
    @{ Section='VM'; Key='a';  Name='initial-setup';   Mode='Console'; Requires='none';    DisabledWhen='core-pods-running'; Desc='Run the initial VM setup wizard' }
    @{ Section='VM'; Key='c';  Name='start-vm';        Mode='InApp';   Requires='exists';  DisabledWhen='vm-running';  Desc='Power on the VM only (no battlegroup)' }
    @{ Section='VM'; Key='d';  Name='startup';         Mode='Console'; Requires='exists';  DisabledWhen='bg-running';  Desc='Power on VM, start battlegroup, wait for maps Ready' }
    @{ Section='VM'; Key='e';  Name='shutdown';        Mode='Console'; Requires='running'; Desc='Stop battlegroup, power off VM' }
    @{ Section='VM'; Key='f';  Name='reboot';          Mode='Console'; Requires='running'; Desc='Stop battlegroup, reboot VM, start battlegroup' }
    @{ Section='VM'; Key='g';  Name='rotate-ssh-key';  Mode='Console'; Requires='running'; Desc='Generate a new SSH key and authorize it on the VM' }
    @{ Section='VM'; Key='h';  Name='change-password'; Mode='Console'; Requires='running'; Desc="Change the password of the 'dune' user on the VM" }

    @{ Section='Battlegroup'; Key='2';  Name='start';                    Mode='Console'; Requires='running'; DisabledWhen='bg-running';  Desc='Start the selected battlegroup' }
    @{ Section='Battlegroup'; Key='3';  Name='restart';                  Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Restart the selected battlegroup' }
    @{ Section='Battlegroup'; Key='4';  Name='stop';                     Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Stop the selected battlegroup' }
    @{ Section='Battlegroup'; Key='5';  Name='update';                   Mode='Console'; Requires='running'; Desc='Check for new versions and apply them' }
    @{ Section='Battlegroup'; Key='6';  Name='edit';                     Mode='Console'; Requires='running'; External=$true; Desc='Edit battlegroup via utilities interface' }
    @{ Section='Battlegroup'; Key='7';  Name='edit-advanced';            Mode='Console'; Requires='running'; External=$true; Desc='(Advanced) Edit battlegroup YAML directly' }
    @{ Section='Battlegroup'; Key='8';  Name='enable-experimental-swap'; Mode='Console'; Requires='running'; Desc='(Experimental) Enable experimental swap memory' }
    @{ Section='Battlegroup'; Key='9';  Name='backup';                   Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc="Back up the battlegroup's database" }
    @{ Section='Battlegroup'; Key='10'; Name='import';                   Mode='Console'; Requires='running'; DisabledWhen='bg-running';  Desc='Import a database backup' }
    @{ Section='Battlegroup'; Key='11'; Name='logs-export';              Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Retrieve logs from all battlegroup pods' }
    @{ Section='Battlegroup'; Key='12'; Name='operator-logs-export';     Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Retrieve logs from all operator pods' }
    @{ Section='Battlegroup'; Key='13'; Name='open-file-browser';        Mode='InApp';   Requires='running'; DisabledWhen='bg-stopped';  Desc='Open battlegroup file browser in your browser' }
    @{ Section='Battlegroup'; Key='14'; Name='open-director';            Mode='InApp';   Requires='running'; DisabledWhen='bg-stopped';  Desc='Open battlegroup director page in your browser' }
    @{ Section='Battlegroup'; Key='15'; Name='shell-vm';                 Mode='Console'; Requires='running'; Desc='Open a shell to the VM' }
    @{ Section='Battlegroup'; Key='16'; Name='shell-pod';                Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Open a shell to a pod' }

    @{ Section='Tools'; Key='17'; Name='ssh';         Mode='Console'; Requires='running'; Desc='Open an SSH terminal to the VM' }
    @{ Section='Tools'; Key='18'; Name='dune-admin';  Mode='InApp';   Requires='running'; Desc='Launch dune-admin + open its web UI' }
    @{ Section='Tools'; Key='19'; Name='setup-guide'; Mode='InApp';   Requires='none';    Desc='Open Funcom self-hosted setup guide' }
)

# ---- Availability ------------------------------------------------------------

function Get-DuneCommandAvailability {
    param(
        [Parameter(Mandatory)][hashtable]$Command,
        [Parameter(Mandatory)][hashtable]$State
    )
    # State: @{ vmExists; vmRunning; bgState ('running'|'stopped'|'unknown'|...) }
    $available = switch ($Command.Requires) {
        'none'    { $true }
        'exists'  { [bool]$State.vmExists }
        'running' { [bool]$State.vmRunning }
        default   { $true }
    }
    $reason = ''
    if (-not $available) {
        $reason = switch ($Command.Requires) {
            'exists'  { "VM '$script:DuneVmName' not found" }
            'running' { "VM is not running" }
            default   { 'unavailable' }
        }
    }

    # Optional DisabledWhen overrides above
    if ($available -and $Command.DisabledWhen) {
        switch ($Command.DisabledWhen) {
            'vm-running' {
                if ($State.vmRunning) { $available = $false; $reason = 'VM already running' }
            }
            'bg-running' {
                if ($State.bgState -eq 'running') { $available = $false; $reason = 'Battlegroup already running' }
            }
            'bg-stopped' {
                if ($State.bgState -eq 'stopped') { $available = $false; $reason = 'Battlegroup is stopped' }
            }
            'core-pods-running' {
                if ($State.bgState -eq 'running') { $available = $false; $reason = 'Core pods running' }
            }
        }
    }
    return @{ available = $available; reason = $reason }
}

function Get-DuneCurrentState {
    $vm = Get-DuneVmStatus
    $bgState = 'unknown'
    if ($vm.running) {
        try {
            $bg = Get-DuneBattlegroupSnapshot
            if ($bg.available -and $bg.state) { $bgState = $bg.state }
            elseif (-not $bg.available)       { $bgState = 'unknown' }
        } catch {}
    }
    return @{
        vmExists  = [bool]$vm.exists
        vmRunning = [bool]$vm.running
        bgState   = $bgState
        vm        = $vm
    }
}

# ---- Order persistence -------------------------------------------------------

function Get-DuneCommandOrderFile {
    # Prefer APPDATA canonical location (matches Get-DuneConfigPath / v6.0
    # convention). Falls back to repo-root .dune\ for dev runs from source.
    $appdataDir = Join-Path $env:APPDATA 'DuneServer'
    $appdataFile = Join-Path $appdataDir 'button-order.json'
    if (Test-Path -LiteralPath $appdataFile) { return $appdataFile }

    # Dev fallback — repo root or installed app dir
    $root = if ($script:AppDir) { Split-Path -Parent $script:AppDir } else { (Get-Location).Path }
    $devDir = Join-Path $root '.dune'
    $devFile = Join-Path $devDir 'button-order.json'
    if (Test-Path -LiteralPath $devFile) { return $devFile }

    # Neither exists — default to APPDATA so future Save-DuneCommandOrder writes
    # land in the canonical location.
    if (-not (Test-Path -LiteralPath $appdataDir)) {
        New-Item -ItemType Directory -Path $appdataDir -Force | Out-Null
    }
    return $appdataFile
}

function Get-DuneCommandOrder {
    $f = Get-DuneCommandOrderFile
    if (-not (Test-Path $f)) { return @() }
    try {
        $parsed = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        # Accept both shapes:
        #   v6.0 WPF: { "order": [ "name1", "name2", ... ] }   (object wrapper)
        #   v6.1+:   [ "name1", "name2", ... ]                 (bare array)
        if ($parsed -is [array]) { return @($parsed | ForEach-Object { "$_" }) }
        if ($parsed.PSObject.Properties['order']) {
            return @($parsed.order | ForEach-Object { "$_" })
        }
        return @()
    } catch { return @() }
}

function Save-DuneCommandOrder {
    param([string[]]$Order)
    $f = Get-DuneCommandOrderFile
    $dir = Split-Path -Parent $f
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Write as a bare JSON array — Get-DuneCommandOrder also accepts the
    # legacy v6.0 { "order": [...] } shape for compatibility.
    $payload = if ($Order -and $Order.Count -gt 0) {
        ConvertTo-Json -InputObject ([object[]]$Order) -Depth 2
    } else { '[]' }
    Set-Content -LiteralPath $f -Value $payload -Encoding UTF8
}

function Get-DuneCommandByName {
    param([string]$Name)
    foreach ($c in $script:DuneCommands) {
        if ($c.Name -eq $Name) { return $c }
    }
    return $null
}

# Launch a command in a new visible console window (elevated).
# Uses pwsh -File <dune-server.ps1> -Cmd <name>, the same entry point the WPF
# UI used for external commands. Phase 4 will route InApp commands through the
# embedded terminal instead; for now everything opens a console window.
function Invoke-DuneCommandExternal {
    param([string]$Name)
    if (-not $script:PwshExe -or -not $script:MainScript) {
        throw "Command execution not configured (pwsh.exe or dune-server.ps1 missing)."
    }
    $cmd = Get-DuneCommandByName -Name $Name
    if (-not $cmd) { throw "Unknown command: $Name" }

    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy','Bypass'
        '-File',"`"$script:MainScript`""
        '-Cmd',$cmd.Name
    )
    $startArgs = @{
        FilePath         = $script:PwshExe
        ArgumentList     = $argList
        WorkingDirectory = (Split-Path -Parent $script:MainScript)
        WindowStyle      = 'Normal'
        Verb             = 'RunAs'   # dune-server.ps1 requires admin
        PassThru         = $true
    }
    $proc = Start-Process @startArgs
    return @{
        ok      = $true
        name    = $cmd.Name
        mode    = $cmd.Mode
        pid     = if ($proc) { $proc.Id } else { $null }
        started = (Get-Date).ToString('o')
    }
}
