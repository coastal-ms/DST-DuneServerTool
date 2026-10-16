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

    It 'returns closed only when every selected node reports connection refused' {
        $result = @{
            'us1.node.check-host.net' = @(@{ error = 'Connection refused' })
            'de1.node.check-host.net' = @(@{ error = 'Connection refused' })
            'pt1.node.check-host.net' = @(@{ error = 'Connection refused' })
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

    It 'does not call timeout, routing or checker failures closed' -ForEach @(
        @{ error='Connection timed out' }, @{ error='No route to host' }, @{ error='limit_exceeded' }
    ) {
        $result = @{}
        foreach ($node in $script:checkHostNodes) { $result[$node] = @(@{error=$error}) }
        $result = $result | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        Get-DuneCheckHostTcpVerdict -Result $result -Nodes $script:checkHostNodes | Should -Be 'unknown'
    }
}

Describe 'CanYouSeeMe observer and fallback' {
    BeforeEach { Mock Test-DunePortCheckTool { 'unknown' } }
    It 'requires the success verdict to name the requested address and port' -ForEach @(
        @{ ip='192.0.2.1'; port=31982; expected='open' },
        @{ ip='192.0.2.2'; port=31982; expected='unknown' },
        @{ ip='192.0.2.1'; port=80; expected='unknown' }
    ) {
        Mock Invoke-WebRequest { @{Content='<b>Success:</b></font>&nbsp;I can see your service on <b>192.0.2.1</b> on port (<b>31982</b>)'} }
        Test-DunePortCanYouSeeMe -PublicIp $ip -Port $port | Should -Be $expected
    }
    It 'distinguishes a refused connection from a timeout' -ForEach @(
        @{ reason='Connection refused'; expected='closed' },
        @{ reason='Connection timed out'; expected='unknown' },
        @{ reason='No route to host'; expected='unknown' }
    ) {
        Mock Invoke-WebRequest { @{Content="<b>Error:</b></font>&nbsp;I could not see your service on <b>192.0.2.1</b> on port (<b>31982</b>)<br>Reason: $reason"} }
        Test-DunePortCanYouSeeMe -PublicIp '192.0.2.1' -Port 31982 | Should -Be $expected
    }
    It 'uses CanYouSeeMe first without consuming Check-Host quota after success' {
        Mock Test-DunePortCanYouSeeMe { 'open' }
        Mock Test-DunePortCheckHost { throw 'Must not request quota when primary succeeds' }
        Test-DunePortBuiltin -PublicIp '192.0.2.1' -Port 31982 -Protocol TCP | Should -Be 'open'
        Should -Invoke Test-DunePortCheckHost -Times 0
        Should -Invoke Test-DunePortCheckTool -Times 0
    }
    It 'uses PortCheckTool before consuming Check-Host quota' {
        Mock Test-DunePortCanYouSeeMe { 'unknown' }
        Mock Test-DunePortCheckTool { 'open' }
        Mock Test-DunePortCheckHost { throw 'Must not request quota after success' }
        Test-DunePortBuiltin -PublicIp '192.0.2.1' -Port 31982 -Protocol TCP | Should -Be 'open'
        Should -Invoke Test-DunePortCheckHost -Times 0
    }
    It 'falls back on an inconclusive primary and lets a positive connection override a refusal' -ForEach @(
        @{ primary='unknown'; fallback='open'; expected='open' },
        @{ primary='closed'; fallback='open'; expected='open' },
        @{ primary='unknown'; fallback='unknown'; expected='unknown' },
        @{ primary='closed'; fallback='unknown'; expected='closed' }
    ) {
        Mock Test-DunePortCanYouSeeMe { $primary }
        Mock Test-DunePortCheckHost { $fallback }
        Test-DunePortBuiltin -PublicIp '192.0.2.1' -Port 31982 -Protocol TCP | Should -Be $expected
    }
}

Describe 'PortCheckTool target verification' {
    It 'accepts only a success verdict for the requested target' -ForEach @(
        @{ip='192.0.2.1';port=31982;expected='open'},
        @{ip='192.0.2.2';port=31982;expected='unknown'},
        @{ip='192.0.2.1';port=80;expected='unknown'}
    ) {
        Mock Invoke-WebRequest { @{Content='<strong>Success!</strong>&nbsp;&nbsp;I can see your service on <b>192.0.2.1</b> on port (<b>31982</b>)'} }
        Test-DunePortCheckTool -PublicIp $ip -Port $port | Should -Be $expected
    }
    It 'keeps transport and unrecognized responses unknown' {
        Mock Invoke-WebRequest { throw 'Unavailable' }
        Test-DunePortCheckTool -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'unknown'
        Mock Invoke-WebRequest { @{Content='<strong>Error!</strong>Connection timed out'} }
        Test-DunePortCheckTool -PublicIp '192.0.2.1' -Port 31982 | Should -Be 'unknown'
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

    It 'returns closed from all-node connection refusals' {
        Mock Invoke-WebRequest {
            param($Uri)
            if ($Uri -like 'https://check-host.net/check-tcp*') {
                return @{ Content = $script:checkHostStartJson }
            }
            return @{
                Content = (@{
                    'us1.node.check-host.net' = @(@{ error = 'Connection refused' })
                    'de1.node.check-host.net' = @(@{ error = 'Connection refused' })
                    'pt1.node.check-host.net' = @(@{ error = 'Connection refused' })
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
    It 'recovers a closed badge automatically after the server comes back' {
        Mock Test-DunePortBuiltin { 'closed' }
        Get-DunePortStatus | Out-Null
        $script:portTestNow = $script:portTestNow.AddSeconds(59)
        (Get-DunePortStatus).cached | Should -BeTrue
        Mock Test-DunePortBuiltin { 'open' }
        $script:portTestNow = $script:portTestNow.AddSeconds(1)
        $result = Get-DunePortStatus
        $result.cached | Should -BeFalse
        $result.results[0].status | Should -Be 'open'
        Assert-MockCalled Get-DunePublicIp -Times 2
    }
    It 'bypasses a recent verdict on battlegroup startup and shares the new context across workers' {
        $worker = [PowerShell]::Create()
        try {
            $null = $worker.AddScript({
                param($source)
                . $source
                $script:DuneApiLockTable = [hashtable]::Synchronized(@{})
                function Read-DuneConfig { @{PortCheckMode='builtin'} }
                function Get-DunePublicIp { '192.0.2.1' }
                function Test-DunePortBuiltin { $script:verdict }
                $script:verdict = 'closed'
                Get-DunePortStatus -BattlegroupState stopped | Out-Null
                $script:verdict = 'open'
                $started = Get-DunePortStatus -BattlegroupState running
                # Simulate another worker with no local snapshot, sharing the table.
                $script:DunePortCheckBgState = $null
                $script:DunePortCheckCache = $null
                $reused = Get-DunePortStatus -BattlegroupState running
                $script:verdict = 'closed'
                $stopped = Get-DunePortStatus -BattlegroupState stopped
                @{started=$started;reused=$reused;stopped=$stopped}
            }).AddArgument((Join-Path (Get-DstRepoRoot) 'app/server/lib/Ports.ps1'))
            $result = @($worker.Invoke())[0]
            $worker.HadErrors | Should -BeFalse
            $result.started.cached | Should -BeFalse
            $result.started.results[0].status | Should -Be 'open'
            $result.reused.cached | Should -BeTrue
            $result.stopped.cached | Should -BeFalse
            $result.stopped.results[0].status | Should -Be 'closed'
        } finally { $worker.Dispose() }
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
    It 'does not replay an older closed result when the new automatic check is inconclusive' {
        Mock Test-DunePortBuiltin { 'closed' }
        Get-DunePortStatus | Out-Null
        Mock Test-DunePortBuiltin { 'unknown' }
        $script:portTestNow = $script:portTestNow.AddHours(6)
        (Get-DunePortStatus).results[0].status | Should -Be 'unknown'
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
    BeforeAll {
        $tokens = $null; $parseErrors = $null
        $cli = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-DstRepoRoot) 'dune-server.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $cli.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PortOpen-Builtin' }, $false)
        Set-Item function:global:Test-PortOpen-Builtin $definition.Body.GetScriptBlock()
        $script:scriptDir = Get-DstRepoRoot
    }
    It 'uses the shared observer policy in the CLI without running the CLI entry point' {
        Mock Invoke-WebRequest { @{Content='<b>Success:</b></font>&nbsp;I can see your service on <b>192.0.2.1</b> on port (<b>31982</b>)'} }
        Test-PortOpen-Builtin -PublicIp '192.0.2.1' -Port 31982 -Protocol TCP | Should -Be 'open'
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Uri -eq 'https://canyouseeme.org/' }
    }
    It 'preserves UDP as unchecked' {
        Test-DunePortBuiltin -PublicIp '192.0.2.1' -Port 7777 -Protocol UDP | Should -Be 'udp-skip'
    }

    It 'contains no reference to the retired YouGetSignal hostname' {
        $root = Get-DstRepoRoot
        (Get-Content (Join-Path $root 'app\server\lib\Ports.ps1') -Raw) | Should -Not -Match 'ports\.yougetsignal\.com'
        (Get-Content (Join-Path $root 'dune-server.ps1') -Raw) | Should -Not -Match 'ports\.yougetsignal\.com'
    }
}
