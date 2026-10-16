BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'GameConfig.ps1'
    $script:ReadActualGameConfig = (Get-Command Get-DuneGameConfig).ScriptBlock
    function Invoke-V6Ssh { param($Ip,$Cmd,$StdinData,$TimeoutSec) throw 'Unmocked SSH' }
    function Register-DuneRoute {
        param($Method, $Path, $Handler, [switch]$LocalOnly)
        if ($Method -eq 'PUT' -and $Path -eq '/api/gameconfig') { $script:ClearRouteHandler = $Handler }
    }
    function Get-DuneGameConfigContext { @{ ok=$true; ip='192.0.2.1' } }
    function Test-DunePlayerGuard { param($Req,$Res,$Ip) $true }
    function Write-DuneJson { param($Response,$Body) }
    function Write-DuneError { param($Response,$Status,$Message) throw $Message }
    . (Join-Path (Get-DstRepoRoot) 'app/server/routes/GameConfig.ps1')
}

Describe 'Clearing server INI scalar overrides' {
    BeforeEach {
        $script:SavedClearUpdates = @()
        Mock Save-DuneGameConfigLocked { $script:SavedClearUpdates = $Updates }
        Mock Get-DuneGameConfig { @{source='installed';game=@{};engine=@{}} }
        Mock Save-DuneGameConfigClient { throw 'Server save must not write local player INIs' }
    }

    It 'removes a cleared curated CVar through the real save route' -ForEach @(
        @{ value='' }, @{ value='   ' }, @{ value=$null }
    ) {
        & $script:ClearRouteHandler $null $null @{} @{updates=@{'Dune.GlobalMiningOutputMultiplier'=$value}}
        $script:SavedClearUpdates.Count | Should -Be 1
        $script:SavedClearUpdates[0].remove | Should -BeTrue
        Should -Invoke Save-DuneGameConfigClient -Times 0
    }

    It 'removes cleared Experimental Lab CVars and raw INI entries' -ForEach @(
        @{ file='engine'; section='ConsoleVariables'; key='Dune.GlobalVehicleMiningOutputMultiplier' },
        @{ file='game'; section='ManualSection'; key='ManualTestKey' }
    ) {
        & $script:ClearRouteHandler $null $null @{} @{updates=@(@{file=$file;section=$section;key=$key;value=''})}
        $script:SavedClearUpdates[0].remove | Should -BeTrue
        $script:SavedClearUpdates[0].file | Should -Be $file
        Should -Invoke Save-DuneGameConfigClient -Times 0
    }

    It 'honors an explicit raw removal and preserves zero as a real value' {
        & $script:ClearRouteHandler $null $null @{} @{updates=@(
            @{file='engine';section='ConsoleVariables';key='Dune.GlobalMiningOutputMultiplier';value='2';remove=$true},
            @{file='engine';section='ConsoleVariables';key='Dune.GlobalVehicleMiningOutputMultiplier';value='0'}
        )}
        $script:SavedClearUpdates[0].remove | Should -BeTrue
        $script:SavedClearUpdates[1].remove | Should -BeFalse
    }

    It 'writes an explicitly supplied Funcom default instead of removing the entry' {
        & $script:ClearRouteHandler $null $null @{} @{updates=@{'Dune.GlobalMiningOutputMultiplier'='1.0'}}
        $script:SavedClearUpdates[0].value | Should -Be '1.0'
        $script:SavedClearUpdates[0].remove | Should -BeFalse
    }

    It 'uses the same clear and zero semantics for an actual Experimental Lab catalog key' {
        $key = @(Get-DuneAdvancedCvarCatalog)[0].key
        & $script:ClearRouteHandler $null $null @{} @{updates=@{"$key"=''} }
        $script:SavedClearUpdates[0].remove | Should -BeTrue
        & $script:ClearRouteHandler $null $null @{} @{updates=@{"$key"='0'} }
        $script:SavedClearUpdates[0].remove | Should -BeFalse
        $script:SavedClearUpdates[0].value | Should -Be '0'
    }

    It 'clears a structured member without substituting a default or deleting sibling customizations' {
        $section = '/Script/DuneSandbox.LandsraadSettings'
        $folded = @(Convert-DuneStructUpdates -Raw "[$section]`nData=(m_TaskGoalAmount=600,ManualSibling=77)" -Updates @(
            @{file='game';section=$section;key='m_TaskGoalAmount';value='';remove=$true}
        ))
        $folded[0].value | Should -Not -Match 'm_TaskGoalAmount='
        $folded[0].value | Should -Match 'ManualSibling=77'
    }

    It 'reads manual changes from an established authoritative file without replaying an older PVC' {
        Mock Invoke-V6Ssh {
            param($Ip,$Cmd)
            if ($Cmd -match 'curGame=') { return 'stale' }
            if ($Cmd -match "cat '.*/UserGame.ini'") { return '[ManualGame]' }
            if ($Cmd -match "cat '.*/UserEngine.ini'") { return "[ConsoleVariables]`nManualTest=2.5" }
            throw 'Reading manually changed authoritative INIs must not migrate or write anything.'
        }
        $actual = & $script:ReadActualGameConfig -Ip '192.0.2.1'
        $actual.engine.effectiveByKey.ManualTest | Should -Be '2.5'
        $actual.engine.effectiveByKey.ContainsKey('Dune.GlobalMiningOutputMultiplier') | Should -BeFalse
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $StdinData -or $Cmd -match 'tee |install |ls -t' }
    }

    It 'rebuilds startup commands from present values including explicit defaults, omitting cleared entries' {
        Mock Get-DuneGameConfig { @{engine=@{effectiveByKey=@{
            'Dune.GlobalMiningOutputMultiplier'='1.0'
            'Dune.GlobalVehicleMiningOutputMultiplier'=''
            'dw.FuelBurningMultiplier'='0'
        }}} }
        Mock Set-DuneStartupConsoleVariableOverrides {
            $Values.ContainsKey('Dune.GlobalVehicleMiningOutputMultiplier') | Should -BeFalse
            $Values['Dune.GlobalMiningOutputMultiplier'] | Should -Be '1.0'
            $Values['dw.FuelBurningMultiplier'] | Should -Be '0'
            @{Success=$true}
        }
        $null = Sync-DuneStartupConsoleVariableOverrides -Ip '192.0.2.1'
        Should -Invoke Set-DuneStartupConsoleVariableOverrides -Times 1
    }

    It 'deletes all duplicate assignments while preserving manual siblings and other sections' {
        $raw = "[ConsoleVariables]`nDune.GlobalMiningOutputMultiplier=2`nManualOther=7`n[ConsoleVariables]`nDune.GlobalMiningOutputMultiplier=3`n[Unrelated]`nManualElsewhere=9`n"
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @(
            @{section='ConsoleVariables';key='Dune.GlobalMiningOutputMultiplier';value=''}
        ) -QuotedKeys @{}
        $effective = Get-DuneIniEffective -Raw $out
        $effective.ContainsKey('ConsoleVariables||Dune.GlobalMiningOutputMultiplier') | Should -BeFalse
        $effective['ConsoleVariables||ManualOther'] | Should -Be '7'
        $effective['Unrelated||ManualElsewhere'] | Should -Be '9'
        # A later unrelated save must not resurrect the removed assignment.
        $again = ConvertTo-DuneIniManaged -Raw $out -Updates @(@{section='ConsoleVariables';key='ManualOther';value='8'}) -QuotedKeys @{}
        (Get-DuneIniEffective -Raw $again).ContainsKey('ConsoleVariables||Dune.GlobalMiningOutputMultiplier') | Should -BeFalse
    }
}
