# Tests the offline specialization-LEVEL set (the editable Level field on
# Players -> Specs): Invoke-DunePlayerSetSpecLevel in lib/GameplayPlayers.ps1.
#
# Behavior: write an ABSOLUTE level for one track (the admin types the exact level
# they want), clamped 0..100, routing through dune.set_specialization_xp_and_level
# (writes BOTH xp_amount and level). The game treats `level` as authoritative on
# login - it keeps the level and recomputes xp_amount from it on its own non-linear
# curve - so we write the target level plus an xp_amount placeholder (quadratic
# best-fit of observed curve points) for a sensible pre-login readout. The value
# reflects in-game after a full re-login. There is no read-before-write: the UI
# already shows the current value, so the set is a single authoritative proc call.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    $script:lastWriteSql  = $null
    $script:lastSelectSql = $null
    $script:writeCount    = 0
    $script:playerOffline = $true

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        if ($ReadOnly) {
            $script:lastSelectSql = $Sql
            return @{ ok = $true; maps = @() }
        }
        $script:lastWriteSql = $Sql
        $script:writeCount   = $script:writeCount + 1
        return @{ ok = $true; maps = @(); message = 'SELECT 1' }
    }
    function global:ConvertTo-DuneRowMaps {
        param($Result)
        if ($Result -and $Result.maps) { return $Result.maps }
        return @()
    }
    function global:ConvertTo-DuneInt {
        param($Value)
        if ($null -eq $Value) { return 0 }
        return [int]$Value
    }
    function global:Get-DuneKeystoneCatalog {
        return @{
            1 = @{ track = 'Combat'; level = 1; name = 'DA_CombatKeystone_SkillPoint_Major'; cost = 2 }
            2 = @{ track = 'Combat'; level = 63; name = 'DA_CombatKeystone_SkillPoint'; cost = 20 }
            3 = @{ track = 'Crafting'; level = 20; name = 'Crafting'; cost = 5 }
            4 = @{ track = 'Combat'; level = 50; name = 'Combat fifty'; cost = 15 }
        }
    }
    function global:Test-DunePlayerOfflineByController {
        if ($script:playerOffline) { return @{ ok = $true; reason = $null } }
        return @{ ok = $false; reason = 'player is online' }
    }

    Import-DstLib 'GameplayPlayers.ps1'
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery   -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt     -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-DuneKeystoneCatalog -ErrorAction SilentlyContinue
    Remove-Item function:global:Test-DunePlayerOfflineByController -ErrorAction SilentlyContinue
}

Describe 'Invoke-DunePlayerApplySpecLevel (apply specialization rewards)' -Tag 'Players' {
    BeforeEach {
        $script:lastWriteSql  = $null
        $script:lastSelectSql = $null
        $script:writeCount    = 0
        $script:playerOffline = $true
    }

    It 'sets the selected level and grants only rewards in that track through that level' {
        $r = Invoke-DunePlayerApplySpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 62
        $r.ok | Should -BeTrue
        $r.rewards_applied | Should -Be 2
        $script:lastWriteSql | Should -Match 'set_specialization_xp_and_level'
        $script:lastWriteSql | Should -Match '62::real'
        $script:lastWriteSql | Should -Match 'ARRAY\[1,4\]::smallint\[\]'
        $script:lastWriteSql | Should -Not -Match 'FROM unnest\(ARRAY\[[^\]]*2'
        $script:lastWriteSql | Should -Not -Match 'FROM unnest\(ARRAY\[[^\]]*3'
    }

    It 'maps standard, major, and super skill-point rewards' {
        (Get-DuneSpecSkillPointBonus -RewardName 'DA_CombatKeystone_SkillPoint') | Should -Be 1
        (Get-DuneSpecSkillPointBonus -RewardName 'DA_CombatKeystone_SkillPoint_Major') | Should -Be 3
        (Get-DuneSpecSkillPointBonus -RewardName 'DA_CombatKeystone_SkillPoint_Super') | Should -Be 5
        (Get-DuneSpecSkillPointBonus -RewardName 'DA_CombatKeystone_MaxHealth') | Should -Be 0
    }

    It 'matches the shipped Combat track total of 54 skill points' {
        $path = Join-Path (Get-DstRepoRoot) 'app\data\dune-keystones.json'
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $total = 0
        foreach ($entry in $json.PSObject.Properties.Value) {
            if ($entry.track -eq 'Combat') {
                $total += Get-DuneSpecSkillPointBonus -RewardName ([string]$entry.name)
            }
        }

        $total | Should -Be 54
    }

    It 'reconciles specialization skill-point rewards into the character pool' {
        $null = Invoke-DunePlayerApplySpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 62

        $script:lastWriteSql | Should -Match 'WHEN 1 THEN 3'
        $script:lastWriteSql | Should -Match 'WHEN 2 THEN 1'
        $script:lastWriteSql | Should -Match 'KeystoneBonusSkillPoints'
        $script:lastWriteSql | Should -Match 'TotalSkillPoints'
        $script:lastWriteSql | Should -Match 'UnspentSkillPoints'
        $script:lastWriteSql | Should -Match 'expected\.amount > target\.current_bonus'
    }

    It 'preserves existing and above-level rewards' {
        $null = Invoke-DunePlayerApplySpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 62
        $script:lastWriteSql | Should -Match 'ON CONFLICT DO NOTHING'
        $script:lastWriteSql | Should -Not -Match '\bDELETE\b'
    }

    It 'sets level zero without attempting an empty reward insert' {
        $r = Invoke-DunePlayerApplySpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 0
        $r.ok | Should -BeTrue
        $r.rewards_applied | Should -Be 0
        $script:lastWriteSql | Should -Match '0::real'
        $script:lastWriteSql | Should -Not -Match 'INSERT INTO dune\.purchased_specialization_keystones'
    }

    It 'rejects Apply level while the player is online' {
        $script:playerOffline = $false

        $r = Invoke-DunePlayerApplySpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 2

        $r.ok | Should -BeFalse
        $r.error | Should -Be 'player is online'
        $script:writeCount | Should -Be 0
    }
}

Describe 'Invoke-DunePlayerSetSpecLevel (offline spec level set)' -Tag 'Players' {
    BeforeEach {
        $script:lastWriteSql  = $null
        $script:lastSelectSql = $null
        $script:writeCount    = 0
    }

    It 'routes through the stored proc and never does a raw level-only UPDATE' {
        $r = Invoke-DunePlayerSetSpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 50
        $r.ok | Should -BeTrue

        $script:lastWriteSql | Should -Match 'dune\.set_specialization_xp_and_level'
        $script:lastWriteSql | Should -Not -Match 'UPDATE\s+dune\.specialization_tracks'
        # writes the typed level, on the right track + controller
        $script:lastWriteSql | Should -Match '50::real'
        $script:lastWriteSql | Should -Match "'Combat'::dune\.specializationtracktype"
        $script:lastWriteSql | Should -Match '555::bigint'
    }

    It 'writes the typed level verbatim (does not add to anything)' {
        $r = Invoke-DunePlayerSetSpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Gathering' -Level 37
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '37::real'
    }

    It 'does not read the track before writing (set is authoritative, single call)' {
        $null = Invoke-DunePlayerSetSpecLevel -Ip '1.2.3.4' -ControllerId 777 -TrackType 'Combat' -Level 10
        $script:lastSelectSql | Should -BeNullOrEmpty
        $script:writeCount | Should -Be 1
    }

    It 'caps level at the maximum (100) and writes the max XP' {
        $r = Invoke-DunePlayerSetSpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level 999
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '100::real'
        $script:lastWriteSql | Should -Match '44182::integer'   # max xp anchor
    }

    It 'clamps a negative value to zero level and zero XP' {
        $r = Invoke-DunePlayerSetSpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Level -5
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '0::real'
        $script:lastWriteSql | Should -Match '0::integer'
    }

    It 'returns a message reporting the level that was set' {
        $r = Invoke-DunePlayerSetSpecLevel -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Crafting' -Level 50
        $r.message | Should -Match 'level'
        $r.message | Should -Match '50'
    }
}
