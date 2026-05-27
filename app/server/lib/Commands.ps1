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

# ---- Layout (v6.1.10+) -------------------------------------------------------
#
# The Commands page now models three sections as ordered arrays of command
# names, plus a parallel array of user-renamable section labels. This replaces
# the old "order + catalogue-default + overrides" model, which had a subtle
# bug where dragging a command across sections could snap back on the next
# server refresh because the override layer and order layer disagreed.
#
# On-disk shape (button-order.json):
#   {
#     "version": 3,
#     "sectionNames": ["VM", "Battlegroup", "Tools"],
#     "sections":     [["startup", "...", ...], [...], [...]]
#   }
#
# A missing or corrupt file falls back to Get-DuneDefaultCommandLayout — which
# distributes the catalogue across three sections with startup commands first,
# shutdown commands next, and the remainder alphabetically.

function Get-DuneDefaultCommandLayout {
    $priority = @{
        'start'    = 0; 'start-vm'   = 0; 'startup' = 0
        'reboot'   = 1; 'shutdown'   = 1; 'stop'    = 1
    }
    $sorted = @(
        $script:DuneCommands |
            ForEach-Object {
                $p = if ($priority.ContainsKey($_.Name)) { $priority[$_.Name] } else { 2 }
                [pscustomobject]@{ Name = $_.Name; Priority = $p }
            } |
            Sort-Object Priority, Name |
            Select-Object -ExpandProperty Name
    )

    # Sequential top-left → bottom-right fill across 3 sections.
    $total = $sorted.Count
    $per   = [Math]::Max(1, [Math]::Ceiling($total / 3.0))
    $sections = @(@(), @(), @())
    for ($i = 0; $i -lt $total; $i++) {
        $idx = [Math]::Min(2, [Math]::Floor($i / $per))
        $sections[$idx] += $sorted[$i]
    }
    return @{
        sectionNames = @('VM','Battlegroup','Tools')
        sections     = $sections
    }
}

function Get-DuneCommandLayout {
    $f = Get-DuneCommandOrderFile
    $default = Get-DuneDefaultCommandLayout
    if (-not (Test-Path $f)) { return $default }

    try {
        $parsed = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        if ($null -eq $parsed) { return $default }

        # v6.1.10+ shape: { version: 3, sectionNames: [...], sections: [[],[],[]] }
        if ($parsed.PSObject.Properties['sections'] -and $parsed.sections -is [array] -and $parsed.sections.Count -ge 1) {
            # Names — pad / trim to exactly 3, fall back to defaults if missing.
            $defaultNames = @('VM','Battlegroup','Tools')
            $rawNames = if ($parsed.PSObject.Properties['sectionNames']) { @($parsed.sectionNames | ForEach-Object { "$_" }) } else { @() }
            $names = @()
            for ($i = 0; $i -lt 3; $i++) {
                $n = if ($i -lt $rawNames.Count) { $rawNames[$i] } else { $defaultNames[$i] }
                $n = "$n".Trim()
                if ($n.Length -eq 0) { $n = $defaultNames[$i] }
                if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
                $names += $n
            }

            # Sections — pad / trim to exactly 3 arrays. Drop unknown commands
            # and de-dupe across all three (a command may only live in one
            # section at a time).
            $catalogSet = @{}
            foreach ($c in $script:DuneCommands) { $catalogSet[$c.Name] = $true }
            $sections = @(@(), @(), @())
            $seen     = @{}
            for ($i = 0; $i -lt 3; $i++) {
                $arr = if ($i -lt $parsed.sections.Count) { @($parsed.sections[$i]) } else { @() }
                $kept = @()
                foreach ($n in $arr) {
                    $s = "$n"
                    if ($catalogSet.ContainsKey($s) -and -not $seen.ContainsKey($s)) {
                        $kept += $s
                        $seen[$s] = $true
                    }
                }
                $sections[$i] = $kept
            }

            # Catalogue entries not yet placed anywhere (e.g. new commands
            # introduced after the layout was saved) land in section 0 so
            # they're always visible.
            foreach ($c in $script:DuneCommands) {
                if (-not $seen.ContainsKey($c.Name)) {
                    $sections[0] += $c.Name
                    $seen[$c.Name] = $true
                }
            }

            return @{ sectionNames = $names; sections = $sections }
        }

        # Legacy shapes (v6.1 bare array, v6.1.9 {order, sections{}}) — ignore
        # the old data and start fresh. Users who haven't touched layout get
        # the new default; users who had a custom order lose it once, but the
        # new model is qualitatively different so a clean slate is correct.
        return $default
    } catch {
        return $default
    }
}

function Save-DuneCommandLayout {
    param(
        [Parameter(Mandatory)][string[]]$SectionNames,
        [Parameter(Mandatory)][array]$Sections
    )

    if ($SectionNames.Count -ne 3) { throw "Expected exactly 3 section names, got $($SectionNames.Count)" }
    if ($Sections.Count     -ne 3) { throw "Expected exactly 3 sections, got $($Sections.Count)" }

    # Sanitize section names — trim, fall back to defaults, cap length.
    $defaultNames = @('VM','Battlegroup','Tools')
    $cleanNames = @()
    for ($i = 0; $i -lt 3; $i++) {
        $n = "$($SectionNames[$i])".Trim()
        if ($n.Length -eq 0)  { $n = $defaultNames[$i] }
        if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
        $cleanNames += $n
    }

    # Sanitize sections — only catalogue commands, globally unique.
    $catalogSet = @{}
    foreach ($c in $script:DuneCommands) { $catalogSet[$c.Name] = $true }
    $cleanSections = @(@(), @(), @())
    $seen = @{}
    for ($i = 0; $i -lt 3; $i++) {
        $arr = @($Sections[$i])
        foreach ($n in $arr) {
            $s = "$n"
            if ($catalogSet.ContainsKey($s) -and -not $seen.ContainsKey($s)) {
                $cleanSections[$i] += $s
                $seen[$s] = $true
            }
        }
    }
    # Any catalogue command not represented in the incoming payload still has
    # to live somewhere — park it in section 0 so it's discoverable.
    foreach ($c in $script:DuneCommands) {
        if (-not $seen.ContainsKey($c.Name)) {
            $cleanSections[0] += $c.Name
            $seen[$c.Name] = $true
        }
    }

    $f = Get-DuneCommandOrderFile
    $dir = Split-Path -Parent $f
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $obj = [ordered]@{
        version      = 3
        sectionNames = $cleanNames
        sections     = @(
            ,([object[]]$cleanSections[0])
            ,([object[]]$cleanSections[1])
            ,([object[]]$cleanSections[2])
        )
    }
    $payload = $obj | ConvertTo-Json -Depth 4 -Compress:$false
    Set-Content -LiteralPath $f -Value $payload -Encoding UTF8
}

function Reset-DuneCommandLayout {
    $f = Get-DuneCommandOrderFile
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
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
