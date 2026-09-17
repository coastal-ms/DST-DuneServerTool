# Persisted vehicle reads, independently implemented against the Red-Blink
# vehicle model documented in docs/vehicle-lifecycle.md. The game DB is authority.

function Get-DuneVehicleHostScope {
    param([string]$Ip)
    $probe = Invoke-DuneBackupShell -Ip $Ip -Script @'
kubectl get namespaces -o jsonpath='{range .items[*]}DST_VEHICLE_SCOPE={.metadata.name}|{.metadata.uid}{"\n"}{end}'
'@ -TimeoutSec 30
    if ($null -eq $probe -or $probe.rc -ne 0) { throw 'Vehicle database namespace could not be observed.' }
    $scopes = @([regex]::Matches([string]$probe.out, '(?m)^DST_VEHICLE_SCOPE=(funcom-seabass-sh-[a-z0-9-]+)\|([a-f0-9-]{36})\r?$'))
    if ($scopes.Count -ne 1) { throw 'Vehicle reads require exactly one proven battlegroup namespace.' }
    $ns = $scopes[0].Groups[1].Value
    $pod = Find-V6DbPod -Ip $Ip -Force
    if ($pod.ns -cne $ns) { throw 'The discovered database does not belong to the proven vehicle namespace.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $scope = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Ip|$ns|$($scopes[0].Groups[2].Value)")))).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
    return @{ key = $scope; namespace = $ns; world = $ns.Substring('funcom-seabass-'.Length) }
}

function Get-DuneVehicleTargetRevisionSql {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$DatabaseScope)
    # Exclude transient actor state and durability: stopping a map flushes those.
    # Identity, access, installed modules, their inventory scope, and recovery ownership must still match.
    return @'
md5(jsonb_build_array('__DATABASE_SCOPE__', a.id::text, a.class, a.map, pa.actor_name,
    (SELECT jsonb_agg(jsonb_build_array(r.player_id::text, r.rank) ORDER BY r.player_id, r.rank)
     FROM dune.permission_actor_rank r WHERE r.permission_actor_id = a.id),
    (SELECT jsonb_agg(jsonb_build_array(m.id::text, m.template_id) ORDER BY m.id)
     FROM dune.vehicle_modules m WHERE m.vehicle_id = a.id),
    (SELECT jsonb_agg(rv.character_id::text ORDER BY rv.character_id)
     FROM dune.recovered_vehicles rv WHERE rv.vehicle_id = a.id),
    (SELECT jsonb_agg(bv.character_id::text ORDER BY bv.character_id)
     FROM dune.backup_vehicles bv WHERE bv.vehicle_id = a.id),
    (SELECT jsonb_agg(jsonb_build_array(to_jsonb(inv),
        (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id)
         FROM dune.items i WHERE i.inventory_id = inv.id)) ORDER BY inv.id)
     FROM dune.inventories inv
     WHERE inv.actor_id = a.id
        OR inv.vehicle_module_id IN (SELECT m.id FROM dune.vehicle_modules m WHERE m.vehicle_id = a.id))
)::text)
'@.Replace('__DATABASE_SCOPE__', $DatabaseScope)
}

$script:DuneVehicleModuleDurabilityDefaults = $null

function Get-DuneVehicleModuleDurabilityDefaults {
    if ($null -ne $script:DuneVehicleModuleDurabilityDefaults) {
        return $script:DuneVehicleModuleDurabilityDefaults
    }
    $defaults = @{}
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot '..\..\data\vehicle-module-durability.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\data\vehicle-module-durability.json')
    )) {
        try {
            $path = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
            $json = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($property in $json.defaults.PSObject.Properties) {
                $defaults[$property.Name] = [double]$property.Value
            }
            break
        } catch {}
    }
    $script:DuneVehicleModuleDurabilityDefaults = $defaults
    return $defaults
}

function Get-DuneVehicleModuleDefaultDurability {
    param([string]$TemplateId)
    $defaults = Get-DuneVehicleModuleDurabilityDefaults
    if ($defaults.ContainsKey($TemplateId)) { return [double]$defaults[$TemplateId] }
    $rule = Get-DuneGameplayItemRule -TemplateId $TemplateId
    return [double]$rule.max_durability
}

function Get-DuneVehicleModuleRepairDefaults {
    $combined = @{}
    foreach ($entry in (Get-DuneVehicleModuleDurabilityDefaults).GetEnumerator()) {
        $combined[[string]$entry.Key] = [double]$entry.Value
    }
    Initialize-DuneGameplayItemData
    foreach ($templateId in $script:DuneGameplayItemRules.Keys) {
        $rule = $script:DuneGameplayItemRules[$templateId]
        if ([string]$rule.category -like 'items/vehicles/*' -and [double]$rule.max_durability -gt 0) {
            $combined[[string]$templateId] = [double]$rule.max_durability
        }
    }
    return $combined
}

function ConvertTo-DuneVehicleNumber {
    param($Value)
    $number = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
        -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0) {
        return $number
    }
    return $null
}

function Get-DuneVehicleFleetLive {
    param([string]$Ip, [long]$VehicleId = 0)
    $filter = if ($VehicleId -gt 0) { "AND a.id = $VehicleId::bigint" } else { '' }
    $hostScope = Get-DuneVehicleHostScope -Ip $Ip
    $revisionSql = Get-DuneVehicleTargetRevisionSql -DatabaseScope $hostScope.key
    $sql = @"
SELECT a.id::text AS vehicle_id, a.class, COALESCE(a.map, '') AS map,
       COALESCE(pa.actor_name, '') AS vehicle_name,
       COALESCE(a.state::text, '') AS actor_state,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
           'player_id', par.player_id::text, 'rank', par.rank,
           'character_name', (SELECT CASE WHEN count(*) = 1 THEN min(ps.character_name) END
                             FROM dune.player_state ps WHERE ps.player_controller_id = par.player_id),
          'online_status', (SELECT CASE WHEN count(*) = 1 THEN min(ps.online_status::text) END
                            FROM dune.player_state ps WHERE ps.player_controller_id = par.player_id),
          'player_state_count', (SELECT count(*) FROM dune.player_state ps
                                 WHERE ps.player_controller_id = par.player_id)
       ) ORDER BY par.rank, par.player_id)
       FROM dune.permission_actor_rank par WHERE par.permission_actor_id = a.id), '[]'::jsonb)::text AS permissions,
       (SELECT count(*) FROM dune.vehicle_modules vm WHERE vm.vehicle_id = a.id)::text AS module_count,
       (SELECT count(*) FROM dune.recovered_vehicles rv WHERE rv.vehicle_id = a.id)::text AS recovery_count,
       (SELECT CASE WHEN count(*) = 1 THEN min(rv.chassis_durability::text) END
        FROM dune.recovered_vehicles rv WHERE rv.vehicle_id = a.id) AS recovery_durability,
       (SELECT count(*) FROM dune.backup_vehicles bv WHERE bv.vehicle_id = a.id)::text AS backup_count,
       (SELECT count(*) FROM dune.inventories inv WHERE inv.actor_id = a.id AND inv.inventory_type = 0)::text AS cargo_hold_count,
       (SELECT count(*) FROM dune.inventories inv
        WHERE inv.actor_id = a.id AND inv.inventory_type = 0
          AND (inv.exchange_id IS NOT NULL OR inv.item_id IS NOT NULL OR inv.vehicle_module_id IS NOT NULL))::text AS cargo_conflict_count,
       (SELECT count(*) FROM dune.inventories inv
        WHERE (inv.vehicle_module_id IN (SELECT vm.id FROM dune.vehicle_modules vm WHERE vm.vehicle_id = a.id)
               AND inv.actor_id IS NOT NULL AND inv.actor_id <> a.id)
           OR (inv.actor_id = a.id AND inv.vehicle_module_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dune.vehicle_modules vm
                               WHERE vm.id = inv.vehicle_module_id AND vm.vehicle_id = a.id)))::text AS closure_owner_conflict_count,
       (SELECT count(*) FROM dune.items i JOIN dune.inventories inv ON inv.id = i.inventory_id
        WHERE inv.actor_id = a.id AND inv.inventory_type = 0)::text AS cargo_stack_count,
       (SELECT CASE WHEN count(*) = 1 THEN min(inv.max_item_count)::text END FROM dune.inventories inv
        WHERE inv.actor_id = a.id AND inv.inventory_type = 0) AS cargo_max_item_count,
       (SELECT CASE WHEN count(*) = 1 THEN min(inv.max_item_volume)::text END FROM dune.inventories inv
        WHERE inv.actor_id = a.id AND inv.inventory_type = 0) AS cargo_max_item_volume,
       $revisionSql AS target_revision
FROM dune.vehicles v
JOIN dune.actors a ON a.id = v.id
LEFT JOIN dune.permission_actor pa ON pa.actor_id = a.id AND pa.actor_type = 2
WHERE true $filter
ORDER BY COALESCE(NULLIF(pa.actor_name, ''), a.class), a.id;
"@
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 10001 -TimeoutSec 30
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    $rows = ConvertTo-DuneRowMaps -Result $result
    if ($rows.Count -gt 10000) { return @{ ok = $false; error = 'Fleet exceeds the 10,000 vehicle read limit; no partial fleet is returned.' } }
    $catalog = Get-DuneVehicleKitCatalog
    $vehicles = @()
    $seen = @{}
    foreach ($row in $rows) {
        $id = [int64](ConvertTo-DuneInt $row['vehicle_id'])
        if ($id -le 0 -or $id -gt 9007199254740991 -or $seen.ContainsKey($id)) { throw 'Vehicle fleet returned an invalid or ambiguous actor identity.' }
        $seen[$id] = $true
        $parsedPermissions = ([string]$row['permissions']) | ConvertFrom-Json -ErrorAction Stop
        $permissions = [Collections.Generic.List[object]]::new()
        foreach ($permission in $parsedPermissions) {
            if ($permission -is [Array]) {
                foreach ($nestedPermission in $permission) { $permissions.Add($nestedPermission) }
            } else {
                $permissions.Add($permission)
            }
        }
        $owners = @($permissions | Where-Object { $null -ne $_.rank -and $_.rank -eq 1 })
        $ownership = if ($permissions.Count -eq 0) { 'unowned' } elseif ($owners.Count -ne 1 -or -not $owners[0].character_name) { 'ambiguous' } else { 'owned' }
        $duplicateOwners = @($owners | Group-Object player_id | Where-Object Count -gt 1)
        $short = ConvertTo-DuneVehicleShortClass ([string]$row['class'])
        $subtypes = @($catalog.vehicles | Where-Object {
            (ConvertTo-DuneVehicleShortClass ([string]$_.className)) -eq $short
        })
        $recoveryCount = [int](ConvertTo-DuneInt $row['recovery_count'])
        $cargoHolds = [int](ConvertTo-DuneInt $row['cargo_hold_count'])
        $cargoConflicts = [int](ConvertTo-DuneInt $row['cargo_conflict_count'])
        $closureOwnerConflicts = [int](ConvertTo-DuneInt $row['closure_owner_conflict_count'])
        $blockedState = @(([string]$row['actor_state'] -split ', ') | Where-Object { $_ -eq 'Travel' })
        $recoveryState = @(([string]$row['actor_state'] -split ', ') | Where-Object { $_ -in @('VehicleRecovery', 'VehicleBackup') })
        $unresolvedOwners = @($owners | Where-Object {
            [int](ConvertTo-DuneInt $_.player_state_count) -ne 1 -or -not $_.character_name -or -not $_.online_status
        })
        $onlineOwners = @($owners | Where-Object { [string]$_.online_status -cne 'Offline' })
        $revision = [string]$row['target_revision']
        if ($revision -notmatch '^[a-f0-9]{32}$') { throw 'Vehicle target revision is unavailable.' }
        $vehicles += @{
            id = $id
            class = $short
            vehicle_name = [string]$row['vehicle_name']
            map = [string]$row['map']
            actor_state = [string]$row['actor_state']
            subtype = if ($subtypes.Count -eq 1) { [string]$subtypes[0].label } else { $short }
            subtype_source = if ($subtypes.Count -eq 1) { 'catalog' } else { 'actor-class' }
            owners = (@($owners | ForEach-Object {
                if ($_.character_name) { [string]$_.character_name } else { "Unresolved controller $($_.player_id)" }
            }) -join ', ')
            ownership_status = $ownership
            permissions = $permissions.ToArray()
            module_count = [int](ConvertTo-DuneInt $row['module_count'])
            recovery_count = $recoveryCount
            recovery_durability = ConvertTo-DuneVehicleNumber $row['recovery_durability']
            backup_count = [int](ConvertTo-DuneInt $row['backup_count'])
            cargo_hold_count = $cargoHolds
            cargo_stack_count = [int](ConvertTo-DuneInt $row['cargo_stack_count'])
            cargo_max_item_count = ConvertTo-DuneVehicleNumber $row['cargo_max_item_count']
            cargo_max_item_volume = ConvertTo-DuneVehicleNumber $row['cargo_max_item_volume']
            target_revision = $revision
            rename_blocked_reason = if ($recoveryCount -gt 0 -or [int](ConvertTo-DuneInt $row['backup_count']) -gt 0 -or $recoveryState.Count -gt 0) {
                'Rename is unavailable for backed-up or recovery vehicles.'
            } elseif ($owners.Count -eq 0) {
                'Rename requires at least one proven rank-1 vehicle owner.'
            } elseif ($duplicateOwners.Count -gt 0 -or $unresolvedOwners.Count -gt 0) {
                'Rename is unavailable because DST cannot resolve the exact vehicle ownership.'
            } elseif ($onlineOwners.Count -gt 0) {
                'Every owning player must be Offline before renaming this vehicle.'
            } else { $null }
            deletion_blocked_reason = if ($blockedState.Count -gt 0) {
                'This vehicle is currently travelling. Finish the trip before deleting it.'
            } elseif ($cargoHolds -gt 1 -or $cargoConflicts -gt 0 -or $closureOwnerConflicts -gt 0) {
                'Delete is unavailable because DST cannot prove which cargo and module records belong only to this vehicle.'
            } else { $null }
        }

    }
    return @{
        ok = $true; vehicles = $vehicles; total = $vehicles.Count; source = 'live'
        observed_at = [datetimeoffset]::UtcNow.ToString('o'); stale_after_seconds = 20
        database_scope = $hostScope.key
    }
}

function Test-DuneVehicleRenameName {
    param([AllowEmptyString()][string]$Name)
    $trimmed = ([string]$Name).Trim()
    if (-not $trimmed) { return @{ ok = $false; error = 'name is required.' } }
    if ($trimmed.Length -gt 64) { return @{ ok = $false; error = 'name must be 64 characters or fewer.' } }
    if ($trimmed -match '[\x00-\x1F\x7F]') { return @{ ok = $false; error = 'name cannot contain control characters.' } }
    if ($trimmed.StartsWith('##')) { return @{ ok = $false; error = 'Remove the leading ## and enter a custom name.' } }
    if ($trimmed -eq 'None') { return @{ ok = $false; error = 'name is reserved by the game.' } }
    return @{ ok = $true; name = $trimmed }
}

function Invoke-DuneVehicleRenameBatch {
    param(
        [string]$Ip,
        [array]$Changes,
        [string]$DatabaseScope
    )
    if ($DatabaseScope -cnotmatch '^[a-f0-9]{64}$') {
        return @{ ok = $false; status = 409; error = 'Refresh the fleet and retry against its current database scope.' }
    }
    if ($Changes.Count -lt 1 -or $Changes.Count -gt 100) {
        return @{ ok = $false; status = 400; error = 'Change between 1 and 100 vehicle names at once.' }
    }
    try {
        $currentScope = Get-DuneVehicleHostScope -Ip $Ip
    } catch {
        return @{ ok = $false; status = 503; error = $_.Exception.Message }
    }
    if ($currentScope.key -cne $DatabaseScope) {
        return @{ ok = $false; status = 409; error = 'The vehicle database scope changed. Refresh the fleet before saving names.' }
    }

    $targets = @()
    $seen = @{}
    foreach ($change in $Changes) {
        $vehicleId = 0L
        if (-not [long]::TryParse([string]$change.vehicle_id, [ref]$vehicleId) -or
            $vehicleId -le 0 -or $vehicleId -gt 9007199254740991 -or $seen.ContainsKey($vehicleId)) {
            return @{ ok = $false; status = 400; error = 'Every changed vehicle must have one unique positive integer id.' }
        }
        $expected = [string]$change.expected_current_name
        if ($null -eq $change.expected_current_name -or $expected.Length -gt 512) {
            return @{ ok = $false; status = 400; error = "Vehicle $vehicleId is missing a valid expected_current_name." }
        }
        $validName = Test-DuneVehicleRenameName -Name ([string]$change.name)
        if (-not $validName.ok) {
            return @{ ok = $false; status = 400; error = "Vehicle $vehicleId $($validName.error)" }
        }
        if ([string]$validName.name -ceq $expected) {
            return @{ ok = $false; status = 400; error = "Vehicle $vehicleId has no name change." }
        }
        $seen[$vehicleId] = $true
        $targets += @{
            vehicle_id = $vehicleId
            expected_current_name = $expected
            name = [string]$validName.name
        }
    }

    $values = @($targets | ForEach-Object {
        "($($_.vehicle_id)::bigint, '$(ConvertTo-DuneSqlString $_.expected_current_name)'::text, '$(ConvertTo-DuneSqlString $_.name)'::text)"
    }) -join ",`n    "
    $sql = @'
BEGIN;
SET LOCAL search_path TO dune, public;
SET LOCAL lock_timeout = '5s';
CREATE TEMP TABLE dst_vehicle_rename_targets (
    vehicle_id bigint PRIMARY KEY,
    expected_current_name text NOT NULL,
    new_name text NOT NULL
) ON COMMIT DROP;
INSERT INTO dst_vehicle_rename_targets (vehicle_id, expected_current_name, new_name) VALUES
    __TARGET_VALUES__;
LOCK TABLE dune.permission_actor IN SHARE ROW EXCLUSIVE MODE;
DO $dst$
BEGIN
    PERFORM 1
    FROM dune.actors a
    JOIN dune.vehicles v ON v.id = a.id
    JOIN dune.permission_actor pa ON pa.actor_id = a.id AND pa.actor_type = 2
    JOIN dst_vehicle_rename_targets t ON t.vehicle_id = a.id
    FOR UPDATE OF a, v, pa;

    IF (SELECT count(*) FROM dst_vehicle_rename_targets) <> (
        SELECT count(*)
        FROM dst_vehicle_rename_targets t
        JOIN dune.actors a ON a.id = t.vehicle_id
        JOIN dune.vehicles v ON v.id = a.id
        JOIN dune.permission_actor pa ON pa.actor_id = a.id AND pa.actor_type = 2
    ) THEN
        RAISE EXCEPTION 'One or more exact active-fleet vehicle name rows were not found.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM dst_vehicle_rename_targets t
        JOIN dune.actors actor_state ON actor_state.id = t.vehicle_id
        WHERE actor_state.state::text IN ('VehicleRecovery', 'VehicleBackup')
    ) OR EXISTS (
        SELECT 1 FROM dst_vehicle_rename_targets t
        JOIN dune.recovered_vehicles rv ON rv.vehicle_id = t.vehicle_id
    ) OR EXISTS (
        SELECT 1 FROM dst_vehicle_rename_targets t
        JOIN dune.backup_vehicles bv ON bv.vehicle_id = t.vehicle_id
    ) THEN
        RAISE EXCEPTION 'Backed-up or recovery vehicles cannot be renamed.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM dst_vehicle_rename_targets t
        LEFT JOIN dune.permission_actor_rank par
          ON par.permission_actor_id = t.vehicle_id AND par.rank = 1
        GROUP BY t.vehicle_id
        HAVING count(par.player_id) = 0
    ) THEN
        RAISE EXCEPTION 'Every vehicle requires at least one proven rank-1 owner.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM dst_vehicle_rename_targets t
        JOIN dune.permission_actor_rank par
          ON par.permission_actor_id = t.vehicle_id AND par.rank = 1
        LEFT JOIN LATERAL (
            SELECT count(*) AS row_count,
                   CASE WHEN count(*) = 1 THEN min(ps.online_status::text) END AS online_status
            FROM dune.player_state ps
            WHERE ps.player_controller_id = par.player_id
        ) owner_state ON true
        GROUP BY t.vehicle_id, par.player_id, owner_state.row_count, owner_state.online_status
        HAVING count(*) <> 1
            OR owner_state.row_count <> 1
            OR owner_state.online_status IS DISTINCT FROM 'Offline'
    ) THEN
        RAISE EXCEPTION 'Every rank-1 owner must resolve exactly once and be Offline.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM dst_vehicle_rename_targets t
        JOIN dune.permission_actor pa ON pa.actor_id = t.vehicle_id AND pa.actor_type = 2
        WHERE COALESCE(pa.actor_name, '') IS DISTINCT FROM t.expected_current_name
    ) THEN
        RAISE EXCEPTION 'A vehicle name changed; refresh and retry against the current fleet.';
    END IF;

    UPDATE dune.permission_actor pa
    SET actor_name = t.new_name
    FROM dst_vehicle_rename_targets t
    WHERE pa.actor_id = t.vehicle_id AND pa.actor_type = 2;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No exact vehicle name rows were updated.';
    END IF;
END
$dst$;
COMMIT;
'@.Replace('__TARGET_VALUES__', $values)
    $write = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $write.ok) { return @{ ok = $false; status = 409; error = $write.error } }

    $readbackSql = @"
WITH expected(vehicle_id, expected_name) AS (VALUES
    $(@($targets | ForEach-Object { "($($_.vehicle_id)::bigint, '$(ConvertTo-DuneSqlString $_.name)'::text)" }) -join ",`n    ")
)
SELECT expected.vehicle_id::text, pa.actor_name
FROM expected
LEFT JOIN dune.permission_actor pa ON pa.actor_id = expected.vehicle_id AND pa.actor_type = 2
ORDER BY expected.vehicle_id;
"@
    $readback = Invoke-DuneSqlQuery -Ip $Ip -Sql $readbackSql -ReadOnly $true -MaxRows 101 -TimeoutSec 15
    $readbackError = $null
    if (-not $readback.ok) {
        $readbackError = "Committed readback failed: $($readback.error)"
    } else {
        $rows = ConvertTo-DuneRowMaps -Result $readback
        $expectedById = @{}
        foreach ($target in $targets) { $expectedById[[string]$target.vehicle_id] = [string]$target.name }
        if ($rows.Count -ne $targets.Count -or @($rows | Where-Object {
            -not $expectedById.ContainsKey([string]$_['vehicle_id']) -or
            [string]$_['actor_name'] -cne $expectedById[[string]$_['vehicle_id']]
        }).Count -gt 0) {
            $readbackError = 'Exact committed readback could not be proven.'
        }
    }

    $restartError = $null
    try {
        $restart = Invoke-DuneBattlegroupRestart -Ip $Ip
    } catch {
        $restartError = $_.Exception.Message
    }
    if (-not $restartError -and -not $restart.ok) { $restartError = [string]$restart.message }
    if ($readbackError -or $restartError) {
        $parts = @()
        if ($readbackError) { $parts += $readbackError }
        if ($restartError) { $parts += "The battlegroup restart could not be launched: $restartError Restart it immediately." }
        else { $parts += 'The battlegroup restart was launched.' }
        return @{
            ok = $false
            status = 503
            committed = $true
            restart_started = (-not $restartError)
            error = "Vehicle names were committed. $($parts -join ' ')"
        }
    }
    return @{
        ok = $true
        renamed = $targets.Count
        vehicles = @($targets | ForEach-Object { @{ vehicle_id = $_.vehicle_id; name = $_.name } })
        restart_started = $true
        message = "Saved $($targets.Count) vehicle name change$(if ($targets.Count -eq 1) { '' } else { 's' }) and launched the battlegroup restart. Watch Server Health while it comes back."
    }
}

function Get-DuneVehicleIntegrityLive {
    param([string]$Ip, [long]$VehicleId)
    if ($VehicleId -le 0) { return @{ ok = $false; error = 'vehicle_id is required.' } }
    [void](Get-DuneVehicleHostScope -Ip $Ip)
    $sql = @"
SELECT vm.id::text AS module_id, vm.template_id,
       vm.stats->'FVehicleModuleDurabilityStats'->1->>'CurrentDurability' AS current_durability,
       vm.stats->'FVehicleModuleDurabilityStats'->1->>'MaxDurability' AS max_durability,
       vm.stats->'FVehicleModuleDurabilityStats'->1->>'DecayedMaxDurability' AS decayed_max_durability
FROM dune.vehicle_modules vm
JOIN dune.vehicles v ON v.id = vm.vehicle_id
JOIN dune.actors a ON a.id = v.id
WHERE vm.vehicle_id = $VehicleId::bigint
ORDER BY vm.id
LIMIT 501;
"@
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 501 -TimeoutSec 20
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    $rows = ConvertTo-DuneRowMaps -Result $result
    if ($rows.Count -gt 500) { return @{ ok = $false; error = 'Module detail exceeds the 500 module read limit.' } }
    $modules = @($rows | ForEach-Object {
        @{
            id = [string]$_['module_id']
            template_id = [string]$_['template_id']
            current_durability = ConvertTo-DuneVehicleNumber $_['current_durability']
            max_durability = ConvertTo-DuneVehicleNumber $_['max_durability']
            decayed_max_durability = ConvertTo-DuneVehicleNumber $_['decayed_max_durability']
            repair_max_durability = ConvertTo-DuneVehicleNumber (Get-DuneVehicleModuleDefaultDurability -TemplateId ([string]$_['template_id']))
        }
    })
    return @{ ok = $true; modules = $modules; source = 'live'; observed_at = [datetimeoffset]::UtcNow.ToString('o') }
}
