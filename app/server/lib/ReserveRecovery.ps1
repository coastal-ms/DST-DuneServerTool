# Guarded recovery for hidden player Reserve inventories. Field evidence proved
# Reserve as a pawn-owned type-33 inventory with this exact actor component.

$script:DuneReserveInventoryType = 33
$script:DuneReserveComponentHash = -689927216
$script:DuneReserveRecoveryStateFile = $null

function Get-DuneReserveRecoveryStatePath {
    if ($script:DuneReserveRecoveryStateFile) { return $script:DuneReserveRecoveryStateFile }
    $dir = if ($env:APPDATA) { Join-Path $env:APPDATA 'DuneServer' } else { $env:TEMP }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'reserve-recoveries.json')
}

function New-DuneReserveRecoveryState {
    return @{ version = 1; entries = @(); history = @(); updated = [datetime]::UtcNow.ToString('o') }
}

function Read-DuneReserveRecoveryState {
    $path = Get-DuneReserveRecoveryStatePath
    if (-not (Test-Path -LiteralPath $path)) { return (New-DuneReserveRecoveryState) }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-DuneReserveRecoveryState) }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return @{
            version = 1
            entries = @($parsed.entries)
            history = @($parsed.history)
            updated = [string]$parsed.updated
        }
    } catch {
        throw "Reserve recovery state could not be read: $($_.Exception.Message)"
    }
}

function Save-DuneReserveRecoveryState {
    param([Parameter(Mandatory)]$State)
    $path = Get-DuneReserveRecoveryStatePath
    $State.updated = [datetime]::UtcNow.ToString('o')
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $tmp,
            ($State | ConvertTo-Json -Depth 20),
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-DuneReserveStateValue {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Name, $Value)
    if ($Entry -is [Collections.IDictionary]) {
        $Entry[$Name] = $Value
    } else {
        $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Get-DuneReserveActiveRollback {
    param([long]$PawnId, [string]$DatabaseScope)
    $state = Read-DuneReserveRecoveryState
    $matches = @($state.entries | Where-Object {
        [long]$_.pawn_id -eq $PawnId -and [string]$_.database_scope -ceq $DatabaseScope -and
        [string]$_.status -in @('moved', 'readback_failed')
    })
    if ($matches.Count -gt 1) { throw "Multiple active Reserve rollback records exist for pawn $PawnId." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Test-DunePlayerReserveItems {
    param([string]$Ip, [long]$PawnId)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'A proven player pawn is required.' } }
    $sql = @"
SELECT count(i.id)::text AS item_rows,
       COALESCE(sum(i.stack_size), 0)::text AS item_units
FROM dune.inventories inv
JOIN dune.actor_inventories ai
  ON ai.inventory_id = inv.id
 AND ai.component_name_hash = $script:DuneReserveComponentHash::bigint
LEFT JOIN dune.items i ON i.inventory_id = inv.id
WHERE inv.actor_id = $PawnId::bigint
  AND inv.inventory_type = $script:DuneReserveInventoryType;
"@
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $result.ok) {
        return @{ ok = $false; error = "Reserve inventory could not be checked. $($result.error)" }
    }
    $rows = @(ConvertTo-DuneRowMaps -Result $result)
    if ($rows.Count -ne 1) {
        return @{ ok = $false; error = 'Reserve inventory could not be checked exactly.' }
    }
    return @{
        ok = $true
        item_rows = [long](ConvertTo-DuneInt $rows[0]['item_rows'])
        item_units = [long](ConvertTo-DuneInt $rows[0]['item_units'])
    }
}

function Get-DuneReserveSnapshotSql {
    param([long]$PawnId, [long]$ControllerId)
    return @"
WITH exact_player AS (
    SELECT ps.*
    FROM dune.player_state ps
    WHERE ps.player_pawn_id = $PawnId::bigint
      AND ps.player_controller_id = $ControllerId::bigint
),
reserve_rows AS (
    SELECT inv.*, to_jsonb(ai) AS actor_inventory
    FROM dune.inventories inv
    JOIN dune.actor_inventories ai
      ON ai.inventory_id = inv.id
     AND ai.component_name_hash = $script:DuneReserveComponentHash::bigint
    WHERE inv.actor_id = $PawnId::bigint
      AND inv.inventory_type = $script:DuneReserveInventoryType
),
backpack_rows AS (
    SELECT inv.*
    FROM dune.inventories inv
    WHERE inv.actor_id = $PawnId::bigint
      AND inv.inventory_type = 0
),
reserve_items AS (
    SELECT jsonb_build_object(
        'row', to_jsonb(i),
        'invariant_revision', md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text)
    ) AS item
    FROM dune.items i
    JOIN reserve_rows r ON r.id = i.inventory_id
    ORDER BY i.id
),
backpack_items AS (
    SELECT jsonb_build_object(
        'row', to_jsonb(i),
        'invariant_revision', md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text)
    ) AS item
    FROM dune.items i
    JOIN backpack_rows b ON b.id = i.inventory_id
    ORDER BY i.id
),
snapshot AS (
    SELECT jsonb_build_object(
        'player', COALESCE((SELECT to_jsonb(p) FROM exact_player p), '{}'::jsonb),
        'reserve', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM reserve_rows r), '[]'::jsonb),
        'reserve_items', COALESCE((SELECT jsonb_agg(item) FROM reserve_items), '[]'::jsonb),
        'backpack', COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.id) FROM backpack_rows b), '[]'::jsonb),
        'backpack_items', COALESCE((SELECT jsonb_agg(item) FROM backpack_items), '[]'::jsonb)
    ) AS value
)
SELECT (SELECT count(*) FROM exact_player)::text AS player_count,
       COALESCE((SELECT online_status::text FROM exact_player), '') AS online_status,
       (SELECT count(*) FROM reserve_rows)::text AS reserve_count,
       (SELECT count(*) FROM backpack_rows)::text AS backpack_count,
       COALESCE((SELECT to_jsonb(r)::text FROM reserve_rows r ORDER BY r.id LIMIT 1), '{}') AS reserve_inventory,
       COALESCE((SELECT to_jsonb(b)::text FROM backpack_rows b ORDER BY b.id LIMIT 1), '{}') AS backpack_inventory,
       COALESCE((SELECT jsonb_agg(item)::text FROM reserve_items), '[]') AS reserve_items,
       COALESCE((SELECT jsonb_agg(item)::text FROM backpack_items), '[]') AS backpack_items,
       md5((SELECT value::text FROM snapshot)) AS snapshot_revision;
"@
}

function ConvertFrom-DuneReserveJson {
    param([string]$Value, $Fallback)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    try { return ($Value | ConvertFrom-Json -ErrorAction Stop) } catch { throw "Reserve snapshot JSON was invalid: $($_.Exception.Message)" }
}

function Get-DuneReserveSnapshot {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId)
    if ($PawnId -le 0 -or $ControllerId -le 0) {
        return @{ ok = $false; error = 'Both pawn and controller identities are required.' }
    }
    try {
        $scope = Get-DuneVehicleHostScope -Ip $Ip
    } catch {
        return @{ ok = $false; error = "Database scope could not be proven. $($_.Exception.Message)" }
    }
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql (Get-DuneReserveSnapshotSql -PawnId $PawnId -ControllerId $ControllerId) `
        -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    $rows = @(ConvertTo-DuneRowMaps -Result $result)
    if ($rows.Count -ne 1) { return @{ ok = $false; error = 'Reserve snapshot did not return exactly one result.' } }
    $row = $rows[0]
    try {
        return @{
            ok = $true
            database_scope = [string]$scope.key
            player_count = [int](ConvertTo-DuneInt $row['player_count'])
            online_status = [string]$row['online_status']
            reserve_count = [int](ConvertTo-DuneInt $row['reserve_count'])
            backpack_count = [int](ConvertTo-DuneInt $row['backpack_count'])
            reserve_inventory = ConvertFrom-DuneReserveJson -Value ([string]$row['reserve_inventory']) -Fallback ([pscustomobject]@{})
            backpack_inventory = ConvertFrom-DuneReserveJson -Value ([string]$row['backpack_inventory']) -Fallback ([pscustomobject]@{})
            reserve_items = @(ConvertFrom-DuneReserveJson -Value ([string]$row['reserve_items']) -Fallback @())
            backpack_items = @(ConvertFrom-DuneReserveJson -Value ([string]$row['backpack_items']) -Fallback @())
            snapshot_revision = [string]$row['snapshot_revision']
        }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-DuneReserveBoundRevision {
    param([string]$DatabaseScope, [string]$SnapshotRevision)
    $bytes = [Text.Encoding]::UTF8.GetBytes("$DatabaseScope|$SnapshotRevision")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Resolve-DuneReserveUnitVolume {
    param([Parameter(Mandatory)]$Item)
    $row = $Item.row
    $override = 0.0
    if ($null -ne $row.volume_override -and [double]::TryParse(
        [string]$row.volume_override,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$override
    ) -and $override -gt 0) {
        return @{ ok = $true; volume = $override; source = 'override' }
    }
    $rule = Get-DuneGameplayItemRule -TemplateId ([string]$row.template_id)
    if ($rule -and $rule.ContainsKey('volume') -and $null -ne $rule.volume) {
        $volume = [double]$rule.volume
        if ([double]::IsNaN($volume) -or [double]::IsInfinity($volume) -or $volume -lt 0) {
            return @{ ok = $false; error = "Item $($row.id) has an invalid catalog volume." }
        }
        return @{ ok = $true; volume = $volume; source = 'catalog' }
    }
    return @{ ok = $false; error = "Item $($row.id) ($($row.template_id)) has no proven volume." }
}

function ConvertTo-DuneReservePreview {
    param([Parameter(Mandatory)]$Snapshot, [long]$PawnId, [long]$ControllerId)
    $preview = [ordered]@{
        ok = $true
        source = 'live'
        available = $false
        blocked_reason = $null
        pawn_id = $PawnId
        controller_id = $ControllerId
        online_status = [string]$Snapshot.online_status
        reserve_inventory_id = 0L
        backpack_inventory_id = 0L
        item_rows = 0
        item_units = 0L
        required_volume = 0.0
        used_volume = 0.0
        max_slots = 0
        used_slots = 0
        max_volume = 0.0
        revision = ''
        items = @()
        rollback = $null
        database_scope = [string]$Snapshot.database_scope
        snapshot_revision = [string]$Snapshot.snapshot_revision
    }
    if ($Snapshot.player_count -ne 1) { $preview.blocked_reason = 'The exact pawn/controller pair no longer identifies one player.'; return $preview }
    if ([string]$Snapshot.online_status -cne 'Offline') { $preview.blocked_reason = 'The player must be Offline before Reserve recovery.'; return $preview }
    if ($Snapshot.reserve_count -ne 1) { $preview.blocked_reason = 'DST requires exactly one Reserve inventory with the proven type and component identity.'; return $preview }
    if ($Snapshot.backpack_count -ne 1) { $preview.blocked_reason = 'DST requires exactly one pawn-owned Backpack inventory.'; return $preview }
    if ([string]$Snapshot.snapshot_revision -notmatch '^[a-f0-9]{32}$') { $preview.blocked_reason = 'The database snapshot revision could not be proven.'; return $preview }

    $reserveId = [long]$Snapshot.reserve_inventory.id
    $backpackId = [long]$Snapshot.backpack_inventory.id
    $maxSlots = [int]$Snapshot.backpack_inventory.max_item_count
    $maxVolume = [double]$Snapshot.backpack_inventory.max_item_volume
    $preview.reserve_inventory_id = $reserveId
    $preview.backpack_inventory_id = $backpackId
    $preview.max_slots = $maxSlots
    $preview.max_volume = $maxVolume
    if ($reserveId -le 0 -or $backpackId -le 0 -or $reserveId -eq $backpackId) {
        $preview.blocked_reason = 'Reserve and Backpack identities could not be proven.'; return $preview
    }
    $reserveItems = @($Snapshot.reserve_items)
    $backpackItems = @($Snapshot.backpack_items)
    $preview.item_rows = $reserveItems.Count
    foreach ($item in $reserveItems) { $preview.item_units += [long]$item.row.stack_size }
    $preview.used_slots = $backpackItems.Count
    $preview.revision = Get-DuneReserveBoundRevision -DatabaseScope $Snapshot.database_scope -SnapshotRevision $Snapshot.snapshot_revision
    try {
        $active = Get-DuneReserveActiveRollback -PawnId $PawnId -DatabaseScope $Snapshot.database_scope
        if ($active) {
            $preview.rollback = @{
                recovery_id = [string]$active.recovery_id
                item_rows = @($active.items).Count
                created_at = [string]$active.created_at
            }
        }
    } catch {
        $preview.blocked_reason = $_.Exception.Message; return $preview
    }
    if ($reserveItems.Count -eq 0) {
        $preview.blocked_reason = if ($preview.rollback) { 'Reserve is empty. The last guarded recovery can still be rolled back.' } else { 'Reserve is empty.' }
        return $preview
    }
    if ($preview.rollback) {
        $preview.blocked_reason = 'A prior Reserve recovery still has an active rollback record.'; return $preview
    }
    if ($maxSlots -le 0 -or $maxVolume -le 0) {
        $preview.blocked_reason = 'Backpack slot and volume capacities must both be present and positive.'; return $preview
    }

    $occupied = [Collections.Generic.HashSet[int]]::new()
    $usedVolume = 0.0
    foreach ($item in $backpackItems) {
        $position = [int]$item.row.position_index
        if ($position -lt 0 -or $position -ge $maxSlots -or -not $occupied.Add($position)) {
            $preview.blocked_reason = 'Backpack positions are invalid or duplicated.'; return $preview
        }
        $volume = Resolve-DuneReserveUnitVolume -Item $item
        if (-not $volume.ok) { $preview.blocked_reason = $volume.error; return $preview }
        $usedVolume += [double]$volume.volume * [long]$item.row.stack_size
    }
    $free = [Collections.Generic.List[int]]::new()
    for ($position = 0; $position -lt $maxSlots -and $free.Count -lt $reserveItems.Count; $position++) {
        if (-not $occupied.Contains($position)) { [void]$free.Add($position) }
    }
    if ($free.Count -ne $reserveItems.Count) {
        $preview.blocked_reason = "Backpack needs $($reserveItems.Count) free slots but only $($maxSlots - $occupied.Count) are available."; return $preview
    }
    $movingVolume = 0.0
    $planned = @()
    $sourcePositions = [Collections.Generic.HashSet[int]]::new()
    for ($index = 0; $index -lt $reserveItems.Count; $index++) {
        $item = $reserveItems[$index]
        $sourcePosition = [int]$item.row.position_index
        if ($sourcePosition -lt 0 -or -not $sourcePositions.Add($sourcePosition)) {
            $preview.blocked_reason = "Reserve item $($item.row.id) has an invalid or duplicated source position."; return $preview
        }
        $volume = Resolve-DuneReserveUnitVolume -Item $item
        if (-not $volume.ok) { $preview.blocked_reason = $volume.error; return $preview }
        $totalVolume = [double]$volume.volume * [long]$item.row.stack_size
        $movingVolume += $totalVolume
        $planned += [ordered]@{
            item_id = [long]$item.row.id
            template_id = [string]$item.row.template_id
            name = Get-DuneGameplayItemName -TemplateId ([string]$item.row.template_id)
            stack_size = [long]$item.row.stack_size
            quality = [long]$item.row.quality_level
            source_position = $sourcePosition
            destination_position = [int]$free[$index]
            unit_volume = [double]$volume.volume
            total_volume = $totalVolume
            invariant_revision = [string]$item.invariant_revision
            before_image = $item.row
        }
    }
    $preview.used_volume = $usedVolume
    $preview.required_volume = $movingVolume
    $preview.items = $planned
    if (($usedVolume + $movingVolume) -gt ($maxVolume + 0.000001)) {
        $preview.blocked_reason = "Backpack volume is insufficient: $([Math]::Round($usedVolume + $movingVolume, 3)) required of $maxVolume."; return $preview
    }
    $preview.available = $true
    return $preview
}

function Get-DuneReserveRecoveryPreview {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId)
    $snapshot = Get-DuneReserveSnapshot -Ip $Ip -PawnId $PawnId -ControllerId $ControllerId
    if (-not $snapshot.ok) { return $snapshot }
    return ConvertTo-DuneReservePreview -Snapshot $snapshot -PawnId $PawnId -ControllerId $ControllerId
}

function ConvertTo-DuneReservePublicPreview {
    param([Parameter(Mandatory)]$Preview)
    return [ordered]@{
        source = 'live'
        available = [bool]$Preview.available
        blocked_reason = [string]$Preview.blocked_reason
        pawn_id = [long]$Preview.pawn_id
        controller_id = [long]$Preview.controller_id
        online_status = [string]$Preview.online_status
        reserve_inventory_id = [long]$Preview.reserve_inventory_id
        backpack_inventory_id = [long]$Preview.backpack_inventory_id
        item_rows = [int]$Preview.item_rows
        item_units = [long]$Preview.item_units
        required_volume = [double]$Preview.required_volume
        used_volume = [double]$Preview.used_volume
        max_slots = [int]$Preview.max_slots
        used_slots = [int]$Preview.used_slots
        max_volume = [double]$Preview.max_volume
        revision = [string]$Preview.revision
        rollback = $Preview.rollback
        items = @($Preview.items | ForEach-Object {
            [ordered]@{
                item_id = [long]$_.item_id
                template_id = [string]$_.template_id
                name = [string]$_.name
                stack_size = [long]$_.stack_size
                quality = [long]$_.quality
                source_position = [int]$_.source_position
                destination_position = [int]$_.destination_position
                unit_volume = [double]$_.unit_volume
                total_volume = [double]$_.total_volume
            }
        })
    }
}

function Get-DuneReserveMoveSql {
    param([Parameter(Mandatory)]$Preview)
    $snapshotSql = (Get-DuneReserveSnapshotSql -PawnId ([long]$Preview.pawn_id) -ControllerId ([long]$Preview.controller_id)).Trim().TrimEnd(';')
    $values = @($Preview.items | ForEach-Object {
        "($([long]$_.item_id)::bigint,$([int]$_.source_position)::integer,$([int]$_.destination_position)::integer,'$([string]$_.invariant_revision)'::text)"
    }) -join ",`n        "
    return @"
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO `$dst`$
DECLARE
    actual_revision text;
    moved_count integer;
BEGIN
    PERFORM 1 FROM dune.encrypted_player_state
     WHERE player_pawn_id = $([long]$Preview.pawn_id)::bigint FOR UPDATE;
    IF NOT EXISTS (
        SELECT 1 FROM dune.player_state
        WHERE player_pawn_id = $([long]$Preview.pawn_id)::bigint
          AND player_controller_id = $([long]$Preview.controller_id)::bigint
          AND online_status::text = 'Offline'
    ) THEN RAISE EXCEPTION 'player identity or Offline state changed'; END IF;

    PERFORM 1 FROM dune.inventories
     WHERE id IN ($([long]$Preview.reserve_inventory_id)::bigint, $([long]$Preview.backpack_inventory_id)::bigint)
     ORDER BY id FOR UPDATE;
    PERFORM 1 FROM dune.actor_inventories
     WHERE inventory_id = $([long]$Preview.reserve_inventory_id)::bigint
       AND component_name_hash = $script:DuneReserveComponentHash::bigint
     FOR UPDATE;
    PERFORM 1 FROM dune.items
     WHERE inventory_id IN ($([long]$Preview.reserve_inventory_id)::bigint, $([long]$Preview.backpack_inventory_id)::bigint)
     ORDER BY id FOR UPDATE;

    SELECT snapshot_revision INTO actual_revision
    FROM ($snapshotSql) current_snapshot;
    IF actual_revision IS DISTINCT FROM '$([string]$Preview.snapshot_revision)' THEN
        RAISE EXCEPTION 'Reserve or Backpack changed after preview';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM dune.inventories inv
        JOIN dune.actor_inventories ai
          ON ai.inventory_id = inv.id
         AND ai.component_name_hash = $script:DuneReserveComponentHash::bigint
        WHERE inv.id = $([long]$Preview.reserve_inventory_id)::bigint
          AND inv.actor_id = $([long]$Preview.pawn_id)::bigint
          AND inv.inventory_type = $script:DuneReserveInventoryType
    ) OR NOT EXISTS (
        SELECT 1 FROM dune.inventories inv
        WHERE inv.id = $([long]$Preview.backpack_inventory_id)::bigint
          AND inv.actor_id = $([long]$Preview.pawn_id)::bigint
          AND inv.inventory_type = 0
    ) THEN RAISE EXCEPTION 'Reserve or Backpack identity changed'; END IF;

    WITH plan(item_id, source_position, destination_position, invariant_revision) AS (
        VALUES $values
    )
    UPDATE dune.items i
       SET inventory_id = $([long]$Preview.backpack_inventory_id)::bigint,
           position_index = plan.destination_position
      FROM plan
     WHERE i.id = plan.item_id
       AND i.inventory_id = $([long]$Preview.reserve_inventory_id)::bigint
       AND i.position_index = plan.source_position
       AND md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text) = plan.invariant_revision;
    GET DIAGNOSTICS moved_count = ROW_COUNT;
    IF moved_count <> $(@($Preview.items).Count) THEN RAISE EXCEPTION 'exact Reserve rows changed before move'; END IF;
    IF EXISTS (SELECT 1 FROM dune.items WHERE inventory_id = $([long]$Preview.reserve_inventory_id)::bigint) THEN
        RAISE EXCEPTION 'Reserve did not become empty';
    END IF;
    IF EXISTS (
        WITH plan(item_id, source_position, destination_position, invariant_revision) AS (VALUES $values)
        SELECT 1 FROM plan
        LEFT JOIN dune.items i
          ON i.id = plan.item_id
         AND i.inventory_id = $([long]$Preview.backpack_inventory_id)::bigint
         AND i.position_index = plan.destination_position
         AND md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text) = plan.invariant_revision
        WHERE i.id IS NULL
    ) THEN RAISE EXCEPTION 'Reserve move readback failed'; END IF;
END
`$dst`$;
COMMIT;
"@
}

function Test-DuneReserveMovedReadback {
    param([string]$Ip, [Parameter(Mandatory)]$Entry)
    $ids = @($Entry.items | ForEach-Object { [long]$_.item_id }) -join ','
    $sql = @"
SELECT i.id::text AS item_id, i.inventory_id::text AS inventory_id,
       i.position_index::text AS position_index,
       md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text) AS invariant_revision
FROM dune.items i
WHERE i.id IN ($ids)
ORDER BY i.id;
"@
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows @($Entry.items).Count -TimeoutSec 20
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    $actual = @(ConvertTo-DuneRowMaps -Result $result)
    if ($actual.Count -ne @($Entry.items).Count) { return @{ ok = $false; error = 'Moved item count did not read back exactly.' } }
    foreach ($expected in @($Entry.items)) {
        $row = @($actual | Where-Object { [long]$_['item_id'] -eq [long]$expected.item_id })
        if ($row.Count -ne 1 -or [long]$row[0]['inventory_id'] -ne [long]$Entry.backpack_inventory_id -or
            [int]$row[0]['position_index'] -ne [int]$expected.destination_position -or
            [string]$row[0]['invariant_revision'] -cne [string]$expected.invariant_revision) {
            return @{ ok = $false; error = "Moved item $($expected.item_id) did not read back exactly." }
        }
    }
    $reserve = Test-DunePlayerReserveItems -Ip $Ip -PawnId ([long]$Entry.pawn_id)
    if (-not $reserve.ok -or $reserve.item_rows -ne 0) {
        return @{ ok = $false; error = 'Reserve did not read back empty.' }
    }
    return @{ ok = $true }
}

function Invoke-DuneReserveRecovery {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId, [string]$Revision)
    if ($Revision -notmatch '^[a-f0-9]{64}$') { return @{ ok = $false; error = 'A current Reserve preview revision is required.' } }
    $preview = Get-DuneReserveRecoveryPreview -Ip $Ip -PawnId $PawnId -ControllerId $ControllerId
    if (-not $preview.ok) { return $preview }
    if (-not $preview.available) { return @{ ok = $false; error = [string]$preview.blocked_reason } }
    if ($preview.revision -cne $Revision) { return @{ ok = $false; error = 'Reserve or Backpack changed. Refresh the preview before recovering.' } }

    $backup = Invoke-DuneVerifiedSafetyBackup -Ip $Ip -StemPrefix 'dst-reserve-recovery' -ProofLabel 'DST_RESERVE_BACKUP'
    if (-not $backup.ok) { return @{ ok = $false; error = "Reserve recovery stopped because $($backup.error)" } }
    if ($backup.database_scope -cne $preview.database_scope) {
        return @{ ok = $false; error = 'The database scope changed before backup. Nothing was moved.' }
    }
    $state = Read-DuneReserveRecoveryState
    $entry = [ordered]@{
        recovery_id = [guid]::NewGuid().ToString('N')
        pawn_id = $PawnId
        controller_id = $ControllerId
        database_scope = $preview.database_scope
        preview_revision = $preview.revision
        snapshot_revision = $preview.snapshot_revision
        reserve_inventory_id = $preview.reserve_inventory_id
        backpack_inventory_id = $preview.backpack_inventory_id
        backup_path = $backup.path
        backup_bytes = $backup.bytes
        items = @($preview.items)
        status = 'prepared'
        created_at = [datetime]::UtcNow.ToString('o')
        updated_at = [datetime]::UtcNow.ToString('o')
        message = 'Before-image persisted; no move has been confirmed.'
    }
    $state.entries = @(@($state.entries) + $entry)
    Save-DuneReserveRecoveryState -State $state

    $write = Invoke-DuneSqlQuery -Ip $Ip -Sql (Get-DuneReserveMoveSql -Preview $preview) -ReadOnly $false -MaxRows 1 -TimeoutSec 45 -Bulk
    if (-not $write.ok) {
        Set-DuneReserveStateValue -Entry $entry -Name status -Value 'failed'
        Set-DuneReserveStateValue -Entry $entry -Name updated_at -Value ([datetime]::UtcNow.ToString('o'))
        Set-DuneReserveStateValue -Entry $entry -Name message -Value $write.error
        Save-DuneReserveRecoveryState -State $state
        return @{ ok = $false; error = "Reserve recovery transaction rolled back. $($write.error)" }
    }
    Set-DuneReserveStateValue -Entry $entry -Name status -Value 'moved'
    Set-DuneReserveStateValue -Entry $entry -Name updated_at -Value ([datetime]::UtcNow.ToString('o'))
    Set-DuneReserveStateValue -Entry $entry -Name message -Value 'Reserve rows moved intact to Backpack; rollback remains available.'
    Save-DuneReserveRecoveryState -State $state

    $readback = Test-DuneReserveMovedReadback -Ip $Ip -Entry $entry
    if (-not $readback.ok) {
        Set-DuneReserveStateValue -Entry $entry -Name status -Value 'readback_failed'
        Set-DuneReserveStateValue -Entry $entry -Name message -Value $readback.error
        Save-DuneReserveRecoveryState -State $state
        return @{
            ok = $false
            error = "The transaction committed but the independent readback failed. Exact rollback $($entry.recovery_id) is available. $($readback.error)"
        }
    }
    return @{
        ok = $true
        message = "Recovered $(@($entry.items).Count) Reserve item row(s) into Backpack. Exact rollback remains available."
        recovery_id = $entry.recovery_id
        item_rows = @($entry.items).Count
    }
}

function Get-DuneReserveRollbackSql {
    param([Parameter(Mandatory)]$Entry)
    $values = @($Entry.items | ForEach-Object {
        "($([long]$_.item_id)::bigint,$([int]$_.source_position)::integer,$([int]$_.destination_position)::integer,'$([string]$_.invariant_revision)'::text)"
    }) -join ",`n        "
    return @"
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO `$dst`$
DECLARE restored_count integer;
BEGIN
    PERFORM 1 FROM dune.encrypted_player_state
     WHERE player_pawn_id = $([long]$Entry.pawn_id)::bigint FOR UPDATE;
    IF NOT EXISTS (
        SELECT 1 FROM dune.player_state
        WHERE player_pawn_id = $([long]$Entry.pawn_id)::bigint
          AND player_controller_id = $([long]$Entry.controller_id)::bigint
          AND online_status::text = 'Offline'
    ) THEN RAISE EXCEPTION 'player identity or Offline state changed'; END IF;
    PERFORM 1 FROM dune.inventories
     WHERE id IN ($([long]$Entry.reserve_inventory_id)::bigint, $([long]$Entry.backpack_inventory_id)::bigint)
     ORDER BY id FOR UPDATE;
    PERFORM 1 FROM dune.actor_inventories
     WHERE inventory_id = $([long]$Entry.reserve_inventory_id)::bigint
       AND component_name_hash = $script:DuneReserveComponentHash::bigint
     FOR UPDATE;
    PERFORM 1 FROM dune.items
     WHERE inventory_id IN ($([long]$Entry.reserve_inventory_id)::bigint, $([long]$Entry.backpack_inventory_id)::bigint)
     ORDER BY id FOR UPDATE;
    IF NOT EXISTS (
        SELECT 1 FROM dune.inventories inv
        JOIN dune.actor_inventories ai
          ON ai.inventory_id = inv.id
         AND ai.component_name_hash = $script:DuneReserveComponentHash::bigint
        WHERE inv.id = $([long]$Entry.reserve_inventory_id)::bigint
          AND inv.actor_id = $([long]$Entry.pawn_id)::bigint
          AND inv.inventory_type = $script:DuneReserveInventoryType
    ) OR NOT EXISTS (
        SELECT 1 FROM dune.inventories inv
        WHERE inv.id = $([long]$Entry.backpack_inventory_id)::bigint
          AND inv.actor_id = $([long]$Entry.pawn_id)::bigint
          AND inv.inventory_type = 0
    ) THEN RAISE EXCEPTION 'Reserve or Backpack identity changed'; END IF;
    IF EXISTS (SELECT 1 FROM dune.items WHERE inventory_id = $([long]$Entry.reserve_inventory_id)::bigint) THEN
        RAISE EXCEPTION 'Reserve changed after recovery';
    END IF;
    IF EXISTS (
        WITH plan(item_id, source_position, destination_position, invariant_revision) AS (VALUES $values)
        SELECT 1 FROM plan
        LEFT JOIN dune.items i
          ON i.id = plan.item_id
         AND i.inventory_id = $([long]$Entry.backpack_inventory_id)::bigint
         AND i.position_index = plan.destination_position
         AND md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text) = plan.invariant_revision
        WHERE i.id IS NULL
    ) THEN RAISE EXCEPTION 'recovered rows changed after recovery'; END IF;

    WITH plan(item_id, source_position, destination_position, invariant_revision) AS (VALUES $values)
    UPDATE dune.items i
       SET inventory_id = $([long]$Entry.reserve_inventory_id)::bigint,
           position_index = plan.source_position
      FROM plan
     WHERE i.id = plan.item_id
       AND i.inventory_id = $([long]$Entry.backpack_inventory_id)::bigint
       AND i.position_index = plan.destination_position
       AND md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text) = plan.invariant_revision;
    GET DIAGNOSTICS restored_count = ROW_COUNT;
    IF restored_count <> $(@($Entry.items).Count) THEN RAISE EXCEPTION 'exact recovered rows changed before rollback'; END IF;
    IF EXISTS (
        WITH plan(item_id, source_position, destination_position, invariant_revision) AS (VALUES $values)
        SELECT 1 FROM plan
        LEFT JOIN dune.items i
          ON i.id = plan.item_id
         AND i.inventory_id = $([long]$Entry.reserve_inventory_id)::bigint
         AND i.position_index = plan.source_position
         AND md5((to_jsonb(i) - 'inventory_id' - 'position_index')::text) = plan.invariant_revision
        WHERE i.id IS NULL
    ) THEN RAISE EXCEPTION 'Reserve rollback readback failed'; END IF;
END
`$dst`$;
COMMIT;
"@
}

function Invoke-DuneReserveRecoveryRollback {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId, [string]$RecoveryId)
    if ($PawnId -le 0 -or $ControllerId -le 0 -or $RecoveryId -notmatch '^[a-f0-9]{32}$') {
        return @{ ok = $false; error = 'A player identity and recovery_id are required.' }
    }
    try { $scope = Get-DuneVehicleHostScope -Ip $Ip } catch { return @{ ok = $false; error = $_.Exception.Message } }
    $state = Read-DuneReserveRecoveryState
    $matches = @($state.entries | Where-Object {
        [string]$_.recovery_id -ceq $RecoveryId -and [long]$_.pawn_id -eq $PawnId -and
        [long]$_.controller_id -eq $ControllerId -and [string]$_.database_scope -ceq [string]$scope.key -and
        [string]$_.status -in @('moved', 'readback_failed')
    })
    if ($matches.Count -ne 1) { return @{ ok = $false; error = 'No exact active rollback record matches this player and database.' } }
    $entry = $matches[0]
    $backup = Invoke-DuneVerifiedSafetyBackup -Ip $Ip -StemPrefix 'dst-reserve-rollback' -ProofLabel 'DST_RESERVE_BACKUP'
    if (-not $backup.ok) { return @{ ok = $false; error = "Rollback stopped because $($backup.error)" } }
    if ($backup.database_scope -cne [string]$entry.database_scope) {
        return @{ ok = $false; error = 'The database scope changed before rollback. Nothing was moved.' }
    }
    $write = Invoke-DuneSqlQuery -Ip $Ip -Sql (Get-DuneReserveRollbackSql -Entry $entry) -ReadOnly $false -MaxRows 1 -TimeoutSec 45 -Bulk
    if (-not $write.ok) { return @{ ok = $false; error = "Reserve rollback transaction made no changes. $($write.error)" } }
    Set-DuneReserveStateValue -Entry $entry -Name status -Value 'rolled_back'
    Set-DuneReserveStateValue -Entry $entry -Name updated_at -Value ([datetime]::UtcNow.ToString('o'))
    Set-DuneReserveStateValue -Entry $entry -Name rollback_backup_path -Value $backup.path
    Set-DuneReserveStateValue -Entry $entry -Name message -Value 'Exact original Reserve positions were restored and verified inside the transaction.'
    $state.entries = @($state.entries | Where-Object { [string]$_.recovery_id -cne $RecoveryId })
    $state.history = @($entry) + @($state.history) | Select-Object -First 50
    Save-DuneReserveRecoveryState -State $state
    return @{ ok = $true; message = "Rolled back Reserve recovery $RecoveryId and restored $(@($entry.items).Count) item row(s)." }
}
