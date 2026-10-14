# Tests pure helper behavior in PlayersRmq.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRmq.ps1'
}

Describe 'Resolve-DuneStackMax' -Tag 'Pure' {
    It 'honors restored stack metadata for wire and ammunition' {
        Resolve-DuneStackMax -Ip fixture -Template WeldingMaterial | Should -Be 500
        Resolve-DuneStackMax -Ip fixture -Template RocketAmmo | Should -Be 250
        Resolve-DuneStackMax -Ip fixture -Template Napalm | Should -Be 1000
    }
    It 'uses existing stack room before demanding another inventory slot' -ForEach @(@{Quantity=50;Fits=$true},@{Quantity=51;Fits=$false}) {
        $script:stackCapacityQueries=0
        Mock Invoke-DuneSqlQuery {
            $script:stackCapacityQueries++
            if($script:stackCapacityQueries -eq 1){return @{ok=$true;columns=@('inv_id','max_slots','max_vol');rows=@(,@('1','1','-1'))}}
            return @{ok=$true;columns=@('t','ss','quality','augmented','vov');rows=@(,@('WeldingMaterial','450','0','false','-1'))}
        }
        (Test-DuneInventoryCapacity -Ip fixture -PawnId 10 -Template WeldingMaterial -Quantity $Quantity).ok | Should -Be $Fits
    }
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

    It 'treats Light Darts as one stack per 1000 items' {
        Resolve-DuneStackMax -Ip '1.2.3.4' -Template 'Ammo' -Quality 0 | Should -Be 1000
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

Describe 'Clean Inventory Reserve safety' -Tag 'Pure' {
    BeforeEach {
        function global:Resolve-DuneFlsIdOrError { @{ ok = $true; fls_id = 'fixture-user' } }
        $script:reserveChecks = 0
        $script:rmqCleanCalls = 0
        function global:Test-DunePlayerReserveItems {
            $script:reserveChecks++
            @{ ok = $true; item_rows = 0; item_units = 0 }
        }
        function global:Invoke-DuneRmqCleanPlayerInventory {
            $script:rmqCleanCalls++
            @{ ok = $true }
        }
    }
    AfterEach {
        Remove-Item function:global:Resolve-DuneFlsIdOrError -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerReserveItems -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneRmqCleanPlayerInventory -ErrorAction SilentlyContinue
    }

    It 'sends the command only after proving Reserve empty for the exact pawn' {
        $result = Invoke-DunePlayerCleanInventoryLive -Ip fixture -ActorId 42
        $result.ok | Should -BeTrue
        $script:reserveChecks | Should -Be 1
        $script:rmqCleanCalls | Should -Be 1
    }

    It 'blocks Clean Inventory whenever Reserve contains rows' {
        function global:Test-DunePlayerReserveItems {
            $script:reserveChecks++
            @{ ok = $true; item_rows = 2; item_units = 9 }
        }
        $result = Invoke-DunePlayerCleanInventoryLive -Ip fixture -ActorId 42
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'blocked while Reserve contains 2'
        $script:rmqCleanCalls | Should -Be 0
    }

    It 'fails closed when Reserve inspection fails' {
        function global:Test-DunePlayerReserveItems {
            $script:reserveChecks++
            @{ ok = $false; error = 'database unavailable' }
        }
        $result = Invoke-DunePlayerCleanInventoryLive -Ip fixture -ActorId 42
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'safety could not be proven'
        $script:rmqCleanCalls | Should -Be 0
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
        function global:Get-DuneRegisTankSupport { param($Ip,$ActorId); @{enabled=$true} }
        $r = Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 `
            -VehicleId 'Tank' -ActorClass '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C' `
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

    It 'reports accepted but unverified when the database observation cannot confirm the vehicle' {
        function global:Get-DuneRegisTankSupport { param($Ip,$ActorId); @{enabled=$true} }
        $script:spawnSurvives = $false

        $r = Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 `
            -VehicleId 'Tank' -ActorClass '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C' `
            -TemplateName 'T6_CombatFire' -Persistent $true -VerificationDelaySeconds 0

        $r.ok | Should -BeTrue
        $r.permission_repaired | Should -BeTrue
        $r.vehicle_survived | Should -BeFalse
        $r.verification_pending | Should -BeTrue
        $r.message | Should -Match 'before granting another'
    }
    It 'waits past the old ten-poll window without issuing a second spawn' {
        function global:Get-DuneRegisTankSupport { param($Ip,$ActorId); @{enabled=$true} }
        $script:delayedRepairCount=0
        function global:Invoke-DuneSqlQuery {
            param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec)
            if ($Sql -match 'WITH candidate AS') {
                $script:delayedRepairCount++
                if ($script:delayedRepairCount -lt 12) {return @{ok=$true;columns=@('permission_actor_id');rows=@()}}
                return @{ok=$true;columns=@('permission_actor_id');rows=@(,@('8001'))}
            }
            if ($Sql -match 'AS controller_id') {return @{ok=$true;columns=@('controller_id','x','y','z','qx','qy','qz','qw');rows=@(,@('99','10.5','20.25','30.75','0','0','0','1'))}}
            if ($Sql -match 'AS max_id') {return @{ok=$true;columns=@('max_id');rows=@(,@('8000'))}}
            return @{ok=$true;columns=@('vehicle_id');rows=@(,@('8001'))}
        }
        Mock Start-Sleep {}
        $result=Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 -VehicleId 'Tank' -ActorClass '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C' -TemplateName 'T6_CombatDart' -Persistent $true -VerificationDelaySeconds 0
        $result.ok | Should -BeTrue
        $result.vehicle_survived | Should -BeTrue
        $script:delayedRepairCount | Should -Be 12
        $script:spawnArgs.TemplateName | Should -Be 'T6_CombatDart'
    }

    It 'rejects transient spawns because they cannot receive durable ownership' {
        $r = Invoke-DuneVehicleSpawnLive -Ip '1.2.3.4' -ActorId 42 `
            -VehicleId 'TreadWheel' -ActorClass '/Game/Test/BP_TreadWheel.BP_TreadWheel_C' `
            -TemplateName 'T6_Boost' -Persistent $false -VerificationDelaySeconds 0

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'Persistent must be enabled'
        $script:spawnArgs | Should -BeNullOrEmpty
    }

    It 'keeps the UI success claim aligned with persistence verification' {
        $ui = Get-Content (Join-Path (Get-DstRepoRoot) 'webui\src\pages\gameplay\players\sections.tsx') -Raw
        $ui | Should -Match 'Success is reported only after DST verifies the vehicle row'
        $ui | Should -Match 'rank-1 owner permission survived'
        $ui | Should -Not -Match 'successful API response only means the command was sent'
    }
}
