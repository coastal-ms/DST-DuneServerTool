# Minimal status projection: no credentials, host configuration or commands.
Register-DuneRoute -Method GET -Path '/api/player-portal/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $snapshot = Get-DuneBattlegroupSnapshot
        Write-DuneJson -Response $res -Body @{
            available = [bool]$snapshot.available
            state = [string]$snapshot.state
            ts = (Get-Date).ToUniversalTime().ToString('o')
        }
    } catch { Write-DuneError -Response $res -Status 503 -Message 'Server status is unavailable.' }
}
