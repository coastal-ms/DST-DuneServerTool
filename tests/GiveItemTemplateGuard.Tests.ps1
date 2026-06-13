# Tests the numeric-template give-item guard (Test-DuneValidGiveTemplate) and
# that the player + storage give functions reject a numeric template_id ("859")
# BEFORE touching the DB. A numeric id can never resolve to a game class string,
# so the row inserts but the item is invisible in-game and dropped on zone/login
# load — the exact bug confirmed on the live DB (one stray row template_id='859').
# No DB / network: Invoke-DuneSqlQuery is stubbed to throw, so any DB round-trip
# fails the test loudly, proving the guard short-circuits first.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'GameplayWorld.ps1'

    # Any give path that reaches the DB is a bug for a numeric/empty template.
    function global:Invoke-DuneSqlQuery {
        throw 'DB must not be called for an invalid template'
    }
}

Describe 'Test-DuneValidGiveTemplate' -Tag 'Pure' {
    It 'accepts real class-string template ids' {
        foreach ($t in @('CopperBar', 'Buggy_Booster_Mk6', 'BuildingBlueprint_CopyDevice', 'Combat_Light_SpiceMask')) {
            (Test-DuneValidGiveTemplate -TemplateId $t).ok | Should -BeTrue
        }
    }

    It 'rejects a purely-numeric id (the "859" leak)' {
        $r = Test-DuneValidGiveTemplate -TemplateId '859'
        $r.ok | Should -BeFalse
        $r.error | Should -Match '859'
        $r.error | Should -Match 'class name'
    }

    It 'rejects numeric ids with surrounding whitespace' {
        (Test-DuneValidGiveTemplate -TemplateId '  859  ').ok | Should -BeFalse
        (Test-DuneValidGiveTemplate -TemplateId '0').ok       | Should -BeFalse
    }

    It 'rejects empty / whitespace-only ids' {
        (Test-DuneValidGiveTemplate -TemplateId '').ok    | Should -BeFalse
        (Test-DuneValidGiveTemplate -TemplateId '   ').ok | Should -BeFalse
        (Test-DuneValidGiveTemplate -TemplateId $null).ok | Should -BeFalse
    }
}

Describe 'Invoke-DunePlayerGiveItem — rejects numeric template without DB' -Tag 'Pure' {
    It 'returns ok=$false for a numeric template and never calls the DB' {
        $r = Invoke-DunePlayerGiveItem -Ip '1.2.3.4' -PawnId 1 -Template '859' -Qty 10 -Quality 0
        $r.ok | Should -BeFalse
        $r.error | Should -Match '859'
    }

    It 'returns ok=$false for an empty template' {
        $r = Invoke-DunePlayerGiveItem -Ip '1.2.3.4' -PawnId 1 -Template '' -Qty 1 -Quality 0
        $r.ok | Should -BeFalse
    }
}

Describe 'Invoke-DuneStorageGiveItem — rejects numeric template without DB' -Tag 'Pure' {
    It 'returns ok=$false for a numeric template and never calls the DB' {
        $r = Invoke-DuneStorageGiveItem -Ip '1.2.3.4' -ContainerId 3630 -Template '859' -Qty 10 -Quality 0
        $r.ok | Should -BeFalse
        $r.error | Should -Match '859'
    }

    It 'returns ok=$false for an empty template' {
        $r = Invoke-DuneStorageGiveItem -Ip '1.2.3.4' -ContainerId 3630 -Template '' -Qty 1 -Quality 0
        $r.ok | Should -BeFalse
    }
}
