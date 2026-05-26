# GET /api/config — returns current config (localhost-only, full values).
Register-DuneRoute -Method GET -Path '/api/config' -Handler {
    param($req, $res, $routeParams, $body)
    $cfg = Read-DuneConfig
    $obj = @{}
    foreach ($k in $cfg.Keys) { $obj[$k] = $cfg[$k] }
    Write-DuneJson -Response $res -Body @{
        path     = Get-DuneConfigPath
        exists   = (Test-Path -LiteralPath (Get-DuneConfigPath))
        complete = Test-DuneConfigComplete -Config $cfg
        keys     = $script:DuneConfigKeys
        values   = $obj
    }
}

# PUT /api/config — merge + persist
Register-DuneRoute -Method PUT -Path '/api/config' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not $body) {
        Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body'
        return
    }
    $patch = @{}
    if ($body -is [hashtable]) {
        $patch = $body
    } elseif ($body.values) {
        foreach ($k in $body.values.Keys) { $patch[$k] = $body.values[$k] }
    } else {
        foreach ($k in $body.Keys) { $patch[$k] = $body[$k] }
    }
    # Validate the SSH key path if provided
    if ($patch.SshKey -and -not (Test-Path -LiteralPath $patch.SshKey)) {
        Write-DuneError -Response $res -Status 400 -Message "SshKey path does not exist: $($patch.SshKey)"
        return
    }
    $saved = Save-DuneConfig -Config $patch
    $obj = @{}
    foreach ($k in $saved.Keys) { $obj[$k] = $saved[$k] }
    Write-DuneJson -Response $res -Body @{
        ok       = $true
        complete = Test-DuneConfigComplete -Config $saved
        values   = $obj
    }
}
