# Landsraad.ps1 — Landsraad house-contribution admin (#224).
#
# Lets an operator read the live Landsraad competition state (current term, the
# 25 Houses, a player's present per-House contributions) and SET a player's
# contribution to any House to an arbitrary amount. Reads from BOTH the DB
# (terms/tasks/contributions) and the server UserGame.ini
# ([/Script/DuneSandbox.LandsraadSettings]).
#
# Style mirrors lib/PlayersAdmin.ps1: every Invoke/Get/Set takes -Ip and returns
# @{ ok=$true|$false; ... }. SQL via Invoke-DuneSqlQuery + ConvertTo-DuneRowMaps.
#
# KEY FACTS (verified on the live DB):
#   landsraad_task_player_contributions(player_id, faction_id, task_id, amount real)
#   landsraad_task_faction_contributions(faction_id, task_id, amount int)  = SUM(player) per faction
#   landsraad_task_guild_contributions(guild_id, faction_id, task_id, amount real) = SUM(player) per guild
#   landsraad_tasks(id, term_id, board_index, house_name, goal_amount, completed, ...)
#   player_id == player CONTROLLER id (matches guild_members.player_id, player_faction.actor_id)
#   House display name = strip the "DA_House" prefix.

# Strip the "DA_House" prefix for display (DA_HouseEcaz -> Ecaz). Leaves anything
# that doesn't match untouched.
function Get-DuneLandsraadHouseDisplay {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name -match '^DA_House(.+)$') { return $matches[1] }
    return $Name
}

# Resolve the current Landsraad term id (0/null when the system isn't running).
function Get-DuneLandsraadCurrentTermId {
    param([string]$Ip)
    $sql = 'SELECT term_id FROM dune.landsraad_load_current_term();'
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = "current term: $($r.error)" } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0 -or $null -eq $maps[0]['term_id']) {
        return @{ ok = $true; term_id = 0 }
    }
    return @{ ok = $true; term_id = [long](ConvertTo-DuneInt $maps[0]['term_id']) }
}

# Parse a handful of scalar settings out of the single-line LandsraadSettings
# Data=(...) blob in the server UserGame.ini. The blob nests parens for messages /
# curves / widget paths, so we extract a curated set of flat scalar sub-keys by
# targeted regex rather than fully parsing the struct. Returns @{ ok; settings }.
$script:DuneLandsraadIniKeys = @(
    @{ Key='m_TaskGoalAmount';                 Label='Task Goal Amount';            Help='Contribution target per House task.' }
    @{ Key='m_NumberOfWeeksTermRetention';     Label='Term Retention (weeks)';      Help='How many weeks of term history are kept.' }
    @{ Key='m_NumberOfDecreesToNominate';      Label='Decrees to Nominate';         Help='Number of decrees nominated for voting.' }
    @{ Key='m_NumberOfGuildsInHighscoreList';  Label='Guilds in Highscore List';    Help='How many guilds appear on the highscore list.' }
    @{ Key='m_ControlPointsPerCycle';          Label='Control Points per Cycle';    Help='Territory control points awarded per cycle.' }
    @{ Key='m_VotingPeriodDurationInSec';      Label='Voting Period (sec)';         Help='Length of the voting window in seconds.' }
    @{ Key='m_VotingPeriodStartBeforeCoriolisCycleInSec'; Label='Voting Starts Before Cycle (sec)'; Help='How long before the Coriolis cycle voting opens.' }
    @{ Key='m_LandsraadContractsMaxActiveAmount'; Label='Max Active Contracts';     Help='Maximum simultaneously-active Landsraad contracts.' }
    @{ Key='m_bIsPlayerVotingEnabled';         Label='Player Voting Enabled';       Help='Whether players can vote on decrees.' }
    @{ Key='m_bIsTerritoryControlEnabled';     Label='Territory Control Enabled';   Help='Whether territory control is active.' }
)

function Get-DuneLandsraadIniSettings {
    param([string]$Ip)
    $settings = New-Object 'System.Collections.Generic.List[object]'
    try {
        $paths = Resolve-DuneGameConfigPaths -Ip $Ip
        $raw = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.game)' 2>/dev/null") -join "`n"
    } catch {
        return @{ ok = $false; error = "read UserGame.ini: $($_.Exception.Message)"; settings = @() }
    }
    # Isolate the LandsraadSettings Data=(...) line.
    $blob = ''
    foreach ($line in ($raw -replace "`r", '' -split "`n")) {
        if ($line -match '^\s*Data\s*=\s*\(' -and $line -match 'm_Landsraad|m_NumberOfWeeksTermRetention|m_TaskGoalAmount') {
            $blob = $line; break
        }
    }
    foreach ($def in $script:DuneLandsraadIniKeys) {
        $val = $null
        if ($blob -and $blob -match ($def.Key + '\s*=\s*([^,()]+)')) {
            $val = $matches[1].Trim()
        }
        $settings.Add([ordered]@{
            key   = $def.Key
            label = $def.Label
            help  = $def.Help
            value = $val
        })
    }
    return @{ ok = $true; settings = $settings.ToArray() }
}

# Overview: current term + every House (task) for that term + the INI settings.
function Get-DuneLandsraadOverview {
    param([string]$Ip)
    $term = Get-DuneLandsraadCurrentTermId -Ip $Ip
    if (-not $term.ok) { return @{ ok = $false; error = $term.error } }
    $houses = @()
    if ($term.term_id -gt 0) {
        $sql = @"
SELECT id, board_index, house_name, COALESCE(goal_amount, 0) AS goal_amount, completed,
       COALESCE(winning_faction_id, 0) AS winning_faction_id
FROM dune.landsraad_tasks
WHERE term_id = $($term.term_id)::bigint
ORDER BY board_index;
"@
        $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 200 -TimeoutSec 20
        if (-not $r.ok) { return @{ ok = $false; error = "houses: $($r.error)" } }
        foreach ($row in (ConvertTo-DuneRowMaps -Result $r)) {
            $hn = [string]$row['house_name']
            $houses += [ordered]@{
                task_id      = [long](ConvertTo-DuneInt $row['id'])
                board_index  = [int](ConvertTo-DuneInt $row['board_index'])
                house_name   = $hn
                display_name = (Get-DuneLandsraadHouseDisplay $hn)
                goal_amount  = [long](ConvertTo-DuneInt $row['goal_amount'])
                completed    = ([string]$row['completed'] -match '^(t|true|1)$')
                winning_faction_id = [int](ConvertTo-DuneInt $row['winning_faction_id'])
            }
        }
    }
    $ini = Get-DuneLandsraadIniSettings -Ip $Ip
    return @{
        ok       = $true
        term_id  = $term.term_id
        houses   = $houses
        settings = $ini.settings
        settings_error = if ($ini.ok) { $null } else { $ini.error }
    }
}

# A player's PRESENT per-House contribution for the current term, keyed by task_id.
function Get-DuneLandsraadPlayerContributions {
    param([string]$Ip, [long]$ControllerId)
    if ($ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }
    $term = Get-DuneLandsraadCurrentTermId -Ip $Ip
    if (-not $term.ok) { return @{ ok = $false; error = $term.error } }
    if ($term.term_id -le 0) { return @{ ok = $true; term_id = 0; contributions = @() } }
    $sql = @"
SELECT pc.task_id, t.house_name, pc.amount
FROM dune.landsraad_task_player_contributions pc
JOIN dune.landsraad_tasks t ON t.id = pc.task_id
WHERE t.term_id = $($term.term_id)::bigint AND pc.player_id = $ControllerId::bigint
ORDER BY t.board_index;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 200 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; error = "contributions: $($r.error)" } }
    $out = @()
    foreach ($row in (ConvertTo-DuneRowMaps -Result $r)) {
        $out += [ordered]@{
            task_id      = [long](ConvertTo-DuneInt $row['task_id'])
            house_name   = [string]$row['house_name']
            display_name = (Get-DuneLandsraadHouseDisplay ([string]$row['house_name']))
            amount       = [double]([string]$row['amount'])
        }
    }
    return @{ ok = $true; term_id = $term.term_id; contributions = $out }
}

# Resolve a player's faction id from player_faction (actor_id == controller id).
function Get-DuneLandsraadPlayerFactionId {
    param([string]$Ip, [long]$ControllerId)
    $sql = "SELECT faction_id FROM dune.player_faction WHERE actor_id = $ControllerId::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @{ ok = $false; error = "faction: $($r.error)" } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0 -or $null -eq $maps[0]['faction_id']) {
        return @{ ok = $false; error = 'player has no faction (player_faction row missing) - cannot contribute.' }
    }
    return @{ ok = $true; faction_id = [int](ConvertTo-DuneInt $maps[0]['faction_id']) }
}

# Set a player's contribution to one House (task) to an arbitrary amount.
#
# Routes through the GAME's own contribution cascade so the live board updates
# exactly like real gameplay: landsraad_insert_task_progress (resolves the
# player's guild + guild_faction and links the player/guild) then
# landsraad_process_task_progress (upserts the player/guild/faction contribution
# totals AND fires the guild_vote_changed pg_notify the map pod listens for to
# refresh VOTING POWER). Writing the contribution tables directly - as this
# used to - fills the leaderboard but never fires that notify, so guild voting
# power stays 0; it can also stamp the wrong faction. The cascade is ADDITIVE,
# so we feed it the DELTA (target - current) to land on the requested amount.
#
# Players NOT in a faction-aligned guild cannot go through the cascade (it
# raises, and they have no guild voting power to refresh anyway), so those fall
# back to a direct player-row write + faction/guild aggregate rebuild.
function Set-DuneLandsraadPlayerContribution {
    param([string]$Ip, [long]$ControllerId, [long]$TaskId, [double]$Amount)
    if ($ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }
    if ($TaskId -le 0) { return @{ ok = $false; error = 'task_id is required.' } }
    if ([double]::IsNaN($Amount) -or [double]::IsInfinity($Amount)) { return @{ ok = $false; error = 'amount must be a finite number.' } }
    if ($Amount -lt 0) { return @{ ok = $false; error = 'amount must be >= 0.' } }

    # Validate the task exists + grab its term + (full) house name.
    $tsql = "SELECT term_id, house_name FROM dune.landsraad_tasks WHERE id = $TaskId::bigint;"
    $tr = Invoke-DuneSqlQuery -Ip $Ip -Sql $tsql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $tr.ok) { return @{ ok = $false; error = "task lookup: $($tr.error)" } }
    $tmaps = ConvertTo-DuneRowMaps -Result $tr
    if ($tmaps.Count -eq 0) { return @{ ok = $false; error = "No Landsraad task with id $TaskId." } }
    $termId    = [long](ConvertTo-DuneInt $tmaps[0]['term_id'])
    $houseFull = [string]$tmaps[0]['house_name']
    $house     = Get-DuneLandsraadHouseDisplay $houseFull

    # The player's CURRENT contribution to this task (for the additive delta).
    $csql = "SELECT COALESCE(SUM(amount), 0) AS amt FROM dune.landsraad_task_player_contributions WHERE player_id = $ControllerId::bigint AND task_id = $TaskId::bigint;"
    $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $csql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $cr.ok) { return @{ ok = $false; error = "current contribution: $($cr.error)" } }
    $cmaps = ConvertTo-DuneRowMaps -Result $cr
    $current = if ($cmaps.Count -gt 0 -and $null -ne $cmaps[0]['amt']) { [double]([string]$cmaps[0]['amt']) } else { 0.0 }
    $delta = $Amount - $current

    # Is the player in a guild aligned to a real faction? (faction id 3 = None.)
    $gsql = @"
SELECT g.guild_id, COALESCE(g.guild_faction, 0) AS fac
FROM dune.guild_members gm
JOIN dune.guilds g ON g.guild_id = gm.guild_id
WHERE gm.player_id = $ControllerId::bigint
LIMIT 1;
"@
    $gr = Invoke-DuneSqlQuery -Ip $Ip -Sql $gsql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $gr.ok) { return @{ ok = $false; error = "guild lookup: $($gr.error)" } }
    $gmaps = ConvertTo-DuneRowMaps -Result $gr
    $guildId = [long]0; $guildFac = 0
    if ($gmaps.Count -gt 0) {
        $guildId  = [long](ConvertTo-DuneInt $gmaps[0]['guild_id'])
        $guildFac = [int](ConvertTo-DuneInt $gmaps[0]['fac'])
    }
    $aligned = ($guildId -gt 0 -and $guildFac -ne 0 -and $guildFac -ne 3)

    if ($aligned) {
        if ([math]::Abs($delta) -lt 0.0000001) {
            $fName = Get-DuneFactionDisplayName $guildFac
            return @{ ok = $true; message = "House $house already at $Amount for player $ControllerId; no change."; task_id = $TaskId; amount = $Amount; faction = $fName; house = $house }
        }
        $deltaReal = Format-DuneFloatForSql -Value $delta
        $facDelta  = [int][math]::Round($delta, [System.MidpointRounding]::AwayFromZero)
        # Drive the game's real cascade: insert the progress row (resolves guild +
        # guild_faction, links player + guild) then process it (upserts the
        # player/guild/faction totals + fires guild_vote_changed so the pod
        # refreshes voting power).
        $sql = @"
SET search_path = dune;
SELECT landsraad_insert_task_progress($termId::bigint, $ControllerId::bigint, $guildId::bigint, '$houseFull', $facDelta::int, $deltaReal::real, $deltaReal::real, (now() AT TIME ZONE 'UTC'));
SELECT landsraad_process_task_progress(1000);
"@
        $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $r.ok) { return @{ ok = $false; error = "set contribution (cascade): $($r.error)" } }
        $fName = Get-DuneFactionDisplayName $guildFac
        return @{
            ok = $true
            message = "Set $($fName) contribution to House $house = $Amount for player $ControllerId via the game cascade (voting power refreshed)."
            task_id = $TaskId
            amount  = $Amount
            faction = $fName
            house   = $house
        }
    }

    # Fallback: player not in a faction-aligned guild. No guild voting power to
    # refresh, so write the player row directly and rebuild faction + guild
    # aggregates for the task from the (now updated) player rows.
    $fac = Get-DuneLandsraadPlayerFactionId -Ip $Ip -ControllerId $ControllerId
    if (-not $fac.ok) { return @{ ok = $false; error = $fac.error } }
    $fid = $fac.faction_id
    $amtSql = Format-DuneFloatForSql -Value $Amount
    $sql = @"
DELETE FROM dune.landsraad_task_player_contributions WHERE player_id = $ControllerId::bigint AND task_id = $TaskId::bigint;
INSERT INTO dune.landsraad_task_player_contributions (player_id, faction_id, task_id, amount)
VALUES ($ControllerId::bigint, $fid::smallint, $TaskId::bigint, $amtSql::real);

DELETE FROM dune.landsraad_task_faction_contributions WHERE task_id = $TaskId::bigint;
INSERT INTO dune.landsraad_task_faction_contributions (faction_id, task_id, amount)
SELECT faction_id, $TaskId::bigint, FLOOR(SUM(amount))::int
FROM dune.landsraad_task_player_contributions WHERE task_id = $TaskId::bigint
GROUP BY faction_id;

DELETE FROM dune.landsraad_task_guild_contributions WHERE task_id = $TaskId::bigint;
INSERT INTO dune.landsraad_task_guild_contributions (guild_id, faction_id, task_id, amount)
SELECT gm.guild_id, pc.faction_id, $TaskId::bigint, SUM(pc.amount)
FROM dune.landsraad_task_player_contributions pc
JOIN dune.guild_members gm ON gm.player_id = pc.player_id
WHERE pc.task_id = $TaskId::bigint
GROUP BY gm.guild_id, pc.faction_id;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "set contribution: $($r.error)" } }

    $fName = Get-DuneFactionDisplayName $fid
    return @{
        ok = $true
        message = "Set $($fName) contribution to House $house = $amtSql for player $ControllerId; faction + guild totals recomputed (player not in an aligned guild - no voting power)."
        task_id = $TaskId
        amount  = $Amount
        faction = $fName
        house   = $house
    }
}

# ---------------------------------------------------------------------------
# Landsraad task rewards admin — read + edit the milestone items/thresholds.
# ---------------------------------------------------------------------------

# Read ALL reward rows (landsraad_task_rewards) for the current term's tasks,
# grouped by task (house). Returns @{ ok; term_id; houses=@( @{ task_id; house_name;
# display_name; tiers=@( @{ threshold; template_id; amount } ) } ) }.
function Get-DuneLandsraadRewards {
    param([string]$Ip)
    $term = Get-DuneLandsraadCurrentTermId -Ip $Ip
    if (-not $term.ok) { return @{ ok = $false; error = $term.error } }
    if ($term.term_id -le 0) { return @{ ok = $true; term_id = 0; houses = @() } }
    
    # Join rewards -> tasks for the current term, order by task (board_index) then threshold.
    $sql = @"
SELECT t.id AS task_id, t.house_name, t.board_index,
       r.threshold, r.template_id, r.amount
FROM dune.landsraad_task_rewards r
JOIN dune.landsraad_tasks t ON t.id = r.task_id
WHERE t.term_id = $($term.term_id)::bigint
ORDER BY t.board_index, r.threshold;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 500 -TimeoutSec 20
    if (-not $res.ok) { return @{ ok = $false; error = "rewards: $($res.error)" } }
    
    $rows = ConvertTo-DuneRowMaps -Result $res
    # Group by task_id into house -> tiers structure.
    $houseMap = @{}
    foreach ($row in $rows) {
        $tid = [long](ConvertTo-DuneInt $row['task_id'])
        if (-not $houseMap.ContainsKey($tid)) {
            $hn = [string]$row['house_name']
            $houseMap[$tid] = [ordered]@{
                task_id      = $tid
                house_name   = $hn
                display_name = (Get-DuneLandsraadHouseDisplay $hn)
                board_index  = [int](ConvertTo-DuneInt $row['board_index'])
                tiers        = New-Object 'System.Collections.Generic.List[object]'
            }
        }
        $houseMap[$tid].tiers.Add([ordered]@{
            threshold   = [int](ConvertTo-DuneInt $row['threshold'])
            template_id = [string]$row['template_id']
            amount      = [int](ConvertTo-DuneInt $row['amount'])
        })
    }
    
    $houses = @($houseMap.Values | Sort-Object board_index)
    return @{ ok = $true; term_id = $term.term_id; houses = $houses }
}

# Bulk-set reward thresholds across ALL tasks for the current term using a CASE
# mapping (Discord pattern). Takes an array of @{ old; new } mappings. Example:
# @( @{old=700;new=250}, @{old=3500;new=1250}, @{old=7000;new=2500},
#    @{old=10500;new=3750}, @{old=14000;new=5000} )
# Updates every row where threshold matches an 'old' value to its 'new' value.
# Returns @{ ok; message; updated_count; thresholds=@(distinct new thresholds) }.
function Set-DuneLandsraadRewardThresholds {
    param([string]$Ip, [array]$Mappings)
    if ($null -eq $Mappings -or $Mappings.Count -eq 0) {
        return @{ ok = $false; error = 'mappings array is required (e.g. @( @{old=700;new=250}, ... )).' }
    }
    $term = Get-DuneLandsraadCurrentTermId -Ip $Ip
    if (-not $term.ok) { return @{ ok = $false; error = $term.error } }
    if ($term.term_id -le 0) { return @{ ok = $false; error = 'No active Landsraad term — cannot update reward thresholds.' } }
    
    # Build CASE threshold WHEN <old> THEN <new> ... ELSE threshold END
    $whenClauses = @()
    foreach ($m in $Mappings) {
        $old = [int]$m.old
        $new = [int]$m.new
        if ($old -le 0 -or $new -le 0) { continue }
        $whenClauses += "WHEN $old THEN $new"
    }
    if ($whenClauses.Count -eq 0) {
        return @{ ok = $false; error = 'No valid mappings (each must have old>0 and new>0).' }
    }
    $caseExpr = "CASE threshold " + ($whenClauses -join ' ') + " ELSE threshold END"
    
    # UPDATE only rows for the current term's tasks. WITH t AS subquery ensures we
    # touch only this term's rewards even if task_id values from older terms exist.
    # NOTE: Must be two separate queries — compound "UPDATE; SELECT" returns only the
    # UPDATE's empty rowset through the SQL proxy.
    $updateSql = @"
WITH current_term_tasks AS (
    SELECT id FROM dune.landsraad_tasks WHERE term_id = $($term.term_id)::bigint
)
UPDATE dune.landsraad_task_rewards r
SET threshold = $caseExpr
FROM current_term_tasks t
WHERE r.task_id = t.id;
"@
    $upd = Invoke-DuneSqlQuery -Ip $Ip -Sql $updateSql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $upd.ok) { return @{ ok = $false; error = "set thresholds: $($upd.error)" } }

    # Fetch the new distinct thresholds for the response message.
    $selectSql = @"
SELECT DISTINCT threshold FROM dune.landsraad_task_rewards r
JOIN dune.landsraad_tasks t ON t.id = r.task_id
WHERE t.term_id = $($term.term_id)::bigint
ORDER BY threshold;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $selectSql -ReadOnly $true -MaxRows 100 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = "fetch thresholds: $($res.error)" } }

    $maps = ConvertTo-DuneRowMaps -Result $res
    $thresholds = @($maps | ForEach-Object { [int](ConvertTo-DuneInt $_['threshold']) } | Sort-Object)
    
    return @{
        ok             = $true
        message        = "Updated reward thresholds for term $($term.term_id). New thresholds: $($thresholds -join ', ')."
        updated_count  = $upd.rowCount
        thresholds     = $thresholds
    }
}

# Set a single reward tier's item (template_id) and/or amount for one house (task).
# Finds the row matching (task_id, threshold) and updates template_id and/or amount.
# Pass $TemplateId and/or $Amount (at least one required). Returns @{ ok; message; house }.
function Set-DuneLandsraadRewardTier {
    param([string]$Ip, [long]$TaskId, [int]$Threshold, [string]$TemplateId, [int]$Amount)
    if ($TaskId -le 0) { return @{ ok = $false; error = 'task_id is required.' } }
    if ($Threshold -le 0) { return @{ ok = $false; error = 'threshold is required.' } }
    if ([string]::IsNullOrWhiteSpace($TemplateId) -and $Amount -le 0) {
        return @{ ok = $false; error = 'At least one of template_id or amount must be provided.' }
    }
    
    # Validate task exists + grab house name for the message.
    $tsql = "SELECT house_name FROM dune.landsraad_tasks WHERE id = $TaskId::bigint;"
    $tr = Invoke-DuneSqlQuery -Ip $Ip -Sql $tsql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $tr.ok) { return @{ ok = $false; error = "task lookup: $($tr.error)" } }
    $tmaps = ConvertTo-DuneRowMaps -Result $tr
    if ($tmaps.Count -eq 0) { return @{ ok = $false; error = "No Landsraad task with id $TaskId." } }
    $house = Get-DuneLandsraadHouseDisplay ([string]$tmaps[0]['house_name'])
    
    # Build SET clause dynamically.
    $setParts = @()
    if (-not [string]::IsNullOrWhiteSpace($TemplateId)) {
        $tEsc = ConvertTo-DuneSqlString $TemplateId
        $setParts += "template_id = '$tEsc'"
    }
    if ($Amount -gt 0) {
        $setParts += "amount = $Amount::int"
    }
    $setClause = $setParts -join ', '
    
    $sql = @"
UPDATE dune.landsraad_task_rewards
SET $setClause
WHERE task_id = $TaskId::bigint AND threshold = $Threshold::int
RETURNING task_id;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = "set tier: $($res.error)" } }
    if ([int]$res.rowCount -lt 1) {
        return @{ ok = $false; error = "No reward row found for House $house (task $TaskId) at threshold $Threshold." }
    }
    
    return @{
        ok      = $true
        message = "Updated House $house threshold $Threshold reward."
        house   = $house
    }
}


# Set landsraad_tasks.goal_amount for every house in the CURRENT term. Called
# whenever Game Config's m_TaskGoalAmount is saved so the change takes effect on
# the running term instead of only future terms (which is what Funcom's own INI
# read does at term-creation time). Best-effort: skips silently and returns a
# helpful message when there's no active term or no DB.
function Set-DuneLandsraadCurrentTermGoal {
    param([string]$Ip, [long]$Goal)
    if ($Goal -lt 0) { return @{ ok = $false; error = 'goal must be >= 0.' } }
    $term = Get-DuneLandsraadCurrentTermId -Ip $Ip
    if (-not $term.ok) { return @{ ok = $false; skipped = $true; error = $term.error } }
    if ($term.term_id -le 0) {
        return @{ ok = $true; skipped = $true; message = 'No active Landsraad term — goal will apply to the next term.' }
    }

    $sql = @"
UPDATE dune.landsraad_tasks
SET goal_amount = $Goal::int
WHERE term_id = $($term.term_id)::bigint;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "set goal_amount: $($r.error)" } }

    return @{
        ok           = $true
        skipped      = $false
        term_id      = [long]$term.term_id
        goal_amount  = [long]$Goal
        updated      = [int]$r.rowCount
        message      = "Set goal_amount = $Goal for $([int]$r.rowCount) house(s) in term $($term.term_id)."
    }
}