BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path $PSScriptRoot '..\app\server\lib\Maps.ps1'
    . $lib
    foreach ($name in @('_Get-DuneMapServerGuids','_Get-DuneMapLiveServers')) {
        Set-Item -Path "function:global:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
}

Describe 'Rolling INI game-pod reload safety' {
    It 'matches only operator game-server pod names' {
        Test-DuneGameServerPodName 'my-bg-sg-survival-1-pod-0' | Should -BeTrue
        Test-DuneGameServerPodName 'my-bg-sg-deepdesert-1-pod-12' | Should -BeTrue
        Test-DuneGameServerPodName 'my-bg-sg-arrakeen-pod-2' | Should -BeTrue
    }

    It 'rejects database, director, operator, jobs, and malformed names' {
        foreach ($name in @(
            'my-bg-postgresql-0',
            'my-bg-director-7c9f',
            'dune-operator-controller-manager-abc',
            'my-bg-dump-20260729',
            'my-bg-sg-survival-1',
            'sg-survival-1-pod-admin'
        )) {
            Test-DuneGameServerPodName $name | Should -BeFalse -Because "$name must never be part of an INI rolling reload"
        }
    }
}

Describe 'Rolling INI reload waits for the map, not just the pod' {

    # The pod goes Running/Ready as soon as the container starts, but the game
    # server then loads the world and only later reports ready in the battlegroup
    # CR. Gating on the pod condition alone claimed success while both maps were
    # still in Startup, and let the next pod be deleted mid-load. These lock the
    # remote script's shape so that regression can't return silently.

    BeforeAll {
        $script:rollingScript = (Get-Command Restart-DuneGameServerPodsRolling).ScriptBlock.ToString()
    }

    It 'queries the battlegroup CR readiness, not only the pod condition' {
        $script:rollingScript | Should -Match 'get battlegroups'
        $script:rollingScript | Should -Match 'partitionMap'
    }

    It 'derives the map slug from the pod name' {
        # ...-sg-survival-1-pod-1 -> survival-1
        $script:rollingScript | Should -Match '\-sg\-'
        $script:rollingScript | Should -Match 'SLUG'
    }

    It 'folds underscores so Survival_1 matches the survival-1 pod slug' {
        $script:rollingScript | Should -Match 'gsub\(/_/'
    }

    It 'fails the roll when a map never reports ready' {
        $script:rollingScript | Should -Match 'map-ready-timeout'
    }

    It 'gives world loading a longer deadline than container startup' {
        $script:rollingScript | Should -Match 'MAP_DEADLINE'
    }

    It 'no longer claims readiness on the pod condition alone' {
        # The success message must not promise more than was verified.
        $libText = Get-Content (Join-Path $PSScriptRoot '..\app\server\lib\Maps.ps1') -Raw
        $libText | Should -Not -Match 'Every replacement reached Ready'
        $libText | Should -Match 'Every map finished loading and reported ready'
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
            # This was (part of) the root cause: a serverset-level early
            # "continue" on readyReplicas>=replicas could hide a core map
            # sitting in game phase PreShutdown whose k8s readiness was
            # satisfied -- reproduced via a mocked-kubectl harness.
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
