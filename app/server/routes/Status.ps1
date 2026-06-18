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
        vm         = $vm
        bg         = $bg
        ports      = $ports
        serverName = $serverName
        ts         = (Get-Date).ToString('o')
    }
}

# POST /api/status/refresh — force re-check (ports + everything)
Register-DuneRoute -Method POST -Path '/api/status/refresh' -Handler {
    param($req, $res, $routeParams, $body)
    $vm = Get-DuneVmStatus
    $bg = $null
    if ($vm.running) {
        try { $bg = Get-DuneBattlegroupSnapshot } catch { $bg = @{ available=$false; reason=$_.Exception.Message } }
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
