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

    Describe 'Boot-only core map recovery: stale PreShutdown/Stopping pods' {
        BeforeAll {
            $script:fnSource = Get-Content (Join-Path $PSScriptRoot '..\app\resources\remote-scripts\dune-clear-partitions-install.sh') -Raw
            # Isolate just the force_clear_stuck_pods() body so assertions about
            # ordering (phase-check-before-Ready-check) can't accidentally match
            # unrelated text elsewhere in the file.
            $script:fnBody = if ($script:fnSource -match '(?s)force_clear_stuck_pods\(\) \{(.*?)\n\}') { $Matches[1] } else { '' }
        }

        It 'extracted the force_clear_stuck_pods function body' {
            $script:fnBody | Should -Not -BeNullOrEmpty
        }

        It 'recognizes the game phase "PreShutdown" as a stale/draining pod, not only "Stopping"' {
            $script:fnBody | Should -Match '\[ "\$gphase" = "Stopping" \] \|\| \[ "\$gphase" = "PreShutdown" \]'
        }

        It 'no longer skips a whole serverset just because Kubernetes readyReplicas is satisfied' {
            # This was the root cause: a serverset-level early "continue" on
            # readyReplicas>=replicas hid a core map stuck in game phase
            # PreShutdown for hours because k8s still reported it Ready.
            $script:fnBody | Should -Not -Match 'readyReplicas'
            $script:fnBody | Should -Not -Match 'rdyN'
        }

        It 'checks game phase / deletionTimestamp BEFORE consulting the per-pod Ready condition' {
            # The other half of the root cause: the per-pod loop used to bail
            # out on Ready=True before ever inspecting phase/deletionTimestamp.
            # Assert the phase/deletionTimestamp force-clear branch appears
            # before the Ready lookup in the pod loop, so a demonstrably-stale
            # (Stopping/PreShutdown/terminating) pod is force-cleared even
            # when Kubernetes still reports it Ready.
            $phaseCheckIdx = $script:fnBody.IndexOf('if [ -n "$del" ] || [ "$gphase" = "Stopping" ] || [ "$gphase" = "PreShutdown" ]')
            $readyLookupIdx = $script:fnBody.IndexOf('conditions[?(@.type=="Ready")].status')
            $phaseCheckIdx | Should -BeGreaterThan -1
            $readyLookupIdx | Should -BeGreaterThan -1
            $phaseCheckIdx | Should -BeLessThan $readyLookupIdx
        }

        It 'still requires replicas>=1 (a cleanly stopped map, replicas=0, is left untouched)' {
            $script:fnBody | Should -Match '\[ "\$rep" -ge 1 \] \|\| continue'
        }

        It 'still force-clears a plain stuck Terminating pod (deletionTimestamp) with no phase match' {
            $script:fnBody | Should -Match '\[ -n "\$del" \]'
        }

        It 'the on-demand partition pass also recognizes PreShutdown alongside Stopping for boot-only drain recovery' {
            # Same crash class can strand on-demand/warm maps too; keep the
            # phase vocabulary consistent between both passes.
            $script:fnSource | Should -Match '\[ -n "\$del" \] \|\| \[ "\$gphase" = "Stopping" \] \|\| \[ "\$gphase" = "PreShutdown" \]'
        }

        It 'boot-only aggressive draining recovery for on-demand maps remains gated to MODE=boot (never cron/manual)' {
            $script:fnSource | Should -Match 'if \[ "\$MODE" = "boot" \]; then recover_pods="\$recover_pods \$draining_pods"; fi'
        }
    }

    It 'reads current status.servers before legacy pod fields' {
        @(_Get-DuneMapLiveServers -Bg $script:bg -Pattern '^DeepDesert').Count | Should -Be 2
    }

    It 'returns every live Deep Desert server guid' {
        @(_Get-DuneMapServerGuids -Bg $script:bg -Pattern '^DeepDesert') | Should -Be @('dd8','dd31')
    }
}
