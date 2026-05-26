# Characters API — 13 endpoints over the existing Db-Postgres helpers.
# Every endpoint VM-gates via Get-DuneCharContext and returns 503 if the
# battlegroup isn't running.

function Resolve-DuneCharContext {
    param($Response)
    $ctx = Get-DuneCharContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $Response -Status $ctx.status -Message $ctx.message
        return $null
    }
    return $ctx
}

function ConvertTo-DuneInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    try { return [int]$Value } catch { return $Default }
}

function ConvertTo-DuneDouble {
    param($Value, [double]$Default = 0.0)
    if ($null -eq $Value) { return $Default }
    try { return [double]$Value } catch { return $Default }
}

# -----------------------------------------------------------------------------
# GET /api/characters — list (id, name)
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/characters' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        $list = Get-V6CharacterList -Ip $ctx.ip
        $items = @($list | ForEach-Object { @{ id = $_.id; name = $_.name } })
        Write-DuneJson -Response $res -Body @{
            available  = $true
            characters = $items
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Character list failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# GET /api/characters/{id} — full detail bundle
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/characters/{id}' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        $bundle = Get-DuneCharacterBundle -Ip $ctx.ip -Id $id
        Write-DuneJson -Response $res -Body $bundle
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Character load failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/characters/{id}/stats — body { values: { MaxHealth: 100, ... } }
# Only keys present in the catalogue are honored.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/characters/{id}/stats' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }

    $values = $null
    if ($body -is [hashtable] -and $body.ContainsKey('values')) { $values = $body.values }
    elseif ($body.values) { $values = $body.values }
    if (-not $values) { Write-DuneError -Response $res -Status 400 -Message 'Body must include a "values" object.'; return }

    $updates = [System.Collections.Generic.List[hashtable]]::new()
    $keys = if ($values -is [hashtable]) { $values.Keys } else { $values.PSObject.Properties.Name }
    foreach ($k in $keys) {
        $def = Get-DuneCharStatDef -Key $k
        if (-not $def) { continue }
        $rawValue = if ($values -is [hashtable]) { $values[$k] } else { $values.$k }
        if ($null -eq $rawValue -or "$rawValue" -eq '') { continue }
        $num = ConvertTo-DuneDouble $rawValue
        $pathParts = $def.Path -split '\.'
        if ($def.Field -eq 'gas_attributes') {
            # GAS attributes are wrapped objects; we set the BaseValue leaf only.
            $pathParts = @($pathParts) + @('BaseValue')
        }
        [void]$updates.Add(@{ Field = $def.Field; Path = $pathParts; Value = $num })
    }

    if ($updates.Count -eq 0) {
        Write-DuneJson -Response $res -Body @{ ok = $true; updated = 0 }
        return
    }

    try {
        Set-V6CharacterStats -Ip $ctx.ip -Id $id -Updates $updates.ToArray()
        Write-DuneJson -Response $res -Body @{ ok = $true; updated = $updates.Count }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST /api/characters/{id}/tech/unlock-all
# POST /api/characters/{id}/tech/lock-all
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/characters/{id}/tech/unlock-all' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Invoke-V6TechUnlockAll -Ip $ctx.ip -Id $id
        Write-DuneJson -Response $res -Body @{ ok = $true; action = 'unlock-all' }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Unlock-all failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/characters/{id}/tech/lock-all' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Invoke-V6TechLockAll -Ip $ctx.ip -Id $id
        Write-DuneJson -Response $res -Body @{ ok = $true; action = 'lock-all' }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Lock-all failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/characters/{id}/specs/{track} — body { xp, level }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/characters/{id}/specs/{track}' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $track = "$($routeParams.track)"
    if ($script:DuneSpecTracks -notcontains $track) {
        Write-DuneError -Response $res -Status 400 -Message "Invalid track. Use one of: $($script:DuneSpecTracks -join ', ')"
        return
    }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    $xp    = ConvertTo-DuneInt    $body.xp
    $level = ConvertTo-DuneDouble $body.level
    try {
        Set-V6SpecializationTrack -Ip $ctx.ip -Id $id -TrackType $track -Xp $xp -Level $level
        Write-DuneJson -Response $res -Body @{ ok = $true; track = $track; xp = $xp; level = $level }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Spec save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST /api/characters/{id}/specs/{prefix}/unlock-keystones
#   prefix must be one of Combat_, Crafting_, Exploration_, Gathering_, Sabotage_
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/characters/{id}/specs/{prefix}/unlock-keystones' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $prefix = "$($routeParams.prefix)"
    if ($script:DuneSpecKeystonePrefixes -notcontains $prefix) {
        Write-DuneError -Response $res -Status 400 -Message "Invalid keystone prefix. Use one of: $($script:DuneSpecKeystonePrefixes -join ', ')"
        return
    }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Invoke-V6UnlockKeystonesForTrack -Ip $ctx.ip -Id $id -TrackPrefix $prefix
        Write-DuneJson -Response $res -Body @{ ok = $true; prefix = $prefix }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Keystone unlock failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/characters/{id}/currency/{currencyId} — body { balance }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/characters/{id}/currency/{currencyId}' -Handler {
    param($req, $res, $routeParams, $body)
    $id  = ConvertTo-DuneInt $routeParams.id
    $cur = ConvertTo-DuneInt $routeParams.currencyId
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    $balance = ConvertTo-DuneInt $body.balance
    try {
        Set-V6Currency -Ip $ctx.ip -Id $id -CurrencyId $cur -Balance $balance
        Write-DuneJson -Response $res -Body @{ ok = $true; currencyId = $cur; balance = $balance }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Currency save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/characters/{id}/faction/{factionId} — body { amount }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/characters/{id}/faction/{factionId}' -Handler {
    param($req, $res, $routeParams, $body)
    $id  = ConvertTo-DuneInt $routeParams.id
    $fac = ConvertTo-DuneInt $routeParams.factionId
    if (-not $id)  { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    if (-not $fac) { Write-DuneError -Response $res -Status 400 -Message 'Invalid faction id';   return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    $amount = ConvertTo-DuneInt $body.amount
    try {
        Set-V6FactionReputation -Ip $ctx.ip -Id $id -FactionId $fac -Amount $amount
        Write-DuneJson -Response $res -Body @{ ok = $true; factionId = $fac; amount = $amount }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Faction save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST   /api/characters/{id}/cosmetics — body { cosmeticId }
# DELETE /api/characters/{id}/cosmetics/{cosmeticId}
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/characters/{id}/cosmetics' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $cosmeticId = "$($body.cosmeticId)"
    if (-not $cosmeticId) { Write-DuneError -Response $res -Status 400 -Message 'Body must include cosmeticId'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Add-V6Cosmetic -Ip $ctx.ip -Id $id -CosmeticId $cosmeticId
        Write-DuneJson -Response $res -Body @{ ok = $true; action = 'add'; cosmeticId = $cosmeticId }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Cosmetic add failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method DELETE -Path '/api/characters/{id}/cosmetics/{cosmeticId}' -Handler {
    param($req, $res, $routeParams, $body)
    $id = ConvertTo-DuneInt $routeParams.id
    if (-not $id) { Write-DuneError -Response $res -Status 400 -Message 'Invalid character id'; return }
    $cosmeticId = "$($routeParams.cosmeticId)"
    if (-not $cosmeticId) { Write-DuneError -Response $res -Status 400 -Message 'Missing cosmeticId'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Remove-V6Cosmetic -Ip $ctx.ip -Id $id -CosmeticId $cosmeticId
        Write-DuneJson -Response $res -Body @{ ok = $true; action = 'remove'; cosmeticId = $cosmeticId }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Cosmetic remove failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST   /api/inventories/{inventoryId}/items — body { templateId, stackSize, isEquipment }
# DELETE /api/items/{itemId}
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/inventories/{inventoryId}/items' -Handler {
    param($req, $res, $routeParams, $body)
    $invId = ConvertTo-DuneInt $routeParams.inventoryId
    if (-not $invId) { Write-DuneError -Response $res -Status 400 -Message 'Invalid inventory id'; return }
    $tmpl = "$($body.templateId)"
    if (-not $tmpl) { Write-DuneError -Response $res -Status 400 -Message 'Body must include templateId'; return }
    $stack = ConvertTo-DuneInt $body.stackSize 1
    $isEq  = [bool]$body.isEquipment
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Add-V6InventoryItem -Ip $ctx.ip -InventoryId $invId -TemplateId $tmpl -StackSize $stack -IsEquipment $isEq
        Write-DuneJson -Response $res -Body @{ ok = $true; inventoryId = $invId; templateId = $tmpl; stackSize = $stack }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Inventory add failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method DELETE -Path '/api/items/{itemId}' -Handler {
    param($req, $res, $routeParams, $body)
    $itemId = ConvertTo-DuneInt $routeParams.itemId
    if (-not $itemId) { Write-DuneError -Response $res -Status 400 -Message 'Invalid item id'; return }
    $ctx = Resolve-DuneCharContext -Response $res
    if (-not $ctx) { return }
    try {
        Remove-V6InventoryItem -Ip $ctx.ip -ItemId $itemId
        Write-DuneJson -Response $res -Body @{ ok = $true; itemId = $itemId }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Item delete failed: $($_.Exception.Message)"
    }
}
