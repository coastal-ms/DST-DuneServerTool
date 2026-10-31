# Player-safe projection of the same game-server snapshot used by the host.
Register-DuneRoute -Method GET -Path '/api/player-portal/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $snapshot = Get-DuneBattlegroupSnapshot
        $maps = @($snapshot.gameServers | Where-Object { $_ -and $_.map } | ForEach-Object {
            $ready = ([string]$_.ready -ieq 'true')
            $phase = [string]$_.phase
            $state = if ($ready) { 'Ready' } elseif ($phase -in @('Failed','Error','CrashLoopBackOff')) { 'Error' } elseif ($phase -in @('Stopped','Completed','Succeeded')) { 'Stopped' } else { 'Starting' }
            $players = 0
            [void][int]::TryParse([string]$_.players, [ref]$players)
            @{ map=[string]$_.map; state=$state; ready=$ready; players=[math]::Max(0,$players) }
        })
        Write-DuneJson -Response $res -Body @{
            available = [bool]$snapshot.available
            state = [string]$snapshot.state
            serverName = [string]$snapshot.title
            ready = [bool](Test-DuneHaggaReady -Snapshot $snapshot)
            maps = $maps
            ts = (Get-Date).ToUniversalTime().ToString('o')
        }
    } catch { Write-DuneError -Response $res -Status 503 -Message 'Server status is unavailable.' }
}
