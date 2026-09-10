# Safe vehicle deletion queue. Deletions are only applied inside an explicit
# backup -> battlegroup stop -> database mutation -> battlegroup start window.

$script:DuneVehicleDeletionStateFile = $null
$script:DuneVehicleDeletionMaxAgeDays = 14
$script:DuneVehicleDeletionMaxAttempts = 3
$script:DuneVehicleDeletionRunningMaxHours = 2

function Get-DuneVehicleDeletionStatePath {
    if ($script:DuneVehicleDeletionStateFile) { return $script:DuneVehicleDeletionStateFile }
    $dir = if ($env:APPDATA) { Join-Path $env:APPDATA 'DuneServer' } else { $env:TEMP }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'vehicle-deletions.json')
}

function New-DuneVehicleDeletionState {
    return @{
        version = 1
        entries = @()
        history = @()
        processing = @{ running = $false; started_at = $null; finished_at = $null }
        updated = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Read-DuneVehicleDeletionState {
    $path = Get-DuneVehicleDeletionStatePath
    if (-not (Test-Path -LiteralPath $path)) { return (New-DuneVehicleDeletionState) }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-DuneVehicleDeletionState) }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return @{
            version = 1
            entries = @($parsed.entries)
            history = @($parsed.history)
            processing = if ($parsed.processing) {
                @{
                    running = [bool]$parsed.processing.running
                    started_at = [string]$parsed.processing.started_at
                    finished_at = [string]$parsed.processing.finished_at
                    last_error = [string]$parsed.processing.last_error
                }
            } else {
                @{ running = $false; started_at = $null; finished_at = $null }
            }
            updated = [string]$parsed.updated
        }
    } catch {
        throw "Vehicle deletion queue could not be read: $($_.Exception.Message)"
    }
}

function Save-DuneVehicleDeletionState {
    param([Parameter(Mandatory)]$State)
    $path = Get-DuneVehicleDeletionStatePath
    $State.updated = (Get-Date).ToUniversalTime().ToString('o')
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $tmp,
            ($State | ConvertTo-Json -Depth 8),
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Set-DuneVehicleDeletionEntryValue {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )
    if ($Entry -is [System.Collections.IDictionary]) {
        $Entry[$Name] = $Value
    } else {
        $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function ConvertFrom-DuneVehicleDeletionTimestamp {
    param([string]$Value)
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    if (-not $ok) { return $null }
    return $parsed
}

function Update-DuneVehicleDeletionExpiry {
    param([Parameter(Mandatory)]$State)
    $now = [datetimeoffset]::UtcNow
    $pending = @()
    $expired = @()
    foreach ($entry in @($State.entries)) {
        $created = ConvertFrom-DuneVehicleDeletionTimestamp ([string]$entry.created_at)
        if ($null -ne $created -and $created.AddDays($script:DuneVehicleDeletionMaxAgeDays) -lt $now) {
            Set-DuneVehicleDeletionEntryValue -Entry $entry -Name status -Value 'expired'
            Set-DuneVehicleDeletionEntryValue -Entry $entry -Name finished_at -Value $now.ToString('o')
            Set-DuneVehicleDeletionEntryValue -Entry $entry -Name message -Value "Expired after $script:DuneVehicleDeletionMaxAgeDays days without a safe deletion window."
            $expired += $entry
        } else {
            $pending += $entry
        }
    }
    $State.entries = $pending
    if ($expired.Count -gt 0) {
        $State.history = @($expired + @($State.history) | Select-Object -First 50)
    }
    return $State
}

function ConvertTo-DuneVehicleShortClass {
    param([string]$Class)
    $short = [string]$Class
    $dot = $short.LastIndexOf('.')
    if ($dot -ge 0 -and $dot -lt $short.Length - 1) { $short = $short.Substring($dot + 1) }
    $quote = $short.IndexOf("'")
    if ($quote -ge 0) { $short = $short.Substring(0, $quote) }
    return $short
}

function Get-DuneVehicleDeletionQueue {
    $state = Update-DuneVehicleDeletionExpiry (Read-DuneVehicleDeletionState)
    $started = ConvertFrom-DuneVehicleDeletionTimestamp ([string]$state.processing.started_at)
    $running = [bool]$state.processing.running -and
        $null -ne $started -and
        $started.AddHours($script:DuneVehicleDeletionRunningMaxHours) -gt [datetimeoffset]::UtcNow
    return @{ entries = @($state.entries); history = @($state.history); running = $running; last_error = [string]$state.processing.last_error; revision = Get-DuneVehicleDeletionRevision -Entries @($state.entries) }
}

function Get-DuneVehicleDeletionRevision {
    param([array]$Entries)
    $payload = ConvertTo-Json -InputObject @($Entries | Sort-Object id) -Depth 8 -Compress
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Add-DuneVehicleDeletion {
    param(
        [Parameter(Mandatory)][long]$VehicleId,
        [Parameter(Mandatory)][string]$VehicleClass,
        [string]$VehicleName,
        [string]$Map,
        [string]$Owners,
        [string]$ActorState,
        [string]$TargetRevision,
        [int]$ModuleCount = 0,
        [int]$CargoStackCount = 0,
        [string]$DatabaseScope
    )
    if ($VehicleId -le 0) { return @{ ok = $false; error = 'vehicle_id is required.' } }
    $state = Update-DuneVehicleDeletionExpiry (Read-DuneVehicleDeletionState)
    $existing = @($state.entries | Where-Object { [int64]$_.vehicle_id -eq $VehicleId } | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        return @{ ok = $true; duplicate = $true; entry = $existing[0]; message = "Vehicle $VehicleId is already queued." }
    }
    $entry = [ordered]@{
        id           = [guid]::NewGuid().ToString('N')
        vehicle_id   = $VehicleId
        class        = $VehicleClass
        vehicle_name = $VehicleName
        map          = $Map
        owners       = $Owners
        actor_state  = $ActorState
        target_revision = $TargetRevision
        module_count = $ModuleCount
        cargo_stack_count = $CargoStackCount
        database_scope = $DatabaseScope
        status       = 'queued'
        attempts     = 0
        created_at   = [datetime]::UtcNow.ToString('o')
        message      = 'Waiting for an explicit safe restart window.'
    }
    $state.entries = @(@($state.entries) + $entry)
    Save-DuneVehicleDeletionState -State $state
    return @{ ok = $true; entry = $entry; message = "Queued vehicle $VehicleId for safe deletion." }
}

function Remove-DuneVehicleDeletion {
    param([Parameter(Mandatory)][string]$EntryId)
    $state = Update-DuneVehicleDeletionExpiry (Read-DuneVehicleDeletionState)
    $before = @($state.entries).Count
    $state.entries = @($state.entries | Where-Object { [string]$_.id -ne $EntryId })
    if (@($state.entries).Count -eq $before) { return @{ ok = $false; error = 'Queued deletion was not found.' } }
    Save-DuneVehicleDeletionState -State $state
    return @{ ok = $true; message = 'Queued vehicle deletion cancelled.' }
}

function Test-DuneVehicleWindowStopped {
    param([string]$Ip, [string]$DatabaseScope)
    $scope = Get-DuneVehicleHostScope -Ip $Ip
    if ($scope.key -cne $DatabaseScope) { return @{ ok = $false; error = 'Vehicle database scope changed. Cancel and requeue the target.' } }
    $probe = Invoke-DuneBackupShell -Ip $Ip -Script "kubectl get battlegroup '$($scope.world)' -n '$($scope.namespace)' -o jsonpath='{.status.phase}'" -TimeoutSec 30
    if ($null -eq $probe -or $probe.rc -ne 0 -or ([string]$probe.out).Trim() -cne 'Stopped') {
        return @{ ok = $false; error = 'A fresh Stopped battlegroup state could not be proven. No deletion was attempted.' }
    }
    $sessions = Invoke-DuneSqlQuery -Ip $Ip -Sql "SELECT count(*)::text AS sessions FROM pg_stat_activity WHERE datname = current_database() AND application_name LIKE 'DuneSandbox%' AND pid <> pg_backend_pid();" -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $sessions.ok) { return @{ ok = $false; error = "Live game session preflight failed: $($sessions.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $sessions
    if ($rows.Count -ne 1 -or [string]$rows[0]['sessions'] -cne '0') {
        return @{ ok = $false; error = 'No-session preflight did not prove all game database connections are gone.' }
    }
    return @{ ok = $true }
}

function Invoke-DuneVerifiedSafetyBackup {
    param(
        [string]$Ip,
        [ValidatePattern('^[a-z0-9-]+$')][string]$StemPrefix,
        [ValidatePattern('^[A-Z0-9_]+$')][string]$ProofLabel
    )
    $scope = Get-DuneVehicleHostScope -Ip $Ip
    $stem = $StemPrefix + '-' + [guid]::NewGuid().ToString('N')
    $script = @'
set -euo pipefail
/home/dune/.dune/bin/battlegroup backup '__STEM__'
mapfile -t files < <(find '/funcom/artifacts/database-dumps/__WORLD__' -maxdepth 1 -type f \( -name '__STEM__' -o -name '__STEM__.backup' \))
[ "${#files[@]}" -eq 1 ]
bytes=$(stat -c %s -- "${files[0]}")
[ "$bytes" -gt 1024 ]
printf '\n__PROOF__=%s|%s\n' "${files[0]}" "$bytes"
'@.Replace('__STEM__', $stem).Replace('__WORLD__', $scope.world).Replace('__PROOF__', $ProofLabel)
    $backup = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 900
    $proof = if ($backup) {
        [regex]::Matches([string]$backup.out, "(?m)^$([regex]::Escape($ProofLabel))=([^\r\n|]+)\|([0-9]+)\r?$")
    } else { @() }
    if ($null -eq $backup -or $backup.rc -ne 0 -or $proof.Count -ne 1 -or [long]$proof[0].Groups[2].Value -le 1024) {
        return @{ ok = $false; error = 'the fresh safety backup was not verified on disk. No database write was attempted.' }
    }
    return @{ ok = $true; path = $proof[0].Groups[1].Value; bytes = [long]$proof[0].Groups[2].Value; database_scope = $scope.key }
}

function Invoke-DuneVehicleSafetyBackup {
    param([string]$Ip)
    $result = Invoke-DuneVerifiedSafetyBackup -Ip $Ip -StemPrefix 'dst-vehicle-delete' -ProofLabel 'DST_VEHICLE_BACKUP'
    if (-not $result.ok) {
        $result.error = 'The fresh safety backup was not verified on disk. No vehicles were deleted.'
    }
    return $result
}

function Invoke-DuneVehicleDeleteTransaction {
    param([string]$Ip, [long]$VehicleId, [string]$TargetRevision, [string]$DatabaseScope)
    if ($VehicleId -le 0 -or $TargetRevision -cnotmatch '^[a-f0-9]{32}$' -or $DatabaseScope -cnotmatch '^[a-f0-9]{64}$') {
        return @{ ok = $false; error = 'A bound target snapshot is required. Cancel and requeue legacy entries.' }
    }
    $stopped = Test-DuneVehicleWindowStopped -Ip $Ip -DatabaseScope $DatabaseScope
    if (-not $stopped.ok) { return $stopped }
    $revisionSql = Get-DuneVehicleTargetRevisionSql -DatabaseScope $DatabaseScope
    $sql = @'
BEGIN;
SET LOCAL search_path TO dune, public;
SET LOCAL lock_timeout = '5s';
DO $dst$
DECLARE
    actual_revision text;
    inventory_ids bigint[];
    item_ids bigint[];
BEGIN
    PERFORM 1 FROM dune.actors a JOIN dune.vehicles v ON v.id = a.id
    WHERE a.id = __VEHICLE_ID__::bigint FOR UPDATE OF a, v;
    IF NOT FOUND THEN RAISE EXCEPTION 'Exact vehicle no longer exists; cancel its queued removal.'; END IF;
    PERFORM pg_stat_clear_snapshot();
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
               AND application_name LIKE 'DuneSandbox%' AND pid <> pg_backend_pid()) THEN
        RAISE EXCEPTION 'A live game database session remains; refusing vehicle deletion.';
    END IF;
    IF EXISTS (SELECT 1 FROM dune.actor_state WHERE actor_id = __VEHICLE_ID__::bigint
               AND state::text = 'Travel') THEN
        RAISE EXCEPTION 'Vehicle travel is still pending; refusing deletion.';
    END IF;
    PERFORM 1 FROM dune.vehicle_modules WHERE vehicle_id = __VEHICLE_ID__::bigint FOR UPDATE;
    PERFORM 1 FROM dune.inventories inv
    WHERE inv.actor_id = __VEHICLE_ID__::bigint
       OR inv.vehicle_module_id IN (SELECT id FROM dune.vehicle_modules WHERE vehicle_id = __VEHICLE_ID__::bigint)
    FOR UPDATE;
    IF EXISTS (
        SELECT 1
        FROM dune.inventories inv
        WHERE inv.actor_id = __VEHICLE_ID__::bigint
          AND inv.inventory_type = 0
          AND (inv.exchange_id IS NOT NULL OR inv.item_id IS NOT NULL OR inv.vehicle_module_id IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'Vehicle cargo hold has conflicting ownership references; refusing deletion.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM dune.inventories inv
        WHERE (inv.vehicle_module_id IN (SELECT id FROM dune.vehicle_modules WHERE vehicle_id = __VEHICLE_ID__::bigint)
               AND inv.actor_id IS NOT NULL
               AND inv.actor_id <> __VEHICLE_ID__::bigint)
           OR (inv.actor_id = __VEHICLE_ID__::bigint AND inv.vehicle_module_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dune.vehicle_modules vm
                               WHERE vm.id = inv.vehicle_module_id AND vm.vehicle_id = __VEHICLE_ID__::bigint))
    ) THEN
        RAISE EXCEPTION 'Vehicle deletion closure includes inventory owned by another actor; refusing deletion.';
    END IF;
    SELECT __REVISION_SQL__ INTO actual_revision
    FROM dune.vehicles v JOIN dune.actors a ON a.id = v.id
    LEFT JOIN dune.permission_actor pa ON pa.actor_id = a.id AND pa.actor_type = 2
    WHERE v.id = __VEHICLE_ID__::bigint;
    IF actual_revision IS DISTINCT FROM '__REVISION__' THEN
        RAISE EXCEPTION 'Vehicle identity, ownership, modules or cargo changed; cancel and requeue.';
    END IF;
    SELECT array_agg(inv.id) INTO inventory_ids FROM dune.inventories inv
    WHERE inv.actor_id = __VEHICLE_ID__::bigint OR inv.vehicle_module_id IN
        (SELECT id FROM dune.vehicle_modules WHERE vehicle_id = __VEHICLE_ID__::bigint);
    SELECT array_agg(id) INTO item_ids FROM dune.items WHERE inventory_id = ANY(inventory_ids);
    PERFORM dune.permission_actor_destroy(__VEHICLE_ID__::bigint);
    PERFORM dune.delete_actors(ARRAY[__VEHICLE_ID__::bigint]);
    IF EXISTS (SELECT 1 FROM dune.inventories WHERE id = ANY(inventory_ids))
       OR EXISTS (SELECT 1 FROM dune.items WHERE id = ANY(item_ids))
       OR __REMAINS_SQL__ THEN
        RAISE EXCEPTION 'Vehicle dependent-record postflight failed; deletion rolled back.';
    END IF;
    PERFORM pg_stat_clear_snapshot();
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
               AND application_name LIKE 'DuneSandbox%' AND pid <> pg_backend_pid()) THEN
        RAISE EXCEPTION 'A game database session appeared during deletion; rolling back.';
    END IF;
END
$dst$;
COMMIT;
'@
    $remainsSql = @'
EXISTS(SELECT 1 FROM dune.actors WHERE id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.vehicles WHERE id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.vehicle_modules WHERE vehicle_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.permission_actor WHERE actor_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.permission_actor_rank WHERE permission_actor_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.recovered_vehicles WHERE vehicle_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.backup_vehicles WHERE vehicle_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.inventories WHERE actor_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.markers WHERE marker_hash_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.player_markers WHERE marker_hash_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.overmap_players WHERE vehicle_id = __VEHICLE_ID__::bigint)
OR EXISTS(SELECT 1 FROM dune.actor_state WHERE actor_id = __VEHICLE_ID__::bigint)
'@.Replace('__VEHICLE_ID__', [string]$VehicleId)
    $sql = $sql.Replace('__REVISION_SQL__', $revisionSql).Replace('__REVISION__', $TargetRevision).Replace('__REMAINS_SQL__', $remainsSql).Replace('__VEHICLE_ID__', [string]$VehicleId)
    $delete = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 10 -TimeoutSec 60
    if (-not $delete.ok) { return @{ ok = $false; error = $delete.error } }
    $verify = Invoke-DuneSqlQuery -Ip $Ip -Sql "SELECT ($remainsSql)::text AS remains;" -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $verify.ok) { return @{ ok = $false; error = "Deletion ran, but verification failed: $($verify.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $verify
    if ($rows.Count -ne 1 -or [string]$rows[0]['remains'] -notin @('f', 'false')) {
        return @{ ok = $false; error = "Vehicle $VehicleId deletion could not be proven by postflight." }
    }
    return @{ ok = $true }
}

function Invoke-DuneVehicleDeletionWindow {
    param([string]$Ip, [string]$QueueRevision)
    $state = $null
    try {
        $state = Update-DuneVehicleDeletionExpiry (Read-DuneVehicleDeletionState)
        $entries = @($state.entries)
        if ($QueueRevision -cne (Get-DuneVehicleDeletionRevision -Entries $entries)) {
            return @{ ok = $false; error = 'The deletion queue changed. Refresh and confirm the exact current target list.' }
        }
        if ($entries.Count -eq 0) { return @{ ok = $true; processed = 0; message = 'No vehicle deletions are queued.' } }
        foreach ($entry in $entries) {
            if ([string]$entry.target_revision -notmatch '^[a-f0-9]{32}$' -or [string]$entry.database_scope -notmatch '^[a-f0-9]{64}$') {
                return @{ ok = $false; error = 'A queued entry lacks a bound snapshot. Cancel and requeue it before processing.' }
            }
            $fresh = Get-DuneVehicleFleetLive -Ip $Ip -VehicleId ([long]$entry.vehicle_id)
            if (-not $fresh.ok) { return @{ ok = $false; error = "Vehicle preflight failed: $($fresh.error)" } }
            if (@($fresh.vehicles).Count -ne 1 -or $fresh.database_scope -cne $entry.database_scope -or
                $fresh.vehicles[0].target_revision -cne $entry.target_revision -or $fresh.vehicles[0].deletion_blocked_reason) {
                return @{ ok = $false; error = "Vehicle $($entry.vehicle_id) changed or is unsafe. Cancel and requeue after resolving it in-game." }
            }
        }
        $state.processing = @{
            running = $true
            started_at = [datetimeoffset]::UtcNow.ToString('o')
            finished_at = $null
        }
        Save-DuneVehicleDeletionState -State $state

        $backup = Invoke-DuneVehicleSafetyBackup -Ip $Ip
        if (-not $backup.ok) { $state.processing.last_error = $backup.error; return $backup }
        if (@($entries | Where-Object { $_.database_scope -cne $backup.database_scope }).Count -gt 0) {
            return @{ ok = $false; error = 'The database scope changed before backup. No vehicles were deleted.' }
        }
        foreach ($entry in $entries) { Set-DuneVehicleDeletionEntryValue -Entry $entry -Name safety_backup -Value $backup.path }
        Save-DuneVehicleDeletionState -State $state

        $completed = @()
        $failed = @()
        $start = $null
        $windowError = $null
        try {
            $stop = Invoke-DuneBackupShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup stop' -TimeoutSec 600
            if ($null -eq $stop -or $stop.rc -ne 0) {
                throw "No vehicles were deleted because the battlegroup did not stop cleanly. $([string]$stop.out)"
            }
            foreach ($entry in $entries) {
                $result = Invoke-DuneVehicleDeleteTransaction -Ip $Ip -VehicleId ([int64]$entry.vehicle_id) -TargetRevision $entry.target_revision -DatabaseScope $entry.database_scope
                if ($result.ok) {
                    Set-DuneVehicleDeletionEntryValue -Entry $entry -Name status -Value 'deleted'
                    Set-DuneVehicleDeletionEntryValue -Entry $entry -Name finished_at -Value ([datetime]::UtcNow.ToString('o'))
                    Set-DuneVehicleDeletionEntryValue -Entry $entry -Name message -Value 'Vehicle and dependent records deleted and verified.'
                    $completed += $entry
                } else {
                    $attempts = [int]$entry.attempts + 1
                    Set-DuneVehicleDeletionEntryValue -Entry $entry -Name attempts -Value $attempts
                    Set-DuneVehicleDeletionEntryValue -Entry $entry -Name status -Value $(if ($attempts -ge $script:DuneVehicleDeletionMaxAttempts) { 'failed' } else { 'queued' })
                    Set-DuneVehicleDeletionEntryValue -Entry $entry -Name message -Value ([string]$result.error)
                    $failed += $entry
                }
                $state.entries = @($entries | Where-Object { $_.status -eq 'queued' })
                $state.history = @($completed + @($failed | Where-Object status -eq 'failed') + @($state.history | Where-Object { $_.id -notin @($entries.id) }) | Select-Object -First 50)
                Save-DuneVehicleDeletionState -State $state
            }
        } catch {
            $windowError = $_.Exception.Message
            $state.processing.last_error = $windowError
        } finally {
            $start = Invoke-DuneBackupShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup start' -TimeoutSec 900
        }

        $retry = @($entries | Where-Object { $_.status -eq 'queued' })
        $terminal = @($failed | Where-Object { $_.status -eq 'failed' })
        $state.entries = $retry
        $state.history = @($completed + $terminal + @($state.history | Where-Object { $_.id -notin @($entries.id) }) | Select-Object -First 50)
        Save-DuneVehicleDeletionState -State $state

        if ($null -eq $start -or [int]$start.rc -ne 0) {
            $detail = if ($start) { ([string]$start.out).Trim() } else { 'No start result returned.' }
            $state.processing.last_error = "Battlegroup restart failed. Start it manually. $detail $windowError"
            return @{
                ok = $false; processed = $completed.Count; failed = $failed.Count
                error = "Vehicle deletion window ended, but the battlegroup did not start cleanly. Start it manually. $detail $windowError"
            }
        }
        if ($windowError) { return @{ ok = $false; processed = $completed.Count; error = $windowError } }
        if ($failed.Count -gt 0) {
            return @{
                ok = $false; processed = $completed.Count; failed = $failed.Count
                error = "Deleted $($completed.Count) vehicle(s); $($failed.Count) failed and remain queued when retryable."
            }
        }
        $vehicleNoun = if ($completed.Count -eq 1) { 'vehicle' } else { 'vehicles' }
        return @{
            ok = $true; processed = $completed.Count; failed = 0
            message = "Safety backup completed, $($completed.Count) $vehicleNoun deleted and verified, and the battlegroup restarted."
        }
    } finally {
        if ($null -ne $state -and [bool]$state.processing.running) {
            $state.processing.running = $false
            $state.processing.finished_at = [datetimeoffset]::UtcNow.ToString('o')
            Save-DuneVehicleDeletionState -State $state
        }
    }
}
