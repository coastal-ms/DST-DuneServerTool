$script:DunePlatformMaxRequestBytes = 5MB
$script:DunePlatformMaxResponseBytes = 8MB
$script:DunePlatformQueryTimeoutSec = 15
$script:DunePlatformMaxRows = 10000
$script:DunePlatformHistoryRetentionDays = 90
$script:DunePlatformHistoryRetentionRows = 100000
$script:DunePlatformSnapshotRetentionGenerations = 20
$script:DunePlatformCacheMaxBytes = 250MB
$script:DunePlatformSnapshotState = $null

function Get-DunePlatformCachePath {
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is unavailable for the derived platform cache.'
    }
    Join-Path $env:LOCALAPPDATA 'DuneServer\platform-cache\platform-cache-v1.sqlite'
}

function Get-DunePlatformHelperPath {
    $candidates = @()
    if ($script:AppDir) {
        $candidates += (Join-Path $script:AppDir 'tools\platform\DunePlatformStore.exe')
    }
    $project = Join-Path $PSScriptRoot '..\..\tools\DunePlatformStore'
    $candidates += (Join-Path $project 'bin\Release\net10.0-windows\win-x64\DunePlatformStore.exe')
    $candidates += (Join-Path $project 'bin\Release\net10.0-windows\win-x64\publish\DunePlatformStore.exe')
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        } catch {}
    }
    return $null
}

function ConvertTo-DunePlatformReadOnlyValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }

    $dictionary = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $dictionary[[string]$key] = ConvertTo-DunePlatformReadOnlyValue $Value[$key]
        }
        return [Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($dictionary)
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $dictionary[$property.Name] = ConvertTo-DunePlatformReadOnlyValue $property.Value
        }
        return [Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($dictionary)
    }
    if ($Value -is [Collections.IEnumerable]) {
        $list = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            [void]$list.Add((ConvertTo-DunePlatformReadOnlyValue $item))
        }
        Write-Output -NoEnumerate ([Collections.ObjectModel.ReadOnlyCollection[object]]::new($list))
        return
    }
    return $Value
}

function Get-DunePlatformSnapshotState {
    if (-not $script:DunePlatformSnapshotState) {
        $script:DunePlatformSnapshotState = [Collections.Hashtable]::Synchronized(@{
            revision = 0L
            available = $false
            snapshot = $null
            lastErrorCode = 'not-initialized'
            updatedAt = $null
        })
    }
    return $script:DunePlatformSnapshotState
}

function Set-DunePlatformSnapshot {
    param(
        $Snapshot,
        [string]$LastErrorCode
    )

    $state = Get-DunePlatformSnapshotState
    $readOnlySnapshot = ConvertTo-DunePlatformReadOnlyValue $Snapshot
    [Threading.Monitor]::Enter($state.SyncRoot)
    try {
        $state.snapshot = $readOnlySnapshot
        $state.available = $null -ne $readOnlySnapshot
        $state.lastErrorCode = if ($LastErrorCode) { $LastErrorCode } else { $null }
        $state.updatedAt = [DateTime]::UtcNow.ToString('o')
        $state.revision = [long]$state.revision + 1
        return [pscustomobject]@{
            revision = [long]$state.revision
            available = [bool]$state.available
            lastErrorCode = $state.lastErrorCode
        }
    } finally {
        [Threading.Monitor]::Exit($state.SyncRoot)
    }
}

function Get-DunePlatformSnapshot {
    $state = Get-DunePlatformSnapshotState
    [Threading.Monitor]::Enter($state.SyncRoot)
    try {
        return [pscustomobject]@{
            revision = [long]$state.revision
            available = [bool]$state.available
            snapshot = $state.snapshot
            lastErrorCode = $state.lastErrorCode
            updatedAt = $state.updatedAt
        }
    } finally {
        [Threading.Monitor]::Exit($state.SyncRoot)
    }
}

function ConvertTo-DunePlatformProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.IndexOf([char]0) -ge 0 -or $Value.Contains('"')) {
        throw 'Platform cache process arguments cannot contain NUL or quote characters.'
    }
    return '"' + $Value + '"'
}

function Invoke-DunePlatformHelper {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('migrate','hydrate','replace-generation','integrity','prune','self-test-delayed-replace')]
        [string]$Command,
        [string]$RequestJson,
        [hashtable]$Options = @{},
        [int]$TimeoutSec = 30
    )

    $helper = Get-DunePlatformHelperPath
    if (-not $helper) {
        throw 'DunePlatformStore.exe is unavailable. Build or install the platform cache helper.'
    }
    if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 120) {
        throw 'Platform cache helper timeout must be between 1 and 120 seconds.'
    }
    $allowedOptions = @{
        migrate = @()
        hydrate = @()
        'replace-generation' = @()
        'self-test-delayed-replace' = @('delay-ms')
        integrity = @()
        prune = @('history-days','history-rows','snapshot-generations','max-bytes')
    }
    foreach ($key in $Options.Keys) {
        if ([string]$key -notin $allowedOptions[$Command]) {
            throw "Unsupported option '$key' for platform cache command '$Command'."
        }
    }
    $requestCommands = @('replace-generation','self-test-delayed-replace')
    if ($Command -in $requestCommands -and -not $RequestJson) {
        throw "$Command requires a JSON request."
    }
    if ($Command -notin $requestCommands -and $RequestJson) {
        throw "Command '$Command' does not accept a JSON request."
    }
    if ($RequestJson -and [Text.Encoding]::UTF8.GetByteCount($RequestJson) -gt $script:DunePlatformMaxRequestBytes) {
        throw 'Platform cache request exceeds the 5 MiB limit.'
    }

    $callerDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $childDeadline = $callerDeadline.AddSeconds(-1)
    if ($childDeadline -le [DateTime]::UtcNow) {
        $childDeadline = [DateTime]::UtcNow.AddMilliseconds(100)
    }
    $deadlineTicks = $childDeadline.Ticks
    $arguments = @('--command', $Command, '--deadline-utc-ticks', [string]$deadlineTicks)
    if ($env:DST_PLATFORM_SELF_TEST -eq '1') {
        $arguments += @('--database', (Get-DunePlatformCachePath))
    }
    foreach ($key in ($Options.Keys | Sort-Object)) {
        $arguments += "--$key"
        $arguments += [string]$Options[$key]
    }
    $argumentText = (($arguments | ForEach-Object {
        ConvertTo-DunePlatformProcessArgument ([string]$_
        )
    }) -join ' ')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $helper
    $start.Arguments = $argumentText
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw 'The platform cache helper did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($RequestJson) {
            $process.StandardInput.AutoFlush = $true
            $writeTask = $process.StandardInput.WriteAsync($RequestJson)
            $remainingMs = [Math]::Max(
                0,
                [int][Math]::Ceiling(($callerDeadline - [DateTime]::UtcNow).TotalMilliseconds))
            if (-not $writeTask.Wait($remainingMs)) {
                try { $process.Kill() } catch {}
                throw "Platform cache helper timed out while receiving its request after ${TimeoutSec}s."
            }
            $writeTask.GetAwaiter().GetResult()
        }
        $process.StandardInput.Close()
        $remainingMs = [Math]::Max(
            0,
            [int][Math]::Ceiling(($callerDeadline - [DateTime]::UtcNow).TotalMilliseconds))
        if (-not $process.WaitForExit($remainingMs)) {
            try { $process.Kill() } catch {}
            throw "Platform cache helper timed out after ${TimeoutSec}s."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt $script:DunePlatformMaxResponseBytes) {
            throw 'Platform cache helper response exceeds the 8 MiB limit.'
        }
        $raw = if ($stdout) { $stdout } else { $stderr }
        $result = $null
        if ($raw) {
            try { $result = $raw | ConvertFrom-Json } catch {
                throw 'Platform cache helper returned malformed JSON.'
            }
        }
        if ($process.ExitCode -ne 0) {
            $message = if ($result -and $result.error) { [string]$result.error } else { "Platform cache helper failed with exit code $($process.ExitCode)." }
            $exception = [InvalidOperationException]::new($message)
            if ($result -and $result.errorCode) { $exception.Data['errorCode'] = [string]$result.errorCode }
            throw $exception
        }
        if (-not $result -or -not $result.ok) {
            throw 'Platform cache helper returned an invalid result.'
        }
        return $result
    } finally {
        $process.Dispose()
    }
}

function Initialize-DunePlatformCache {
    try {
        $cachePath = Get-DunePlatformCachePath
        if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
            $null = Invoke-DunePlatformHelper -Command migrate -TimeoutSec 30
        }
        try {
            $result = Invoke-DunePlatformHelper -Command hydrate -TimeoutSec 30
        } catch {
            if ($_.Exception.Message -notlike '*not initialized; run the migrate command*') { throw }
            $null = Invoke-DunePlatformHelper -Command migrate -TimeoutSec 30
            $result = Invoke-DunePlatformHelper -Command hydrate -TimeoutSec 30
        }
        if ($result.available -and $result.snapshot) {
            $state = Set-DunePlatformSnapshot -Snapshot $result.snapshot
        } else {
            $state = Set-DunePlatformSnapshot -Snapshot $null -LastErrorCode ([string]$result.errorCode)
        }
        return [pscustomobject]@{
            ok = $true
            available = [bool]$state.available
            revision = [long]$state.revision
            lastErrorCode = $state.lastErrorCode
        }
    } catch {
        $code = if ($_.Exception.Data['errorCode']) { [string]$_.Exception.Data['errorCode'] } else { 'cache-startup-failed' }
        $state = Set-DunePlatformSnapshot -Snapshot $null -LastErrorCode $code
        return [pscustomobject]@{
            ok = $false
            available = $false
            revision = [long]$state.revision
            lastErrorCode = $code
            message = $_.Exception.Message
        }
    }
}

function Invoke-DunePlatformGenerationReplace {
    param(
        [Parameter(Mandatory)]$Generation,
        [int]$TimeoutSec = 30
    )

    $json = $Generation | ConvertTo-Json -Depth 12 -Compress
    Invoke-DunePlatformGate -Name writer -TimeoutSec $TimeoutSec -Script {
        $result = Invoke-DunePlatformHelper -Command replace-generation -RequestJson $json -TimeoutSec $TimeoutSec
        $prune = $null
        $pruneErrorCode = $null
        try {
            $prune = Invoke-DunePlatformHelper `
                -Command prune `
                -Options @{
                    'history-days'        = $script:DunePlatformHistoryRetentionDays
                    'history-rows'        = $script:DunePlatformHistoryRetentionRows
                    'snapshot-generations' = $script:DunePlatformSnapshotRetentionGenerations
                    'max-bytes'           = $script:DunePlatformCacheMaxBytes
                } `
                -TimeoutSec $TimeoutSec
        } catch {
            $pruneErrorCode = if ($_.Exception.Data['errorCode']) {
                [string]$_.Exception.Data['errorCode']
            } else {
                'cache-prune-failed'
            }
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Platform cache prune failed after generation '$($result.generation)': $($_.Exception.Message)" 'WARN'
            }
        }
        $hydrated = Invoke-DunePlatformHelper -Command hydrate -TimeoutSec $TimeoutSec
        if (-not $hydrated.available -or -not $hydrated.snapshot) {
            throw 'The replaced platform cache generation could not be hydrated.'
        }
        $state = Set-DunePlatformSnapshot -Snapshot $hydrated.snapshot -LastErrorCode $pruneErrorCode
        return [pscustomobject]@{
            ok = $true
            generation = [string]$result.generation
            counts = $result.counts
            replaceMs = [double]$result.replaceMs
            snapshotRevision = [long]$state.revision
            prune = $prune
            pruneErrorCode = $pruneErrorCode
        }
    }
}

function Get-DunePlatformCoordinationTable {
    if (-not $script:DuneApiLockTable) {
        $script:DuneApiLockTable = [Collections.Hashtable]::Synchronized(@{})
    }
    return $script:DuneApiLockTable
}

function Get-DunePlatformGate {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ssh','database','background','writer')]
        [string]$Name
    )

    $capacities = @{ ssh = 4; database = 3; background = 2; writer = 1 }
    $table = Get-DunePlatformCoordinationTable
    $key = "platform-gate:$Name"
    [Threading.Monitor]::Enter($table.SyncRoot)
    try {
        if (-not $table.ContainsKey($key)) {
            $capacity = [int]$capacities[$Name]
            $table[$key] = [Threading.SemaphoreSlim]::new($capacity, $capacity)
        }
        return $table[$key]
    } finally {
        [Threading.Monitor]::Exit($table.SyncRoot)
    }
}

function Invoke-DunePlatformGate {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ssh','database','background','writer')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$TimeoutSec = 30
    )

    $gate = Get-DunePlatformGate -Name $Name
    if (-not $gate.Wait($TimeoutSec * 1000)) {
        throw "Platform '$Name' concurrency gate timed out after ${TimeoutSec}s."
    }
    try { & $Script } finally { [void]$gate.Release() }
}

function Invoke-DunePlatformGateChain {
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$TimeoutSec = 30,
        [int]$Index = 0
    )

    if ($Index -ge $Names.Count) { return & $Script }
    $name = $Names[$Index]
    $nextIndex = $Index + 1
    $next = {
        Invoke-DunePlatformGateChain -Names $Names -Script $Script -TimeoutSec $TimeoutSec -Index $nextIndex
    }.GetNewClosure()
    Invoke-DunePlatformGate -Name $name -TimeoutSec $TimeoutSec -Script $next
}

function Invoke-DunePlatformSingleFlight {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$')][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$TimeoutSec = 30,
        [int]$ResultReuseSec = 1
    )

    $table = Get-DunePlatformCoordinationTable
    $entryKey = "platform-flight:$Key"
    $owner = $false
    [Threading.Monitor]::Enter($table.SyncRoot)
    try {
        $entry = $table[$entryKey]
        $now = [DateTime]::UtcNow
        if (-not $entry -or ($entry.completed -and $entry.expiresAt -le $now)) {
            $entry = [Collections.Hashtable]::Synchronized(@{
                completed = $false
                expiresAt = [DateTime]::MinValue
                result = $null
                error = $null
                event = [Threading.ManualResetEventSlim]::new($false)
            })
            $table[$entryKey] = $entry
            $owner = $true
        }
    } finally {
        [Threading.Monitor]::Exit($table.SyncRoot)
    }

    if ($owner) {
        try {
            $entry.result = & $Script
        } catch {
            $entry.error = $_
        } finally {
            $entry.completed = $true
            $entry.expiresAt = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $ResultReuseSec))
            $entry.event.Set()
        }
    } elseif (-not $entry.event.Wait($TimeoutSec * 1000)) {
        throw "Platform single-flight '$Key' timed out after ${TimeoutSec}s."
    }

    if ($entry.error) { throw $entry.error }
    return $entry.result
}

function Get-DunePlatformBackoffDelay {
    param(
        [Parameter(Mandatory)][int]$FailureCount,
        [double]$Jitter = (Get-Random -Minimum 0.0 -Maximum 1.0)
    )

    $caps = @(15, 30, 60, 120, 300)
    $index = [Math]::Min([Math]::Max($FailureCount - 1, 0), $caps.Count - 1)
    $cap = [int]$caps[$index]
    $boundedJitter = [Math]::Min(1.0, [Math]::Max(0.0, $Jitter))
    return [Math]::Max(1, [int][Math]::Round($cap * (0.5 + (0.5 * $boundedJitter))))
}

function Assert-DunePlatformBackoffReady {
    param([Parameter(Mandatory)][string]$SourceKey)
    $table = Get-DunePlatformCoordinationTable
    $entry = $table["platform-backoff:$SourceKey"]
    if ($entry -and $entry.nextAttemptAt -gt [DateTime]::UtcNow) {
        $seconds = [Math]::Max(1, [int][Math]::Ceiling(($entry.nextAttemptAt - [DateTime]::UtcNow).TotalSeconds))
        throw "Platform source '$SourceKey' is backing off for ${seconds}s."
    }
}

function Register-DunePlatformRefreshFailure {
    param([Parameter(Mandatory)][string]$SourceKey)
    $table = Get-DunePlatformCoordinationTable
    $key = "platform-backoff:$SourceKey"
    [Threading.Monitor]::Enter($table.SyncRoot)
    try {
        $prior = $table[$key]
        $failures = if ($prior) { [int]$prior.failures + 1 } else { 1 }
        $delay = Get-DunePlatformBackoffDelay -FailureCount $failures
        $table[$key] = [pscustomobject]@{
            failures = $failures
            delaySeconds = $delay
            nextAttemptAt = [DateTime]::UtcNow.AddSeconds($delay)
        }
        return $table[$key]
    } finally {
        [Threading.Monitor]::Exit($table.SyncRoot)
    }
}

function Reset-DunePlatformRefreshBackoff {
    param([Parameter(Mandatory)][string]$SourceKey)
    $table = Get-DunePlatformCoordinationTable
    [void]$table.Remove("platform-backoff:$SourceKey")
}

function Get-DunePlatformRefreshPolicy {
    [pscustomobject]@{
        queryTimeoutSec = $script:DunePlatformQueryTimeoutSec
        maxPayloadBytes = $script:DunePlatformMaxRequestBytes
        maxRows = $script:DunePlatformMaxRows
        sshConcurrency = 4
        databaseConcurrency = 3
        backgroundConcurrency = 2
        cacheWriterConcurrency = 1
        backoffCapsSec = @(15, 30, 60, 120, 300)
    }
}

function Invoke-DunePlatformSourceRead {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')][string]$SourceKey,
        [Parameter(Mandatory)][scriptblock]$Read,
        [ValidateRange(1,10000)][int]$MaxRows = 10000,
        [switch]$Foreground,
        [int]$TimeoutSec = 30
    )

    Assert-DunePlatformBackoffReady -SourceKey $SourceKey
    Invoke-DunePlatformSingleFlight -Key "source:$SourceKey" -TimeoutSec $TimeoutSec -Script {
        try {
            $gates = if ($Foreground) { @('database','ssh') } else { @('background','database','ssh') }
            $policy = [pscustomobject]@{
                queryTimeoutSec = $script:DunePlatformQueryTimeoutSec
                maxPayloadBytes = $script:DunePlatformMaxRequestBytes
                maxRows = $MaxRows
            }
            $result = Invoke-DunePlatformGateChain -Names $gates -TimeoutSec $TimeoutSec -Script {
                & $Read $policy
            }
            if ($result -and $result.PSObject.Properties['ok'] -and -not [bool]$result.ok) {
                $message = if ($result.PSObject.Properties['error'] -and $result.error) {
                    [string]$result.error
                } elseif ($result.PSObject.Properties['reasonCode'] -and $result.reasonCode) {
                    "Platform source '$SourceKey' reported $($result.reasonCode)."
                } else {
                    "Platform source '$SourceKey' reported an unsuccessful result."
                }
                $exception = [InvalidOperationException]::new($message)
                if ($result.PSObject.Properties['reasonCode'] -and $result.reasonCode) {
                    $exception.Data['errorCode'] = [string]$result.reasonCode
                }
                $exception.Data['sourceResult'] = $result
                throw $exception
            }
            $json = $result | ConvertTo-Json -Depth 12 -Compress
            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:DunePlatformMaxRequestBytes) {
                throw "Platform source '$SourceKey' exceeded the 5 MiB payload budget."
            }
            if (-not $result -or -not $result.PSObject.Properties['rows']) {
                throw "Platform source '$SourceKey' did not return the required rows collection."
            }
            if (@($result.rows).Count -gt $MaxRows) {
                throw "Platform source '$SourceKey' exceeded the $MaxRows row budget."
            }
            Reset-DunePlatformRefreshBackoff -SourceKey $SourceKey
            return $result
        } catch {
            $null = Register-DunePlatformRefreshFailure -SourceKey $SourceKey
            throw
        }
    }
}

function Invoke-DunePlatformAggregateRefresh {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$')][string]$AggregateKey,
        [Parameter(Mandatory)][scriptblock]$Build,
        [int]$TimeoutSec = 30
    )

    Invoke-DunePlatformSingleFlight -Key "aggregate:$AggregateKey" -TimeoutSec $TimeoutSec -Script {
        $generation = & $Build (Get-DunePlatformRefreshPolicy)
        Invoke-DunePlatformGenerationReplace -Generation $generation -TimeoutSec $TimeoutSec
    }
}
