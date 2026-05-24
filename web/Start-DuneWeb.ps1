#Requires -Version 7.0

<#
.SYNOPSIS
    Localhost web UI for the Dune Awakening Server Management Tool.

.DESCRIPTION
    Mirrors the dune-server.ps1 console menu as a button panel served at
    http://127.0.0.1:8765. Each button POSTs to /api/exec/{name}, which
    spawns dune-server.ps1 -Cmd <name> in a new console window so any
    interactive prompts (battlegroup picker, password entry, confirms)
    still work.

    No authentication. Binds 127.0.0.1 only.
#>

[CmdletBinding()]
param(
    [int]$Port = 8765
)

Import-Module Pode -ErrorAction Stop

$script:Root       = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:MainScript = Join-Path $script:Root 'dune-server.ps1'
$script:ConfigFile = Join-Path $script:Root 'dune-server.config'
$script:VmName     = 'dune-awakening'

function Read-Config {
    $cfgFile = (Get-PodeState -Name 'ConfigFile')
    $cfg = @{}
    if ($cfgFile -and (Test-Path $cfgFile)) {
        Get-Content $cfgFile | ForEach-Object {
            if ($_ -match '^([^#=]+)=(.*)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }
    return $cfg
}

function Get-VmStatus {
    $vmName = (Get-PodeState -Name 'VmName')
    try {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $ip = ($vm | Get-VMNetworkAdapter).IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
              Select-Object -First 1
        return @{
            exists  = $true
            state   = $vm.State.ToString()
            running = ($vm.State -eq 'Running')
            ip      = $ip
        }
    } catch {
        return @{ exists = $false; state = 'NotFound'; running = $false; ip = $null }
    }
}

# Commands exposed in the web UI. Mirrors $vmCommands / $bgCommands /
# $toolCommands in dune-server.ps1. Keep in sync when adding new menu items.
$script:VmCommands = @(
    @{ key='a'; name='initial-setup';     desc='Run the initial VM setup';                                                requires='none' }
    # 'b' (web) intentionally omitted from the web UI itself; remaining keys
    # are re-sequenced so the displayed list has no gap.
    @{ key='b'; name='start-vm';          desc='Power on VM only (no battlegroup commands)';                              requires='exists' }
    @{ key='c'; name='startup';           desc='Power on VM, start battlegroup, wait for overmap + survival maps';        requires='exists' }
    @{ key='d'; name='shutdown';          desc='Stop battlegroup, power off VM';                                          requires='running'; confirm=$true }
    @{ key='e'; name='reboot';            desc='Stop battlegroup, restart VM, start battlegroup (clean cycle)';           requires='running'; confirm=$true }
    @{ key='f'; name='rotate-ssh-key';    desc='Generate a new SSH key and replace the authorized one on the VM';        requires='running' }
    @{ key='g'; name='change-password';   desc="Change the password of the 'dune' user on the VM";                        requires='running' }
)

$script:BgCommands = @(
    @{ key='1';  name='status';                    desc='Status of the selected battlegroup';                  sub=$null }
    @{ key='2';  name='start';                     desc='Start the selected battlegroup';                      sub=$null }
    @{ key='3';  name='restart';                   desc='Restart the selected battlegroup';                    sub=$null }
    @{ key='4';  name='stop';                      desc='Stop the selected battlegroup';                       sub=$null }
    @{ key='5';  name='update';                    desc='Check for new versions and apply them';               sub=$null }
    @{ key='6';  name='edit';                      desc='Edit battlegroup via utilities interface';            sub=$null }
    @{ key='7';  name='edit-advanced';             desc='(Advanced) Edit battlegroup YAML directly';           sub=$null }
    @{ key='8';  name='enable-experimental-swap'; desc='(Experimental) Enable experimental swap memory';      sub=$null }
    @{ key='9';  name='backup';                    desc="Back up the battlegroup's database";                  sub='Database' }
    @{ key='10'; name='import';                    desc='Import a database backup';                            sub='Database' }
    @{ key='11'; name='logs-export';               desc='Retrieve logs from all pods in the battlegroup';      sub='Logs' }
    @{ key='12'; name='operator-logs-export';      desc='Retrieve logs from all operator pods';                sub='Logs' }
    @{ key='13'; name='open-file-browser';         desc='Open battlegroup file browser (configs/logs)';        sub='Monitoring' }
    @{ key='14'; name='open-director';             desc='Open battlegroup director page';                      sub='Monitoring' }
    @{ key='15'; name='shell-vm';                  desc='Open a shell to the VM';                              sub='Monitoring' }
    @{ key='16'; name='shell-pod';                 desc='Open a shell to a pod in the battlegroup';            sub='Monitoring' }
)

function Get-ToolCommandList {
    $cfg = Read-Config
    $list = @(
        @{ key='17'; name='ssh';         desc='Open an SSH terminal to the VM';                       requires='running' }
    )
    if ($cfg.DuneAdminExe -and (Test-Path $cfg.DuneAdminExe)) {
        $list += @{ key='18'; name='dune-admin';  desc='Launch dune-admin.exe + open dune-admin web UI'; requires='running' }
    }
    $list += @{ key='19'; name='setup-guide';  desc='Open Funcom Self-Hosted Server Setup Instructions'; requires='none' }
    $list += @{ key='20'; name='report-issue'; desc='Report a bug in this tool (opens prefilled GitHub issue)'; requires='none' }
    return $list
}

function Resolve-Available {
    param([hashtable]$cmd, [hashtable]$vm)
    switch ($cmd.requires) {
        'none'    { return $true }
        'exists'  { return [bool]$vm.exists }
        'running' { return [bool]$vm.running }
        default   { return [bool]$vm.running }
    }
}

# Runs the battlegroup `status` command on the VM and returns the captured
# text. Cached in Pode state for 25s so multiple browser tabs / quick polls
# don't repeatedly hammer SSH. Pass -Fresh to bypass the cache (used by the
# manual "Refresh" button in the UI).
function Get-BattlegroupStatus {
    param([switch]$Fresh)

    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if (-not $Fresh) {
        $cached = Get-PodeState -Name 'BgStatusCache'
        if ($cached -and ($now - [int]$cached.fetched) -lt 25) {
            return $cached
        }
    }

    $vm = Get-VmStatus
    if (-not $vm.running) {
        return @{
            available = $false
            reason    = "VM not running (state: $($vm.state))."
            fetched   = $now
            timestamp = (Get-Date).ToString('s')
        }
    }

    $cfg    = Read-Config
    $sshKey = $cfg.SshKey
    if (-not $sshKey -or -not (Test-Path $sshKey)) {
        return @{
            available = $false
            reason    = "SSH key not configured or missing: $sshKey"
            fetched   = $now
            timestamp = (Get-Date).ToString('s')
        }
    }
    if (-not $vm.ip) {
        return @{
            available = $false
            reason    = 'VM is running but has no IP yet.'
            fetched   = $now
            timestamp = (Get-Date).ToString('s')
        }
    }

    $bgBinPath = '/home/dune/.dune/bin/battlegroup'
    $result = $null
    try {
        $raw = & ssh `
            -o StrictHostKeyChecking=no `
            -o LogLevel=QUIET `
            -o ConnectTimeout=10 `
            -o BatchMode=yes `
            -i $sshKey "dune@$($vm.ip)" "$bgBinPath status" 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($raw | Out-String).TrimEnd()
        # Strip ANSI escape sequences in case battlegroup emits color codes
        # without a TTY (it shouldn't, but be defensive).
        $text = $text -replace "`e\[[0-9;]*[A-Za-z]", ''
        $result = @{
            available = $true
            exitCode  = $exitCode
            output    = $text
            fetched   = $now
            timestamp = (Get-Date).ToString('s')
        }
    } catch {
        $result = @{
            available = $false
            reason    = "SSH error: $($_.Exception.Message)"
            fetched   = $now
            timestamp = (Get-Date).ToString('s')
        }
    }

    Set-PodeState -Name 'BgStatusCache' -Value $result | Out-Null
    return $result
}

Start-PodeServer {
    # Publish shared state for the route runspaces (they can't see $script:* vars).
    Set-PodeState -Name 'Root'        -Value $script:Root       | Out-Null
    Set-PodeState -Name 'MainScript'  -Value $script:MainScript | Out-Null
    Set-PodeState -Name 'ConfigFile'  -Value $script:ConfigFile | Out-Null
    Set-PodeState -Name 'VmName'      -Value $script:VmName     | Out-Null
    Set-PodeState -Name 'VmCommands'  -Value $script:VmCommands | Out-Null
    Set-PodeState -Name 'BgCommands'  -Value $script:BgCommands | Out-Null

    Add-PodeEndpoint -Address 127.0.0.1 -Port $Port -Protocol Http

    Add-PodeStaticRoute -Path '/' -Source (Join-Path $script:Root 'web\public') -Defaults @('index.html')

    Add-PodeRoute -Method Get -Path '/api/status' -ScriptBlock {
        $vm = Get-VmStatus
        Write-PodeJsonResponse -Value @{
            vm        = $vm
            timestamp = (Get-Date).ToString('s')
        }
    }

    Add-PodeRoute -Method Get -Path '/api/bg-status' -ScriptBlock {
        $fresh = ($WebEvent.Query['fresh'] -eq '1')
        if ($fresh) { $r = Get-BattlegroupStatus -Fresh }
        else        { $r = Get-BattlegroupStatus }
        Write-PodeJsonResponse -Value $r
    }

    Add-PodeRoute -Method Get -Path '/api/commands' -ScriptBlock {
        $vm = Get-VmStatus
        $sections = @()

        $vmList = foreach ($c in (Get-PodeState -Name 'VmCommands')) {
            @{ key=$c.key; name=$c.name; desc=$c.desc; available=(Resolve-Available -cmd $c -vm $vm); confirm=([bool]$c.confirm) }
        }
        $sections += @{ name='VM';          items=@($vmList) }

        $bgList = foreach ($c in (Get-PodeState -Name 'BgCommands')) {
            @{ key=$c.key; name=$c.name; desc=$c.desc; sub=$c.sub; available=[bool]$vm.running; confirm=$false }
        }
        $sections += @{ name='Battlegroup'; items=@($bgList) }

        $toolList = foreach ($c in (Get-ToolCommandList)) {
            @{ key=$c.key; name=$c.name; desc=$c.desc; available=(Resolve-Available -cmd $c -vm $vm); confirm=$false }
        }
        $sections += @{ name='Tools';       items=@($toolList) }

        Write-PodeJsonResponse -Value @{ sections = $sections }
    }

    Add-PodeRoute -Method Post -Path '/api/exec/:name' -ScriptBlock {
        $name = $WebEvent.Parameters['name']

        $allNames = @()
        $allNames += (Get-PodeState -Name 'VmCommands').name
        $allNames += (Get-PodeState -Name 'BgCommands').name
        $allNames += (Get-ToolCommandList).name
        if ($allNames -notcontains $name) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ ok=$false; error="Unknown command: $name" }
            return
        }

        $mainScript = (Get-PodeState -Name 'MainScript')
        try {
            Start-Process pwsh -Verb RunAs -ArgumentList @(
                '-NoExit',
                '-NoProfile',
                '-ExecutionPolicy','Bypass',
                '-File',"`"$mainScript`"",
                '-Cmd',$name
            ) | Out-Null
            Set-PodeResponseStatus -Code 202
            Write-PodeJsonResponse -Value @{ ok=$true; spawned=$name }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }

    Write-Host ""
    Write-Host "Dune Server Web UI listening on http://127.0.0.1:$Port" -ForegroundColor Green
    Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
}
