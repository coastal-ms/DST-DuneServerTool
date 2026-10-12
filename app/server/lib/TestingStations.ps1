# Testing Station progression for a selected offline self-hosted character.
function Get-DuneTestingStationSelection {
    param([string]$Station)
    $stations = @('DA_Dgn_024_Darkness','DA_Dgn_089_Radiation','DA_Dgn_136_Fire','DA_Dgn_152_Electric','DA_Dgn_195_Poison','DA_Dgn_Pit')
    if ($Station -ceq 'all') { return $stations }
    if ($Station -cnotin $stations) { throw 'Choose a supported Testing Station or all six.' }
    return @($Station)
}

function Get-DuneTestingStationUnlockSql {
    param([long]$PawnId, [long]$ControllerId, [long]$AccountId, [string]$Station)
    if ($PawnId -le 0 -or $ControllerId -le 0 -or $AccountId -le 0) { throw 'A current character identity is required.' }
    $selected = @(Get-DuneTestingStationSelection -Station $Station)
    $stationArray = ConvertTo-DunePgTextArray -Values $selected
    return @'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
CREATE TEMP TABLE dst_testing_station_result(added integer, selected integer) ON COMMIT DROP;
DO $dst$
DECLARE
    station text;
    completion bigint;
    added integer := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(__CONTROLLER__::bigint);
    PERFORM 1 FROM dune.encrypted_player_state
    WHERE player_pawn_id=__PAWN__::bigint AND player_controller_id=__CONTROLLER__::bigint
      AND account_id=__ACCOUNT__::bigint AND online_status::text='Offline'
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'The selected character changed or is not fully Offline. No unlock was saved.'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attname='player_id'
        JOIN pg_attribute b ON b.attrelid=c.confrelid AND b.attname='id'
        WHERE c.contype='f' AND c.conrelid='dune.dungeon_completion_players'::regclass
          AND c.confrelid='dune.actors'::regclass
          AND c.conkey=ARRAY[a.attnum] AND c.confkey=ARRAY[b.attnum]
    ) THEN RAISE EXCEPTION 'Unsupported Testing Station player-link schema. No unlock was saved.'; END IF;
    FOREACH station IN ARRAY __STATIONS__ LOOP
        IF EXISTS (
            SELECT 1 FROM dune.dungeon_completion d
            JOIN dune.dungeon_completion_players p ON p.completion_id=d.completion_id
            WHERE p.player_id=__CONTROLLER__::bigint AND d.dungeon_id=station AND d.difficulty>=1000
        ) THEN CONTINUE; END IF;
        INSERT INTO dune.dungeon_completion(dungeon_id,difficulty,duration_ms,players_num)
        VALUES(station,1000,2147483647,1) RETURNING completion_id INTO completion;
        INSERT INTO dune.dungeon_completion_players(player_id,completion_id) VALUES(__CONTROLLER__::bigint,completion);
        added := added+1;
    END LOOP;
    IF (SELECT count(DISTINCT d.dungeon_id) FROM dune.dungeon_completion d
        JOIN dune.dungeon_completion_players p ON p.completion_id=d.completion_id
        WHERE p.player_id=__CONTROLLER__::bigint AND d.dungeon_id=ANY(__STATIONS__) AND d.difficulty>=1000) <> __COUNT__ THEN
        RAISE EXCEPTION 'Testing Station unlock verification failed. No unlock was saved.';
    END IF;
    INSERT INTO dst_testing_station_result VALUES(added,__COUNT__);
END
$dst$;
SELECT added::text AS added, selected::text AS selected FROM dst_testing_station_result;
COMMIT;
'@.Replace('__PAWN__',[string]$PawnId).Replace('__CONTROLLER__',[string]$ControllerId).Replace('__ACCOUNT__',[string]$AccountId).Replace('__STATIONS__',$stationArray).Replace('__COUNT__',[string]$selected.Count)
}

function Invoke-DunePlayerUnlockTestingStations {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId, [long]$AccountId, [string]$Station)
    $sql = Get-DuneTestingStationUnlockSql -PawnId $PawnId -ControllerId $ControllerId -AccountId $AccountId -Station $Station
    $scope = Get-DuneVehicleHostScope -Ip $Ip
    $probe = Invoke-DuneSqlQuery -Ip $Ip -Sql @"
SELECT online_status::text AS status FROM dune.player_state
WHERE player_pawn_id=$PawnId::bigint AND player_controller_id=$ControllerId::bigint AND account_id=$AccountId::bigint;
"@ -ReadOnly $true -MaxRows 2 -TimeoutSec 15
    if (-not $probe.ok) { return @{ ok=$false; error="Character status could not be verified. $($probe.error)" } }
    $players = ConvertTo-DuneRowMaps -Result $probe
    if ($players.Count -ne 1 -or [string]$players[0]['status'] -cne 'Offline') {
        return @{ ok=$false; error='The selected character must be fully Offline before unlocking Testing Stations.' }
    }
    $backup = Invoke-DuneVerifiedSafetyBackup -Ip $Ip -StemPrefix 'dst-testing-stations' -ProofLabel 'DST_TESTING_STATIONS_BACKUP'
    if (-not $backup.ok) { return @{ ok=$false; error="Testing Station unlock stopped because $($backup.error)" } }
    $current = Get-DuneVehicleHostScope -Ip $Ip
    if ($backup.database_scope -cne $scope.key -or $current.key -cne $scope.key) {
        return @{ ok=$false; error='The database changed during the backup. No unlock was attempted.' }
    }
    $write = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 45
    if (-not $write.ok) { return @{ ok=$false; error="Testing Station transaction failed. $($write.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $write
    if ($rows.Count -ne 1) { return @{ ok=$false; error='The write result could not be read. Refresh the character before retrying.' } }
    return @{ ok=$true; message='Testing Station difficulties unlocked for this character. Log in and select a difficulty; faction requirements still apply.'; added=[int]$rows[0]['added']; selected=[int]$rows[0]['selected']; safetyBackup=$backup.path }
}
