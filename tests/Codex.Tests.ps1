BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'Codex.ps1'
    Import-DstLib 'PlayerAccess.ps1'
    Import-DstLib 'PlayersWrites.ps1'
    Import-DstLib 'Database.ps1'
    Import-DstLib 'PlayersAdmin.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
}

Describe 'Codex ownership' {
    It 'distinguishes owned fragments from revealed but incomplete lore' {
        $result = ConvertTo-DuneCodexOwnership -Nodes @(
            @{ node_id = 'DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment1Title.ImperiumFragment1Content'; is_complete = $true; is_revealed = $true },
            @{ node_id = 'DA_Dunipedia_WarForArrakis.TheWaterShippers.WaterShipperFrag1Title.WaterShipperFrag1Content'; is_complete = $false; is_revealed = $true },
            @{ node_id = 'DA_MQ_FindTheFremen'; is_complete = $true }
        )
        $result.total | Should -Be 138
        $result.owned | Should -Be 1
        $result.missing | Should -Be 137
        ($result.fragments | Where-Object fragment -eq 'Harkonnen Dossier: The Water Shippers').owned | Should -BeFalse
        ($result.fragments | Where-Object id -eq 'DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment1Title.ImperiumFragment1Content').owned | Should -BeTrue
    }

    It 'does not count a completed parent as ownership of its fragments' {
        $result = ConvertTo-DuneCodexOwnership -Nodes @(@{ node_id = 'DA_Dunipedia_KnownUniverse.Imperium'; is_complete = $true })
        $result.owned | Should -Be 0
    }

    It 'rejects duplicate codex state instead of choosing one value' {
        { ConvertTo-DuneCodexOwnership -Nodes @(
            @{ node_id = 'DA_Dunipedia_KnownUniverse'; is_complete = $true },
            @{ node_id = 'DA_Dunipedia_KnownUniverse'; is_complete = $false }
        ) } | Should -Throw '*Duplicate*'
    }

    It 'scopes the self-hosted read to the linked account' {
        Get-DunePlayerRoutePolicy -Method GET -Path '/api/gameplay/players/codex' | Should -Be 'account_id'
        Get-DunePlayerRoutePolicy -Method POST -Path '/api/gameplay/players/codex/grant' | Should -Be 'account_id'
    }

    It 'does not report unavailable data as an entirely missing collection' {
        { ConvertTo-DuneCodexOwnership -Nodes @() } | Should -Throw '*unavailable*'
    }

    It 'keeps Solo reads bound to the profile used by the helper' {
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Get-DuneSoloProfile { @{ dbPath = 'C:\captured\game.db' } }
        Mock Test-Path { $true }
        Mock Invoke-DuneSoloHelper { @{ ok = $true; nodes = @(@{ node_id = 'DA_Dunipedia_KnownUniverse.Imperium'; is_complete = $false }) } }
        $result = Get-DuneSoloCodex
        $result.profileToken | Should -Be (Get-DuneSoloProfileToken -DbPath 'C:\captured\game.db')
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -Exactly -ParameterFilter { $Command -eq 'codex' -and $Arguments.input -eq 'C:\captured\game.db' }
    }

    It 'rejects quest IDs, partial IDs and duplicate fragment selections' {
        foreach ($ids in @(@('DA_MQ_FindTheFremen'), @('DA_Dunipedia_KnownUniverse.Imperium'), @('DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment1Title.ImperiumFragment1Content','DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment1Title.ImperiumFragment1Content'))) {
            { Get-DuneCodexSelection -Ids $ids } | Should -Throw '*exact supported*'
        }
    }

    It 'never writes if the self-hosted backup fails' {
        Mock Invoke-DuneSqlQuery { @{ ok = $true } }
        Mock ConvertTo-DuneRowMaps { @(@{status='Offline'}) }
        Mock Invoke-DuneBaseWaterBgCommand { @{ok=$false} }
        { Invoke-DunePlayerCodexGrant -Ip '127.0.0.1' -AccountId 3 -Ids @('DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title.ImperiumFragment2Content') -Confirm 'GRANT CODEX FRAGMENTS' } | Should -Throw '*backup failed*'
        Should -Invoke Invoke-DuneSqlQuery -Times 0 -Exactly -ParameterFilter { -not $ReadOnly }
    }

    It 'fails closed on unknown character status before requesting a backup' {
        Mock Invoke-DuneSqlQuery { @{ok=$false} }
        Mock Invoke-DuneBaseWaterBgCommand { throw 'Must not back up' }
        { Invoke-DunePlayerCodexGrant -Ip '127.0.0.1' -AccountId 3 -Ids @('DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title.ImperiumFragment2Content') -Confirm 'GRANT CODEX FRAGMENTS' } | Should -Throw '*status could not be verified*'
        Should -Invoke Invoke-DuneBaseWaterBgCommand -Times 0 -Exactly
    }

    It 'never routes a codex read through Xbox account mutation' {
        Mock Assert-DuneSoloGameClosed {}
        { New-DuneSoloXboxMutation -Command 'codex' -Arguments @{input='C:\captured\game.db'} } | Should -Throw '*read-only helper*'
    }

    It 'retains the self-hosted backup before writing and returns its path' {
        $script:codexOrder = [Collections.Generic.List[string]]::new()
        Mock Invoke-DuneSqlQuery {
            if ($ReadOnly) { $script:codexOrder.Add('read'); return @{ok=$true;rows=@(@{status='Offline'})} }
            $script:codexOrder.Add('write'); return @{ok=$true;rows=@(@{granted=1})}
        }
        Mock ConvertTo-DuneRowMaps { $Result.rows }
        Mock Invoke-DuneBaseWaterBgCommand { $script:codexOrder.Add('backup'); @{ok=$true;backupPath='/backups/codex-test.sql.gz'} }
        $result = Invoke-DunePlayerCodexGrant -Ip '127.0.0.1' -AccountId 3 -Ids @('DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title.ImperiumFragment2Content') -Confirm 'GRANT CODEX FRAGMENTS'
        $result.granted | Should -Be 1
        $result.backup | Should -Be '/backups/codex-test.sql.gz'
        ($script:codexOrder -join ',') | Should -Be 'read,backup,write'
    }

    It 'distinguishes an owned hidden fragment from an accessible fragment' {
        $id = 'DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title.ImperiumFragment2Content'
        $result = ConvertTo-DuneCodexOwnership -Nodes @(@{node_id=$id;is_complete=$true;is_revealed=$false})
        $row = $result.fragments | Where-Object id -eq $id
        $row.owned | Should -BeTrue
        $row.revealed | Should -BeFalse
    }
}
