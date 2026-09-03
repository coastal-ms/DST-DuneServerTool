Describe 'Autostart startup state' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\app\server\lib\Autostart.ps1')
    }

    It 'resolves autostart and service modes with one scheduled-task query' {
        Mock Get-ScheduledTask {
            @(
                [pscustomobject]@{ TaskName = Get-DuneAutostartTaskName }
                [pscustomobject]@{ TaskName = Get-DuneServiceTaskName }
            )
        }

        $state = Get-DuneTaskModeState

        $state.autostart | Should -BeTrue
        $state.service | Should -BeTrue
        Should -Invoke Get-ScheduledTask -Times 1
    }
}
