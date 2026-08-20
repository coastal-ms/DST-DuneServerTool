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
}
