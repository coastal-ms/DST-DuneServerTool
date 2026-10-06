function Get-DuneSoloCosmeticOwnership {
    param($Inspection)
    $raw = $Inspection.cosmetics
    if (-not $raw -or -not $raw.available) {
        return @{ available=$false; owned=@(); unlocked=@(); pending=@(); error='Solo ownership is unavailable; reconnect and validate the save.' }
    }
    $unlocked = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($raw.unlocked)) { if ($id) { [void]$unlocked.Add([string]$id) } }
    Add-DuneCosmeticCatalogOwnership -Owned $unlocked -CustomizationIds @($raw.customizations)
    $owned = [Collections.Generic.HashSet[string]]::new($unlocked, [StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($raw.pending)) { if ($id) { [void]$owned.Add([string]$id) } }
    return @{ available=$true; owned=@($owned | Sort-Object); unlocked=@($unlocked | Sort-Object); pending=@($raw.pending); error='' }
}

function Invoke-DuneSoloGrantUnlocks {
    param([ValidateSet('building-sets','armor','weapon','vehicle','dyes','house','placeables')][string]$Kind)
    Assert-DuneSoloSupportedPlatform
    Assert-DuneSoloGameClosed
    $status = Get-DuneSoloStatus
    if (-not $status.inspection) { throw 'Connect and validate a Solo save before granting unlocks.' }
    $ownership = Get-DuneSoloCosmeticOwnership -Inspection $status.inspection
    if (-not $ownership.available) { throw $ownership.error }
    $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $ownership.owned) { [void]$owned.Add([string]$id) }
    $catalog = @(switch ($Kind) {
        'building-sets' { Get-DuneBuildingSetGrantCatalog }
        'house' { Get-DuneHouseSwatchCatalog -Kind all }
        'placeables' { Get-DuneHouseSwatchCatalog -Kind placeables }
        default { Get-DuneSkinGrantCatalog -Kind $Kind }
    })
    $missing = @($catalog | Where-Object { -not $owned.Contains([string]$_.template) })
    if ($missing.Count -eq 0) { return @{ ok=$true; submitted=0; remaining=0; skipped=$catalog.Count; message='No missing unlock tokens.' } }
    $backpack = @($status.inspection.inventories | Where-Object { $_.kind -eq 'backpack' })
    if ($backpack.Count -ne 1) { throw 'A verified Solo backpack is required.' }
    $slots = $missing.Count
    if ($backpack[0].maxItemCount -gt 0) { $slots = [Math]::Max(0, [long]$backpack[0].maxItemCount - [long]$backpack[0].itemRows) }
    if ($slots -eq 0) { throw 'The Solo backpack is full. Free slots in-game, exit, and try again.' }
    $batch = @($missing | Select-Object -First $slots)
    $items = @($batch | ForEach-Object { @{ templateId=[string]$_.template; quantity=1; quality=0 } })
    $result = Invoke-DuneSoloGiveItems -Destination $backpack[0].key -Items $items -Confirm 'GIVE SOLO ITEMS'
    $result | Add-Member -NotePropertyName submitted -NotePropertyValue $batch.Count -Force
    $result | Add-Member -NotePropertyName remaining -NotePropertyValue ($missing.Count-$batch.Count) -Force
    $result | Add-Member -NotePropertyName skipped -NotePropertyValue ($catalog.Count-$missing.Count) -Force
    return $result
}
