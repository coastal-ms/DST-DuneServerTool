Describe 'One-shot command orchestration' -Tag 'Commands' {
    BeforeAll {
        $script:entry = Get-Content (Join-Path $PSScriptRoot '..\dune-server.ps1') -Raw
    }

    It 'exits one-shot start and restart commands before Director-port discovery' {
        $oneShot = $script:entry.IndexOf('if ($Cmd) { break }')
        $director = $script:entry.IndexOf('# Interactive menu only: resolve Director port')

        $oneShot | Should -BeGreaterThan 0
        $director | Should -BeGreaterThan $oneShot
    }

    It 'keeps Director-port discovery for the interactive menu' {
        $script:entry | Should -Match 'Interactive menu only: resolve Director port'
        $script:entry | Should -Match 'sudo kubectl get svc -A'
    }
}
