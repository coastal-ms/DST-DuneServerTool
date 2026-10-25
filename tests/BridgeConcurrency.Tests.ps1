BeforeAll {
    . (Join-Path $PSScriptRoot '..\helper\bridge\DstHelperBridge.ps1') -NoStart
    # Exercise the real pool/dispatch helpers without opening a network listener.
    function Invoke-Request {
        param($Context)
        $Context.Started.Set()
        if ($Context.Gate) { [void]$Context.Gate.Wait(10000) }
        $Context.Done.Set()
    }
    function New-BridgeFixtureContext {
        param($Gate = $null)
        @{Started=[Threading.ManualResetEventSlim]::new();Done=[Threading.ManualResetEventSlim]::new();Gate=$Gate}
    }
}

Describe 'Concurrent bridge request workers' {
    It 'lets another request complete while a slow transfer is still active' {
        $pool = New-DuneBridgeRequestPool -Maximum 2
        $gate = [Threading.ManualResetEventSlim]::new()
        $slow = New-BridgeFixtureContext $gate; $fast = New-BridgeFixtureContext
        $jobs = [Collections.Generic.List[object]]::new()
        try {
            $jobs.Add((Start-DuneBridgeRequest -Pool $pool -Context $slow))
            $slow.Started.Wait(5000) | Should -BeTrue
            $jobs.Add((Start-DuneBridgeRequest -Pool $pool -Context $fast))
            $fast.Done.Wait(5000) | Should -BeTrue
            $slow.Done.IsSet | Should -BeFalse
        } finally {
            $gate.Set()
            foreach ($job in $jobs) { [void]$job.worker.EndInvoke($job.handle); $job.worker.Dispose() }
            $pool.Close(); $pool.Dispose(); $gate.Dispose()
        }
    }
    It 'keeps authentication capacity available when transfer workers are occupied' {
        $pool = New-DuneBridgeRequestPool -Maximum 1
        $authPool = New-DuneBridgeRequestPool -Maximum 1
        $gate = [Threading.ManualResetEventSlim]::new()
        $slow = New-BridgeFixtureContext $gate; $logout = New-BridgeFixtureContext
        $jobs = [Collections.Generic.List[object]]::new()
        try {
            $jobs.Add((Start-DuneBridgeRequest -Pool $pool -Context $slow))
            $slow.Started.Wait(5000) | Should -BeTrue
            $jobs.Add((Start-DuneBridgeRequest -Pool $authPool -Context $logout))
            $logout.Done.Wait(5000) | Should -BeTrue
            $slow.Done.IsSet | Should -BeFalse
        } finally {
            $gate.Set()
            foreach ($job in $jobs) { [void]$job.worker.EndInvoke($job.handle); $job.worker.Dispose() }
            $pool.Close(); $pool.Dispose(); $authPool.Close(); $authPool.Dispose(); $gate.Dispose()
        }
    }
}

AfterAll { $script:HttpClient.Dispose() }
