BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Commands.ps1'
    function global:Assert-DuneRegisTankUpdateAllowed { param($Ip) throw 'Legacy Tank veto must not run' }
    function global:Get-DuneDbContext { throw 'Database discovery must not gate an update launch' }
}

Describe 'Operator-requested server updates' {
    BeforeEach {
        $script:PwshExe = 'pwsh.exe'
        $script:MainScript = Join-Path (Get-DstRepoRoot) 'dune-server.ps1'
        Mock Start-DuneVisibleElevated { @{pid=123;via='test'} }
        Mock Get-DuneDbContext { throw 'Database unavailable' }
        Mock Assert-DuneRegisTankUpdateAllowed { throw 'Tank image selected' }
    }

    It 'launches the normal update command despite a legacy Tank veto or unavailable database' {
        $result = Invoke-DuneCommandExternal -Name update
        $result.ok | Should -BeTrue
        $result.name | Should -Be update
        Should -Invoke Start-DuneVisibleElevated -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and
            $ArgumentList -contains 'update' -and
            $ArgumentList -contains '-PauseOnExit'
        }
        Should -Invoke Get-DuneDbContext -Times 0
        Should -Invoke Assert-DuneRegisTankUpdateAllowed -Times 0
    }

    It 'still rejects an unknown command without launching a console' {
        { Invoke-DuneCommandExternal -Name 'unknown-update' } | Should -Throw '*Unknown command*'
        Should -Invoke Start-DuneVisibleElevated -Times 0
    }
}
