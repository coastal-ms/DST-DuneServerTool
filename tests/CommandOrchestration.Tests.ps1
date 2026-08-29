Describe 'One-shot command orchestration' -Tag 'Commands' {
    BeforeAll {
        $script:entry = Get-Content (Join-Path $PSScriptRoot '..\dune-server.ps1') -Raw
    }

    Describe 'World Restart command exclusion' -Tag 'Commands' {
        BeforeAll {
            . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
            Import-DstLib 'Commands.ps1'
        }

        It 'blocks battlegroup mutations while maintenance is active' {
            $command = Get-DuneCommandByName -Name 'restart'
            $availability = Get-DuneCommandAvailability -Command $command -State @{
                vmExists=$true; vmRunning=$true; bgState='running'; worldRestartActive=$true
            }

            $availability.available | Should -BeFalse
            $availability.reason | Should -Match 'World Restart'
        }

        It 'keeps diagnostic log export available during maintenance' {
            $command = Get-DuneCommandByName -Name 'logs-export'
            $availability = Get-DuneCommandAvailability -Command $command -State @{
                vmExists=$true; vmRunning=$true; bgState='running'; worldRestartActive=$true
            }

            $availability.available | Should -BeTrue
        }

        It 'blocks shells and browser admin surfaces during maintenance' {
            foreach ($name in @('open-file-browser', 'open-director', 'shell-vm', 'shell-pod', 'ssh')) {
                $command = Get-DuneCommandByName -Name $name
                $availability = Get-DuneCommandAvailability -Command $command -State @{
                    vmExists=$true; vmRunning=$true; bgState='running'; worldRestartActive=$true
                }
                $availability.available | Should -BeFalse
                $availability.reason | Should -Match 'World Restart'
            }
        }
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

    It 'does not hold Reboot All on a fixed post-reboot operator settle' {
        $script:entry | Should -Match "Invoke-OnDemandPartitionClear -Ip \`$ip -DelaySec 0 -Phase 'post-reboot' -Mode cron -Fast"
        $script:entry | Should -Not -Match "Invoke-OnDemandPartitionClear -Ip \`$ip -DelaySec 45 -Phase 'post-reboot'"
    }

    It 'passes explicit conservative and manual partition-heal modes' {
        $script:entry | Should -Match 'Invoke-DuneRemotePartitionScript -Ip \$Ip -WaitAttempts \$waitAttempts -Mode \$Mode'
        $script:entry | Should -Match 'sh \$remoteTmp \$Mode'
        $script:entry | Should -Match "-Phase 'post-startup' -Mode cron -Fast"
        $script:entry | Should -Match '-Phase "post-\$cmdName" -Mode cron -Fast'
        $script:entry | Should -Match "-Phase 'fix-on-demand-maps' -Mode manual"
    }

    It 'removes the unreachable report-issue menu entry and handler' {
        $script:entry | Should -Not -Match 'report-issue'
        $script:entry | Should -Not -Match 'issues/new\?|bug_report\.yml|Get-EncodedParam'
    }

    It 'directs memory-pressure and P34 support to diagnostics package plus Discord' {
        $script:entry | Should -Match 'Help > Create Diagnostics Package \(vm-memory-pressure\.txt\)'
        $diagnosticsRoute = Get-Content (Join-Path $PSScriptRoot '..\app\server\routes\Diagnostics.ps1') -Raw
        $diagnosticsRoute | Should -Not -Match '(?i)legacy CLI'
        $p34 = Get-Content (Join-Path $PSScriptRoot '..\docs\troubleshooting-p34.md') -Raw
        $p34 | Should -Match 'Help . Create Diagnostics Package'
        $p34 | Should -Match 'DST Discord support thread'
        $p34 | Should -Not -Match 'Create GitHub Issue'
    }
}
