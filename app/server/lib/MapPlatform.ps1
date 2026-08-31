$script:DuneMapsSchemaSourceKey = 'maps.schema'
$script:DuneMapsActiveSpiceSourceKey = 'maps.active-spice'
$script:DuneMapsPublicPoiSourceKey = 'maps.public-poi'
$script:DuneMapsFarmId = 'local-farm'
$script:DuneMapsDeepDesertId = 'deep-desert'
$script:DuneMapsCurrentPartitionId = 'current'
$script:DuneMapsActiveSpiceMaxRows = 200
$script:DuneMapsActiveSpiceStaleAfterSec = 60
$script:DuneMapsSchemaRefreshCadenceSec = 1800
$script:DuneMapsObservationHeartbeatSec = 900
$script:DuneMapsHistoryDeliveryMaxRows = 250
$script:DuneMapsSourceMapDimensionMax = 64
$script:DuneMapsRefreshCadenceSec = 15
$script:DuneMapsRefreshJitterPercent = 10
$script:DuneMapsStartupRefreshStarted = $false
$script:DuneMapsRefreshCancellation = $null
$script:DuneMapsRefreshPowerShell = $null
$script:DuneMapsRefreshCompletion = $null

function Get-DuneMapPlatformValue {
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Set-DuneMapsSourceDetails {
    param(
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)]$Details
    )

    if (-not (Get-Command Set-DunePlatformSourceDetails -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        $result = Set-DunePlatformSourceDetails -SourceKey $SourceKey -Details $Details
        if ($result -and -not $result.ok -and
            (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
            Write-DuneLog "Maps source details were omitted for '$SourceKey' ($($result.errorCode))." 'WARN'
        }
        return [bool]$result.ok
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Maps source details failed for '$SourceKey': $($_.Exception.Message)" 'WARN'
        }
        return $false
    }
}

function Set-DuneMapsSourceNextDue {
    param(
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][datetime]$NextDueAt
    )

    if (-not (Get-Command Set-DunePlatformSourceNextDue -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        Set-DunePlatformSourceNextDue -SourceKey $SourceKey -NextDueAt $NextDueAt
        return $true
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Maps source schedule telemetry failed for '$SourceKey': $($_.Exception.Message)" 'WARN'
        }
        return $false
    }
}

function Get-DuneMapsRefreshDelaySec {
    param([double]$Sample = (Get-Random -Minimum 0.0 -Maximum 1.0))
    $bounded = [Math]::Min(1.0, [Math]::Max(0.0, $Sample))
    $spread = $script:DuneMapsRefreshJitterPercent / 100.0
    return $script:DuneMapsRefreshCadenceSec * ((1.0 - $spread) + (2.0 * $spread * $bounded))
}

function Get-DuneMapsScheduledRefreshDelaySec {
    param([double]$Sample = (Get-Random -Minimum 0.0 -Maximum 1.0))

    $delay = Get-DuneMapsRefreshDelaySec -Sample $Sample
    $table = Get-DunePlatformCoordinationTable
    $backoff = $table["platform-backoff:$script:DuneMapsActiveSpiceSourceKey"]
    if ($backoff -and $backoff.nextAttemptAt -gt [DateTime]::UtcNow) {
        $remaining = ($backoff.nextAttemptAt - [DateTime]::UtcNow).TotalSeconds
        $delay = [Math]::Max($delay, $remaining)
    }
    return $delay
}

function Invoke-DuneMapsPlatformRefreshLoop {
    param(
        [Parameter(Mandatory)][Threading.CancellationToken]$CancellationToken,
        [double]$InitialDelaySec = (Get-DuneMapsRefreshDelaySec),
        [scriptblock]$Refresh,
        [scriptblock]$NextDelay
    )

    if (-not $Refresh) { $Refresh = { Invoke-DuneMapsPlatformRefresh } }
    if (-not $NextDelay) { $NextDelay = { Get-DuneMapsScheduledRefreshDelaySec } }
    if ($InitialDelaySec -gt 0 -and $CancellationToken.WaitHandle.WaitOne(
        [int][Math]::Ceiling($InitialDelaySec * 1000)
    )) {
        return 0
    }

    $attempts = 0
    while (-not $CancellationToken.IsCancellationRequested) {
        try {
            $null = & $Refresh
        } catch {
            if (-not $CancellationToken.IsCancellationRequested -and
                (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
                Write-DuneLog "Maps platform refresh failed: $($_.Exception.Message)" 'WARN'
            }
        }
        $attempts++
        if ($CancellationToken.IsCancellationRequested) { break }
        $delaySec = [Math]::Max(0.01, [double](& $NextDelay))
        [void](Set-DuneMapsSourceNextDue `
            -SourceKey $script:DuneMapsActiveSpiceSourceKey `
            -NextDueAt ([DateTime]::UtcNow.AddSeconds($delaySec)))
        if ($CancellationToken.WaitHandle.WaitOne([int][Math]::Ceiling($delaySec * 1000))) {
            break
        }
    }
    return $attempts
}

function Get-DuneMapsPayloadSha256 {
    param($Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    if (Get-Command Get-DuneSha256Hex -ErrorAction SilentlyContinue) {
        return Get-DuneSha256Hex $json
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) |
            ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Get-DuneMapsSnapshotItems {
    param($Snapshot, [Parameter(Mandatory)][string]$Name)
    $value = Get-DuneMapPlatformValue $Snapshot $Name
    if ($null -eq $value) { return @() }
    return @($value)
}

function Get-DuneMapsPriorLayer {
    param($Snapshot, [Parameter(Mandatory)][string]$LayerId)
    return @(Get-DuneMapsSnapshotItems -Snapshot $Snapshot -Name 'layers' |
        Where-Object { [string](Get-DuneMapPlatformValue $_ 'layerId') -eq $LayerId } |
        Select-Object -First 1)[0]
}

function Get-DuneMapsPriorSource {
    param($Snapshot, [Parameter(Mandatory)][string]$SourceKey)
    return @(Get-DuneMapsSnapshotItems -Snapshot $Snapshot -Name 'sources' |
        Where-Object { [string](Get-DuneMapPlatformValue $_ 'sourceKey') -eq $SourceKey } |
        Select-Object -First 1)[0]
}

function Get-DuneMapsActiveSpiceSignature {
    param([object[]]$Rows)

    $normalized = @($Rows | ForEach-Object {
        [ordered]@{
            farmId = [string](Get-DuneMapPlatformValue $_ 'farmId')
            mapId = [string](Get-DuneMapPlatformValue $_ 'mapId')
            partitionId = [string](Get-DuneMapPlatformValue $_ 'partitionId')
            fieldId = [string](Get-DuneMapPlatformValue $_ 'fieldId')
            state = [string](Get-DuneMapPlatformValue $_ 'state')
            coordinateSpace = [string](Get-DuneMapPlatformValue $_ 'coordinateSpace')
            x = Get-DuneMapPlatformValue $_ 'x'
            y = Get-DuneMapPlatformValue $_ 'y'
            sourceFingerprint = [string](Get-DuneMapPlatformValue $_ 'sourceFingerprint')
        }
    } | Sort-Object farmId, mapId, partitionId, fieldId)
    return Get-DuneMapsPayloadSha256 $normalized
}

function Get-DuneMapsLatestHistoryObservedAt {
    param(
        $Snapshot,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $latest = @(Get-DuneMapsSnapshotItems -Snapshot $Snapshot -Name 'activeSpiceHistory' |
        Where-Object {
            [string](Get-DuneMapPlatformValue $_ 'sourceFingerprint') -eq $SourceFingerprint
        } |
        Sort-Object {
            try { ([datetime](Get-DuneMapPlatformValue $_ 'observedAt')).ToUniversalTime() }
            catch { [datetime]::MinValue }
        } -Descending |
        Select-Object -First 1)[0]
    if (-not $latest) { return $null }
    try { return ([datetime](Get-DuneMapPlatformValue $latest 'observedAt')).ToUniversalTime() }
    catch { return $null }
}

function Get-DuneMapsActiveSpiceHistoryRows {
    param(
        [object[]]$CurrentRows,
        $PreviousSnapshot,
        [Parameter(Mandatory)]$SourceResult,
        [datetime]$Now = [DateTime]::UtcNow
    )

    if ([string]$SourceResult.status -ne 'ready' -or [bool]$SourceResult.truncated) {
        return @()
    }
    if (@($CurrentRows).Count -eq 0) {
        # Absence is not an inactive event; it may be a real empty sample.
        return @()
    }

    $fingerprint = [string]$SourceResult.source.schemaFingerprint
    if (-not $PreviousSnapshot -or -not $fingerprint) { return @($CurrentRows) }
    $priorLayer = Get-DuneMapsPriorLayer -Snapshot $PreviousSnapshot -LayerId 'active-spice'
    $priorSource = Get-DuneMapsPriorSource `
        -Snapshot $PreviousSnapshot `
        -SourceKey $script:DuneMapsActiveSpiceSourceKey
    $priorComplete = (
        $priorLayer -and
        [string](Get-DuneMapPlatformValue $priorLayer 'freshnessState') -eq 'fresh' -and
        -not [bool](Get-DuneMapPlatformValue $priorLayer 'truncated') -and
        [string](Get-DuneMapPlatformValue $priorSource 'schemaFingerprint') -eq $fingerprint
    )
    if (-not $priorComplete) { return @($CurrentRows) }

    $priorRows = @(Get-DuneMapsSnapshotItems -Snapshot $PreviousSnapshot -Name 'activeSpice')
    if ((Get-DuneMapsActiveSpiceSignature $priorRows) -ne
        (Get-DuneMapsActiveSpiceSignature $CurrentRows)) {
        return @($CurrentRows)
    }

    $latest = Get-DuneMapsLatestHistoryObservedAt `
        -Snapshot $PreviousSnapshot `
        -SourceFingerprint $fingerprint
    if (-not $latest -or ($Now.ToUniversalTime() - $latest).TotalSeconds -ge
        $script:DuneMapsObservationHeartbeatSec) {
        return @($CurrentRows)
    }
    return @()
}

function Get-DuneMapsRuntimeSourceHealth {
    param($Snapshot)

    return @(Get-DuneMapsSnapshotItems -Snapshot $Snapshot -Name 'sources' | ForEach-Object {
        $sourceKey = [string](Get-DuneMapPlatformValue $_ 'sourceKey')
        [ordered]@{
            sourceKey = $sourceKey
            schemaFingerprint = [string](Get-DuneMapPlatformValue $_ 'schemaFingerprint')
            lastAttemptAt = Get-DuneMapPlatformValue $_ 'lastAttemptAt'
            lastSuccessAt = Get-DuneMapPlatformValue $_ 'lastSuccessAt'
            expiresAt = Get-DuneMapPlatformValue $_ 'expiresAt'
            lastErrorCode = Get-DuneMapPlatformValue $_ 'lastErrorCode'
            runtime = if (Get-Command Get-DunePlatformSourceTelemetry -ErrorAction SilentlyContinue) {
                Get-DunePlatformSourceTelemetry -SourceKey $sourceKey
            } else {
                $null
            }
            details = if (Get-Command Get-DunePlatformSourceDetails -ErrorAction SilentlyContinue) {
                Get-DunePlatformSourceDetails -SourceKey $sourceKey
            } else {
                $null
            }
        }
    })
}

function New-DuneMapsLayerRecord {
    param(
        [Parameter(Mandatory)][string]$LayerId,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][ValidateSet('fresh','refreshing','stale','unavailable','partial')][string]$FreshnessState,
        [string]$ObservedAt,
        [string]$CachedAt = ([DateTime]::UtcNow.ToString('o')),
        [string]$ExpiresAt,
        [string]$LastErrorCode,
        [int]$RowCount = 0,
        [bool]$Truncated = $false,
        $Payload = @()
    )
    return [ordered]@{
        farmId = $script:DuneMapsFarmId
        mapId = $script:DuneMapsDeepDesertId
        partitionId = $script:DuneMapsCurrentPartitionId
        layerId = $LayerId
        sourceKey = $SourceKey
        observedAt = if ($ObservedAt) { $ObservedAt } else { $null }
        cachedAt = $CachedAt
        expiresAt = if ($ExpiresAt) { $ExpiresAt } else { $null }
        freshnessState = $FreshnessState
        lastErrorCode = if ($LastErrorCode) { $LastErrorCode } else { $null }
        rowCount = $RowCount
        truncated = $Truncated
        payloadSha256 = Get-DuneMapsPayloadSha256 $Payload
    }
}

function ConvertTo-DuneMapsActiveSpiceCacheRows {
    param([Parameter(Mandatory)]$Result)
    $observedAt = [datetime]$Result.freshness.observedAt
    $expiresAt = $observedAt.AddSeconds($script:DuneMapsActiveSpiceStaleAfterSec).ToString('o')
    return @($Result.fields | Where-Object {
        [string]$_.map -like 'DeepDesert*'
    } | ForEach-Object {
        $coordinateSpace = 'none'
        $x = $null
        $y = $null
        if ($_.position.status -eq 'verified' -and
            [string]$_.position.coordinateSystem -in @('sector-v1','normalized-v1')) {
            $coordinateSpace = [string]$_.position.coordinateSystem
            $x = $_.position.x
            $y = $_.position.y
        }
        [ordered]@{
            farmId = $script:DuneMapsFarmId
            mapId = $script:DuneMapsDeepDesertId
            partitionId = $script:DuneMapsCurrentPartitionId
            fieldId = [string]$_.fieldId
            state = [string]$_.state
            coordinateSpace = $coordinateSpace
            x = $x
            y = $y
            sourceFingerprint = [string]$Result.source.schemaFingerprint
            observedAt = $observedAt.ToString('o')
            expiresAt = $expiresAt
        }
    })
}

function New-DuneMapsPlatformGeneration {
    param(
        [string]$Ip,
        $PreviousSnapshot,
        [string]$SourceErrorCode,
        [datetime]$Now = [DateTime]::UtcNow
    )

    $now = $Now.ToUniversalTime()
    $cachedAt = $now.ToString('o')
    $activeRows = @()
    $historyRows = @()
    $activeLayer = $null
    $capability = $null
    $schemaFingerprint = 'unknown'
    $lastSuccessAt = $null
    $sourceError = $SourceErrorCode
    $schemaError = $null
    $schemaAttempted = $false
    $activeAttempted = $false

    if ($Ip -and -not $sourceError) {
        $schemaAttempted = $true
        try {
            $schemaRead = Invoke-DunePlatformSourceRead `
                -SourceKey $script:DuneMapsSchemaSourceKey `
                -MaxRows 2 `
                -TimeoutSec 30 `
                -Read ({
                    param($limits)
                    $capabilityResult = Get-DuneMapDataCapabilities -Ip $Ip
                    [pscustomobject]@{
                        ok = [bool]$capabilityResult.ok
                        rows = @(
                            $capabilityResult.activeSpice,
                            $capabilityResult.publicStaticPoi
                        )
                        capability = $capabilityResult
                        reasonCode = [string]$capabilityResult.reasonCode
                        error = [string]$capabilityResult.error
                    }
                }.GetNewClosure())
            $capability = $schemaRead.capability
        } catch {
            $schemaError = Get-DunePlatformExceptionCode $_
            if ($schemaError -eq 'source-read-failed') { $schemaError = 'schema-probe-failed' }
            $capability = Get-DuneMapDataCachedCapabilities -Ip $Ip -AllowExpired
            if (-not $capability) {
                $sourceError = $schemaError
            }
        }

        if ($capability) {
            $schemaFingerprint = [string]$capability.schemaFingerprint
            $probe = $capability.source.capabilityProbe
            [void](Set-DuneMapsSourceDetails `
                -SourceKey $script:DuneMapsSchemaSourceKey `
                -Details ([ordered]@{
                    cadenceSeconds = $script:DuneMapsSchemaRefreshCadenceSec
                    cached = [bool]$probe.cached
                    stale = [bool]$probe.stale
                    observedAt = [string]$probe.observedAt
                    expiresAt = [string]$probe.expiresAt
                    lastErrorCode = $schemaError
                }))
            if (-not $probe.stale -and $probe.expiresAt) {
                [void](Set-DuneMapsSourceNextDue `
                    -SourceKey $script:DuneMapsSchemaSourceKey `
                    -NextDueAt ([datetime]$probe.expiresAt))
            }

            try {
                $activeAttempted = $true
                $sourceRead = Invoke-DunePlatformSourceRead `
                    -SourceKey $script:DuneMapsActiveSpiceSourceKey `
                    -MaxRows $script:DuneMapsActiveSpiceMaxRows `
                    -TimeoutSec 30 `
                    -Read ({
                        param($limits)
                        $active = Get-DuneActiveSpiceLive `
                            -Ip $Ip `
                            -Limit ([Math]::Min($script:DuneMapsActiveSpiceMaxRows, [int]$limits.maxRows)) `
                            -Capability $capability `
                            -TimeoutSec ([int]$limits.queryTimeoutSec)
                        $schemaChanged = (
                            -not $active.ok -and
                            (Test-DuneMapDataSchemaSignatureError -Message ([string]$active.error))
                        )
                        if ($schemaChanged) {
                            Clear-DuneMapDataCapabilityCache -Ip $Ip
                        }
                        [pscustomobject]@{
                            ok = [bool]$active.ok
                            rows = @($active.fields)
                            active = $active
                            capability = $capability
                            reasonCode = if ($schemaChanged) { 'schema-changed' } else { [string]$active.reasonCode }
                            error = [string]$active.error
                        }
                    }.GetNewClosure())
                $activeResult = $sourceRead.active
                $activeRows = @(ConvertTo-DuneMapsActiveSpiceCacheRows -Result $activeResult)
                $historyRows = @(Get-DuneMapsActiveSpiceHistoryRows `
                    -CurrentRows $activeRows `
                    -PreviousSnapshot $PreviousSnapshot `
                    -SourceResult $activeResult `
                    -Now $now)
                $schemaFingerprint = [string]$activeResult.source.schemaFingerprint
                $lastSuccessAt = [string]$activeResult.freshness.observedAt
                $mapDimensions = [Collections.Generic.List[object]]::new()
                $seenMapDimensions = @{}
                foreach ($field in @($activeResult.fields)) {
                    $sourceMap = [string]$field.map
                    $dimensionIndex = [int]$field.dimensionIndex
                    if ($sourceMap -notmatch '^[A-Za-z0-9_.-]{1,128}$') { continue }
                    $identity = "$sourceMap|$dimensionIndex"
                    if ($seenMapDimensions.ContainsKey($identity)) { continue }
                    $seenMapDimensions[$identity] = $true
                    if ($mapDimensions.Count -lt $script:DuneMapsSourceMapDimensionMax) {
                        $mapDimensions.Add([ordered]@{
                            map = $sourceMap
                            dimensionIndex = $dimensionIndex
                        })
                    }
                }
                [void](Set-DuneMapsSourceDetails `
                    -SourceKey $script:DuneMapsActiveSpiceSourceKey `
                    -Details ([ordered]@{
                        cadenceSeconds = $script:DuneMapsRefreshCadenceSec
                        identityStatus = 'source-map-dimension'
                        partitionStatus = 'unresolved'
                        mapDimensionCount = $seenMapDimensions.Count
                        mapDimensionsTruncated = (
                            $seenMapDimensions.Count -gt $script:DuneMapsSourceMapDimensionMax)
                        mapDimensions = $mapDimensions.ToArray()
                    }))
                $activeLayer = New-DuneMapsLayerRecord `
                    -LayerId 'active-spice' `
                    -SourceKey $script:DuneMapsActiveSpiceSourceKey `
                    -FreshnessState $(if ($activeResult.status -eq 'partial') { 'partial' } else { 'fresh' }) `
                    -ObservedAt $lastSuccessAt `
                    -CachedAt $cachedAt `
                    -ExpiresAt ([datetime]$lastSuccessAt).AddSeconds($script:DuneMapsActiveSpiceStaleAfterSec).ToString('o') `
                    -RowCount $activeRows.Count `
                    -Truncated ([bool]$activeResult.truncated) `
                    -Payload $activeRows
            } catch {
                $sourceError = Get-DunePlatformExceptionCode $_
                if ($sourceError -eq 'schema-changed') {
                    Reset-DunePlatformRefreshBackoff -SourceKey $script:DuneMapsSchemaSourceKey
                }
            }
        }
    }

    $priorActiveSource = Get-DuneMapsPriorSource `
        -Snapshot $PreviousSnapshot `
        -SourceKey $script:DuneMapsActiveSpiceSourceKey
    if (-not $activeLayer) {
        $priorRows = @(Get-DuneMapsSnapshotItems -Snapshot $PreviousSnapshot -Name 'activeSpice' |
            Where-Object {
                [string](Get-DuneMapPlatformValue $_ 'farmId') -eq $script:DuneMapsFarmId -and
                [string](Get-DuneMapPlatformValue $_ 'mapId') -eq $script:DuneMapsDeepDesertId -and
                [string](Get-DuneMapPlatformValue $_ 'partitionId') -eq $script:DuneMapsCurrentPartitionId
            })
        $priorLayer = Get-DuneMapsPriorLayer -Snapshot $PreviousSnapshot -LayerId 'active-spice'
        $activeRows = $priorRows
        $priorObservedAt = [string](Get-DuneMapPlatformValue $priorLayer 'observedAt')
        $priorExpiresAt = [string](Get-DuneMapPlatformValue $priorLayer 'expiresAt')
        $priorFingerprint = @($priorRows | Select-Object -First 1 | ForEach-Object {
            [string](Get-DuneMapPlatformValue $_ 'sourceFingerprint')
        })[0]
        if (-not $priorFingerprint) {
            $priorFingerprint = [string](Get-DuneMapPlatformValue $priorActiveSource 'schemaFingerprint')
        }
        if ($priorFingerprint) { $schemaFingerprint = $priorFingerprint }
        if ($priorObservedAt) { $lastSuccessAt = $priorObservedAt }
        $hasPriorSuccess = (
            $priorLayer -and
            $priorObservedAt -and
            [string](Get-DuneMapPlatformValue $priorLayer 'freshnessState') -ne 'unavailable'
        )
        $activeLayer = New-DuneMapsLayerRecord `
            -LayerId 'active-spice' `
            -SourceKey $script:DuneMapsActiveSpiceSourceKey `
            -FreshnessState $(if ($hasPriorSuccess) { 'stale' } else { 'unavailable' }) `
            -ObservedAt $priorObservedAt `
            -CachedAt $cachedAt `
            -ExpiresAt $priorExpiresAt `
            -LastErrorCode $(if ($sourceError) { $sourceError } else { 'source-unavailable' }) `
            -RowCount $priorRows.Count `
            -Truncated ([bool](Get-DuneMapPlatformValue $priorLayer 'truncated')) `
            -Payload $priorRows
    }

    $priorMap = @(Get-DuneMapsSnapshotItems -Snapshot $PreviousSnapshot -Name 'maps' |
        Where-Object { [string](Get-DuneMapPlatformValue $_ 'mapId') -eq $script:DuneMapsDeepDesertId } |
        Select-Object -First 1)[0]
    $mapLastSeenAt = if ($lastSuccessAt) {
        $lastSuccessAt
    } elseif ($priorMap) {
        [string](Get-DuneMapPlatformValue $priorMap 'lastSeenAt')
    } else {
        $now.ToString('o')
    }
    $maps = @([ordered]@{
        farmId = $script:DuneMapsFarmId
        mapId = $script:DuneMapsDeepDesertId
        partitionId = $script:DuneMapsCurrentPartitionId
        label = 'Deep Desert'
        kind = 'deep-desert'
        lastSeenAt = $mapLastSeenAt
        active = $true
    })

    $publicPoiLayer = New-DuneMapsLayerRecord `
        -LayerId 'public-poi' `
        -SourceKey $script:DuneMapsPublicPoiSourceKey `
        -FreshnessState 'unavailable' `
        -CachedAt $cachedAt `
        -LastErrorCode 'privacy-proof-unavailable' `
        -Payload @()

    [void](Set-DuneMapsSourceDetails `
        -SourceKey $script:DuneMapsPublicPoiSourceKey `
        -Details ([ordered]@{
            enabled = $false
            reasonCode = 'privacy-proof-unavailable'
        }))
    $priorSchemaSource = Get-DuneMapsPriorSource `
        -Snapshot $PreviousSnapshot `
        -SourceKey $script:DuneMapsSchemaSourceKey
    $priorPublicPoiSource = Get-DuneMapsPriorSource `
        -Snapshot $PreviousSnapshot `
        -SourceKey $script:DuneMapsPublicPoiSourceKey
    $schemaProbe = if ($capability -and $capability.source) {
        $capability.source.capabilityProbe
    } else {
        $null
    }
    $schemaLastSuccessAt = if ($schemaProbe -and $schemaProbe.observedAt) {
        [string]$schemaProbe.observedAt
    } else {
        Get-DuneMapPlatformValue $priorSchemaSource 'lastSuccessAt'
    }
    $schemaExpiresAt = if ($schemaProbe -and $schemaProbe.expiresAt) {
        [string]$schemaProbe.expiresAt
    } else {
        Get-DuneMapPlatformValue $priorSchemaSource 'expiresAt'
    }
    $schemaRecordFingerprint = if ($schemaFingerprint -and $schemaFingerprint -ne 'unknown') {
        $schemaFingerprint
    } else {
        [string](Get-DuneMapPlatformValue $priorSchemaSource 'schemaFingerprint')
    }
    if (-not $schemaRecordFingerprint) { $schemaRecordFingerprint = 'unknown' }

    return [ordered]@{
        generation = "maps-$($now.ToString('yyyyMMddHHmmssfff'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        sources = @(
            [ordered]@{
                sourceKey = $script:DuneMapsSchemaSourceKey
                schemaFingerprint = $schemaRecordFingerprint
                lastAttemptAt = if ($schemaAttempted) { $cachedAt } else {
                    Get-DuneMapPlatformValue $priorSchemaSource 'lastAttemptAt'
                }
                lastSuccessAt = $schemaLastSuccessAt
                expiresAt = $schemaExpiresAt
                lastErrorCode = if ($schemaError) {
                    $schemaError
                } elseif ($capability -and $capability.ok) {
                    $null
                } else {
                    Get-DuneMapPlatformValue $priorSchemaSource 'lastErrorCode'
                }
            },
            [ordered]@{
                sourceKey = $script:DuneMapsActiveSpiceSourceKey
                schemaFingerprint = $schemaFingerprint
                lastAttemptAt = if ($activeAttempted) { $cachedAt } else {
                    Get-DuneMapPlatformValue $priorActiveSource 'lastAttemptAt'
                }
                lastSuccessAt = if ($lastSuccessAt) { $lastSuccessAt } else {
                    Get-DuneMapPlatformValue $priorActiveSource 'lastSuccessAt'
                }
                expiresAt = Get-DuneMapPlatformValue $activeLayer 'expiresAt'
                lastErrorCode = Get-DuneMapPlatformValue $activeLayer 'lastErrorCode'
            },
            [ordered]@{
                sourceKey = $script:DuneMapsPublicPoiSourceKey
                schemaFingerprint = $schemaFingerprint
                lastAttemptAt = Get-DuneMapPlatformValue $priorPublicPoiSource 'lastAttemptAt'
                lastSuccessAt = Get-DuneMapPlatformValue $priorPublicPoiSource 'lastSuccessAt'
                expiresAt = Get-DuneMapPlatformValue $priorPublicPoiSource 'expiresAt'
                lastErrorCode = 'privacy-proof-unavailable'
            }
        )
        maps = $maps
        layers = @($activeLayer, $publicPoiLayer)
        activeSpiceCurrent = $activeRows
        activeSpiceHistory = $historyRows
        publicPois = @()
    }
}

function Invoke-DuneMapsPlatformRefresh {
    param(
        [int]$TimeoutSec = 30,
        [ValidateSet('windows','linux','macos','unknown')]
        [string]$RuntimePlatform
    )
    if (-not (Test-DunePlatformLiveCacheSupported -RuntimePlatform $RuntimePlatform)) {
        return [pscustomobject]@{
            ok = $false
            status = 'unavailable'
            reasonCode = 'live-cache-unsupported'
        }
    }
    $prior = Get-DunePlatformSnapshot
    $context = if (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue) {
        Get-DuneDbContext
    } else {
        @{ ok = $false; message = 'Database context is unavailable.' }
    }
    $generation = if ($context.ok) {
        New-DuneMapsPlatformGeneration -Ip ([string]$context.ip) -PreviousSnapshot $prior.snapshot
    } else {
        New-DuneMapsPlatformGeneration `
            -PreviousSnapshot $prior.snapshot `
            -SourceErrorCode 'source-unavailable'
    }
    return Invoke-DunePlatformAggregateRefresh `
        -AggregateKey 'maps.current' `
        -TimeoutSec $TimeoutSec `
        -Build { param($policy, $state) $state } `
        -BuildState $generation
}

function Start-DuneMapsPlatformStartupRefresh {
    param(
        [Parameter(Mandatory)][string]$ServerDir,
        [string]$AppDir = $script:AppDir,
        [double]$DelaySec = (Get-DuneMapsRefreshDelaySec),
        [ValidateSet('windows','linux','macos','unknown')]
        [string]$RuntimePlatform
    )
    if (-not (Test-DunePlatformLiveCacheSupported -RuntimePlatform $RuntimePlatform)) { return $false }
    if ($script:DuneMapsStartupRefreshStarted) { return $false }

    $sharedSnapshot = Get-DunePlatformSnapshotState
    $sharedLocks = Get-DunePlatformCoordinationTable
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        if (-not ('DuneServer.MapsRefreshRunner' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

namespace DuneServer
{
    public static class MapsRefreshRunner
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
                throw new InvalidOperationException("Could not queue the Maps refresh worker.");
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
            param($ServerDir, $AppDir, $SnapshotState, $LockTable, $DelaySec, $CancellationToken, $LogPath)
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
                $script:DunePlatformSnapshotState = $SnapshotState
                $script:DuneApiLockTable = $LockTable
                $null = Invoke-DuneMapsPlatformRefreshLoop `
                    -CancellationToken $CancellationToken `
                    -InitialDelaySec $DelaySec
            } catch {
                if (-not $CancellationToken.IsCancellationRequested -and
                    (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
                    Write-DuneLog "Maps platform refresh scheduler stopped: $($_.Exception.Message)" 'WARN'
                }
            }
        }).AddArgument($ServerDir).AddArgument($AppDir).AddArgument($sharedSnapshot).AddArgument($sharedLocks).AddArgument($DelaySec).AddArgument($cancellation.Token).AddArgument($script:DuneLogPath)
        $completion = [DuneServer.MapsRefreshRunner]::Queue($powershell, $runspace)
        $script:DuneMapsRefreshCancellation = $cancellation
        $script:DuneMapsRefreshPowerShell = $powershell
        $script:DuneMapsRefreshCompletion = $completion
        $script:DuneMapsStartupRefreshStarted = $true
        return $true
    } catch {
        try { $cancellation.Cancel() } catch {}
        try { $cancellation.Dispose() } catch {}
        if ($powershell) { try { $powershell.Dispose() } catch {} }
        if ($runspace) { try { $runspace.Dispose() } catch {} }
        throw
    }
}

function Stop-DuneMapsPlatformRefresh {
    param([ValidateRange(1,30000)][int]$WaitMs = 5000)

    $cancellation = $script:DuneMapsRefreshCancellation
    if (-not $cancellation) { return $false }
    try { $cancellation.Cancel() } catch {}
    $completion = $script:DuneMapsRefreshCompletion
    $powershell = $script:DuneMapsRefreshPowerShell
    if ($completion -and -not $completion.Wait([Math]::Min(1000, $WaitMs))) {
        try { $null = $powershell.BeginStop($null, $null) } catch {}
        if (-not $completion.Wait($WaitMs)) {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog 'Maps platform refresh did not stop within the shutdown timeout.' 'WARN'
            }
            return $false
        }
    }
    $script:DuneMapsRefreshCancellation = $null
    $script:DuneMapsRefreshPowerShell = $null
    $script:DuneMapsRefreshCompletion = $null
    $script:DuneMapsStartupRefreshStarted = $false
    try { if ($completion) { $completion.Dispose() } } catch {}
    try { $cancellation.Dispose() } catch {}
    return $true
}

function New-DuneMapsCacheFreshness {
    param($Layer)
    if (-not $Layer) {
        return New-DuneApiFreshness -State 'unavailable' -LastErrorCode 'snapshot-missing'
    }
    $observedAt = [string](Get-DuneMapPlatformValue $Layer 'observedAt')
    $cachedAt = [string](Get-DuneMapPlatformValue $Layer 'cachedAt')
    $age = $null
    if ($observedAt) {
        $age = [Math]::Max(0, [int][Math]::Floor(([DateTime]::UtcNow - ([datetime]$observedAt).ToUniversalTime()).TotalSeconds))
    }
    $freshnessState = [string](Get-DuneMapPlatformValue $Layer 'freshnessState')
    $expiresAt = [string](Get-DuneMapPlatformValue $Layer 'expiresAt')
    if ($expiresAt -and $freshnessState -in @('fresh','partial') -and
        ([datetime]$expiresAt).ToUniversalTime() -le [DateTime]::UtcNow) {
        $freshnessState = 'stale'
    }
    return New-DuneApiFreshness `
        -State $freshnessState `
        -ObservedAt $observedAt `
        -CachedAt $cachedAt `
        -AgeSeconds $age `
        -LastErrorCode ([string](Get-DuneMapPlatformValue $Layer 'lastErrorCode'))
}

function Get-DuneMapsCacheHealth {
    param($State)
    $snapshot = $State.snapshot
    return [ordered]@{
        cache = [ordered]@{
            available = [bool]$State.available
            revision = [long]$State.revision
            generation = [string](Get-DuneMapPlatformValue $snapshot 'generation')
            hydratedAt = [string](Get-DuneMapPlatformValue $snapshot 'hydratedAt')
            publishedAt = [string]$State.updatedAt
            lastErrorCode = if ($State.lastErrorCode) { [string]$State.lastErrorCode } else { $null }
        }
        sources = @(Get-DuneMapsSnapshotItems -Snapshot $snapshot -Name 'sources')
    }
}

function Get-DuneMapsUnsupportedCacheHealth {
    return [ordered]@{
        cache = [ordered]@{
            available = $false
            revision = 0L
            generation = ''
            hydratedAt = $null
            publishedAt = $null
            lastErrorCode = 'live-cache-unsupported'
        }
        sources = @()
    }
}

function New-DuneMapsUnsupportedLayerEnvelope {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('active-spice','public-poi')]
        [string]$LayerId
    )

    $data = if ($LayerId -eq 'active-spice') {
        [ordered]@{
            summary = [ordered]@{
                activeCount = 0
                state = 'none-active'
                tier = $null
                spatialStatus = 'unresolved'
                historyStatus = 'unavailable'
            }
            items = @()
            history = @()
        }
    } else {
        @()
    }
    return New-DuneApiLayerEnvelope `
        -LayerId $LayerId `
        -Source 'unavailable' `
        -Freshness (New-DuneApiFreshness `
            -State 'unavailable' `
            -LastErrorCode 'live-cache-unsupported') `
        -Count 0 `
        -Page (New-DuneApiPage -Limit 0) `
        -Error ([ordered]@{
            code = 'live-cache-unsupported'
            message = 'Cached live Maps is unavailable on this host platform.'
        }) `
        -Data $data
}

function New-DuneMapsActiveSpiceLayerEnvelope {
    param($State)
    $snapshot = $State.snapshot
    $layer = Get-DuneMapsPriorLayer -Snapshot $snapshot -LayerId 'active-spice'
    $items = @(Get-DuneMapsSnapshotItems -Snapshot $snapshot -Name 'activeSpice' |
        Where-Object {
            [string](Get-DuneMapPlatformValue $_ 'farmId') -eq $script:DuneMapsFarmId -and
            [string](Get-DuneMapPlatformValue $_ 'mapId') -eq $script:DuneMapsDeepDesertId -and
            [string](Get-DuneMapPlatformValue $_ 'partitionId') -eq $script:DuneMapsCurrentPartitionId
        } | ForEach-Object {
        $space = [string](Get-DuneMapPlatformValue $_ 'coordinateSpace')
        [ordered]@{
            fieldId = [string](Get-DuneMapPlatformValue $_ 'fieldId')
            state = [string](Get-DuneMapPlatformValue $_ 'state')
            tier = $null
            observedAt = [string](Get-DuneMapPlatformValue $_ 'observedAt')
            position = [ordered]@{
                status = if ($space -eq 'none') { 'unresolved' } else { 'verified' }
                coordinateSystem = if ($space -eq 'none') { $null } else { $space }
                x = Get-DuneMapPlatformValue $_ 'x'
                y = Get-DuneMapPlatformValue $_ 'y'
                reason = if ($space -eq 'none') {
                    'No independently verified spatial coordinates are available; no live marker is drawn.'
                } else {
                    $null
                }
            }
        }
    })
    $allHistory = @(Get-DuneMapsSnapshotItems -Snapshot $snapshot -Name 'activeSpiceHistory' |
        Where-Object {
            [string](Get-DuneMapPlatformValue $_ 'farmId') -eq $script:DuneMapsFarmId -and
            [string](Get-DuneMapPlatformValue $_ 'mapId') -eq $script:DuneMapsDeepDesertId -and
            [string](Get-DuneMapPlatformValue $_ 'partitionId') -eq $script:DuneMapsCurrentPartitionId
        })
    $historyTruncated = $allHistory.Count -gt $script:DuneMapsHistoryDeliveryMaxRows
    $history = @($allHistory | Select-Object -First $script:DuneMapsHistoryDeliveryMaxRows | ForEach-Object {
        [ordered]@{
            fieldId = [string](Get-DuneMapPlatformValue $_ 'fieldId')
            state = [string](Get-DuneMapPlatformValue $_ 'state')
            observedAt = [string](Get-DuneMapPlatformValue $_ 'observedAt')
        }
    })
    $freshness = New-DuneMapsCacheFreshness -Layer $layer
    $freshnessState = [string]$freshness.state
    $source = if (-not $State.available -or $freshnessState -eq 'unavailable') { 'unavailable' } else { 'cache' }
    return New-DuneApiLayerEnvelope `
        -LayerId 'active-spice' `
        -Source $source `
        -Freshness $freshness `
        -Count $items.Count `
        -Page (New-DuneApiPage -Limit $script:DuneMapsActiveSpiceMaxRows -Truncated ([bool](Get-DuneMapPlatformValue $layer 'truncated'))) `
        -Error $(if ($freshness.lastErrorCode) { [ordered]@{ code = $freshness.lastErrorCode } } else { $null }) `
        -Data ([ordered]@{
            summary = [ordered]@{
                activeCount = @($items | Where-Object state -eq 'active').Count
                state = if ($items.Count -gt 0) { 'active' } else { 'none-active' }
                tier = $null
                spatialStatus = if (@($items | Where-Object { $_.position.status -eq 'verified' }).Count -gt 0) {
                    'verified'
                } else {
                    'unresolved'
                }
                historyStatus = if ($history.Count -gt 0) { 'cached-observations' } else { 'unavailable' }
                historySemantics = 'sampled-observations'
                historyCount = $history.Count
                historyLimit = $script:DuneMapsHistoryDeliveryMaxRows
                historyTruncated = $historyTruncated
            }
            items = $items
            history = $history
        })
}

function New-DuneMapsPublicPoiLayerEnvelope {
    param($State)
    $layer = Get-DuneMapsPriorLayer -Snapshot $State.snapshot -LayerId 'public-poi'
    return New-DuneApiLayerEnvelope `
        -LayerId 'public-poi' `
        -Source 'unavailable' `
        -Freshness (New-DuneMapsCacheFreshness -Layer $layer) `
        -Count 0 `
        -Error ([ordered]@{
            code = 'privacy-proof-unavailable'
            message = 'The production schema cannot prove that private or owned markers are excluded.'
        }) `
        -Data @()
}

function Get-DuneMapsCatalogResponse {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [ValidateSet('windows','linux','macos','unknown')]
        [string]$RuntimePlatform
    )
    if (-not (Test-DunePlatformLiveCacheSupported -RuntimePlatform $RuntimePlatform)) {
        return New-DuneApiV1Envelope `
            -RequestId $RequestId `
            -Source 'unavailable' `
            -Freshness (New-DuneApiFreshness `
                -State 'unavailable' `
                -LastErrorCode 'live-cache-unsupported') `
            -Capabilities @() `
            -Data ([ordered]@{
                maps = @()
                health = Get-DuneMapsUnsupportedCacheHealth
            }) `
            -Page (New-DuneApiPage -Limit 500)
    }
    $state = Get-DunePlatformSnapshot
    $maps = @(Get-DuneMapsSnapshotItems -Snapshot $state.snapshot -Name 'maps')
    $activeLayer = New-DuneMapsActiveSpiceLayerEnvelope -State $state
    return New-DuneApiV1Envelope `
        -RequestId $RequestId `
        -Source $(if ($state.available) { 'cache' } else { 'unavailable' }) `
        -Freshness $activeLayer.freshness `
        -Capabilities @('map.live-cache') `
        -Data ([ordered]@{
            maps = $maps
            health = Get-DuneMapsCacheHealth -State $state
        }) `
        -Page (New-DuneApiPage -Limit 500)
}

function Get-DuneDeepDesertMapResponse {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [ValidateSet('windows','linux','macos','unknown')]
        [string]$RuntimePlatform
    )
    if (-not (Test-DunePlatformLiveCacheSupported -RuntimePlatform $RuntimePlatform)) {
        return New-DuneApiAggregateEnvelope `
            -RequestId $RequestId `
            -Capabilities @() `
            -Layers @(
                (New-DuneMapsUnsupportedLayerEnvelope -LayerId 'active-spice'),
                (New-DuneMapsUnsupportedLayerEnvelope -LayerId 'public-poi')
            ) `
            -Data ([ordered]@{
                map = [ordered]@{
                    farmId = $script:DuneMapsFarmId
                    mapId = $script:DuneMapsDeepDesertId
                    partitionId = $script:DuneMapsCurrentPartitionId
                    identityStatus = 'synthetic-current'
                    label = 'Deep Desert'
                }
                health = Get-DuneMapsUnsupportedCacheHealth
            })
    }
    $state = Get-DunePlatformSnapshot
    $layers = @(
        New-DuneMapsActiveSpiceLayerEnvelope -State $state
        New-DuneMapsPublicPoiLayerEnvelope -State $state
    )
    return New-DuneApiAggregateEnvelope `
        -RequestId $RequestId `
        -Capabilities @('map.live-cache') `
        -Layers $layers `
        -Data ([ordered]@{
            map = [ordered]@{
                farmId = $script:DuneMapsFarmId
                mapId = $script:DuneMapsDeepDesertId
                partitionId = $script:DuneMapsCurrentPartitionId
                identityStatus = 'synthetic-current'
                label = 'Deep Desert'
            }
            health = Get-DuneMapsCacheHealth -State $state
        })
}

function Get-DuneDeepDesertLayerResponse {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('active-spice','public-poi')][string]$LayerId,
        [ValidateSet('windows','linux','macos','unknown')]
        [string]$RuntimePlatform
    )
    if (-not (Test-DunePlatformLiveCacheSupported -RuntimePlatform $RuntimePlatform)) {
        $unsupportedLayer = New-DuneMapsUnsupportedLayerEnvelope -LayerId $LayerId
        return New-DuneApiV1Envelope `
            -RequestId $RequestId `
            -Source 'unavailable' `
            -Freshness $unsupportedLayer.freshness `
            -Capabilities @() `
            -Data $unsupportedLayer `
            -Page $unsupportedLayer.page
    }
    $state = Get-DunePlatformSnapshot
    $layer = if ($LayerId -eq 'active-spice') {
        New-DuneMapsActiveSpiceLayerEnvelope -State $state
    } else {
        New-DuneMapsPublicPoiLayerEnvelope -State $state
    }
    return New-DuneApiV1Envelope `
        -RequestId $RequestId `
        -Source ([string]$layer.source) `
        -Freshness $layer.freshness `
        -Capabilities @('map.live-cache') `
        -Data $layer `
        -Page $layer.page
}
