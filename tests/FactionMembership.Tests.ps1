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
        $script:establishArgs = $null
        function global:Invoke-DuneSqlQuery {
            param([string]$Ip, [string]$Sql, [bool]$ReadOnly, [int]$MaxRows, [int]$TimeoutSec)
            if ($Sql -match 'AS aid')        { return @{ ok = $true; maps = @(@{ aid = 19 }) } }
            if ($Sql -match 'player_faction') { return @{ ok = $true; maps = $script:aligned } }
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

    It 'blocks Set Faction Tier on an already-aligned character' {
        $script:aligned = @(@{ fid = 2 })
        $r = Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Tier 5
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'already a member'
        $script:establishArgs | Should -BeNullOrEmpty
    }
    It 'establishes membership for an unaligned character at the tier reputation' {
        $script:aligned = @()
        $r = Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Tier 5
        $r.ok | Should -BeTrue
        $script:establishArgs.FactionId | Should -Be 1
        $script:establishArgs.Rep       | Should -Be 2000   # tier 5 threshold 1999 + 1
    }
    It 'blocks Give Faction Rep on an aligned character' {
        $script:aligned = @(@{ fid = 1 })
        $r = Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Delta 500
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'already a member'
    }
    It 'establishes membership for unaligned Give Faction Rep at the delta standing' {
        $script:aligned = @()
        $r = Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 1 -Delta 500
        $r.ok | Should -BeTrue
        $script:establishArgs.Rep | Should -Be 500
    }
    It 'rejects non-house factions' {
        Invoke-DunePlayerSetFactionTier -Ip '1.2.3.4' -ActorId 227 -FactionId 4 -Tier 5 | Select-Object -ExpandProperty ok | Should -BeFalse
        Invoke-DunePlayerGiveFactionRep -Ip '1.2.3.4' -ActorId 227 -FactionId 3 -Delta 500 | Select-Object -ExpandProperty ok | Should -BeFalse
    }
}
