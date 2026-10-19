Register-DuneRoute -Method GET -Path '/api/solo/live-map' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    Write-DuneJson -Response $res -Body (Get-DuneSoloLiveMapStatus)
}
Register-DuneRoute -Method POST -Path '/api/solo/live-map/open' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try { Write-DuneJson -Response $res -Body (Open-DuneSoloLiveMap) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
