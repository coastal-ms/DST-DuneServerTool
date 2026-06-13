# ConvertTo-DuneInt sits in Gameplay.ps1 and is the canonical "make me an
# integer" helper used everywhere we touch JSON-decoded SQL output. It must
# tolerate the messy shapes ConvertFrom-Json produces under PS 5.1 — in
# particular single-element Object[] wrappers, which used to make callers
# blow up with "Cannot convert ... System.Object[] to System.Int32" when
# they did a naive [int] cast on the result. See: Coriolis seeds runtime
# error on install v11.5.8/v11.5.9.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
}

Describe 'ConvertTo-DuneInt' -Tag 'Helpers' {
    It 'returns 0 for $null' {
        ConvertTo-DuneInt $null | Should -Be 0
    }

    It 'parses a numeric string' {
        ConvertTo-DuneInt '12345' | Should -Be 12345
    }

    It 'parses an integer literal' {
        ConvertTo-DuneInt 67890 | Should -Be 67890
    }

    It 'parses a negative integer' {
        ConvertTo-DuneInt '-7' | Should -Be -7
    }

    It 'returns 0 for an unparseable string' {
        ConvertTo-DuneInt 'not-a-number' | Should -Be 0
    }

    It 'returns 0 for empty string' {
        ConvertTo-DuneInt '' | Should -Be 0
    }

    It 'unwraps a single-element Object[] (regression: Coriolis seeds)' {
        $arr = @(42)
        ConvertTo-DuneInt $arr | Should -Be 42
    }

    It 'unwraps an Object[] and uses the first element' {
        $arr = @(7, 8, 9)
        ConvertTo-DuneInt $arr | Should -Be 7
    }

    It 'returns 0 for an empty Object[]' {
        $arr = @()
        ConvertTo-DuneInt $arr | Should -Be 0
    }

    It 'unwraps an ArrayList' {
        $al = [System.Collections.ArrayList]::new()
        [void]$al.Add(99)
        ConvertTo-DuneInt $al | Should -Be 99
    }

    It 'returns an Int64 (so callers can safely use [long] for partition ids)' {
        $bigNumberAsString = '9999999999'   # > Int32.MaxValue
        $result = ConvertTo-DuneInt $bigNumberAsString
        $result | Should -Be 9999999999
        $result.GetType().Name | Should -Be 'Int64'
    }
}
