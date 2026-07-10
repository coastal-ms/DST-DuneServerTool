# Tests the establish-faction-membership path: the FactionPlayerComponent upsert
# SQL builder, the recruitment-tag map, and the alignment guard / delegation in
# Set Faction Tier + Give Faction Rep. DB layer is stubbed; no network.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'GameplayPlayers.ps1'   # ConvertTo-DuneSqlString
    Import-DstLib 'PlayersWrites.ps1'     # ConvertTo-DunePgTextArray, component upsert, establish
    Import-DstLib 'PlayersAdmin.ps1'      # rep actions, faction display/thresholds

    # Minimal row-map helpers operating on a `maps` field (mirrors PlayersAdmin.Tests).
    function global:ConvertTo-DuneRowMaps { param($Result) $m = if ($Result -and $Result.maps) { $Result.maps } else { @() }; return ,@($m) }
    function global:ConvertTo-DuneInt     { param($Value) if ($null -eq $Value) { return 0 } return [int64]$Value }
}

AfterAll {
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt     -ErrorAction SilentlyContinue
}

Describe 'Get-DuneFactionComponentUpsertSql' -Tag 'Pure' {
    It 'builds a real-member-shaped array entry (Faction.Name + timestamp + ReputationAmount)' {
        $sql = Get-DuneFactionComponentUpsertSql -ActorId 227 -FactionName 'Atreides' -Rep 2000
        $sql | Should -Match "jsonb_build_object\('Faction', jsonb_build_object\('Name', 'Atreides'\)"
        $sql | Should -Match "'ReputationAmount', to_jsonb\(2000::int\)"
        $sql | Should -Match "'timestamp', to_jsonb\(extract\(epoch from now\(\)\)\)"
    }
    It 'targets the controller actor and replaces any existing entry for that faction' {
        $sql = Get-DuneFactionComponentUpsertSql -ActorId 593 -FactionName 'Harkonnen' -Rep 5
        $sql | Should -Match "WHERE a.id = 593::bigint"
        $sql | Should -Match "WHERE e->'Faction'->>'Name' <> 'Harkonnen'"
    }
    It 'creates the component when missing (COALESCE empties, not a no-op UPDATE)' {
        $sql = Get-DuneFactionComponentUpsertSql -ActorId 1 -FactionName 'Atreides' -Rep 0
        $sql | Should -Match "COALESCE\(a.properties, '\{\}'::jsonb\)"
        $sql | Should -Match "'\[\]'::jsonb"
    }
    It 'SQL-escapes single quotes in the faction name' {
        $sql = Get-DuneFactionComponentUpsertSql -ActorId 1 -FactionName "O'Neil" -Rep 0
        $sql | Should -Match "O''Neil"
    }
}

Describe 'Get-DuneFactionRecruitTags' -Tag 'Pure' {
    It 'returns Atreides recruitment tags for faction 1' {
        $t = Get-DuneFactionRecruitTags 1
        $t.aligned         | Should -Be 'DialogueFlags.Factions.AlignedAtreides'
        $t.recruitmentDone | Should -Be 'Contract.Tracking.AtreidesRecruitmentCompleted'
    }
    It 'returns Harkonnen recruitment tags for faction 2' {
        (Get-DuneFactionRecruitTags 2).aligned | Should -Be 'DialogueFlags.Factions.AlignedHarkonnen'
    }
    It 'returns $null for unsupported factions' {
        Get-DuneFactionRecruitTags 4 | Should -BeNullOrEmpty
        Get-DuneFactionRecruitTags 3 | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DuneEstablishFactionMembership' -Tag 'Establish' {
    BeforeEach {
        $script:capturedTx = $null
        function global:Invoke-DuneSqlQuery {
            param([string]$Ip, [string]$Sql, [bool]$ReadOnly, [int]$MaxRows, [int]$TimeoutSec)
            if (-not $ReadOnly) { $script:capturedTx = $Sql }
            return @{ ok = $true; maps = @(); message = 'SELECT 1' }
        }
        function global:Get-DuneRawFuncomId { param($Ip, $AccountId) return @{ ok = $true; funcom_id = 'FLSTEST' } }
        function global:Get-DuneNodesForPreset { param($Faction, $Preset) return @('DA_FQ_ClimbTheRanks.JoinAHouse', 'DA_FQ_ClimbTheRanks.JoinAHouse.StrikeADeal.TalkToARecruiter') }
    }
    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery     -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DuneRawFuncomId     -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DuneNodesForPreset  -ErrorAction SilentlyContinue
    }

    It 'rejects unsupported factions' {
        $r = Invoke-DuneEstablishFactionMembership -Ip '1.2.3.4' -ControllerId 227 -AccountId 19 -FactionId 4 -Rep 100
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'Atreides or Harkonnen'
    }
    It 'writes a single transaction with all five membership steps' {
        $r = Invoke-DuneEstablishFactionMembership -Ip '1.2.3.4' -ControllerId 227 -AccountId 19 -FactionId 1 -Rep 2000
        $r.ok | Should -BeTrue
        $script:capturedTx | Should -Match 'complete_journey_story_nodes_for_player'
        $script:capturedTx | Should -Match 'change_player_faction\(227::bigint, 1::smallint, 3::smallint'
        $script:capturedTx | Should -Match 'update_player_tags\(19::bigint'
        $script:capturedTx | Should -Match 'set_player_faction_reputation\(227::bigint, 1::smallint, 2000::integer'
        $script:capturedTx | Should -Match "jsonb_build_object\('Name', 'Atreides'\)"
    }
    It 'applies the recruitment + tier tags' {
        Invoke-DuneEstablishFactionMembership -Ip '1.2.3.4' -ControllerId 227 -AccountId 19 -FactionId 1 -Rep 2000 | Out-Null
        $script:capturedTx | Should -Match 'DialogueFlags.Factions.AlignedAtreides'
        $script:capturedTx | Should -Match 'Faction.Atreides.Tier5'
    }
    It 'clamps reputation to the cap' {
        $r = Invoke-DuneEstablishFactionMembership -Ip '1.2.3.4' -ControllerId 227 -AccountId 19 -FactionId 1 -Rep 999999
        $r.rep | Should -Be 12474
    }
}

Describe 'Invoke-DunePlayerSetFactionTier / GiveFactionRep alignment guard' -Tag 'Establish' {
    BeforeEach {
        $script:aligned = @()          # ConvertTo-DuneRowMaps-style maps for player_faction
        $script:currentRep = @()       # ConvertTo-DuneRowMaps-style maps for player_faction_reputation
        $script:establishArgs = $null
        $script:capturedTx = $null
        function global:Invoke-DuneSqlQuery {
            param([string]$Ip, [string]$Sql, [bool]$ReadOnly, [int]$MaxRows, [int]$TimeoutSec)
            if ($Sql -match '^\s*BEGIN;')                              { $script:capturedTx = $Sql; return @{ ok = $true } }
            if ($Sql -match 'AS aid')                                  { return @{ ok = $true; maps = @(@{ aid = 19 }) } }
            if ($Sql -match 'FROM dune\.player_faction_reputation')    { return @{ ok = $true; maps = $script:currentRep } }
            if ($Sql -match 'FROM dune\.player_faction\b')             { return @{ ok = $true; maps = $script:aligned } }
            return @{ ok = $true; maps = @(); message = 'SELECT 1' }
        }
        function global:Invoke-DuneEstablishFactionMembership {
            param($Ip, $ControllerId, $AccountId, $FactionId, $Rep)
            $script:establishArgs = @{ ControllerId = $ControllerId; AccountId = $AccountId; FactionId = $FactionId; Rep = $Rep }
            return @{ ok = $true; message = 'established' }
        }
    }
    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneEstablishFactionMembership -ErrorAction SilentlyContinue
    }

    # -- Set Faction Tier ---------------------------------------------------

    It 'Set Faction Tier: blocks when aligned to a DIFFERENT faction' {
        $script:aligned = @(@{ fid = 2 })  # Harkonnen, but target is Atreides
        $r = Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Tier 5
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'already a member'
        $script:establishArgs | Should -BeNullOrEmpty
    }
    It 'Set Faction Tier: establishes membership for an unaligned character at the tier reputation' {
        $script:aligned = @()
        $r = Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Tier 5
        $r.ok | Should -BeTrue
        $script:establishArgs.FactionId | Should -Be 1
        $script:establishArgs.Rep       | Should -Be 2000   # tier 5 threshold 1999 + 1
    }
    It 'Set Faction Tier: same-faction bypasses Establish and does a rep-only tx' {
        $script:aligned = @(@{ fid = 1 })  # already Atreides
        $r = Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Tier 10
        $r.ok            | Should -BeTrue
        $r.rep           | Should -Be 3875   # tier 10 threshold 3874 + 1
        $r.tier          | Should -Be 10
        $script:establishArgs | Should -BeNullOrEmpty      # NO recruitment ceremony
        $script:capturedTx    | Should -Match 'set_player_faction_reputation\(227::bigint, 1::smallint, 3875::integer\)'
        $script:capturedTx    | Should -Match "jsonb_build_object\('Name', 'Atreides'\)"
    }

    # -- Give Faction Rep ---------------------------------------------------

    It 'Give Faction Rep: blocks when aligned to a DIFFERENT faction' {
        $script:aligned = @(@{ fid = 2 })  # Harkonnen, but target is Atreides
        $r = Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Delta 500
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'already a member'
        $script:establishArgs | Should -BeNullOrEmpty
    }
    It 'Give Faction Rep: establishes membership for unaligned at the delta standing' {
        $script:aligned = @()
        $r = Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Delta 500
        $r.ok | Should -BeTrue
        $script:establishArgs.Rep | Should -Be 500
    }
    It 'Give Faction Rep: same-faction adds Delta to CURRENT rep (not a fresh recruitment)' {
        $script:aligned    = @(@{ fid = 2 })
        $script:currentRep = @(@{ rep = 3000 })   # tier ~9
        $r = Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 2 -Delta 15000
        $r.ok           | Should -BeTrue
        $r.previous_rep | Should -Be 3000
        $r.rep          | Should -Be 12474        # clamped to cap
        $r.delta        | Should -Be 9474
        $script:establishArgs | Should -BeNullOrEmpty
        $script:capturedTx    | Should -Match 'set_player_faction_reputation\(227::bigint, 2::smallint, 12474::integer\)'
        $script:capturedTx    | Should -Match "jsonb_build_object\('Name', 'Harkonnen'\)"
    }
    It 'Give Faction Rep: same-faction with negative Delta drops rep, clamped to 0' {
        $script:aligned    = @(@{ fid = 1 })
        $script:currentRep = @(@{ rep = 100 })
        $r = Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Delta -500
        $r.ok  | Should -BeTrue
        $r.rep | Should -Be 0
        $script:capturedTx | Should -Match 'set_player_faction_reputation\(227::bigint, 1::smallint, 0::integer\)'
    }

    It 'rejects non-house factions' {
        Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 4 -Tier 5 | Select-Object -ExpandProperty ok | Should -BeFalse
        Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 3 -Delta 500 | Select-Object -ExpandProperty ok | Should -BeFalse
    }
}
