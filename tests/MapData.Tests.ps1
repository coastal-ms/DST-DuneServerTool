BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    if (-not (Get-Command Invoke-DuneSqlQuery -ErrorAction SilentlyContinue)) {
        function global:Invoke-DuneSqlQuery {
            throw 'MapData test must mock Invoke-DuneSqlQuery.'
        }
    }
    Import-DstLib 'MapData.ps1'

    function global:New-MapDataResult {
        param(
            [string[]]$Columns,
            [object[]]$Rows,
            [int]$DurationMs = 5,
            [bool]$Truncated = $false,
            [string]$Message = ''
        )
        return @{
            ok = $true
            columns = $Columns
            rows = @($Rows)
            rowCount = @($Rows).Count
            truncated = $Truncated
            durationMs = $DurationMs
            message = $Message
        }
    }

    function global:New-MapDataSchemaRows {
        param(
            [switch]$IncludeSpice,
            [switch]$IncludeMarker,
            [switch]$IncludePrivacyProof,
            [string[]]$Omit = @()
        )

        $rows = @()
        if ($IncludeSpice) {
            foreach ($name in @(
                'field_id', 'map', 'dimension_index', 'spawn_time',
                'value_remaining', 'field_kind_id'
            )) {
                if ($Omit -contains "resourcefield_state.$name") { continue }
                $rows += ,@('column', 'resourcefield_state', $name, 'text', 'text', 'NO')
            }
        }
        if ($IncludeMarker) {
            $columns = @('marker_hash_id', 'dimension_index', 'marker', 'payload', 'map_name_id')
            if ($IncludePrivacyProof) { $columns += @('is_private', 'owner_account_id') }
            foreach ($name in $columns) {
                if ($Omit -contains "markers.$name") { continue }
                $rows += ,@('column', 'markers', $name, 'text', 'text', 'NO')
            }
            foreach ($name in @('marker_type', 'x', 'y', 'z', 'payload_type')) {
                if ($Omit -contains "marker.$name") { continue }
                $rows += ,@('attribute', 'marker', $name, 'text', '', '')
            }
        }
        Write-Output -NoEnumerate $rows
    }

    function global:New-MapDataSchemaResult {
        param(
            [switch]$IncludeSpice,
            [switch]$IncludeMarker,
            [switch]$IncludePrivacyProof,
            [string[]]$Omit = @()
        )
        New-MapDataResult `
            -Columns @('item_kind', 'object_name', 'member_name', 'data_type', 'udt_name', 'is_nullable') `
            -Rows (New-MapDataSchemaRows @PSBoundParameters)
    }
}

AfterAll {
    Remove-Item function:global:New-MapDataResult -ErrorAction SilentlyContinue
    Remove-Item function:global:New-MapDataSchemaRows -ErrorAction SilentlyContinue
    Remove-Item function:global:New-MapDataSchemaResult -ErrorAction SilentlyContinue
}

Describe 'Map live-data SQL parameters' -Tag 'MapData' {
    It 'binds values through a typed base64 JSON parameter CTE' {
        $sql = New-DuneMapDataParameterizedSql `
            -Sql 'WITH /*__DST_PARAMETERS__*/ SELECT payload_type FROM _dst_parameters;' `
            -Parameters @{ payload_type = "value'with quote"; row_limit = 25 } `
            -ParameterTypes @{ payload_type = 'text'; row_limit = 'integer' }

        $sql | Should -Not -Match [regex]::Escape("value'with quote")
        $sql | Should -Match '"payload_type" text'
        $sql | Should -Match '"row_limit" integer'
        $parameterMatch = [regex]::Match($sql, "decode\('([^']+)', 'base64'\)")
        $parameterMatch.Success | Should -BeTrue
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parameterMatch.Groups[1].Value))
        $parameters = $json | ConvertFrom-Json
        $parameters.payload_type | Should -Be "value'with quote"
        $parameters.row_limit | Should -Be 25
    }
}

Describe 'Map live-data schema capabilities' -Tag 'MapData' {
    It 'supports spice and the one static-location category when privacy is explicit' {
        Mock Invoke-DuneSqlQuery {
            $fixture = New-MapDataSchemaResult -IncludeSpice -IncludeMarker -IncludePrivacyProof
            $fixture
        }

        $capability = Get-DuneMapDataCapabilities -Ip '192.0.2.1'

        $capability.ok | Should -BeTrue
        $capability.status | Should -Be 'ready'
        $capability.activeSpice.available | Should -BeTrue
        $capability.activeSpice.spatialStatus | Should -Be 'unresolved'
        $capability.publicStaticPoi.available | Should -BeTrue
        $capability.publicStaticPoi.category | Should -Be 'static-location'
        $capability.schemaFingerprint | Should -Match '^[a-f0-9]{64}$'
    }

    It 'reports missing tables as unavailable rather than an empty success' {
        Mock Invoke-DuneSqlQuery {
            New-MapDataSchemaResult
        }

        $capability = Get-DuneMapDataCapabilities -Ip '192.0.2.1'

        $capability.status | Should -Be 'partial'
        $capability.activeSpice.available | Should -BeFalse
        $capability.publicStaticPoi.available | Should -BeFalse
        $capability.activeSpice.missingColumns | Should -Contain 'field_id'
        $capability.publicStaticPoi.missingMembers | Should -Contain 'marker'
    }

    It 'fails a table capability when one required column is missing' {
        Mock Invoke-DuneSqlQuery {
            New-MapDataSchemaResult `
                -IncludeSpice `
                -IncludeMarker `
                -IncludePrivacyProof `
                -Omit @('resourcefield_state.value_remaining', 'marker.payload_type')
        }

        $capability = Get-DuneMapDataCapabilities -Ip '192.0.2.1'

        $capability.activeSpice.available | Should -BeFalse
        $capability.activeSpice.missingColumns | Should -Contain 'value_remaining'
        $capability.publicStaticPoi.available | Should -BeFalse
        $capability.publicStaticPoi.missingMembers | Should -Contain 'marker.payload_type'
    }

    It 'matches production by refusing markers without explicit private and owner columns' {
        Mock Invoke-DuneSqlQuery {
            New-MapDataSchemaResult -IncludeSpice -IncludeMarker
        }

        $result = Get-DunePublicStaticPoiLive -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.status | Should -Be 'unavailable'
        $result.reasonCode | Should -Be 'privacy-proof-unavailable'
        $result.evidence.missingMembers | Should -Contain 'is_private'
        $result.evidence.missingMembers | Should -Contain 'owner_account_id'
        Assert-MockCalled Invoke-DuneSqlQuery -Times 1
    }
}

Describe 'Active spice live projection' -Tag 'MapData' {
    BeforeEach {
        $script:mapDataQuery = 0
        $script:capturedSpiceSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeSpice -IncludeMarker
            }
            $script:capturedSpiceSql = $Sql
            return New-MapDataResult `
                -Columns @(
                    'field_id', 'map', 'dimension_index', 'spawn_time',
                    'value_remaining', 'field_kind_id', 'x', 'y', 'z',
                    'coordinate_system', 'source_count'
                ) `
                -Rows @(
                    ,@('101', 'DeepDesert', '0', '605236.5', '150000', '1', $null, $null, $null, '', '3'),
                    ,@('102', 'DeepDesert', '0', '605237.5', '150000', '1', $null, $null, $null, '', '3'),
                    ,@('103', 'DeepDesert', '0', '605238.5', '5000', '1', $null, $null, $null, '', '3')
                )
        }
    }

    It 'returns active identity and current-observation history primitives' {
        $result = Get-DuneActiveSpiceLive -Ip '192.0.2.1' -Limit 10

        $result.ok | Should -BeTrue
        $result.status | Should -Be 'ready'
        $result.fields.Count | Should -Be 3
        $result.fields[0].fieldId | Should -Be '101'
        $result.fields[0].state | Should -Be 'active'
        $result.observations[0].identity | Should -Be 'resourcefield_state:101'
        $result.historyStatus | Should -Be 'current-observation-only'
        $result.source.schemaFingerprint | Should -Match '^[a-f0-9]{64}$'
        $script:capturedSpiceSql | Should -Match 'WHERE field_kind_id = 1'
        $script:capturedSpiceSql | Should -Match "map LIKE .*map_prefix"
        $result.partialReasons.GetType().FullName | Should -Be 'System.String[]'
        $result.partialReasons.Count | Should -Be 0
        ($result | ConvertTo-Json -Compress -Depth 8) | Should -Match '"partialReasons":\[\]'
    }

    It 'keeps active fields without coordinates explicitly unresolved' {
        $result = Get-DuneActiveSpiceLive -Ip '192.0.2.1' -Limit 10

        $result.fields[0].position.status | Should -Be 'unresolved'
        $result.fields[0].position.x | Should -BeNullOrEmpty
        $result.fields[0].position.y | Should -BeNullOrEmpty
        $result.fields[0].position.z | Should -BeNullOrEmpty
        $result.fields[0].position.reason | Should -Match 'field_id was not decoded'
    }

    It 'returns a partial-ready shape when the strict row limit truncates data' {
        $result = Get-DuneActiveSpiceLive -Ip '192.0.2.1' -Limit 2

        $result.ok | Should -BeTrue
        $result.status | Should -Be 'partial'
        $result.returned | Should -Be 2
        $result.totalAvailable | Should -Be 3
        $result.truncated | Should -BeTrue
        $result.partialReasons | Should -Contain 'row-limit'
        $result.partialReasons.GetType().FullName | Should -Be 'System.String[]'
        ($result | ConvertTo-Json -Compress -Depth 8) | Should -Match '"partialReasons":\["row-limit"\]'
    }

    It 'surfaces a source query failure without an empty success shape' {
        Mock Invoke-DuneSqlQuery {
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeSpice
            }
            return @{ ok = $false; error = 'database unavailable'; durationMs = 711 }
        }

        $result = Get-DuneActiveSpiceLive -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.status | Should -Be 'error'
        $result.error | Should -Be 'database unavailable'
        $result.source.queryDurationMs | Should -Be 711
    }

    It 'rejects a successful transport result carrying a CSV parse error' {
        Mock Invoke-DuneSqlQuery {
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeSpice
            }
            return New-MapDataResult -Columns @() -Rows @() -Message 'Parse error: invalid CSV'
        }

        $result = Get-DuneActiveSpiceLive -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.status | Should -Be 'error'
        $result.reasonCode | Should -Be 'parse-error'
        $result.error | Should -Be 'Parse error: invalid CSV'
    }

    It 'rejects a successful transport result missing expected columns' {
        Mock Invoke-DuneSqlQuery {
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeSpice
            }
            return New-MapDataResult `
                -Columns @('field_id', 'map') `
                -Rows @(,@('101', 'DeepDesert'))
        }

        $result = Get-DuneActiveSpiceLive -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.status | Should -Be 'error'
        $result.reasonCode | Should -Be 'malformed-result'
        $result.error | Should -Match 'source_count'
    }
}

Describe 'Public static POI projection' -Tag 'MapData' {
    It 'proves category, private, owner, and payload exclusions in SQL' {
        $script:mapDataQuery = 0
        $script:capturedPoiSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeSpice -IncludeMarker -IncludePrivacyProof
            }
            $script:capturedPoiSql = $Sql
            return New-MapDataResult `
                -Columns @(
                    'marker_hash_id', 'dimension_index', 'map_name_id',
                    'marker_type', 'x', 'y', 'z', 'display_name',
                    'location_key', 'source_count'
                ) `
                -Rows @(,@('701', '0', '1', 'CHOAMExchange', '5703', '1566', '52413', 'CHOAM', 'poi.choam', '1'))
        }

        $result = Get-DunePublicStaticPoiLive -Ip '192.0.2.1'

        $result.ok | Should -BeTrue
        $result.pois.Count | Should -Be 1
        $result.pois[0].category | Should -Be 'static-location'
        $result.pois[0].position.status | Should -Be 'verified'
        $result.pois[0].PSObject.Properties.Name | Should -Not -Contain 'ownerAccountId'
        $result.pois[0].PSObject.Properties.Name | Should -Not -Contain 'payload'
        $result.partialReasons.GetType().FullName | Should -Be 'System.String[]'
        $result.partialReasons.Count | Should -Be 0
        ($result | ConvertTo-Json -Compress -Depth 8) | Should -Match '"partialReasons":\[\]'
        $script:capturedPoiSql | Should -Match 'is_private IS FALSE'
        $script:capturedPoiSql | Should -Match 'owner_account_id IS NULL'
        $script:capturedPoiSql | Should -Match "payload, '\{\}'::jsonb"
        $script:capturedPoiSql | Should -Not -Match [regex]::Escape('EMarkerPayloadType::StaticLocation')
    }

    It 'keeps partialReasons as an array when the POI limit truncates' {
        $script:mapDataQuery = 0
        Mock Invoke-DuneSqlQuery {
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeMarker -IncludePrivacyProof
            }
            return New-MapDataResult `
                -Columns @(
                    'marker_hash_id', 'dimension_index', 'map_name_id',
                    'marker_type', 'x', 'y', 'z', 'display_name',
                    'location_key', 'source_count'
                ) `
                -Rows @(
                    ,@('701', '0', '1', 'CHOAMExchange', '5703', '1566', '52413', 'CHOAM', 'poi.choam', '2'),
                    ,@('702', '0', '1', 'Bank', '6500', '1793', '52413', 'Bank', 'poi.bank', '2')
                )
        }

        $result = Get-DunePublicStaticPoiLive -Ip '192.0.2.1' -Limit 1

        $result.status | Should -Be 'partial'
        $result.partialReasons.GetType().FullName | Should -Be 'System.String[]'
        $result.partialReasons | Should -Contain 'row-limit'
        ($result | ConvertTo-Json -Compress -Depth 8) | Should -Match '"partialReasons":\["row-limit"\]'
    }

    It 'rejects a successful POI transport result carrying a CSV parse error' {
        $script:mapDataQuery = 0
        Mock Invoke-DuneSqlQuery {
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeMarker -IncludePrivacyProof
            }
            return New-MapDataResult -Columns @() -Rows @() -Message 'Parse error: malformed marker CSV'
        }

        $result = Get-DunePublicStaticPoiLive -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.reasonCode | Should -Be 'parse-error'
    }

    It 'rejects a successful POI transport result missing expected columns' {
        $script:mapDataQuery = 0
        Mock Invoke-DuneSqlQuery {
            $script:mapDataQuery++
            if ($script:mapDataQuery -eq 1) {
                return New-MapDataSchemaResult -IncludeMarker -IncludePrivacyProof
            }
            return New-MapDataResult `
                -Columns @('marker_hash_id', 'marker_type') `
                -Rows @(,@('701', 'CHOAMExchange'))
        }

        $result = Get-DunePublicStaticPoiLive -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.reasonCode | Should -Be 'malformed-result'
        $result.error | Should -Match 'source_count'
    }
}

Describe 'Map live-data freshness' -Tag 'MapData' {
    It 'distinguishes fresh and stale observations at the boundary' {
        $now = [datetime]'2026-08-28T08:00:00Z'

        (New-DuneMapDataFreshness `
            -ObservedAt $now.AddSeconds(-60) `
            -StaleAfterSec 60 `
            -Now $now).state | Should -Be 'fresh'
        (New-DuneMapDataFreshness `
            -ObservedAt $now.AddSeconds(-61) `
            -StaleAfterSec 60 `
            -Now $now).state | Should -Be 'stale'
    }
}
