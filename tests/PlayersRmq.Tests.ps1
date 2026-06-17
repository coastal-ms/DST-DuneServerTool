# Tests pure helper behavior in PlayersRmq.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRmq.ps1'
}

Describe 'Resolve-DuneStackMax' -Tag 'Pure' {
    BeforeEach {
        function global:Invoke-DuneSqlQuery {
            return @{ ok = $true; rows = @(@{ s = '0' }) }
        }
    }

    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'uses gameplay-item-data stack_max when present' {
        Resolve-DuneStackMax -Ip '1.2.3.4' -Template 'CopperBar' -Quality 0 | Should -Be 500
    }

    It 'treats Light Darts as one stack per 500 items' {
        Resolve-DuneStackMax -Ip '1.2.3.4' -Template 'Ammo' -Quality 0 | Should -Be 500
    }

    It 'keeps catalog-only launchers non-stackable' {
        Resolve-DuneStackMax -Ip '1.2.3.4' -Template 'RocketLauncher_2' -Quality 0 | Should -Be 1
    }

    It 'counts 500 Light Darts as one new slot in the capacity guard' {
        $script:queryCount = 0
        function global:Invoke-DuneSqlQuery {
            $script:queryCount++
            if ($script:queryCount -eq 1) {
                return @{
                    ok      = $true
                    columns = @('inv_id', 'max_slots', 'max_vol')
                    rows    = @(, @('101', '150', '-1'))
                }
            }
            return @{
                ok      = $true
                columns = @('t', 'ss', 'vov')
                rows    = @(1..39 | ForEach-Object { , @("Existing$_", '1', '-1') })
            }
        }

        $r = Test-DuneInventoryCapacity -Ip '1.2.3.4' -PawnId 24 -Template 'Ammo' -Quantity 500 -Quality 0

        $r.ok         | Should -BeTrue
        $r.new_stacks | Should -Be 1
        $r.free_slots | Should -Be 111
    }
}
