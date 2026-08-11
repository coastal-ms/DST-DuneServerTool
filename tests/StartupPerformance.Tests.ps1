Describe 'Cold-start performance guardrails' {
    BeforeAll {
        $repo = Join-Path $PSScriptRoot '..'
        $script:entry = Get-Content (Join-Path $repo 'app\DuneServer.ps1') -Raw
        $script:http = Get-Content (Join-Path $repo 'app\server\HttpServer.ps1') -Raw
        $script:scheduler = Get-Content (Join-Path $repo 'app\server\lib\RestartSchedule.ps1') -Raw
        $script:dashboard = Get-Content (Join-Path $repo 'webui\src\pages\Dashboard.tsx') -Raw
        $script:statusRoute = Get-Content (Join-Path $repo 'app\server\routes\Status.ps1') -Raw
    }

    It 'does not hold listener startup for the app-window focus proxy' {
        $script:entry | Should -Not -Match 'Start-Sleep -Milliseconds 700'
    }

    It 'runs terminal director cleanup on the background scheduler' {
        $script:entry | Should -Not -Match 'Remove-DuneTerminalDirectorPods'
        $script:scheduler | Should -Match 'Remove-DuneTerminalDirectorPods'
    }

    It 'warms one API worker and grows the pool on demand' {
        $script:http | Should -Match 'CreateRunspacePool\(1,\s*\$script:DuneApiMax'
    }

    It 'loads dashboard links only once on mount' {
        $script:dashboard | Should -Match 'useEffect\(\(\) => \{ void refreshLinks\(\) \}, \[refreshLinks\]\)'
    }

    It 'reuses VM discovery and the battlegroup title in the initial status request' {
        $script:statusRoute | Should -Match 'Get-DuneBattlegroupSnapshot -VmStatus \$vm'
        $script:statusRoute | Should -Match '\$bg\.title'
        $script:statusRoute | Should -Match 'Get-DuneServerName -CachedOnly'
    }
}
