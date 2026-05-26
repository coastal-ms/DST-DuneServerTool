# Setup Wizard — preflight + config summary.
# The actual install step (Step 3) dispatches `initial-setup` via the existing
# /api/commands/run/{name} route.

Register-DuneRoute -Method GET -Path '/api/setup/preflight' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneSetupPreflight)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/setup/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneSetupConfigSummary)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
