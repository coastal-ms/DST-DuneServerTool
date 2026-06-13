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
