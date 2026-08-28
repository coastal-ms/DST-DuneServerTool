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

    It 'treats Iodine Pills as one stack per 20 items' {
        Resolve-DuneStackMax -Ip '1.2.3.4' -Template 'AntiRadiationPill' -Quality 0 | Should -Be 20
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

Describe 'Invoke-DuneVehicleSpawnLive' -Tag 'Pure' {
    BeforeEach {
        $script:spawnArgs = $null
        $script:spawnSql = @()
        $script:spawnQueryCount = 0
        $script:spawnSurvives = $true

        function global:Resolve-DuneFlsIdOrError {
            return @{ ok = $true; fls_id = 'fls-test' }
        }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:spawnSql += $Sql
            $script:spawnQueryCount++
            switch ($script:spawnQueryCount) {
                1 {
                    return @{
                        ok = $true
                        columns = @('controller_id', 'x', 'y', 'z', 'qx', 'qy', 'qz', 'qw')
                        rows = @(, @('99', '10.5', '20.25', '30.75', '0', '0', '0', '1'))
                    }
                }
                2 {
                    return @{
                        ok = $true
                        columns = @('max_id')
                        rows = @(, @('8000'))
                    }
                }
                3 {
                    return @{
                        ok = $true
                        columns = @('permission_actor_id')
                        rows = @(, @('8001'))
                    }
                }
                default {
                    return @{
                        ok = $true
                        columns = @('vehicle_id')
                        rows = if ($script:spawnSurvives) { @(, @('8001')) } else { @() }
                    }
                }
            }
        }
        function global:Invoke-DuneRmqSpawnVehicleAt {
            param($FlsId, $ClassName, $X, $Y, $Z, $Rotation, $TemplateName, $Persistent, $Faction)
            $script:spawnArgs = @{
                FlsId = $FlsId; ClassName = $ClassName
                X = $X; Y = $Y; Z = $Z
                Rotation = $Rotation
                TemplateName = $TemplateName; Persistent = $Persistent
            }
            return @{ ok = $true }
        }
    }

    AfterEach {
        Remove-Item function:global:Resolve-DuneFlsIdOrError -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneRmqSpawnVehicleAt -ErrorAction SilentlyContinue
    }

    It 'resolves the current transform and sends the vehicle to that location' {
        $r = Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 `
            -VehicleId 'Tank' -ActorClass '/Game/Test/BP_Tank.BP_Tank_C' `
            -TemplateName 'T6_CombatFire' -Persistent $true -VerificationDelaySeconds 0

        $r.ok | Should -BeTrue
        $script:spawnSql[0] | Should -Match '\(a\.transform\)\.location'
        $script:spawnArgs.ClassName | Should -Be 'Tank'
        $script:spawnArgs.FlsId | Should -Be 'fls-test'
        $script:spawnArgs.X | Should -Be 1010.5
        $script:spawnArgs.Y | Should -Be 20.25
        $script:spawnArgs.Z | Should -Be 30.75
        $script:spawnArgs.Rotation | Should -Be 0
        $script:spawnArgs.TemplateName | Should -Be 'T6_CombatFire'
        $script:spawnArgs.Persistent | Should -BeTrue
        $script:spawnSql[2] | Should -Match 'permission_actor_rank'
        $r.permission_repaired | Should -BeTrue
        $r.vehicle_survived | Should -BeTrue
    }

    It 'fails when Funcom removes the vehicle after accepting the command' {
        $script:spawnSurvives = $false

        $r = Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 `
            -VehicleId 'Tank' -ActorClass '/Game/Test/BP_Tank.BP_Tank_C' `
            -TemplateName 'T6_CombatFire' -Persistent $true -VerificationDelaySeconds 0

        $r.ok | Should -BeFalse
        $r.permission_repaired | Should -BeTrue
        $r.vehicle_survived | Should -BeFalse
        $r.error | Should -Match 'did not survive'
    }

    It 'rejects transient spawns because they cannot receive durable ownership' {
        $r = Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 `
            -VehicleId 'TreadWheel' -ActorClass '/Game/Test/BP_TreadWheel.BP_TreadWheel_C' `
            -TemplateName 'T6_Boost' -Persistent $false -VerificationDelaySeconds 0

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'Persistent must be enabled'
        $script:spawnArgs | Should -BeNullOrEmpty
    }
}
