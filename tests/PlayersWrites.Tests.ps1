# Tests pure-function helpers in PlayersWrites.ps1 and GameplayPlayers.ps1.
# No DB / network — all in-memory.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'PlayersWrites.ps1'
}

Describe 'ConvertTo-DuneSqlString' -Tag 'Pure' {
    It 'returns empty string for $null' {
        ConvertTo-DuneSqlString $null | Should -Be ''
    }
    It 'leaves plain strings untouched' {
        ConvertTo-DuneSqlString 'hello' | Should -Be 'hello'
    }
    It "doubles a single quote (Postgres escape)" {
        ConvertTo-DuneSqlString "O'Brien" | Should -Be "O''Brien"
    }
    It 'doubles every single quote in a longer string' {
        ConvertTo-DuneSqlString "a'b'c" | Should -Be "a''b''c"
    }
    It 'leaves double quotes alone' {
        ConvertTo-DuneSqlString 'say "hi"' | Should -Be 'say "hi"'
    }
    It 'stringifies non-string input' {
        ConvertTo-DuneSqlString 123 | Should -Be '123'
    }
}

Describe 'ConvertTo-DunePgTextArray' -Tag 'Pure' {
    It 'returns an empty text array literal for $null' {
        ConvertTo-DunePgTextArray $null | Should -Be 'ARRAY[]::text[]'
    }
    It 'returns an empty text array literal for @()' {
        ConvertTo-DunePgTextArray @() | Should -Be 'ARRAY[]::text[]'
    }
    It 'wraps a single value with quotes and casts to text[]' {
        ConvertTo-DunePgTextArray @('foo') | Should -Be "ARRAY['foo']::text[]"
    }
    It 'comma-joins multiple values' {
        ConvertTo-DunePgTextArray @('a', 'b', 'c') | Should -Be "ARRAY['a','b','c']::text[]"
    }
    It "SQL-escapes single quotes inside values" {
        ConvertTo-DunePgTextArray @("foo's") | Should -Be "ARRAY['foo''s']::text[]"
    }
    It "does not introduce stray commas" {
        $result = ConvertTo-DunePgTextArray @('one', 'two')
        $result | Should -Not -Match ",,"
        $result | Should -Not -Match "\[,"
        $result | Should -Not -Match ",\]"
    }
}

Describe 'Get-DuneSqlAffected' -Tag 'Pure' {
    It 'returns 0 for $null' {
        Get-DuneSqlAffected $null | Should -Be 0
    }
    It "returns 0 when result.ok is false" {
        Get-DuneSqlAffected @{ ok = $false; message = 'UPDATE 5' } | Should -Be 0
    }
    It 'parses UPDATE <n>' {
        Get-DuneSqlAffected @{ ok = $true; message = 'UPDATE 5' } | Should -Be 5
    }
    It "parses 'INSERT 0 <n>' (two-int form)" {
        Get-DuneSqlAffected @{ ok = $true; message = 'INSERT 0 7' } | Should -Be 7
    }
    It 'parses DELETE <n>' {
        Get-DuneSqlAffected @{ ok = $true; message = 'DELETE 12' } | Should -Be 12
    }
    It 'returns 0 for unparseable tags (e.g. plain SELECT result)' {
        Get-DuneSqlAffected @{ ok = $true; message = 'SELECT' } | Should -Be 0
    }
    It 'returns 0 for empty message' {
        Get-DuneSqlAffected @{ ok = $true; message = '' } | Should -Be 0
    }
}

Describe 'Resolve-DuneRepairDurabilityTarget' -Tag 'Pure' {
    It 'keeps no-current empty durability blocks untouched' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 0 -ItemDecayedMax 0 -HasCurrent $false | Should -Be 0
    }
    It 'repairs current-only zero or low durability items to 100' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 0 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 100
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 50 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 100
    }
    It 'rounds current-only values between 100 and 200 up to 200' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 150 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 200
    }
    It 'preserves known higher catalog or item caps' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 400 -ItemMax 0 -ItemCurrent 50 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 400
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 250 -ItemCurrent 50 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 250
    }
}

Describe 'Invoke-DunePlayerUpdateTags' -Tag 'TagsDelta' {
    BeforeEach {
        $script:capturedSql = $null
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSql = $Sql
            return @{ ok = $true; message = 'SELECT 1' }
        }
    }

    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'rejects a zero account id' {
        $r = Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 0 -Add @('vip') -Remove @()
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'account_id'
    }
    It 'rejects when both add and remove are empty' {
        $r = Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 42 -Add @() -Remove @()
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'add\[\] or remove\[\]'
    }
    It 'calls dune.update_player_tags with the account id and both text[] args' {
        $r = Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 99 -Add @('vip', 'tester') -Remove @('banned')
        $r.ok | Should -BeTrue
        $script:capturedSql | Should -Match 'dune\.update_player_tags\(\s*99::bigint'
        $script:capturedSql | Should -Match "ARRAY\['vip','tester'\]::text\[\]"
        $script:capturedSql | Should -Match "ARRAY\['banned'\]::text\[\]"
    }
    It 'passes an empty text[] for the missing side when only one side is supplied' {
        Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 7 -Add @('vip') -Remove @() | Out-Null
        $script:capturedSql | Should -Match "ARRAY\['vip'\]::text\[\].*ARRAY\[\]::text\[\]"
    }
    It 'SQL-escapes single quotes in tag values' {
        Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 7 -Add @("foo'bar") -Remove @() | Out-Null
        $script:capturedSql | Should -Match "foo''bar"
    }
    It 'skips blank tags after trimming' {
        Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 7 -Add @('  ', 'real') -Remove @() | Out-Null
        $script:capturedSql | Should -Match "ARRAY\['real'\]::text\[\]"
    }
}

Describe 'Invoke-DunePlayerGiveItemsBulk overflow' -Tag 'Pure' {
    BeforeEach {
        $script:liveArgs = $null
        function global:Get-DuneBodyValue {
            param($Body, [string]$Name)
            if ($Body -is [System.Collections.IDictionary] -and $Body.Contains($Name)) { return $Body[$Name] }
            if ($null -ne $Body -and $Body.PSObject.Properties[$Name]) { return $Body.$Name }
            return $null
        }
        function global:Get-DuneBodyInt {
            param($Body, [string]$Name)
            $v = Get-DuneBodyValue -Body $Body -Name $Name
            if ($null -eq $v -or $v -eq '') { return $null }
            return [int64]$v
        }
        function global:Test-DunePlayerOffline { return @{ ok = $false } }
        function global:Resolve-DuneFlsIdOrError { return @{ ok = $true; fls_id = 'fls-test' } }
        function global:Invoke-DunePlayerGiveItemLive {
            param($Ip, $ActorId, $FlsId, $Template, $Quantity, $Durability, $AllowOverflow)
            $script:liveArgs = @{
                Ip = $Ip; ActorId = $ActorId; FlsId = $FlsId; Template = $Template
                Quantity = $Quantity; Durability = $Durability; AllowOverflow = $AllowOverflow
            }
            return @{ ok = $true; path = 'rmq' }
        }
    }
    AfterEach {
        Remove-Item function:global:Get-DuneBodyValue -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DuneBodyInt -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerOffline -ErrorAction SilentlyContinue
        Remove-Item function:global:Resolve-DuneFlsIdOrError -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DunePlayerGiveItemLive -ErrorAction SilentlyContinue
    }

    It 'passes AllowOverflow to live package item gives' {
        $items = @(@{ template = 'Ammo'; qty = 500; quality = 0 })

        $r = Invoke-DunePlayerGiveItemsBulk -Ip '1.2.3.4' -PawnId 24 -Items $items -AllowOverflow $true

        $r.ok | Should -BeTrue
        $script:liveArgs.AllowOverflow | Should -BeTrue
        $script:liveArgs.Template | Should -Be 'Ammo'
        $script:liveArgs.Quantity | Should -Be 500
    }
}

Describe 'Get-DuneAqlTrialCatalog' -Tag 'Pure' {
    It 'includes Trial 4 keyed as "4"' {
        $cat = Get-DuneAqlTrialCatalog
        ($cat | Where-Object { $_.id -eq '4' }) | Should -Not -BeNullOrEmpty
    }
    It 'maps Trial 4 to the FourthTest journey node' {
        $t4 = Get-DuneAqlTrialCatalog | Where-Object { $_.id -eq '4' }
        $t4.node | Should -Be 'DA_MQ_FindTheFremen.FourthTest'
    }
    It 'awards the Cryss Knife recipe for Trial 4 (the ability-slot trigger)' {
        $t4 = Get-DuneAqlTrialCatalog | Where-Object { $_.id -eq '4' }
        $t4.recipe | Should -Be 'RCP_Crysknife_Recipe'
    }
    It 'includes the JourneySets.Fremkit.CryssKnife tag in the Trial 4 delta' {
        $t4 = Get-DuneAqlTrialCatalog | Where-Object { $_.id -eq '4' }
        $t4.tags | Should -Contain 'JourneySets.Fremkit.CryssKnife'
    }
}
