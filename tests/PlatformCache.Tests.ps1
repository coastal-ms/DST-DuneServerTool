BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalPlatformSelfTest = $env:DST_PLATFORM_SELF_TEST
    $env:DST_PLATFORM_SELF_TEST = '1'
    $script:PlatformTestRoot = Join-Path ([IO.Path]::GetTempPath()) "dst-platform-tests-$([guid]::NewGuid().ToString('N'))"
    $env:LOCALAPPDATA = Join-Path $script:PlatformTestRoot 'Local'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    Import-DstLib 'PlatformCache.ps1'
    $script:PlatformHelper = Get-DunePlatformHelperPath
    if (-not $script:PlatformHelper) {
        throw 'Build DunePlatformStore in Release before running PlatformCache.Tests.ps1.'
    }
    function global:New-DunePlatformTestFileLink {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Target
        )
        try {
            New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
            return
        } catch {
            if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw }
            $toWsl = {
                param([string]$WindowsPath)
                $full = [IO.Path]::GetFullPath($WindowsPath)
                if ($full -notmatch '^([A-Za-z]):\\(.*)$') {
                    throw "Cannot convert test path to WSL: $full"
                }
                $drive = $Matches[1].ToLowerInvariant()
                $tail = $Matches[2].Replace('\', '/').Replace("'", "'\''")
                return "/mnt/$drive/$tail"
            }
            $linkPath = & $toWsl $Path
            $targetPath = & $toWsl $Target
            & wsl.exe sh -lc "ln -s -- '$targetPath' '$linkPath'"
            if ($LASTEXITCODE -ne 0) {
                throw "WSL could not create the test symbolic link (exit $LASTEXITCODE)."
            }
        }
    }
    $script:CanCreateFileSymlink = $false
    $probeRoot = Join-Path $script:PlatformTestRoot 'symlink-probe'
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    $probeTarget = Join-Path $probeRoot 'target'
    $probeLink = Join-Path $probeRoot 'link'
    [IO.File]::WriteAllText($probeTarget, 'probe')
    try {
        New-DunePlatformTestFileLink -Path $probeLink -Target $probeTarget
        $script:CanCreateFileSymlink = $true
    } catch {
        $script:CanCreateFileSymlink = $false
    } finally {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:DST_PLATFORM_SELF_TEST = $script:OriginalPlatformSelfTest
    Remove-Item Function:\global:New-DunePlatformTestFileLink -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:PlatformTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'DunePlatformStore production helper' {
    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'DuneServer') -Recurse -Force -ErrorAction SilentlyContinue
        $script:DunePlatformSnapshotState = $null
        $script:DuneApiLockTable = [Collections.Hashtable]::Synchronized(@{})
    }

    It 'passes scale, process concurrency, WAL, migration, and corruption self-tests' {
        $result = (& $script:PlatformHelper --command self-test) | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0
        $result.ok | Should -BeTrue
        $result.historyScale | Should -Be 100000
        $result.publicPoiScale | Should -Be 2000
        $result.processConcurrency | Should -BeTrue
        $result.oneShotExit | Should -BeTrue
        $result.inheritableStandardHandles | Should -BeTrue
        $result.interruptedWriteRecovery | Should -BeTrue
        $result.interruptedMigrationRecovery | Should -BeTrue
        $result.idempotentGenerationReplace | Should -BeTrue
        $result.offsetTimestampPruning | Should -BeTrue
        $result.pathRaceResistance | Should -BeTrue
        $result.runningElevated | Should -BeFalse
        $result.migrationBackup | Should -BeTrue
        $result.newerSchemaFailure | Should -BeTrue
        $result.corruptionFailure | Should -BeTrue
        $result.integrity.quickCheck | Should -Be 'ok'
    }

    It 'has no arbitrary SQL command or option surface' {
        $database = Get-DunePlatformCachePath
        $errorOutput = & $script:PlatformHelper --command sql --database $database --query 'DROP TABLE map_catalog' 2>&1
        $LASTEXITCODE | Should -Be 1
        (($errorOutput | Out-String) | ConvertFrom-Json).error | Should -Match "Unknown command 'sql'"

        $errorOutput = & $script:PlatformHelper --command hydrate --database $database --query 'SELECT 1' 2>&1
        $LASTEXITCODE | Should -Be 1
        (($errorOutput | Out-String) | ConvertFrom-Json).error | Should -Match "Option '--query' is not valid"
    }

    It 'fixes the production database path and drops elevation before parsing commands' {
        $program = Get-Content (Join-Path (Get-DstRepoRoot) 'app\tools\DunePlatformStore\Program.cs') -Raw
        $privilegeDrop = Get-Content (Join-Path (Get-DstRepoRoot) 'app\tools\DunePlatformStore\PrivilegeDrop.cs') -Raw
        $program.IndexOf('PrivilegeDrop.EnsureUnelevated(args)') |
            Should -BeLessThan $program.IndexOf('ParseArgs(args)')
        $program | Should -Match 'unelevatedExitCode\.HasValue'
        $program | Should -Not -Match 'unelevatedExitCode\s*>=\s*0'
        $ensureStart = $privilegeDrop.IndexOf('internal static int? EnsureUnelevated')
        $ensureEnd = $privilegeDrop.IndexOf('internal static bool IsElevated', $ensureStart)
        $ensureSource = $privilegeDrop.Substring($ensureStart, $ensureEnd - $ensureStart)
        $ensureSource | Should -Match 'RelaunchWithUnelevatedToken'
        $privilegeDrop | Should -Match 'OpenProcessToken\(\s*shellProcess,\s*TokenDuplicate \| TokenQuery'
        $privilegeDrop | Should -Match 'DuplicateTokenEx\(\s*token,\s*TokenAssignPrimary \| TokenDuplicate \| TokenQuery'
        $privilegeDrop | Should -Match 'CreateRestrictedToken\([\s\S]+DisableMaxPrivilege \| LuaToken'
        $privilegeDrop | Should -Match 'CreateProcessWithTokenW'
        $privilegeDrop | Should -Match 'DuplicateHandle\([\s\S]+inheritHandle'
        $privilegeDrop | Should -Match 'SelfTestInheritableStandardHandles'
        $privilegeDrop | Should -Match 'CreateKillOnCloseJob'
        $privilegeDrop | Should -Match 'AssignProcessToJobObject'
        $privilegeDrop | Should -Not -Match 'ProcThreadAttributeParentProcess'
        $privilegeDrop | Should -Not -Match 'CreateProcessW\('

        $prior = $env:DST_PLATFORM_SELF_TEST
        Remove-Item Env:DST_PLATFORM_SELF_TEST -ErrorAction SilentlyContinue
        try {
            $database = Join-Path $script:PlatformTestRoot 'override.sqlite'
            $errorOutput = & $script:PlatformHelper --command hydrate --database $database 2>&1
            $LASTEXITCODE | Should -Be 1
            (($errorOutput | Out-String) | ConvertFrom-Json).error |
                Should -Match '--database is available only to the helper self-test'
        } finally {
            $env:DST_PLATFORM_SELF_TEST = $prior
        }
    }

    It 'creates a current-user and SYSTEM-only cache directory' -Skip:(-not $IsWindows) {
        $null = Invoke-DunePlatformHelper -Command migrate
        $directory = Split-Path -Parent (Get-DunePlatformCachePath)
        $allowed = @(
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            'S-1-5-18'
        )
        $unexpected = @(Get-Acl -LiteralPath $directory).Access | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed
        }
        $unexpected.Count | Should -Be 0
    }

    It 'hydrates persisted state across one-shot helper and DST restarts' {
        $database = Get-DunePlatformCachePath
        $fixture = & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 100000 --poi-rows 2000 |
            ConvertFrom-Json
        $fixture.ok | Should -BeTrue

        $first = Initialize-DunePlatformCache
        $first.ok | Should -BeTrue
        $snapshot1 = Get-DunePlatformSnapshot
        $snapshot1.available | Should -BeTrue
        $snapshot1.snapshot['publicPois'].Count | Should -Be 2000

        $script:DunePlatformSnapshotState = $null
        $second = Initialize-DunePlatformCache
        $second.ok | Should -BeTrue
        $snapshot2 = Get-DunePlatformSnapshot
        $snapshot2.snapshot['generation'] | Should -Be 'fixture-1'
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        while (@(Get-Process -Name DunePlatformStore -ErrorAction SilentlyContinue).Count -gt 0 -and
               [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        @(Get-Process -Name DunePlatformStore -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'prunes history to the configured retention cap' {
        $database = Get-DunePlatformCachePath
        & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 100000 --poi-rows 10 | Out-Null
        $result = & $script:PlatformHelper --command prune --database $database --history-rows 1000 |
            ConvertFrom-Json
        $result.ok | Should -BeTrue
        $result.historyRows | Should -Be 1000
        $result.historyRemoved | Should -Be 99000
    }

    It 'kills the actual helper child before caller timeout and prevents a late write' {
        $database = Get-DunePlatformCachePath
        & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 1 --poi-rows 10 | Out-Null
        $hydrated = Invoke-DunePlatformHelper -Command hydrate
        $lateGeneration = [ordered]@{
            generation = 'late-generation'
            sources = @()
            maps = @($hydrated.snapshot.maps)
            layers = @($hydrated.snapshot.layers)
            activeSpiceCurrent = @($hydrated.snapshot.activeSpice)
            activeSpiceHistory = @()
            publicPois = @($hydrated.snapshot.publicPois)
        }
        $lateGeneration['padding'] = 'x' * (4MB)
        $lateJson = $lateGeneration | ConvertTo-Json -Depth 12 -Compress

        $timeoutWatch = [Diagnostics.Stopwatch]::StartNew()
        {
            Invoke-DunePlatformHelper -Command self-test-delayed-replace `
                -RequestJson $lateJson -Options @{ 'delay-ms' = 1500 } -TimeoutSec 1
        } | Should -Throw
        $timeoutWatch.Stop()
        $timeoutWatch.Elapsed.TotalSeconds | Should -BeLessThan 3
        Start-Sleep -Milliseconds 1700
        (Invoke-DunePlatformHelper -Command hydrate).snapshot.generation | Should -Be 'fixture-1'

        $lateGeneration.generation = 'retry-generation'
        $retry = Invoke-DunePlatformGenerationReplace -Generation $lateGeneration
        $retry.generation | Should -Be 'retry-generation'
        Start-Sleep -Milliseconds 200
        (Invoke-DunePlatformHelper -Command hydrate).snapshot.generation | Should -Be 'retry-generation'
        @(Get-Process -Name DunePlatformStore -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'runs the bounded hydrate path from Windows PowerShell 5.1' -Skip:(-not $IsWindows) {
        $database = Get-DunePlatformCachePath
        & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 10 --poi-rows 20 | Out-Null
        $probe = Join-Path $PSScriptRoot 'production\PlatformCache.PS51.ps1'
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe `
            -RepoRoot (Get-DstRepoRoot) -LocalAppData $env:LOCALAPPDATA
        $LASTEXITCODE | Should -Be 0
        ($raw | ConvertFrom-Json).generation | Should -Be 'fixture-1'
    }
}

Describe 'Platform cache reparse-point defenses' {
    BeforeEach {
        $script:SecurityCase = Join-Path $script:PlatformTestRoot "security-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:SecurityCase -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:SecurityCase -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'rejects an ancestor DuneServer junction without changing the target ACL' {
        $parent = Join-Path $script:SecurityCase 'local'
        $target = Join-Path $script:SecurityCase 'attacker-target'
        New-Item -ItemType Directory -Path $parent, $target -Force | Out-Null
        $before = (Get-Acl -LiteralPath $target).Sddl
        $junction = Join-Path $parent 'DuneServer'
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        $database = Join-Path $junction 'platform-cache\platform-cache-v1.sqlite'

        $errorOutput = & $script:PlatformHelper --command migrate --database $database 2>&1

        $LASTEXITCODE | Should -Be 1
        (($errorOutput | Out-String) | ConvertFrom-Json).error | Should -Match 'reparse point'
        (Get-Acl -LiteralPath $target).Sddl | Should -Be $before
    }

    It 'rejects a final platform-cache directory junction without changing the target ACL' {
        $duneServer = Join-Path $script:SecurityCase 'DuneServer'
        $target = Join-Path $script:SecurityCase 'attacker-target'
        New-Item -ItemType Directory -Path $duneServer, $target -Force | Out-Null
        $before = (Get-Acl -LiteralPath $target).Sddl
        $junction = Join-Path $duneServer 'platform-cache'
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        $database = Join-Path $junction 'platform-cache-v1.sqlite'

        $errorOutput = & $script:PlatformHelper --command migrate --database $database 2>&1

        $LASTEXITCODE | Should -Be 1
        (($errorOutput | Out-String) | ConvertFrom-Json).error | Should -Match 'reparse point'
        (Get-Acl -LiteralPath $target).Sddl | Should -Be $before
    }

    It 'rejects a database file symbolic link' {
        if (-not $script:CanCreateFileSymlink) {
            Set-ItResult -Skipped -Because 'This Windows token lacks symbolic-link privilege.'
            return
        }
        $cache = Join-Path $script:SecurityCase 'cache'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $target = Join-Path $script:SecurityCase 'target.sqlite'
        [IO.File]::WriteAllText($target, 'target')
        $database = Join-Path $cache 'platform-cache-v1.sqlite'
        New-DunePlatformTestFileLink -Path $database -Target $target

        $errorOutput = & $script:PlatformHelper --command migrate --database $database 2>&1

        $LASTEXITCODE | Should -Be 1
        (($errorOutput | Out-String) | ConvertFrom-Json).error | Should -Match 'reparse point'
    }

    It 'rejects WAL and SHM file symbolic links' {
        if (-not $script:CanCreateFileSymlink) {
            Set-ItResult -Skipped -Because 'This Windows token lacks symbolic-link privilege.'
            return
        }
        foreach ($suffix in @('-wal', '-shm')) {
            $cache = Join-Path $script:SecurityCase $suffix.TrimStart('-')
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $database = Join-Path $cache 'platform-cache-v1.sqlite'
            & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 1 --poi-rows 1 | Out-Null
            $target = Join-Path $script:SecurityCase "target$suffix"
            [IO.File]::WriteAllText($target, 'target')
            Remove-Item -LiteralPath "$database$suffix" -Force
            New-DunePlatformTestFileLink -Path "$database$suffix" -Target $target

            $errorOutput = & $script:PlatformHelper --command hydrate --database $database 2>&1

            $LASTEXITCODE | Should -Be 1
            (($errorOutput | Out-String) | ConvertFrom-Json).error | Should -Match 'reparse point'
        }
    }

    It 'rejects junctions occupying WAL and SHM sidecar paths' {
        foreach ($suffix in @('-wal', '-shm')) {
            $cache = Join-Path $script:SecurityCase "junction-$($suffix.TrimStart('-'))"
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $database = Join-Path $cache 'platform-cache-v1.sqlite'
            & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 1 --poi-rows 1 | Out-Null
            $target = Join-Path $script:SecurityCase "target-dir-$($suffix.TrimStart('-'))"
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Remove-Item -LiteralPath "$database$suffix" -Force
            New-Item -ItemType Junction -Path "$database$suffix" -Target $target | Out-Null

            $errorOutput = & $script:PlatformHelper --command hydrate --database $database 2>&1

            $LASTEXITCODE | Should -Be 1
            (($errorOutput | Out-String) | ConvertFrom-Json).error |
                Should -Match 'sidecar path is not a regular file'
        }
    }
}

Describe 'Platform cache snapshot and refresh coordination' {
    BeforeEach {
        $script:DunePlatformSnapshotState = $null
        $script:DuneApiLockTable = [Collections.Hashtable]::Synchronized(@{})
    }

    It 'atomically publishes a read-only snapshot reference' {
        $old = [pscustomobject]@{ generation = 'old'; maps = @([pscustomobject]@{ id = 'map-1' }) }
        $new = [pscustomobject]@{ generation = 'new'; maps = @([pscustomobject]@{ id = 'map-2' }) }
        $null = Set-DunePlatformSnapshot -Snapshot $old
        $first = Get-DunePlatformSnapshot
        $null = Set-DunePlatformSnapshot -Snapshot $new
        $second = Get-DunePlatformSnapshot

        $first.snapshot['generation'] | Should -Be 'old'
        $second.snapshot['generation'] | Should -Be 'new'
        $second.revision | Should -BeGreaterThan $first.revision
        { $second.snapshot.Add('injected', $true) } | Should -Throw
    }

    It 'marks expired fresh layers stale during hydration' {
        $database = Get-DunePlatformCachePath
        $null = Invoke-DunePlatformHelper -Command migrate
        $now = [DateTime]::UtcNow
        $generation = [ordered]@{
            generation = 'stale-generation'
            sources = @()
            maps = @([ordered]@{
                farmId = 'farm-1'; mapId = 'deep-desert'; partitionId = 'partition-1'
                label = 'Deep Desert'; kind = 'deep-desert'; lastSeenAt = $now.ToString('o'); active = $true
            })
            layers = @([ordered]@{
                farmId = 'farm-1'; mapId = 'deep-desert'; partitionId = 'partition-1'
                layerId = 'public-poi'; sourceKey = 'maps.public-poi'
                observedAt = $now.AddMinutes(-10).ToString('o'); cachedAt = $now.AddMinutes(-10).ToString('o')
                expiresAt = $now.AddMinutes(-5).ToString('o'); freshnessState = 'fresh'
                rowCount = 0; truncated = $false; payloadSha256 = ('a' * 64)
            })
            activeSpiceCurrent = @()
            activeSpiceHistory = @()
            publicPois = @()
        }
        $result = Invoke-DunePlatformGenerationReplace -Generation $generation
        $result.ok | Should -BeTrue
        (Get-DunePlatformSnapshot).snapshot['layers'][0]['freshnessState'] | Should -Be 'stale'
    }

    It 'prunes every successful production replacement with the accepted bounds' {
        $script:helperCommands = [Collections.Generic.List[object]]::new()
        Mock Invoke-DunePlatformHelper {
            param($Command, $RequestJson, $Options, $TimeoutSec)
            $script:helperCommands.Add([pscustomobject]@{
                command = $Command
                options = $Options
            })
            if ($Command -eq 'replace-generation') {
                return [pscustomobject]@{
                    ok = $true
                    generation = 'production-refresh'
                    counts = @{}
                    replaceMs = 1
                }
            }
            if ($Command -eq 'prune') {
                return [pscustomobject]@{ ok = $true; historyRows = 100000; snapshotRows = 40 }
            }
            return [pscustomobject]@{
                ok = $true
                available = $true
                snapshot = [pscustomobject]@{ generation = 'production-refresh'; layers = @() }
            }
        }

        $result = Invoke-DunePlatformGenerationReplace -Generation @{
            generation = 'production-refresh'
        }

        $result.ok | Should -BeTrue
        @($script:helperCommands.command) | Should -Be @('replace-generation', 'prune', 'hydrate')
        $pruneOptions = @($script:helperCommands | Where-Object command -eq 'prune')[0].options
        $pruneOptions['history-days'] | Should -Be 90
        $pruneOptions['history-rows'] | Should -Be 100000
        $pruneOptions['snapshot-generations'] | Should -Be 20
        $pruneOptions['max-bytes'] | Should -Be (250MB)
    }

    It 'publishes the successful generation and exposes a prune failure in cache health' {
        Mock Invoke-DunePlatformHelper {
            param($Command)
            if ($Command -eq 'replace-generation') {
                return [pscustomobject]@{
                    ok = $true
                    generation = 'fresh-after-prune-error'
                    counts = @{ activeSpiceHistory = 1 }
                    replaceMs = 1
                }
            }
            if ($Command -eq 'prune') {
                throw 'simulated prune failure'
            }
            return [pscustomobject]@{
                ok = $true
                available = $true
                snapshot = [pscustomobject]@{
                    generation = 'fresh-after-prune-error'
                    layers = @([pscustomobject]@{
                        layerId = 'active-spice'
                        freshnessState = 'fresh'
                        rowCount = 1
                    })
                    activeSpice = @([pscustomobject]@{ fieldId = '101' })
                }
            }
        }

        $result = Invoke-DunePlatformGenerationReplace -Generation @{
            generation = 'fresh-after-prune-error'
        }
        $state = Get-DunePlatformSnapshot

        $result.ok | Should -BeTrue
        $result.pruneErrorCode | Should -Be 'cache-prune-failed'
        $state.available | Should -BeTrue
        $state.snapshot['generation'] | Should -Be 'fresh-after-prune-error'
        $state.snapshot['layers'][0]['freshnessState'] | Should -Be 'fresh'
        $state.lastErrorCode | Should -Be 'cache-prune-failed'
    }

    It 'bounds persisted history and old generations on the production replace path' {
        $database = Get-DunePlatformCachePath
        & $script:PlatformHelper --command create-test-fixture --database $database --history-rows 100000 --poi-rows 1 | Out-Null
        $snapshot = (Invoke-DunePlatformHelper -Command hydrate).snapshot
        $generation = [ordered]@{
            generation = ''
            sources = @($snapshot.sources)
            maps = @($snapshot.maps)
            layers = @($snapshot.layers)
            activeSpiceCurrent = @($snapshot.activeSpice)
            activeSpiceHistory = @()
            publicPois = @($snapshot.publicPois)
        }
        foreach ($index in 1..21) {
            $generation.generation = "unpruned-$index"
            $null = Invoke-DunePlatformHelper `
                -Command replace-generation `
                -RequestJson ($generation | ConvertTo-Json -Depth 12 -Compress)
        }
        $generation.generation = 'production-pruned'
        $generation.activeSpiceHistory = @($snapshot.activeSpiceHistory | Select-Object -First 1)

        $result = Invoke-DunePlatformGenerationReplace -Generation $generation
        $integrity = Invoke-DunePlatformHelper -Command integrity

        $result.prune.historyRows | Should -BeLessOrEqual 100000
        $integrity.counts.activeSpiceHistory | Should -BeLessOrEqual 100000
        $integrity.counts.layerSnapshots | Should -BeLessOrEqual (20 * @($snapshot.layers).Count)
    }

    It 'enforces the global permit counts and bounded source policy' {
        (Get-DunePlatformGate -Name ssh).CurrentCount | Should -Be 4
        (Get-DunePlatformGate -Name database).CurrentCount | Should -Be 3
        (Get-DunePlatformGate -Name background).CurrentCount | Should -Be 2
        (Get-DunePlatformGate -Name writer).CurrentCount | Should -Be 1
        $policy = Get-DunePlatformRefreshPolicy
        $policy.queryTimeoutSec | Should -Be 15
        $policy.maxPayloadBytes | Should -Be (5MB)
        $policy.maxRows | Should -Be 10000
        $policy.backoffCapsSec | Should -Be @(15, 30, 60, 120, 300)
        $source = Invoke-DunePlatformSourceRead -SourceKey 'maps.catalog' -MaxRows 1 -Read {
            param($limits)
            [pscustomobject]@{ rows = @('map-1'); queryTimeoutSec = $limits.queryTimeoutSec }
        }
        $source.rows | Should -Be @('map-1')
        $source.queryTimeoutSec | Should -Be 15
    }

    It 'coalesces matching work and applies capped jittered backoff' {
        $script:calls = 0
        $first = Invoke-DunePlatformSingleFlight -Key 'aggregate:generation-1' -ResultReuseSec 30 -Script {
            $script:calls++
            return 'built'
        }
        $second = Invoke-DunePlatformSingleFlight -Key 'aggregate:generation-1' -ResultReuseSec 30 -Script {
            $script:calls++
            return 'duplicate'
        }
        $first | Should -Be 'built'
        $second | Should -Be 'built'
        $script:calls | Should -Be 1
        (Invoke-DunePlatformSingleFlight -Key 'aggregate:farm/map/partition/generation-1' -Script { 'slash-key' }) |
            Should -Be 'slash-key'
        (1..5 | ForEach-Object { Get-DunePlatformBackoffDelay -FailureCount $_ -Jitter 1.0 }) |
            Should -Be @(15, 30, 60, 120, 300)
        (Get-DunePlatformBackoffDelay -FailureCount 9 -Jitter 1.0) | Should -Be 300
    }

    It 'keeps helper and source refresh calls out of the snapshot response path' {
        $definition = (Get-Command Get-DunePlatformSnapshot).Definition
        $definition | Should -Not -Match 'Invoke-DunePlatformHelper'
        $definition | Should -Not -Match 'Invoke-DunePlatformSourceRead'
    }
}
