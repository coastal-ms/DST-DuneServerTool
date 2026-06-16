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

# Set a player's contribution to one House (task) to an arbitrary amount, then
# RECOMPUTE the faction + guild aggregates for that task from the player rows so
# everything stays consistent. Admin-grade: works for any player regardless of
# guild membership (guild aggregate simply omits players not in a guild).
function Set-DuneLandsraadPlayerContribution {
    param([string]$Ip, [long]$ControllerId, [long]$TaskId, [double]$Amount)
    if ($ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }
    if ($TaskId -le 0) { return @{ ok = $false; error = 'task_id is required.' } }
    if ([double]::IsNaN($Amount) -or [double]::IsInfinity($Amount)) { return @{ ok = $false; error = 'amount must be a finite number.' } }
    if ($Amount -lt 0) { return @{ ok = $false; error = 'amount must be >= 0.' } }

    # Validate the task exists + grab its house + term for the message.
    $tsql = "SELECT term_id, house_name FROM dune.landsraad_tasks WHERE id = $TaskId::bigint;"
    $tr = Invoke-DuneSqlQuery -Ip $Ip -Sql $tsql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $tr.ok) { return @{ ok = $false; error = "task lookup: $($tr.error)" } }
    $tmaps = ConvertTo-DuneRowMaps -Result $tr
    if ($tmaps.Count -eq 0) { return @{ ok = $false; error = "No Landsraad task with id $TaskId." } }
    $house = Get-DuneLandsraadHouseDisplay ([string]$tmaps[0]['house_name'])

    $fac = Get-DuneLandsraadPlayerFactionId -Ip $Ip -ControllerId $ControllerId
    if (-not $fac.ok) { return @{ ok = $false; error = $fac.error } }
    $fid = $fac.faction_id

    $amtSql = Format-DuneFloatForSql -Value $Amount

    # One batch: replace the player's row for this task, then rebuild faction +
    # guild aggregates for the task from the (now updated) player rows.
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
        message = "Set $($fName) contribution to House $house = $amtSql for player $ControllerId; faction + guild totals recomputed."
        task_id = $TaskId
        amount  = $Amount
        faction = $fName
        house   = $house
    }
}
