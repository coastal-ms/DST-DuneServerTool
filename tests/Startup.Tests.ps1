Describe 'Start All game readiness after VM boot' {
    BeforeAll {
        $script:source = Get-Content (Join-Path $PSScriptRoot '..\dune-server.ps1') -Raw
        $waitStart = $script:source.IndexOf('function Wait-MapPodReady')
        $waitEnd = $script:source.IndexOf('function Restart-DuneCoreMapPodsAfterVmBoot', $waitStart)
        $script:waitBlock = $script:source.Substring($waitStart, $waitEnd - $waitStart)

        $recycleStart = $waitEnd
        $recycleEnd = $script:source.IndexOf('# ============================================================', $recycleStart)
        $script:recycleBlock = $script:source.Substring($recycleStart, $recycleEnd - $recycleStart)
    }

    It 'uses the Funcom battlegroup server status as the readiness authority' {
        $script:waitBlock | Should -Match 'status\.servers'
        $script:waitBlock | Should -Match "Phase -eq 'Running'"
        $script:waitBlock | Should -Match "Ready -eq 'true'"
    }

    It 'does not accept Kubernetes Ready by itself' {
        $script:waitBlock | Should -Not -Match 'return @\{ Success = \$true; Elapsed = \$elapsed; Pod = \$podName; Ready = \$ready \}'
    }

    It 'recycles only restarted Overmap and Survival pods' {
        $script:recycleBlock | Should -Match '\*-sg-overmap-pod-\*\|\*-sg-survival-1-pod-\*'
        $script:recycleBlock | Should -Match '\[ "\$restarts" -gt 0 \]'
        $script:recycleBlock | Should -Match 'kubectl delete pod'
    }

    It 'runs boot recycling only when Start All powered on the VM' {
        $script:source | Should -Match '\$vmStartedThisRun = \$false'
        $script:source | Should -Match '\$vmStartedThisRun = \$true'
        $script:source | Should -Match 'if \(\$vmStartedThisRun\) \{\s+\$recycle = Restart-DuneCoreMapPodsAfterVmBoot'
    }
}
