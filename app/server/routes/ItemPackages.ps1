# ItemPackages.ps1 (routes) — CRUD for admin-defined item packages.
#
# Backs the Players page "Give Package" action. Packages are persisted via
# lib/ItemPackages.ps1 (%APPDATA%\DuneServer\item-packages.json). Delivery to a
# player reuses the existing POST /api/gameplay/players/give-items bulk route, so
# there is no give endpoint here — only the package library CRUD.
#
#   GET    /api/gameplay/item-packages            -> { ok, packages }
#   PUT    /api/gameplay/item-packages            -> save (create/update) one
#   DELETE /api/gameplay/item-packages?id=<id>    -> delete one

Register-DuneRoute -Method GET -Path '/api/gameplay/item-packages' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $packages = @(Read-DuneItemPackages)
        Write-DuneJson -Response $res -Body @{ ok = $true; packages = $packages; source = 'live' }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "List item packages failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameplay/item-packages' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $saved = Save-DuneItemPackage -Incoming $body
        Write-DuneJson -Response $res -Body @{ ok = $true; package = $saved }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message "Save item package failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method DELETE -Path '/api/gameplay/item-packages' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $id = ''
        try { $id = [string]$req.QueryString['id'] } catch {}
        if ([string]::IsNullOrWhiteSpace($id)) {
            Write-DuneError -Response $res -Status 400 -Message 'id query parameter is required.'
            return
        }
        $removed = Remove-DuneItemPackage -Id $id
        Write-DuneJson -Response $res -Body @{ ok = $true; removed = [bool]$removed }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Delete item package failed: $($_.Exception.Message)"
    }
}
