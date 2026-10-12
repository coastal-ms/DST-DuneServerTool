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
        Assert-MockCalled Invoke-WebRequest -Times 10 -ParameterFilter { $Uri -like 'https://check-host.net/check-result/*' }
    }

    It 'accepts a delayed observer instead of caching its initial pending results' {
        $script:portResultReads = 0
        Mock Invoke-WebRequest {
            param($Uri)
            if ($Uri -like 'https://check-host.net/check-tcp*') { return @{ Content = $script:checkHostStartJson } }
            $script:portResultReads++
            if ($script:portResultReads -le 3) {
                return @{ Content = '{"us1.node.check-host.net":null,"de1.node.check-host.net":null,"pt1.node.check-host.net":null}' }
            }
            return @{ Content = '{"us1.node.check-host.net":[{"time":0.03,"address":"192.0.2.1"}],"de1.node.check-host.net":null,"pt1.node.check-host.net":null}' }
        }
        Test-DunePortCheckHost -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'open'
    }
}

Describe 'Inconclusive port cache recovery' {
    BeforeAll {
        function global:Read-DuneConfig { @{ PortCheckMode = 'builtin' } }
    }
    BeforeEach {
        Reset-DunePortCheckCache
        Mock Get-DunePublicIp { '192.0.2.1' }
        Mock Test-DunePortBuiltin { 'unknown' }
        $script:portTestNow = Get-Date
        Mock Get-Date { $script:portTestNow }
    }
    It 'does not retry an inconclusive result on back-to-back health refreshes' {
        Get-DunePortStatus | Out-Null
        $script:portTestNow = $script:portTestNow.AddSeconds(20)
        (Get-DunePortStatus).cached | Should -BeTrue
        $script:portTestNow = $script:portTestNow.AddSeconds(11)
        (Get-DunePortStatus).cached | Should -BeTrue
        Assert-MockCalled Get-DunePublicIp -Times 1
    }
    It 'keeps a confirmed result cached for six hours across automatic refreshes' {
        Mock Test-DunePortBuiltin { 'open' }
        Get-DunePortStatus | Out-Null
        $script:portTestNow = $script:portTestNow.AddHours(5).AddMinutes(59)
        (Get-DunePortStatus).cached | Should -BeTrue
        Assert-MockCalled Get-DunePublicIp -Times 1
    }
    It 'refreshes a confirmed result when the six-hour interval expires' {
        Mock Test-DunePortBuiltin { 'open' }
        Get-DunePortStatus | Out-Null
        $script:portTestNow = $script:portTestNow.AddHours(6)
        (Get-DunePortStatus).cached | Should -BeFalse
        Assert-MockCalled Get-DunePublicIp -Times 2
    }
    It 'allows a manual forced refresh before the cache expires' {
        Mock Test-DunePortBuiltin { 'open' }
        Get-DunePortStatus | Out-Null
        $script:portTestNow = $script:portTestNow.AddSeconds(10)
        (Get-DunePortStatus -Force).cached | Should -BeFalse
        Assert-MockCalled Get-DunePublicIp -Times 2
    }
    It 'retains the last confirmed result when an automatic observer check fails' {
        Mock Test-DunePortBuiltin { 'open' }
        Get-DunePortStatus | Out-Null
        Mock Test-DunePortBuiltin { 'unknown' }
        $script:portTestNow = $script:portTestNow.AddHours(6)
        $result = Get-DunePortStatus
        $result.results[0].status | Should -Be 'open'
        $result.results[0].detail | Should -Match 'Last confirmed'
        (Get-DunePortStatus -Force).results[0].status | Should -Be 'unknown'
    }
    It 'shares the cache across HTTP worker state and clears it on settings changes' {
        $global:DuneApiLockTable = [hashtable]::Synchronized(@{})
        try {
            Mock Test-DunePortBuiltin { 'open' }
            Get-DunePortStatus | Out-Null
            $global:DunePortCheckCache = $null
            $global:DunePortCheckFetched = [datetime]::MinValue
            (Get-DunePortStatus).cached | Should -BeTrue
            Assert-MockCalled Get-DunePublicIp -Times 1
            Reset-DunePortCheckCache
            (Get-DunePortStatus).cached | Should -BeFalse
            Assert-MockCalled Get-DunePublicIp -Times 2
        } finally { $global:DuneApiLockTable = $null }
    }
    It 'serializes settings invalidation after an in-flight worker snapshot' {
        $table = [hashtable]::Synchronized(@{})
        $gate = [object]::new()
        $table['ports.gate'] = $gate
        $started = [Threading.ManualResetEventSlim]::new($false)
        $worker = [PowerShell]::Create()
        $held = $false
        try {
            [Threading.Monitor]::Enter($gate); $held = $true
            $null = $worker.AddScript({
                param($table,$started,$definition)
                $script:DuneApiLockTable = $table
                Set-Item function:Reset-DunePortCheckCache ([scriptblock]::Create($definition))
                $started.Set()
                Reset-DunePortCheckCache
            }).AddArgument($table).AddArgument($started).AddArgument((Get-Command Reset-DunePortCheckCache).Definition)
            $pending = $worker.BeginInvoke()
            $started.Wait(5000) | Should -BeTrue
            $pending.AsyncWaitHandle.WaitOne(100) | Should -BeFalse
            $table['ports.snapshot'] = @{ Results=@('stale'); Fetched=[datetime]::UtcNow }
            [Threading.Monitor]::Exit($gate); $held = $false
            $pending.AsyncWaitHandle.WaitOne(5000) | Should -BeTrue
            $null = $worker.EndInvoke($pending)
            $worker.HadErrors | Should -BeFalse
            $table.ContainsKey('ports.snapshot') | Should -BeFalse
        } finally {
            if ($held) { [Threading.Monitor]::Exit($gate) }
            $worker.Dispose(); $started.Dispose()
        }
    }
    AfterAll { Remove-Item function:global:Read-DuneConfig }
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
