Describe 'Stop All active pod detection' {
    BeforeAll {
        $scriptText = Get-Content (Join-Path $PSScriptRoot '..\dune-server.ps1') -Raw
        $start = $scriptText.IndexOf('function Get-DuneActiveBattlegroupPodCount')
        $end = $scriptText.IndexOf('function Test-DuneBattlegroupHasPods', $start)
        $script:counterBlock = $scriptText.Substring($start, $end - $start)
    }

    It 'reads pod phase alongside pod name' {
        $script:counterBlock | Should -Match 'custom-columns=NAME:\.metadata\.name,PHASE:\.status\.phase'
    }

    It 'does not count completed or failed pod history as active shutdown work' {
        $script:counterBlock | Should -Match ([regex]::Escape('`$2 != `"Succeeded`"'))
        $script:counterBlock | Should -Match ([regex]::Escape('`$2 != `"Failed`"'))
    }

    It 'uses the shared active count for both precheck and shutdown wait' {
        ([regex]::Matches($scriptText, 'Get-DuneActiveBattlegroupPodCount')).Count | Should -BeGreaterOrEqual 3
    }
}
