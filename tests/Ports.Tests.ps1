BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Ports.ps1'
    $script:checkHostNodes = @(
        'us1.node.check-host.net',
        'de1.node.check-host.net',
        'pt1.node.check-host.net'
    )
    $script:checkHostStartJson = @{
        ok = 1
        request_id = 'request-123'
        nodes = @{
            'us1.node.check-host.net' = @('us', 'USA', 'Los Angeles')
            'de1.node.check-host.net' = @('de', 'Germany', 'Falkenstein')
            'pt1.node.check-host.net' = @('pt', 'Portugal', 'Viana')
        }
    } | ConvertTo-Json -Depth 5
}

Describe 'Check-Host TCP aggregation' {
    It 'returns open when any external node connects' {
        $result = @{
            'us1.node.check-host.net' = @(@{ time = 0.03; address = '192.0.2.1' })
            'de1.node.check-host.net' = @(@{ error = 'Connection timed out' })
            'pt1.node.check-host.net' = $null
        } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        Get-DuneCheckHostTcpVerdict -Result $result -Nodes $script:checkHostNodes | Should -Be 'open'
    }

    It 'returns closed only when every selected node explicitly fails' {
        $result = @{
            'us1.node.check-host.net' = @(@{ error = 'Connection refused' })
            'de1.node.check-host.net' = @(@{ error = 'Connection timed out' })
            'pt1.node.check-host.net' = @(@{ error = 'No route to host' })
        } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        Get-DuneCheckHostTcpVerdict -Result $result -Nodes $script:checkHostNodes | Should -Be 'closed'
    }

    It 'returns unknown while any node is pending and none connected' {
        $result = @{
            'us1.node.check-host.net' = @(@{ error = 'Connection timed out' })
            'de1.node.check-host.net' = $null
            'pt1.node.check-host.net' = $null
        } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        Get-DuneCheckHostTcpVerdict -Result $result -Nodes $script:checkHostNodes | Should -Be 'unknown'
    }

    It 'returns unknown for unsupported result shapes' {
        Get-DuneCheckHostTcpVerdict -Result ([pscustomobject]@{}) -Nodes $script:checkHostNodes | Should -Be 'unknown'
    }
}

Describe 'Check-Host TCP transport' {
    BeforeEach {
        Mock Start-Sleep {}
        Mock Invoke-WebRequest {
            param($Uri)
            if ($Uri -like 'https://check-host.net/check-tcp*') {
                return @{ Content = $script:checkHostStartJson }
            }
            return @{
                Content = (@{
                    'us1.node.check-host.net' = @(@{ time = 0.03; address = '192.0.2.1' })
                    'de1.node.check-host.net' = @(@{ error = 'Connection timed out' })
                    'pt1.node.check-host.net' = $null
                } | ConvertTo-Json -Depth 5)
            }
        }
    }

    It 'returns open from the documented request-id and result contract' {
        Test-DunePortCheckHost -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'open'
        Assert-MockCalled Invoke-WebRequest -Times 1 -ParameterFilter {
            $Uri -eq 'https://check-host.net/check-tcp?host=192.0.2.1%3A31982&max_nodes=3' -and
            $Headers.Accept -eq 'application/json'
        }
    }

    It 'returns closed from all-node explicit failures' {
        Mock Invoke-WebRequest {
            param($Uri)
            if ($Uri -like 'https://check-host.net/check-tcp*') {
                return @{ Content = $script:checkHostStartJson }
            }
            return @{
                Content = (@{
                    'us1.node.check-host.net' = @(@{ error = 'Connection refused' })
                    'de1.node.check-host.net' = @(@{ error = 'Connection timed out' })
                    'pt1.node.check-host.net' = @(@{ error = 'No route to host' })
                } | ConvertTo-Json -Depth 5)
            }
        }
        Test-DunePortCheckHost -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'closed'
    }

    It 'returns unknown on DNS or transport failure' {
        Mock Invoke-WebRequest { throw 'The remote name could not be resolved' }
        Test-DunePortCheckHost -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'unknown'
    }

    It 'returns unknown after bounded polling never completes' {
        Mock Invoke-WebRequest {
            param($Uri)
            if ($Uri -like 'https://check-host.net/check-tcp*') {
                return @{ Content = $script:checkHostStartJson }
            }
            return @{ Content = '{"us1.node.check-host.net":null,"de1.node.check-host.net":null,"pt1.node.check-host.net":null}' }
        }
        Test-DunePortCheckHost -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'unknown'
        Assert-MockCalled Invoke-WebRequest -Times 3 -ParameterFilter { $Uri -like 'https://check-host.net/check-result/*' }
    }
}

Describe 'Built-in port checker behavior' {
    It 'preserves UDP as unchecked' {
        Test-DunePortBuiltin -PublicIp '192.0.2.1' -Port 7777 -Protocol UDP | Should -Be 'udp-skip'
    }

    It 'contains no reference to the retired YouGetSignal hostname' {
        $root = Get-DstRepoRoot
        (Get-Content (Join-Path $root 'app\server\lib\Ports.ps1') -Raw) | Should -Not -Match 'ports\.yougetsignal\.com'
        (Get-Content (Join-Path $root 'dune-server.ps1') -Raw) | Should -Not -Match 'ports\.yougetsignal\.com'
    }
}
