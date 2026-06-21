# GET /api/status — combined VM + Battlegroup + Ports snapshot
Register-DuneRoute -Method GET -Path '/api/status' -Handler {
    param($req, $res, $routeParams, $body)
    $vm = Get-DuneVmStatus
    $bg = $null
    if ($vm.running) {
        try { $bg = Get-DuneBattlegroupSnapshot } catch { $bg = @{ available=$false; reason=$_.Exception.Message } }
    }
    $ports = $null
    try { $ports = Get-DunePortStatus } catch { $ports = $null }
    $serverName = ''
    if ($vm.running -and (Get-Command Get-DuneServerName -ErrorAction SilentlyContinue)) {
        try { $serverName = Get-DuneServerName } catch { $serverName = '' }
    }
    Write-DuneJson -Response $res -Body @{
        vm           = $vm
        bg           = $bg
        ports        = $ports
        serverName   = $serverName
        funcomUpdate = (Get-DuneFuncomUpdateBadge)
        ts           = (Get-Date).ToString('o')
    }
}

# Read the last persisted Funcom server-update result from the restart-schedule
# state file. Cheap (no SSH) - the live check runs during scheduled restarts or
# via POST /api/restart-schedule/check-update.
function Get-DuneFuncomUpdateBadge {
    try {
        if (-not (Get-Command Get-DuneRestartSchedule -ErrorAction SilentlyContinue)) { return $null }
        $s = Get-DuneRestartSchedule
        return @{
            available      = [bool]$s.updateAvailable
            installedBuild = [string]$s.installedBuild
            latestBuild    = [string]$s.latestBuild
            checkedAt      = [string]$s.updateCheckedAt
        }
    } catch { return $null }
}

# POST /api/status/refresh — force re-check (ports + everything)
Register-DuneRoute -Method POST -Path '/api/status/refresh' -Handler {
    param($req, $res, $routeParams, $body)
    $vm = Get-DuneVmStatus
    $bg = $null
    if ($vm.running) {
        try { $bg = Get-DuneBattlegroupSnapshot -Force } catch { $bg = @{ available=$false; reason=$_.Exception.Message } }
    }
    $ports = $null
    try { $ports = Get-DunePortStatus -Force } catch { $ports = $null }
    $serverName = ''
    if ($vm.running -and (Get-Command Get-DuneServerName -ErrorAction SilentlyContinue)) {
        try { $serverName = Get-DuneServerName -Force } catch { $serverName = '' }
    }
    Write-DuneJson -Response $res -Body @{
        vm         = $vm
        bg         = $bg
        ports      = $ports
        serverName = $serverName
        ts         = (Get-Date).ToString('o')
    }
}

# POST /api/server/name — rename the server (battlegroup spec.title shown in the
# in-game server browser). RESTART-class: the operator recreates the battlegroup
# pods to apply the new title, so players are disconnected briefly. No data loss.
Register-DuneRoute -Method POST -Path '/api/server/name' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $name = $null
        if ($body -and $body.PSObject.Properties['name']) { $name = [string]$body.name }
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-DuneError -Response $res -Status 400 -Message 'A non-empty "name" is required.'
            return
        }
        if (-not (Get-Command Set-DuneServerName -ErrorAction SilentlyContinue)) {
            Write-DuneError -Response $res -Status 503 -Message 'Server rename helper unavailable.'
            return
        }
        $r = Set-DuneServerName -Name $name
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
