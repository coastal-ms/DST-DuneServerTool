BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path $PSScriptRoot '..\app\server\lib\Maps.ps1'
    . $lib
    foreach ($name in @('_Get-DuneMapServerGuids','_Get-DuneMapLiveServers')) {
        Set-Item -Path "function:global:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
}

Describe 'Director-driven map status' {
    BeforeAll {
        $script:bg = [pscustomobject]@{ status=[pscustomobject]@{ servers=@(
            [pscustomobject]@{ partitionMap='DeepDesert_1'; partitionIndex=8; ready=$true; serverGuid='dd8' },
            [pscustomobject]@{ partitionMap='DeepDesert_1'; partitionIndex=31; ready=$true; serverGuid='dd31' },
            [pscustomobject]@{ partitionMap='Survival_1'; partitionIndex=1; ready=$true; serverGuid='hag' }
        ) } }
    }

    Describe 'Multi-partition clear safety' {
        It 'preserves ready sibling partitions while force-clearing a stuck pod' {
            $source = Get-Content (Join-Path $PSScriptRoot '..\app\resources\remote-scripts\dune-clear-partitions-install.sh') -Raw
            $source | Should -Match 'force-cleared stuck partition pod'
            $source | Should -Match 'while preserving Ready sibling partition'
            $source | Should -Match 'recover_pods="\$hard_stuck_pods"'
            $source | Should -Match 'if \[ "\$MODE" = "boot" \]; then recover_pods="\$recover_pods \$draining_pods"; fi'
            $source | Should -Match 'case " \$seen_recover_pods " in \*" \$p "\*\) continue'
        }
    }

    It 'reads current status.servers before legacy pod fields' {
        @(_Get-DuneMapLiveServers -Bg $script:bg -Pattern '^DeepDesert').Count | Should -Be 2
    }

    It 'returns every live Deep Desert server guid' {
        @(_Get-DuneMapServerGuids -Bg $script:bg -Pattern '^DeepDesert') | Should -Be @('dd8','dd31')
    }
}
