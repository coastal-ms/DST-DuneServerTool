# Catalog API — item catalog + character-domain definitions.
# Both responses are large-ish (~113KB JSON for items) and the client should
# load them once at page mount.

# GET /api/catalog/items — full item catalog (lazy-loaded + cached)
Register-DuneRoute -Method GET -Path '/api/catalog/items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cat = Get-DuneItemCatalog
        Write-DuneJson -Response $res -Body $cat
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Catalog load failed: $($_.Exception.Message)"
    }
}

# GET /api/catalog/character-defs — stat list, currencies, spec tracks,
#   writable inv types, stack limits, equipment-category prefixes.
Register-DuneRoute -Method GET -Path '/api/catalog/character-defs' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneCharacterDefs)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Character-defs failed: $($_.Exception.Message)"
    }
}
