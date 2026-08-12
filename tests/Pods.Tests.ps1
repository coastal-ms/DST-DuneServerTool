Describe 'Terminal director pod lifecycle' {
    BeforeAll {
        $script:cli = Get-Content (Join-Path $PSScriptRoot '..\dune-server.ps1') -Raw
        $script:lib = Get-Content (Join-Path $PSScriptRoot '..\app\server\lib\Pods.ps1') -Raw
        $script:ui = Get-Content (Join-Path $PSScriptRoot '..\webui\src\pages\Pods.tsx') -Raw
    }

    It 'deletes only terminal bgd pod records in both cleanup paths' {
        foreach ($source in @($script:cli, $script:lib)) {
            $source | Should -Match '\$2 ~ /-bgd-/'
            $source | Should -Match '\$3 == "Succeeded"'
            $source | Should -Match '\$3 == "Failed"'
            $source | Should -Match 'kubectl delete pod'
        }
    }

    It 'automatically cleans history during background scheduler and Start All startup' {
        $scheduler = Get-Content (Join-Path $PSScriptRoot '..\app\server\lib\RestartSchedule.ps1') -Raw
        $scheduler | Should -Match 'Remove-DuneTerminalDirectorPods'
        $script:cli | Should -Match 'Remove-DuneTerminalDirectorPodHistory'
    }

    It 'hides terminal director history from the default Pods view' {
        $script:ui | Should -Match 'visiblePods'
        $script:ui | Should -Match 'isHistoricalDirectorPod'
        $script:ui | Should -Match 'Show.*history'
    }

    It 'labels restart counts as lifetime values' {
        $script:ui | Should -Match 'Lifetime restarts'
    }
}
