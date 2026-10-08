Describe 'Cold-start performance guardrails' {
    BeforeAll {
        $repo = Join-Path $PSScriptRoot '..'
        $script:entry = Get-Content (Join-Path $repo 'app\DuneServer.ps1') -Raw
        $script:http = Get-Content (Join-Path $repo 'app\server\HttpServer.ps1') -Raw
        $script:scheduler = Get-Content (Join-Path $repo 'app\server\lib\RestartSchedule.ps1') -Raw
        $script:statusRoute = Get-Content (Join-Path $repo 'app\server\routes\Status.ps1') -Raw
    }

    It 'does not hold listener startup for the app-window focus proxy' {
        $script:entry | Should -Not -Match 'Start-Sleep -Milliseconds 700'
    }

    It 'runs terminal director cleanup on the background scheduler' {
        $script:entry | Should -Not -Match 'Remove-DuneTerminalDirectorPods'
        $script:scheduler | Should -Match 'Remove-DuneTerminalDirectorPods'
    }

    It 'warms one API worker and grows the pool on demand' {
        $script:http | Should -Match 'CreateRunspacePool\(1,\s*\$script:DuneApiMax'
    }

    It 'releases background startup after registering HTTP acceptance without waiting for a browser' {
        $accept = $script:http.IndexOf('$ctxTask = $listener.GetContextAsync()')
        $ready = $script:http.IndexOf('$httpReady.Set()', $accept)
        $wait = $script:http.IndexOf('$ctxTask.GetAwaiter().GetResult()', $accept)
        $ready | Should -BeGreaterThan $accept
        $ready | Should -BeLessThan $wait
        $script:entry | Should -Not -Match 'Initialize-DuneMobileBridge'
        $script:scheduler | Should -Match 'Initialize-DuneMobileBridge -ServerDir \$DuneSchedulerServerDir'
    }

    Context 'Deferred startup workers' {
        BeforeAll {
            $repo = Join-Path $PSScriptRoot '..'
            $script:cacheSource = Join-Path $repo 'app\server\lib\PlatformCache.ps1'
            . $script:cacheSource
            . (Join-Path $repo 'app\server\lib\RestartSchedule.ps1')
            function Write-DuneLog { param($Message, $Level) }
            function Wait-StartupCondition {
                param([scriptblock]$Condition)
                $deadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (& $Condition)) {
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'Startup test condition timed out.' }
                    Start-Sleep -Milliseconds 20
                }
            }
        }

        BeforeEach {
            $script:DunePlatformSnapshotState = $null
            $script:DunePlatformStartupWorker = $null
            $script:ready = [Threading.ManualResetEventSlim]::new($false)
            $script:entered = [Threading.ManualResetEventSlim]::new($false)
            $script:release = [Threading.ManualResetEventSlim]::new($false)
            $script:refreshed = [Threading.ManualResetEventSlim]::new($false)
            $script:control = [Collections.Hashtable]::Synchronized(@{
                entered = $script:entered
                release = $script:release
                refreshed = $script:refreshed
                failure = $false
                mapStopped = $false
                inventoryStopped = $false
            })
            $script:DuneApiLockTable = [Collections.Hashtable]::Synchronized(@{ testControl = $script:control })
            $script:serverDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $lib = New-Item -ItemType Directory -Path (Join-Path $script:serverDir 'lib')
            Copy-Item $script:cacheSource (Join-Path $lib.FullName 'PlatformCache.ps1')
            Set-Content (Join-Path $lib.FullName 'DuneLog.ps1') @'
    function Set-DuneLogPath { param($Path) }
    function Write-DuneLog { param($Message, $Level) }
'@
            Set-Content (Join-Path $lib.FullName 'PlatformRuntime.ps1') '# no live-source operations in startup tests'
            Set-Content (Join-Path $lib.FullName 'MapPlatform.ps1') @'
    function Get-DunePlatformCachePath { Join-Path $PSScriptRoot 'DuneLog.ps1' }
    function Invoke-DunePlatformHelper {
        param($Command, $TimeoutSec)
        $control = $script:DuneApiLockTable.testControl
        $control.entered.Set()
        $control.release.Wait($CancellationToken)
        if ($control.failure) { throw 'simulated hydrate failure' }
        [pscustomobject]@{
            ok = $true
            available = $true
            snapshot = [pscustomobject]@{ generation = 'persisted'; maps = @([pscustomobject]@{ id = 'map-1' }) }
        }
    }
    function Start-DuneMapsPlatformStartupRefresh {
        param($ServerDir, $AppDir)
        $script:DuneApiLockTable.testControl.mapState = Get-DunePlatformSnapshotState
        return $true
    }
    function Stop-DuneMapsPlatformRefresh {
        $script:DuneApiLockTable.testControl.mapStopped = $true
        return $true
    }
'@
            Set-Content (Join-Path $lib.FullName 'InventoryCache.ps1') @'
    function Start-DuneInventoryCacheStartupRefresh {
        param($ServerDir, $AppDir)
        $script:DuneApiLockTable.testControl.refreshed.Set()
        return $true
    }
    function Stop-DuneInventoryCacheRefresh {
        $script:DuneApiLockTable.testControl.inventoryStopped = $true
        return $true
    }
'@
        }

        AfterEach {
            [void](Stop-DunePlatformCacheStartup)
            [void](Stop-DuneRestartScheduler)
            $script:ready.Dispose()
            $script:entered.Dispose()
            $script:release.Dispose()
            $script:refreshed.Dispose()
        }

        It 'publishes into the same captured state without blocking readers or losing immutability' {
            $state = Get-DunePlatformSnapshotState
            $null = Set-DunePlatformSnapshotError -LastErrorCode 'cache-loading'
            $reader = [powershell]::Create()
            try {
                [void]$reader.AddScript({
                    param($Source, $State)
                    . $Source
                    $script:DunePlatformSnapshotState = $State
                    Get-DunePlatformSnapshot
                }).AddArgument($script:cacheSource).AddArgument($state)

                (Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0) | Should -BeTrue
                (Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0) | Should -BeFalse
                $script:entered.Wait(100) | Should -BeFalse
                $before = $reader.Invoke()[0]
                $before.available | Should -BeFalse
                $before.lastErrorCode | Should -Be 'cache-loading'

                $script:ready.Set()
                $script:entered.Wait(5000) | Should -BeTrue
                $during = $reader.Invoke()[0]
                $during.available | Should -BeFalse
                $script:refreshed.IsSet | Should -BeFalse
                $script:release.Set()
                $script:refreshed.Wait(5000) | Should -BeTrue
                $after = $reader.Invoke()[0]
                $after.available | Should -BeTrue
                $after.lastErrorCode | Should -BeNullOrEmpty
                $after.snapshot['generation'] | Should -Be 'persisted'
                $after.revision | Should -BeGreaterThan $before.revision
                [object]::ReferenceEquals($state, $script:control.mapState) | Should -BeTrue
                [object]::ReferenceEquals($state, (Get-DunePlatformSnapshotState)) | Should -BeTrue
                { $after.snapshot.Add('injected', $true) } | Should -Throw
                { $after.snapshot['maps'][0].Add('injected', $true) } | Should -Throw
                (Stop-DunePlatformCacheStartup) | Should -BeTrue
                $script:control.mapStopped | Should -BeTrue
                $script:control.inventoryStopped | Should -BeTrue
            } finally {
                $reader.Dispose()
            }
        }

        It 'preserves a published generation when background hydration fails' {
            $null = Set-DunePlatformSnapshot -Snapshot @{ generation = 'retained' }
            $before = Get-DunePlatformSnapshot
            $script:control.failure = $true
            $script:release.Set()
            $script:ready.Set()
            [void](Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0)
            $script:refreshed.Wait(5000) | Should -BeTrue
            $after = Get-DunePlatformSnapshot
            $after.available | Should -BeTrue
            $after.lastErrorCode | Should -Be 'cache-startup-failed'
            $after.snapshot['generation'] | Should -Be 'retained'
            $after.updatedAt | Should -Be $before.updatedAt
            [object]::ReferenceEquals($before.snapshot, $after.snapshot) | Should -BeTrue
        }

        It 'reports an unavailable cold cache honestly when hydration fails' {
            $script:control.failure = $true
            $script:release.Set()
            $script:ready.Set()
            [void](Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0)
            $script:refreshed.Wait(5000) | Should -BeTrue
            (Get-DunePlatformSnapshot).available | Should -BeFalse
            (Get-DunePlatformSnapshot).lastErrorCode | Should -Be 'cache-startup-failed'
        }

        It 'cancels before HTTP is ready without loading cache or source workers' {
            [void](Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0)
            (Stop-DunePlatformCacheStartup -WaitMs 1000) | Should -BeTrue
            $script:entered.IsSet | Should -BeFalse
            $script:refreshed.IsSet | Should -BeFalse
            $script:DunePlatformStartupWorker | Should -BeNullOrEmpty
        }

        It 'cancels in-flight hydration before starting either source refresh' {
            $script:ready.Set()
            [void](Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0)
            $script:entered.Wait(5000) | Should -BeTrue
            (Stop-DunePlatformCacheStartup -WaitMs 2000) | Should -BeTrue
            $script:refreshed.IsSet | Should -BeFalse
        }

        It 'owns and cancels both production refresh runners after deferred hydration' {
            $lib = Join-Path $script:serverDir 'lib'
            $productionLib = Split-Path $script:cacheSource -Parent
            Copy-Item (Join-Path $productionLib 'MapPlatform.ps1') (Join-Path $lib 'MapPlatform.ps1') -Force
            Copy-Item (Join-Path $productionLib 'InventoryCache.ps1') (Join-Path $lib 'InventoryCache.ps1') -Force
            Set-Content (Join-Path $lib 'PlatformRuntime.ps1') @'
function Test-DunePlatformLiveCacheSupported { param($RuntimePlatform) return $true }
function Initialize-DunePlatformCache {
    $null = Set-DunePlatformSnapshot -Snapshot @{ generation = 'persisted' }
    return @{ ok = $true; available = $true }
}
'@
            # The production runners/cleanup execute unchanged. Only their
            # live-source loops are replaced by cancellable, observable waits.
            Set-Content (Join-Path $lib 'ZStartupTestLoops.ps1') @'
function Invoke-DuneMapsPlatformRefreshLoop {
    param($CancellationToken, $InitialDelaySec)
    $control = $script:DuneApiLockTable.testControl
    $control.mapState = Get-DunePlatformSnapshotState
    $control.entered.Set()
    try { [void]$CancellationToken.WaitHandle.WaitOne() }
    finally { $control.mapStopped = $true }
}
function Invoke-DuneInventoryCacheRefreshLoop {
    param($CancellationToken, $InitialDelaySec)
    $control = $script:DuneApiLockTable.testControl
    $control.refreshed.Set()
    try { [void]$CancellationToken.WaitHandle.WaitOne() }
    finally { $control.inventoryStopped = $true }
}
'@
            $state = Get-DunePlatformSnapshotState
            $script:ready.Set()
            [void](Start-DunePlatformCacheStartup -ServerDir $script:serverDir -HttpReady $script:ready -DelaySec 0)
            $script:entered.Wait(5000) | Should -BeTrue
            $script:refreshed.Wait(5000) | Should -BeTrue
            [object]::ReferenceEquals($state, $script:control.mapState) | Should -BeTrue
            (Stop-DunePlatformCacheStartup) | Should -BeTrue
            $script:control.mapStopped | Should -BeTrue
            $script:control.inventoryStopped | Should -BeTrue
        }

        It 'starts headless hydration and answers HTTP while that hydration is still blocked' {
            $originalLocalAppData = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = Join-Path $TestDrive 'http-local'
            $httpSource = Join-Path $PSScriptRoot '..\app\server\HttpServer.ps1'
            $server = [powershell]::Create()
            try {
                [void]$server.AddScript({
                    param($HttpSource, $CacheSource, $ServerDir, $State, $Locks)
                    . $HttpSource
                    . $CacheSource
                    $script:DuneServerDir = $ServerDir
                    $script:DunePlatformSnapshotState = $State
                    $script:DuneApiLockTable = $Locks
                    function Write-DuneLog { param($Message, $Level) }
                    function Initialize-DuneApiPool {
                        $script:DuneApiLockTable.testControl.listener = $script:DuneListener
                        $script:DuneApiLockTable.testControl.url = $script:DunePrefixUrl
                    }
                    function Invoke-DuneContext {
                        param($Ctx)
                        $bytes = [Text.Encoding]::UTF8.GetBytes('startup-ready')
                        $Ctx.Response.ContentType = 'text/plain; charset=utf-8'
                        $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $Ctx.Response.Close()
                    }
                    Start-DuneHttpServer -DistRoot $ServerDir -PreferredPort 52840
                }).AddArgument($httpSource).AddArgument($script:cacheSource).AddArgument($script:serverDir).AddArgument((Get-DunePlatformSnapshotState)).AddArgument($script:DuneApiLockTable)
                $handle = $server.BeginInvoke()
                $script:entered.Wait(5000) | Should -BeTrue
                $script:refreshed.IsSet | Should -BeFalse
                $response = Invoke-WebRequest -Uri $script:control.url -UseBasicParsing -TimeoutSec 2
                $response.StatusCode | Should -Be 200
                $response.Content | Should -Be 'startup-ready'
                $script:refreshed.IsSet | Should -BeFalse
            } finally {
                if ($script:control.listener) { $script:control.listener.Stop() }
                if ($handle -and -not $handle.AsyncWaitHandle.WaitOne(5000)) {
                    $null = $server.BeginStop($null, $null)
                }
                $server.Dispose()
                $env:LOCALAPPDATA = $originalLocalAppData
            }
        }

        It 'keeps restart runspace Open free of library execution while preserving the update-check loader' {
            $iss = New-DuneSchedulerInitialSessionState -ServerDir $script:serverDir -DeferLibraryLoad
            $iss.StartupScripts.Count | Should -Be 0
            @($iss.Variables | Where-Object Name -eq 'DuneSchedulerStartupScripts')[0].Value.Count | Should -BeGreaterThan 0
            (New-DuneSchedulerInitialSessionState -ServerDir $script:serverDir).StartupScripts.Count | Should -BeGreaterThan 0
        }

        It 'returns before a slow scheduler library finishes and cancels it safely' {
            $marker = Join-Path $script:serverDir 'library-started'
            $safeMarker = $marker.Replace("'", "''")
            Set-Content (Join-Path $script:serverDir 'lib\Bootstrap.ps1') "Set-Content -LiteralPath '$safeMarker' -Value started; Start-Sleep -Seconds 30"
            Start-DuneRestartScheduler -ServerDir $script:serverDir -HttpReady $script:ready
            (Test-Path $marker) | Should -BeFalse
            $script:ready.Set()
            Wait-StartupCondition { Test-Path $marker }
            $script:DuneRestartSchedulerHandle.IsCompleted | Should -BeFalse
            (Stop-DuneRestartScheduler -WaitMs 2000) | Should -BeTrue
            $script:DuneRestartSchedulerStarted | Should -BeFalse
        }

        It 'runs the entire mobile bridge preflight inside the background pipeline' {
            $marker = Join-Path $script:serverDir 'bridge-started'
            $safeMarker = $marker.Replace("'", "''")
            Set-Content (Join-Path $script:serverDir 'lib\MobileBridge.ps1') @"
    function Initialize-DuneMobileBridge {
        param(`$ServerDir)
        Set-Content -LiteralPath '$safeMarker' -Value started
        Start-Sleep -Seconds 30
    }
"@
            Start-DuneRestartScheduler -ServerDir $script:serverDir -HttpReady $script:ready
            (Test-Path $marker) | Should -BeFalse
            $script:ready.Set()
            Wait-StartupCondition { Test-Path $marker }
            $script:DuneRestartSchedulerHandle.IsCompleted | Should -BeFalse
            (Stop-DuneRestartScheduler -WaitMs 2000) | Should -BeTrue
        }
    }

    It 'reuses VM discovery and the battlegroup title in the initial status request' {
        $script:statusRoute | Should -Match 'Get-DuneBattlegroupSnapshot -VmStatus \$vm'
        $script:statusRoute | Should -Match '\$bg\.title'
        $script:statusRoute | Should -Match 'Get-DuneServerName -CachedOnly'
    }
}
