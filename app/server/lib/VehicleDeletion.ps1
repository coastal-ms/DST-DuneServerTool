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

function Get-DuneVehicleFleetLive {
    param([string]$Ip)
    $sql = @'
SELECT a.id::text AS vehicle_id,
       a.class,
       COALESCE(a.map, '') AS map,
       COALESCE(pa.actor_name, '') AS vehicle_name,
       COALESCE(string_agg(DISTINCT s.state::text, ', '), '') AS actor_state,
       COALESCE(string_agg(DISTINCT NULLIF(ps.character_name, ''), ', '), '') AS owners
FROM dune.permission_actor pa
JOIN dune.actors a ON a.id = pa.actor_id
LEFT JOIN dune.actor_state s ON s.actor_id = a.id
LEFT JOIN dune.permission_actor_rank par ON par.permission_actor_id = pa.actor_id
LEFT JOIN dune.player_state ps ON ps.player_controller_id = par.player_id
WHERE pa.actor_type = 2
GROUP BY a.id, a.class, a.map, pa.actor_name
ORDER BY COALESCE(NULLIF(pa.actor_name, ''), a.class), a.id;
'@
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 10000 -TimeoutSec 30
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    $vehicles = @()
    foreach ($row in @(ConvertTo-DuneRowMaps -Result $result)) {
        $vehicles += @{
            id           = [int64](ConvertTo-DuneInt $row['vehicle_id'])
            class        = ConvertTo-DuneVehicleShortClass ([string]$row['class'])
            vehicle_name = [string]$row['vehicle_name']
            map          = [string]$row['map']
            actor_state  = [string]$row['actor_state']
            owners       = [string]$row['owners']
        }
    }
    return @{ ok = $true; vehicles = $vehicles; total = $vehicles.Count }
}

function Get-DuneVehicleDeletionQueue {
    $state = Update-DuneVehicleDeletionExpiry (Read-DuneVehicleDeletionState)
    $started = ConvertFrom-DuneVehicleDeletionTimestamp ([string]$state.processing.started_at)
    $running = [bool]$state.processing.running -and
        $null -ne $started -and
        $started.AddHours($script:DuneVehicleDeletionRunningMaxHours) -gt [datetimeoffset]::UtcNow
    return @{ entries = @($state.entries); history = @($state.history); running = $running }
}

function Add-DuneVehicleDeletion {
    param(
        [Parameter(Mandatory)][long]$VehicleId,
        [Parameter(Mandatory)][string]$VehicleClass,
        [string]$VehicleName,
        [string]$Map,
        [string]$Owners,
        [string]$ActorState
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

function Invoke-DuneVehicleDeleteTransaction {
    param([string]$Ip, [long]$VehicleId)
    $sql = @'
BEGIN;
DO $dst$
BEGIN
    IF EXISTS (SELECT 1 FROM dune.actors WHERE id = __VEHICLE_ID__::bigint FOR UPDATE) THEN
        PERFORM dune.permission_actor_destroy(__VEHICLE_ID__::bigint);
        PERFORM dune.delete_actors(ARRAY[__VEHICLE_ID__::bigint]);
    END IF;
END
$dst$;
COMMIT;
'@.Replace('__VEHICLE_ID__', [string]$VehicleId)
    $delete = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 10 -TimeoutSec 60
    if (-not $delete.ok) { return @{ ok = $false; error = $delete.error } }
    $verify = Invoke-DuneSqlQuery -Ip $Ip -Sql "SELECT EXISTS(SELECT 1 FROM dune.actors WHERE id = $VehicleId::bigint)::text AS remains;" -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $verify.ok) { return @{ ok = $false; error = "Deletion ran, but verification failed: $($verify.error)" } }
    $rows = @(ConvertTo-DuneRowMaps -Result $verify)
    $remains = if ($rows.Count -gt 0) { ([string]$rows[0]['remains']).ToLowerInvariant() } else { 'true' }
    if ($remains -eq 't' -or $remains -eq 'true') {
        return @{ ok = $false; error = "Vehicle $VehicleId still exists after deletion." }
    }
    return @{ ok = $true }
}

function Invoke-DuneVehicleDeletionWindow {
    param([string]$Ip)
    $state = $null
    try {
        $state = Update-DuneVehicleDeletionExpiry (Read-DuneVehicleDeletionState)
        $entries = @($state.entries)
        if ($entries.Count -eq 0) { return @{ ok = $true; processed = 0; message = 'No vehicle deletions are queued.' } }
        $state.processing = @{
            running = $true
            started_at = [datetimeoffset]::UtcNow.ToString('o')
            finished_at = $null
        }
        Save-DuneVehicleDeletionState -State $state

        $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $backup = Invoke-DuneBackupShell -Ip $Ip -Script "/home/dune/.dune/bin/battlegroup backup 'dst-vehicle-delete-$stamp'" -TimeoutSec 900
        if ($null -eq $backup -or [int]$backup.rc -ne 0) {
            $detail = if ($backup) { ([string]$backup.out).Trim() } else { 'No backup result returned.' }
            return @{ ok = $false; error = "No vehicles were deleted because the mandatory safety backup failed. $detail" }
        }

        $stop = Invoke-DuneBackupShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup stop' -TimeoutSec 600
        if ($null -eq $stop -or [int]$stop.rc -ne 0) {
            [void](Invoke-DuneBackupShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup start' -TimeoutSec 900)
            $detail = if ($stop) { ([string]$stop.out).Trim() } else { 'No stop result returned.' }
            return @{ ok = $false; error = "No vehicles were deleted because the battlegroup did not stop cleanly. $detail" }
        }

        $completed = @()
        $failed = @()
        $start = $null
        try {
            foreach ($entry in $entries) {
                $result = Invoke-DuneVehicleDeleteTransaction -Ip $Ip -VehicleId ([int64]$entry.vehicle_id)
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
            }
        } finally {
            $start = Invoke-DuneBackupShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup start' -TimeoutSec 900
        }

        $retry = @($failed | Where-Object { $_.status -eq 'queued' })
        $terminal = @($failed | Where-Object { $_.status -eq 'failed' })
        $state.entries = $retry
        $state.history = @($completed + $terminal + @($state.history) | Select-Object -First 50)
        Save-DuneVehicleDeletionState -State $state

        if ($null -eq $start -or [int]$start.rc -ne 0) {
            $detail = if ($start) { ([string]$start.out).Trim() } else { 'No start result returned.' }
            return @{
                ok = $false; processed = $completed.Count; failed = $failed.Count
                error = "Vehicle deletions finished, but the battlegroup did not start cleanly. Start it manually. $detail"
            }
        }
        if ($failed.Count -gt 0) {
            return @{
                ok = $false; processed = $completed.Count; failed = $failed.Count
                error = "Deleted $($completed.Count) vehicle(s); $($failed.Count) failed and remain queued when retryable."
            }
        }
        return @{
            ok = $true; processed = $completed.Count; failed = 0
            message = "Safety backup completed, $($completed.Count) vehicle(s) deleted and verified, and the battlegroup restarted."
        }
    } finally {
        if ($null -ne $state -and [bool]$state.processing.running) {
            $state.processing.running = $false
            $state.processing.finished_at = [datetimeoffset]::UtcNow.ToString('o')
            Save-DuneVehicleDeletionState -State $state
        }
    }
}
