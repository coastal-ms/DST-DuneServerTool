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
    Write-DuneJson -Response $res -Body @{
        vm    = $vm
        bg    = $bg
        ports = $ports
        ts    = (Get-Date).ToString('o')
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
    Write-DuneJson -Response $res -Body @{
        vm    = $vm
        bg    = $bg
        ports = $ports
        ts    = (Get-Date).ToString('o')
    }
}
