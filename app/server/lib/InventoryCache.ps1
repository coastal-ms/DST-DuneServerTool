$script:DuneInventoryCacheRefreshCadenceSec = 60
$script:DuneInventoryCacheTtlSec = 300
$script:DuneInventoryCacheStartupRefreshStarted = $false
$script:DuneInventoryCacheRefreshCancellation = $null
$script:DuneInventoryCacheRefreshPowerShell = $null
$script:DuneInventoryCacheRefreshCompletion = $null

function ConvertTo-DuneInventoryCacheFreshness {
    param([Parameter(Mandatory)]$Result)

    return New-DuneApiFreshness `
        -State ([string]$Result.freshness.state) `
        -ObservedAt ([string]$Result.observedAt) `
        -CachedAt ([string]$Result.cachedAt) `
        -AgeSeconds ([int]$Result.freshness.ageSeconds)
}

function Invoke-DuneInventoryGroupedCachePage {
    param(
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$PlayerId = 0,
        [string]$LocationType = '',
        [long]$LocationId = 0,
        [string]$Sort = 'name-asc',
        [int]$Offset = 0,
        [int]$Limit = 101,
        [string]$ExpectedGeneration = ''
    )

    try {
        $result = Invoke-DuneInventoryCacheQuery -Request ([ordered]@{
            query = $Query
            entityTypes = $EntityTypes
            scopeType = if ($ScopeType) { $ScopeType } else { $null }
            scopeId = if ($ScopeType) { $ScopeId } else { $null }
            playerId = if ($PlayerId -gt 0) { $PlayerId } else { $null }
            locationType = if ($LocationType) { $LocationType } else { $null }
            locationId = if ($LocationType) { $LocationId } else { $null }
            sort = $Sort
            offset = $Offset
            limit = $Limit
        })
        if (-not $result.available) {
            return @{ ok = $false; status = 503; error = 'Inventory cache is not ready.'; cacheUnavailable = $true }
        }
        if ($ExpectedGeneration -and [string]$result.generation -ne $ExpectedGeneration) {
            return @{ ok = $false; status = 409; error = 'Inventory cache changed; restart paging.' }
        }
        return @{
            ok = $true
            source = 'cache'
            cursorSource = 'cache'
            generation = [string]$result.generation
            freshness = ConvertTo-DuneInventoryCacheFreshness -Result $result
            groups = @($result.data.groups)
            players = @($result.data.players)
            locations = @($result.data.locations)
            selectedPlayerValid = [bool]$result.data.selectedPlayerValid
            selectedLocationValid = [bool]$result.data.selectedLocationValid
            offset = [int]$result.data.offset
            nextOffset = $result.data.nextOffset
            truncated = [bool]$result.data.truncated
        }
    } catch {
        return @{
            ok = $false
            status = 503
            error = "Inventory cache read failed: $($_.Exception.Message)"
            cacheUnavailable = $true
        }
    }
}

function Invoke-DuneInventoryOccurrenceCachePage {
    param(
        [Parameter(Mandatory)][string]$TemplateId,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$PlayerId = 0,
        [string]$LocationType = '',
        [long]$LocationId = 0,
        [string]$Sort = 'player-asc',
        [int]$Offset = 0,
        [int]$Limit = 51,
        [string]$ExpectedGeneration = ''
    )

    try {
        $result = Invoke-DuneInventoryCacheOccurrenceQuery -Request ([ordered]@{
            templateId = $TemplateId
            entityTypes = $EntityTypes
            scopeType = if ($ScopeType) { $ScopeType } else { $null }
            scopeId = if ($ScopeType) { $ScopeId } else { $null }
            playerId = if ($PlayerId -gt 0) { $PlayerId } else { $null }
            locationType = if ($LocationType) { $LocationType } else { $null }
            locationId = if ($LocationType) { $LocationId } else { $null }
            sort = $Sort
            offset = $Offset
            limit = $Limit
        })
        if (-not $result.available) {
            return @{ ok = $false; status = 503; error = 'Inventory cache is not ready.'; cacheUnavailable = $true }
        }
        if ($ExpectedGeneration -and [string]$result.generation -ne $ExpectedGeneration) {
            return @{ ok = $false; status = 409; error = 'Inventory cache changed; restart paging.' }
        }
        return @{
            ok = $true
            source = 'cache'
            cursorSource = 'cache'
            generation = [string]$result.generation
            freshness = ConvertTo-DuneInventoryCacheFreshness -Result $result
            items = @($result.data.items)
            players = @($result.data.players)
            locations = @($result.data.locations)
            selectedPlayerValid = [bool]$result.data.selectedPlayerValid
            selectedLocationValid = [bool]$result.data.selectedLocationValid
            offset = [int]$result.data.offset
            nextOffset = $result.data.nextOffset
            truncated = [bool]$result.data.truncated
        }
    } catch {
        return @{
            ok = $false
            status = 503
            error = "Inventory cache read failed: $($_.Exception.Message)"
            cacheUnavailable = $true
        }
    }
}

function Invoke-DuneInventoryCacheRefresh {
    param([int]$TimeoutSec = 120)

    $sourceKey = 'inventory.snapshot'
    Assert-DunePlatformBackoffReady -SourceKey $sourceKey
    $startedAt = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $rowCount = $null
    $payloadBytes = $null
    try {
        $source = Invoke-DunePlatformSingleFlight `
            -Key 'source:inventory.snapshot' `
            -TimeoutSec $TimeoutSec `
            -ResultReuseSec 0 `
            -Script {
                Invoke-DunePlatformGateChain `
                    -Names @('background','database','ssh') `
                    -TimeoutSec $TimeoutSec `
                    -Script {
                        $context = Get-DuneDbContext
                        if (-not $context.ok) {
                            throw "Inventory database unavailable: $([string]$context.message)"
                        }
                        $result = Invoke-DuneInventorySnapshotLive `
                            -Ip ([string]$context.ip) `
                            -MaxRows 100000
                        if (-not $result.ok) {
                            throw "Inventory database read failed: $([string]$result.error)"
                        }
                        return $result
                    }
            }
        $rowCount = @($source.items).Count
        $cachedAt = [DateTime]::UtcNow
        $snapshot = [ordered]@{
            generation = "inventory-$($cachedAt.ToString('yyyyMMddTHHmmssfffffffZ'))"
            observedAt = $startedAt.ToString('o')
            cachedAt = $cachedAt.ToString('o')
            expiresAt = $cachedAt.AddSeconds($script:DuneInventoryCacheTtlSec).ToString('o')
            sourceFingerprint = 'inventory-v1:player-storage'
            items = @($source.items)
        }
        $payloadBytes = [Text.Encoding]::UTF8.GetByteCount(
            ($snapshot | ConvertTo-Json -Depth 10 -Compress)
        )
        $result = Invoke-DuneInventoryCacheReplace -Snapshot $snapshot -TimeoutSec $TimeoutSec
        Reset-DunePlatformRefreshBackoff -SourceKey $sourceKey
        $watch.Stop()
        Update-DunePlatformSourceTelemetry `
            -SourceKey $sourceKey `
            -StartedAt $startedAt `
            -DurationMs $watch.Elapsed.TotalMilliseconds `
            -Success $true `
            -RowCount $rowCount `
            -PayloadBytes $payloadBytes
        Set-DunePlatformSourceNextDue `
            -SourceKey $sourceKey `
            -NextDueAt ([DateTime]::UtcNow.AddSeconds($script:DuneInventoryCacheRefreshCadenceSec))
        $null = Set-DunePlatformSourceDetails -SourceKey $sourceKey -Details @{
            cadenceSeconds = $script:DuneInventoryCacheRefreshCadenceSec
            staleAfterSeconds = $script:DuneInventoryCacheTtlSec
            entityTypes = @('player','storage')
            generation = [string]$result.generation
        }
        return $result
    } catch {
        $sourceErrorRecord = $_
        $backoff = Register-DunePlatformRefreshFailure -SourceKey $sourceKey
        $watch.Stop()
        Update-DunePlatformSourceTelemetry `
            -SourceKey $sourceKey `
            -StartedAt $startedAt `
            -DurationMs $watch.Elapsed.TotalMilliseconds `
            -Success $false `
            -RowCount $rowCount `
            -PayloadBytes $payloadBytes `
            -ErrorCode (Get-DunePlatformExceptionCode $sourceErrorRecord) `
            -Backoff $backoff
        throw $sourceErrorRecord
    }
}

function Invoke-DuneInventoryCacheRefreshLoop {
    param(
        [Parameter(Mandatory)][Threading.CancellationToken]$CancellationToken,
        [double]$InitialDelaySec = 2,
        [scriptblock]$Refresh,
        [scriptblock]$NextDelay
    )

    if (-not $Refresh) { $Refresh = { Invoke-DuneInventoryCacheRefresh } }
    if (-not $NextDelay) {
        $NextDelay = { [double]$script:DuneInventoryCacheRefreshCadenceSec }
    }
    if ($InitialDelaySec -gt 0 -and $CancellationToken.WaitHandle.WaitOne(
        [int][Math]::Ceiling($InitialDelaySec * 1000)
    )) {
        return
    }
    while (-not $CancellationToken.IsCancellationRequested) {
        try {
            $null = & $Refresh
        } catch {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Inventory cache refresh failed: $($_.Exception.Message)" 'WARN'
            }
        }
        $delay = [Math]::Max(1, [double](& $NextDelay))
        if ($CancellationToken.WaitHandle.WaitOne([int][Math]::Ceiling($delay * 1000))) {
            return
        }
    }
}

function Start-DuneInventoryCacheStartupRefresh {
    param(
        [Parameter(Mandatory)][string]$ServerDir,
        [string]$AppDir = $script:AppDir,
        [double]$DelaySec = 2
    )

    if ($script:DuneInventoryCacheStartupRefreshStarted) { return $false }
    $sharedLocks = Get-DunePlatformCoordinationTable
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        if (-not ('DuneServer.InventoryRefreshRunner' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

namespace DuneServer
{
    public static class InventoryRefreshRunner
    {
        public static ManualResetEventSlim Queue(PowerShell powershell, Runspace runspace)
        {
            var completed = new ManualResetEventSlim(false);
            if (!ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    powershell.Invoke();
                }
                finally
                {
                    powershell.Dispose();
                    runspace.Dispose();
                    completed.Set();
                }
            }))
            {
                completed.Dispose();
                throw new InvalidOperationException("Could not queue the inventory refresh worker.");
            }
            return completed;
        }
    }
}
'@
        }
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'MTA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
        [void]$powershell.AddScript({
            param($ServerDir, $AppDir, $LockTable, $DelaySec, $CancellationToken, $LogPath)
            try {
                $script:AppDir = $AppDir
                $duneLog = Join-Path $ServerDir 'lib\DuneLog.ps1'
                if (Test-Path -LiteralPath $duneLog) {
                    . $duneLog
                    if ($LogPath) { Set-DuneLogPath -Path $LogPath }
                }
                $bootstrap = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                if (Test-Path -LiteralPath $bootstrap) { . $bootstrap }
                $http = Join-Path $ServerDir 'HttpServer.ps1'
                if (Test-Path -LiteralPath $http) { . $http }
                Get-ChildItem -LiteralPath (Join-Path $ServerDir 'lib') -Filter '*.ps1' |
                    Sort-Object Name |
                    Where-Object { $_.Name -notin @('Bootstrap.ps1','DuneLog.ps1') } |
                    ForEach-Object { . $_.FullName }
                $script:DuneApiLockTable = $LockTable
                $null = Invoke-DuneInventoryCacheRefreshLoop `
                    -CancellationToken $CancellationToken `
                    -InitialDelaySec $DelaySec
            } catch {
                if (-not $CancellationToken.IsCancellationRequested -and
                    (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
                    Write-DuneLog "Inventory cache refresh scheduler stopped: $($_.Exception.Message)" 'WARN'
                }
            }
        }).AddArgument($ServerDir).AddArgument($AppDir).AddArgument($sharedLocks).AddArgument($DelaySec).AddArgument($cancellation.Token).AddArgument($script:DuneLogPath)
        $completion = [DuneServer.InventoryRefreshRunner]::Queue($powershell, $runspace)
        $script:DuneInventoryCacheRefreshCancellation = $cancellation
        $script:DuneInventoryCacheRefreshPowerShell = $powershell
        $script:DuneInventoryCacheRefreshCompletion = $completion
        $script:DuneInventoryCacheStartupRefreshStarted = $true
        return $true
    } catch {
        try { $cancellation.Cancel() } catch {}
        try { $cancellation.Dispose() } catch {}
        if ($powershell) { try { $powershell.Dispose() } catch {} }
        if ($runspace) { try { $runspace.Dispose() } catch {} }
        throw
    }
}

function Stop-DuneInventoryCacheRefresh {
    param([ValidateRange(1,30000)][int]$WaitMs = 5000)

    $cancellation = $script:DuneInventoryCacheRefreshCancellation
    if (-not $cancellation) { return $false }
    try { $cancellation.Cancel() } catch {}
    $completion = $script:DuneInventoryCacheRefreshCompletion
    $powershell = $script:DuneInventoryCacheRefreshPowerShell
    if ($completion -and -not $completion.Wait([Math]::Min(1000, $WaitMs))) {
        try { $null = $powershell.BeginStop($null, $null) } catch {}
        if (-not $completion.Wait($WaitMs)) {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog 'Inventory cache refresh did not stop within the shutdown timeout.' 'WARN'
            }
            return $false
        }
    }
    $script:DuneInventoryCacheRefreshCancellation = $null
    $script:DuneInventoryCacheRefreshPowerShell = $null
    $script:DuneInventoryCacheRefreshCompletion = $null
    $script:DuneInventoryCacheStartupRefreshStarted = $false
    try { if ($completion) { $completion.Dispose() } } catch {}
    try { $cancellation.Dispose() } catch {}
    return $true
}
