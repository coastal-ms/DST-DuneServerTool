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
    $counts = @{}
    foreach ($selection in @('ObservedCharacterSwatches','ObservedGearAppearances','ObservedSchematicRecipes')) {
        $entry = Get-DuneReviewedCustomization $selection
        $keys = if ($selection -eq 'ObservedSchematicRecipes') { @($entry.recipeEntries | ForEach-Object { "$($_.BaseRecipeId.Name)|$($_.m_QualityLevel)" }) } else { @($entry.customizationIds) }
        $existing = if ($selection -eq 'ObservedSchematicRecipes') { @($raw.recipeKeys) } else { @($raw.customizations) }
        $present = @($keys | Where-Object { $existing -ccontains $_ }).Count
        if ($selection -ne 'ObservedSchematicRecipes' -or $null -ne $raw.recipeKeys) { $counts[$selection] = @{total=$keys.Count;owned=$present;remaining=$keys.Count-$present} }
    }
    return @{ available=$true; owned=@($owned | Sort-Object); unlocked=@($unlocked | Sort-Object); pending=@($raw.pending); reviewedCounts=$counts; error='' }
}

function Get-DuneReviewedCustomization {
    param([string]$CustomizationId)
    $catalog = Get-Content -LiteralPath (Get-DuneSoloDataFilePath -Name 'legitimate-customizations.json') -Raw | ConvertFrom-Json
    $matches = @($catalog.entries | Where-Object { [string]$_.id -ceq $CustomizationId })
    if ($catalog.schemaVersion -ne 1 -or $matches.Count -ne 1 -or -not $matches[0].acquisition -or -not $matches[0].mappingEvidence) {
        throw 'Choose an exact supported character customization selection.'
    }
    return $matches[0]
}

function Invoke-DuneSoloReviewedCustomization {
    param([string]$CustomizationId)
    $null = Get-DuneReviewedCustomization -CustomizationId $CustomizationId
    Assert-DuneSoloSupportedPlatform
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { throw 'Connect and validate a Solo save first.' }
    Assert-DuneSoloProgressionAdapter -Profile $profile
    $adapter = Get-DuneSoloAdapterDescriptor -DbPath $profile.dbPath
    $directory = Join-Path (Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath) 'pre-progression'
    return Invoke-DuneSoloHelper -Command 'grant-legitimate-customization' -Arguments @{
        input=$profile.dbPath; adapter=$adapter.manifestPath
        'safety-backup'=(Join-Path $directory ("game-before-customization-{0}.db" -f [guid]::NewGuid().ToString('N')))
        'reviewed-catalog'=(Get-DuneSoloDataFilePath -Name 'legitimate-customizations.json')
        'customization-id'=$CustomizationId
    }
}

function Get-DuneReviewedCustomizationSql {
    param([long]$PawnId, [long]$ControllerId, [long]$AccountId, [string]$CustomizationId)
    $entry = Get-DuneReviewedCustomization -CustomizationId $CustomizationId
    if ($PawnId -le 0 -or $ControllerId -le 0 -or $AccountId -le 0) { throw 'A current character identity is required.' }
    if ($entry.PSObject.Properties.Name -contains 'recipeEntries') {
        return Get-DuneReviewedRecipeSql -PawnId $PawnId -ControllerId $ControllerId -AccountId $AccountId -Entries @($entry.recipeEntries)
    }
    $ids = if ($entry.PSObject.Properties.Name -contains 'customizationIds') { @($entry.customizationIds) } else { @([string]$entry.id) }
    if ($ids.Count -eq 0 -or @($ids | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -or @($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Invalid reviewed customization mapping.' }
    $safeIds = ($ids | ForEach-Object { "'$(ConvertTo-DuneSqlString $_)'" }) -join ','
    return @'
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE dst_customization_result(added integer) ON COMMIT DROP;
DO $dst$
DECLARE
    props jsonb;
    unlocks jsonb;
    changed integer := 0;
    selected_id text;
BEGIN
    PERFORM pg_advisory_xact_lock(__CONTROLLER__::bigint);
    PERFORM 1 FROM dune.encrypted_player_state
      WHERE player_pawn_id=__PAWN__::bigint AND player_controller_id=__CONTROLLER__::bigint
        AND account_id=__ACCOUNT__::bigint AND online_status::text='Offline' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'The matching character must be fully Offline.'; END IF;
    SELECT properties INTO STRICT props FROM dune.actors WHERE id=__PAWN__::bigint FOR UPDATE;
    unlocks := props #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}';
    IF jsonb_typeof(unlocks) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Unsupported customization library.'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(unlocks) e WHERE jsonb_typeof(e) IS DISTINCT FROM 'object'
        OR jsonb_typeof(e->'m_CustomizationId') IS DISTINCT FROM 'string') THEN RAISE EXCEPTION 'Unsupported customization entry.'; END IF;
    FOREACH selected_id IN ARRAY ARRAY[__IDS__]::text[] LOOP
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(unlocks) e WHERE e->>'m_CustomizationId'=selected_id) THEN
        unlocks := unlocks || jsonb_build_array(jsonb_build_object('m_CustomizationId',selected_id));
        changed := changed + 1;
      END IF;
    END LOOP;
    IF changed > 0 THEN
        props := jsonb_set(props,'{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}',unlocks,false);
        UPDATE dune.actors SET properties=props WHERE id=__PAWN__::bigint;
    END IF;
    IF (SELECT properties FROM dune.actors WHERE id=__PAWN__::bigint) IS DISTINCT FROM props THEN
        RAISE EXCEPTION 'Customization verification failed.';
    END IF;
    INSERT INTO dst_customization_result VALUES(changed);
END
$dst$;
SELECT added::text AS added FROM dst_customization_result;
COMMIT;
'@.Replace('__PAWN__',[string]$PawnId).Replace('__CONTROLLER__',[string]$ControllerId).Replace('__ACCOUNT__',[string]$AccountId).Replace('__IDS__',$safeIds)
}

function Get-DuneReviewedRecipeSql {
    param([long]$PawnId, [long]$ControllerId, [long]$AccountId, [object[]]$Entries)
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not $Entries.Count) { throw 'Empty reviewed recipe selection.' }
    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.BaseRecipeId.Name) -or
            ($entry.m_QualityLevel -isnot [long] -and $entry.m_QualityLevel -isnot [int]) -or
            $entry.m_QualityLevel -lt 0 -or $entry.m_QualityLevel -gt 5 -or
            ($entry.m_NumberOfRecipeUses -isnot [long] -and $entry.m_NumberOfRecipeUses -isnot [int]) -or
            $entry.m_NumberOfRecipeUses -lt -1 -or $entry.m_bIsLimitedUseRecipe -isnot [bool] -or
            ($entry.m_NumberOfRecipeUses -eq -1 -and $entry.m_bIsLimitedUseRecipe) -or
            $entry.m_Source -cne 'SchematicPickup' -or
            -not $keys.Add("$($entry.BaseRecipeId.Name)|$($entry.m_QualityLevel)")) { throw 'Invalid reviewed recipe mapping.' }
    }
    $json = ConvertTo-DuneSqlString (ConvertTo-Json -InputObject @($Entries) -Depth 8 -Compress)
    return @'
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE dst_customization_result(added integer) ON COMMIT DROP;
DO $dst$
DECLARE props jsonb; known jsonb; selected jsonb; changed integer := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(__CONTROLLER__::bigint);
    PERFORM 1 FROM dune.encrypted_player_state WHERE player_pawn_id=__PAWN__::bigint
        AND player_controller_id=__CONTROLLER__::bigint AND account_id=__ACCOUNT__::bigint
        AND online_status::text='Offline' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'The matching character must be fully Offline.'; END IF;
    SELECT properties INTO STRICT props FROM dune.actors WHERE id=__PAWN__::bigint FOR UPDATE;
    known := props #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}';
    IF jsonb_typeof(known) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Unsupported crafting recipe library.'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(known) e WHERE jsonb_typeof(e) IS DISTINCT FROM 'object'
        OR jsonb_typeof(e #> '{BaseRecipeId,Name}') IS DISTINCT FROM 'string'
        OR jsonb_typeof(e->'m_QualityLevel') IS DISTINCT FROM 'number') THEN RAISE EXCEPTION 'Unsupported existing recipe entry.'; END IF;
    FOR selected IN SELECT value FROM jsonb_array_elements('__RECIPES__'::jsonb) LOOP
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(known) e
            WHERE e #>> '{BaseRecipeId,Name}'=selected #>> '{BaseRecipeId,Name}'
              AND e->'m_QualityLevel'=selected->'m_QualityLevel') THEN
            known := known || jsonb_build_array(selected);
            changed := changed + 1;
        END IF;
    END LOOP;
    IF changed > 0 THEN
        props := jsonb_set(props,'{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}',known,false);
        UPDATE dune.actors SET properties=props WHERE id=__PAWN__::bigint;
    END IF;
    IF (SELECT properties FROM dune.actors WHERE id=__PAWN__::bigint) IS DISTINCT FROM props THEN RAISE EXCEPTION 'Recipe readback failed.'; END IF;
    INSERT INTO dst_customization_result VALUES(changed);
END
$dst$;
SELECT added::text AS added FROM dst_customization_result;
COMMIT;
'@.Replace('__PAWN__',[string]$PawnId).Replace('__CONTROLLER__',[string]$ControllerId).Replace('__ACCOUNT__',[string]$AccountId).Replace('__RECIPES__',$json)
}

function Get-DuneReviewedGrantStatusSql {
    param([long]$PawnId, [long]$ControllerId, [long]$AccountId, [string]$CustomizationId)
    $entry = Get-DuneReviewedCustomization $CustomizationId
    if ($entry.PSObject.Properties.Name -contains 'recipeEntries') {
        $selected = ConvertTo-DuneSqlString (ConvertTo-Json -InputObject @($entry.recipeEntries) -Depth 8 -Compress)
        $owned = "a.properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}'"
        $match = "o #>> '{BaseRecipeId,Name}'=s #>> '{BaseRecipeId,Name}' AND o->'m_QualityLevel'=s->'m_QualityLevel'"
    } else {
        $ids = if ($entry.PSObject.Properties.Name -contains 'customizationIds') { @($entry.customizationIds) } else { @([string]$entry.id) }
        $selected = ConvertTo-DuneSqlString (ConvertTo-Json -InputObject @($ids) -Compress)
        $owned = "a.properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}'"
        $match = "o->>'m_CustomizationId'=s #>> '{}'"
    }
    return "SELECT count(*)::text AS total, count(*) FILTER (WHERE EXISTS (SELECT 1 FROM jsonb_array_elements($owned) o WHERE $match))::text AS owned FROM dune.actors a JOIN dune.encrypted_player_state p ON p.player_pawn_id=a.id CROSS JOIN jsonb_array_elements('$selected'::jsonb) s WHERE a.id=$PawnId AND p.player_controller_id=$ControllerId AND p.account_id=$AccountId GROUP BY a.id;"
}

function Invoke-DunePlayerReviewedCustomization {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId, [long]$AccountId, [string]$CustomizationId)
    $sql = Get-DuneReviewedCustomizationSql -PawnId $PawnId -ControllerId $ControllerId -AccountId $AccountId -CustomizationId $CustomizationId
    $scope = Get-DuneVehicleHostScope -Ip $Ip
    $offline = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    if (-not $offline.ok) { return @{ok=$false;error='The selected character must be fully Offline.'} }
    $current = Get-DuneVehicleHostScope -Ip $Ip
    if ($current.key -cne $scope.key) { return @{ok=$false;error='Database changed before the grant; no unlock attempted.'} }
    $write = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 120 -Bulk
    $statusSql = Get-DuneReviewedGrantStatusSql $PawnId $ControllerId $AccountId $CustomizationId
    $check = Invoke-DuneSqlQuery -Ip $Ip -Sql $statusSql -ReadOnly $true -MaxRows 1 -TimeoutSec 30 -Bulk
    $verified = @(); if ($check.ok) { $verified = ConvertTo-DuneRowMaps -Result $check }
    if ($verified.Count -ne 1 -or -not $verified[0].ContainsKey('total') -or -not $verified[0].ContainsKey('owned')) {
        return @{ok=$false;error='Grant completion could not be verified. Refresh and retry; existing unlocks will be preserved.'}
    }
    $total = [int]$verified[0]['total']
    $owned = [int]$verified[0]['owned']
    if ($owned -ne $total) {
        return @{ok=$false;error="$owned of $total grants are saved; $($total-$owned) remain. Retry to add the missing entries; existing unlocks are preserved.";total=$total;owned=$owned}
    }
    $rows = @(); if ($write.ok) { $rows = ConvertTo-DuneRowMaps -Result $write }
    $message = if ($rows.Count -eq 1) {
        "$([int]$rows[0]['added']) added; $($total-[int]$rows[0]['added']) already unlocked. Verified $owned of $total saved."
    } else { "Verified $owned of $total saved after the connection ended. No retry is needed." }
    return @{ok=$true;total=$total;owned=$owned;message=$message}
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
