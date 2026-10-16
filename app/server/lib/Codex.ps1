# Lore fragments share journey storage; only exact catalog nodes are counted.
# Completion records ownership; reveal state separately controls visibility.
function ConvertTo-DuneCodexOwnership {
    param([AllowEmptyCollection()][object[]]$Nodes = @())
    $path = Get-DuneSoloDataFilePath -Name 'codex-catalog.json'
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $saved = @{}
    $revealed = @{}
    foreach ($node in $Nodes) {
        $id = [string]$node.node_id
        if ($id -and $id.StartsWith('DA_Dunipedia', [StringComparison]::Ordinal)) {
            if ($saved.ContainsKey($id)) { throw 'Duplicate codex records in character data.' }
            $saved[$id] = ([string]$node.is_complete).ToLowerInvariant() -in @('true','t','1')
            $revealed[$id] = ([string]$node.is_revealed).ToLowerInvariant() -in @('true','t','1')
        }
    }
    if ($saved.Count -eq 0) { throw 'Codex records are unavailable for this character.' }
    $fragments = @($catalog.fragments | ForEach-Object {
        $id = [string]$_.id
        @{
            id = $id; category = [string]$_.category
            entryId = [string]$_.entryId; entry = [string]$_.entry
            fragment = [string]$_.fragment
            owned = $saved.ContainsKey($id) -and $saved[$id]
            revealed = $revealed[$id] -and @($_.ancestors | Where-Object { -not $revealed[[string]$_] }).Count -eq 0
        }
    })
    return @{
        ok = $true; fragments = $fragments; total = $fragments.Count
        owned = @($fragments | Where-Object { $_.owned }).Count
        missing = @($fragments | Where-Object { -not $_.owned }).Count
    }
}

function Get-DuneSoloCodex {
    Assert-DuneSoloSupportedPlatform
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before viewing codex.'
    }
    $result = Invoke-DuneSoloHelper -Command 'codex' -Arguments @{ input = $profile.dbPath }
    if (-not $result.ok) { throw 'Could not read codex records.' }
    $ownership = ConvertTo-DuneCodexOwnership -Nodes @($result.nodes)
    $ownership.profileToken = Get-DuneSoloProfileToken -DbPath $profile.dbPath
    return $ownership
}

function Get-DunePlayerCodexLive {
    param([string]$Ip, [long]$AccountId)
    $journey = Get-DunePlayerJourneyLive -Ip $Ip -AccountId $AccountId
    if (-not $journey.ok) { return $journey }
    return ConvertTo-DuneCodexOwnership -Nodes @($journey.nodes)
}

function Get-DuneCodexSelection {
    param([object[]]$Ids)
    $catalog = Get-Content -LiteralPath (Get-DuneSoloDataFilePath -Name 'codex-catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $catalog.fragments) { [void]$allowed.Add([string]$row.id) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($Ids.Count -lt 1 -or $Ids.Count -gt $allowed.Count) { throw 'Choose codex fragments to grant.' }
    foreach ($id in $Ids) {
        if ($id -isnot [string] -or -not $allowed.Contains($id) -or -not $seen.Add($id)) {
            throw 'Choose exact supported codex fragments without duplicates.'
        }
    }
    return $Ids
}

function Invoke-DuneSoloCodexGrant {
    param([object[]]$Ids, [string]$Confirm)
    if ($Confirm -cne 'GRANT CODEX FRAGMENTS') { throw 'Confirm the selected codex grant.' }
    $selected = @(Get-DuneCodexSelection -Ids $Ids)
    Assert-DuneSoloSupportedPlatform
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { throw 'Connect a valid Solo save first.' }
    $directory = Join-Path (Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath) 'pre-codex'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $selectionFile = Join-Path ([IO.Path]::GetTempPath()) ('dst-codex-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($selectionFile, (ConvertTo-Json -InputObject $selected -Compress), [Text.UTF8Encoding]::new($false))
        return Invoke-DuneSoloHelper -Command 'grant-codex' -Arguments @{
            input = $profile.dbPath
            'safety-backup' = Join-Path $directory ('game-before-codex-' + [guid]::NewGuid().ToString('N') + '.db')
            catalog = Get-DuneSoloDataFilePath -Name 'codex-catalog.json'
            selection = $selectionFile
        }
    } finally {
        if (Test-Path -LiteralPath $selectionFile -PathType Leaf) { Remove-Item -LiteralPath $selectionFile -Force }
    }
}

function Get-DuneCodexGrantSql {
    param([long]$AccountId, [object[]]$Ids)
    if ($AccountId -le 0) { throw 'A current character account is required.' }
    $selected = @(Get-DuneCodexSelection -Ids $Ids)
    $array = ConvertTo-DunePgTextArray -Values $selected
    $catalog = Get-Content -LiteralPath (Get-DuneSoloDataFilePath -Name 'codex-catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ancestors = @($catalog.fragments | Where-Object { $selected -ccontains [string]$_.id } | ForEach-Object { $_.ancestors } | Sort-Object -Unique)
    $required = @(@($selected) + @($ancestors) | Sort-Object -Unique)
    foreach ($parent in $ancestors) { if (-not ([string]$parent).StartsWith('DA_Dunipedia',[StringComparison]::Ordinal)) { throw 'Invalid codex reveal mapping.' } }
    $requiredArray = ConvertTo-DunePgTextArray -Values $required
    $parentArray = ConvertTo-DunePgTextArray -Values $ancestors
    return @'
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE dst_codex_result(granted integer) ON COMMIT DROP;
DO $dst$
DECLARE
    target_character bigint;
    changed integer;
BEGIN
    PERFORM 1 FROM dune.encrypted_player_state WHERE account_id=__ACCOUNT__::bigint AND online_status::text='Offline' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'The character must be fully Offline.'; END IF;
    SELECT id INTO STRICT target_character FROM dune.player_state WHERE account_id=__ACCOUNT__::bigint;
    PERFORM 1 FROM dune.journey_story_node WHERE character_id=target_character AND story_node_id=ANY(__REQUIRED__) FOR UPDATE;
    IF (SELECT COUNT(*) FROM dune.journey_story_node WHERE character_id=target_character AND story_node_id=ANY(__REQUIRED__)) <> __REQUIRED_COUNT__ THEN
        RAISE EXCEPTION 'A selected fragment is unavailable. Nothing was granted.';
    END IF;
    UPDATE dune.journey_story_node SET complete_condition_state='true'::jsonb,reveal_condition_state='true'::jsonb
    WHERE character_id=target_character AND story_node_id=ANY(__IDS__) AND (complete_condition_state IS DISTINCT FROM 'true'::jsonb OR reveal_condition_state IS DISTINCT FROM 'true'::jsonb);
    GET DIAGNOSTICS changed = ROW_COUNT;
    UPDATE dune.journey_story_node SET reveal_condition_state='true'::jsonb WHERE character_id=target_character AND story_node_id=ANY(__PARENTS__) AND reveal_condition_state IS DISTINCT FROM 'true'::jsonb;
    IF (SELECT COUNT(*) FROM dune.journey_story_node WHERE character_id=target_character AND story_node_id=ANY(__IDS__) AND complete_condition_state='true'::jsonb AND reveal_condition_state='true'::jsonb) <> __COUNT__ THEN
        RAISE EXCEPTION 'Codex grant verification failed.';
    END IF;
    IF (SELECT COUNT(*) FROM dune.journey_story_node WHERE character_id=target_character AND story_node_id=ANY(__PARENTS__) AND reveal_condition_state='true'::jsonb) <> __PARENT_COUNT__ THEN RAISE EXCEPTION 'Codex reveal verification failed.'; END IF;
    INSERT INTO dst_codex_result VALUES(changed);
END $dst$;
SELECT granted FROM dst_codex_result;
COMMIT;
'@.Replace('__ACCOUNT__',[string]$AccountId).Replace('__IDS__',$array).Replace('__COUNT__',[string]$selected.Count).Replace('__REQUIRED__',$requiredArray).Replace('__REQUIRED_COUNT__',[string]$required.Count).Replace('__PARENTS__',$parentArray).Replace('__PARENT_COUNT__',[string]$ancestors.Count)
}

function Invoke-DunePlayerCodexGrant {
    param([string]$Ip, [long]$AccountId, [object[]]$Ids, [string]$Confirm)
    if ($Confirm -cne 'GRANT CODEX FRAGMENTS') { throw 'Confirm the selected codex grant.' }
    $sql = Get-DuneCodexGrantSql -AccountId $AccountId -Ids $Ids
    $status = Invoke-DuneSqlQuery -Ip $Ip -Sql "SELECT online_status::text AS status FROM dune.player_state WHERE account_id=$AccountId::bigint;" -ReadOnly $true -MaxRows 2 -TimeoutSec 10
    if (-not $status.ok) { throw 'Character status could not be verified. No changes made.' }
    $statusRows = @(ConvertTo-DuneRowMaps -Result $status)
    if ($statusRows.Count -ne 1 -or [string]$statusRows[0]['status'] -cne 'Offline') { throw 'The character must be fully Offline.' }
    # This shared battlegroup helper runs only "backup" here, never stop/start.
    $backup = Invoke-DuneBaseWaterBgCommand -Ip $Ip -Command 'backup'
    if (-not $backup.ok -or -not $backup.backupPath) { throw 'The safety backup failed. No codex data was changed.' }
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 45
    if (-not $result.ok) { return @{ ok = $false; error = $result.error; backup = $backup.backupPath } }
    $rows = @(ConvertTo-DuneRowMaps -Result $result)
    if ($rows.Count -ne 1) { throw 'Codex write returned an unexpected result. Refresh ownership before retrying.' }
    return @{ ok = $true; granted = [int]$rows[0]['granted']; backup = $backup.backupPath; message = 'Selected codex fragments updated. Safety backup retained.' }
}
