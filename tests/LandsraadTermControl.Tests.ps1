# Tests the Landsraad term-control admin path: the decree display-name helper
# and the validation guards on Set-DuneLandsraadTermControl. DB layer is
# stubbed; no network.
#
# The guards matter because this writes the live term row that decides which
# House holds the Landsraad and which decree is in force for the rest of the
# term, so a bad id must never reach the UPDATE.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Landsraad.ps1'

    function global:ConvertTo-DuneRowMaps { param($Result) $m = if ($Result -and $Result.maps) { $Result.maps } else { @() }; return ,@($m) }
    function global:ConvertTo-DuneInt     { param($Value) if ($null -eq $Value) { return 0 } return [int64]$Value }

    # Records every statement the lib sends so tests can assert both the shape
    # of the UPDATE and that rejected input never reaches the database.
    $global:DstSql = New-Object 'System.Collections.Generic.List[string]'
    $global:DstDecreeRow = @{ decree_name = 'RepairAndRefiningTimes'; disabled = 'f' }
    $global:DstFactionRow = @{ name = 'Atreides' }

    function global:Invoke-DuneSqlQuery {
        param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
        $global:DstSql.Add([string]$Sql)
        if ($Sql -match 'FROM dune\.landsraad_decrees WHERE id') {
            $rows = if ($null -eq $global:DstDecreeRow) { @() } else { @($global:DstDecreeRow) }
            return @{ ok = $true; maps = $rows; rowCount = $rows.Count }
        }
        if ($Sql -match 'FROM dune\.factions WHERE id') {
            $rows = if ($null -eq $global:DstFactionRow) { @() } else { @($global:DstFactionRow) }
            return @{ ok = $true; maps = $rows; rowCount = $rows.Count }
        }
        return @{ ok = $true; maps = @(); rowCount = 1 }
    }

    $global:DstTermId = 4
    function global:Get-DuneLandsraadCurrentTermId {
        param($Ip)
        return @{ ok = $true; term_id = $global:DstTermId }
    }
}

AfterAll {
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt     -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneSqlQuery   -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-DuneLandsraadCurrentTermId -ErrorAction SilentlyContinue
    Remove-Item variable:global:DstSql        -ErrorAction SilentlyContinue
    Remove-Item variable:global:DstDecreeRow  -ErrorAction SilentlyContinue
    Remove-Item variable:global:DstFactionRow -ErrorAction SilentlyContinue
    Remove-Item variable:global:DstTermId     -ErrorAction SilentlyContinue
}

Describe 'Get-DuneLandsraadDecreeDisplay' -Tag 'Pure' {
    It 'splits a CamelCase decree key into words' {
        Get-DuneLandsraadDecreeDisplay 'RepairAndRefiningTimes' | Should -Be 'Repair And Refining Times'
        Get-DuneLandsraadDecreeDisplay 'CraftingCostReduced'    | Should -Be 'Crafting Cost Reduced'
    }
    It 'renders the underscore vendor variants as a suffix' {
        Get-DuneLandsraadDecreeDisplay 'SpecialVendorActive_Armor' | Should -Be 'Special Vendor Active - Armor'
    }
    It 'returns empty for blank input' {
        Get-DuneLandsraadDecreeDisplay ''   | Should -Be ''
        Get-DuneLandsraadDecreeDisplay $null | Should -Be ''
    }
}

Describe 'Set-DuneLandsraadTermControl validation' -Tag 'Pure' {
    BeforeEach {
        $global:DstSql.Clear()
        $global:DstDecreeRow  = @{ decree_name = 'RepairAndRefiningTimes'; disabled = 'f' }
        $global:DstFactionRow = @{ name = 'Atreides' }
        $global:DstTermId = 4
    }

    It 'refuses when neither a faction nor a decree is supplied' {
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4'
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'Nothing to change'
        $global:DstSql.Count | Should -Be 0
    }

    It 'refuses a faction that cannot hold the Landsraad' {
        foreach ($bad in 3, 4, 99) {
            $global:DstSql.Clear()
            $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -FactionId $bad
            $r.ok | Should -BeFalse
            $r.error | Should -Match 'cannot hold the Landsraad'
            $global:DstSql.Count | Should -Be 0
        }
    }

    It 'refuses when there is no active term' {
        $global:DstTermId = 0
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -FactionId 1
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'No active Landsraad term'
        ($global:DstSql | Where-Object { $_ -match 'UPDATE' }).Count | Should -Be 0
    }

    It 'refuses a decree id the server does not know' {
        $global:DstDecreeRow = $null
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -DecreeId 999
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'No decree with id 999'
        ($global:DstSql | Where-Object { $_ -match 'UPDATE' }).Count | Should -Be 0
    }

    It 'refuses a decree the server has disabled' {
        $global:DstDecreeRow = @{ decree_name = 'SpecialVendorActive'; disabled = 't' }
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -DecreeId 7
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'is disabled by the server'
        ($global:DstSql | Where-Object { $_ -match 'UPDATE' }).Count | Should -Be 0
    }

    It 'scopes the UPDATE to the resolved current term and sets both columns' {
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -FactionId 1 -DecreeId 6
        $r.ok | Should -BeTrue
        $update = $global:DstSql | Where-Object { $_ -match 'UPDATE dune\.landsraad_decree_term' }
        $update | Should -Not -BeNullOrEmpty
        $update | Should -Match 'reigning_faction_id = 1::smallint'
        $update | Should -Match 'active_decree_id = 6::bigint'
        $update | Should -Match 'WHERE term_id = 4::bigint'
    }

    It 'writes only the column that was supplied' {
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -DecreeId 6
        $r.ok | Should -BeTrue
        $update = $global:DstSql | Where-Object { $_ -match 'UPDATE dune\.landsraad_decree_term' }
        $update | Should -Match 'active_decree_id = 6::bigint'
        $update | Should -Not -Match 'reigning_faction_id'
    }

    It 'tells the operator a restart is required' {
        $r = Set-DuneLandsraadTermControl -Ip '1.2.3.4' -FactionId 1 -DecreeId 6
        $r.message | Should -Match 'Restart the battlegroup'
    }

    It 'never writes to landsraad_decrees, which the server rewrites at boot' {
        [void](Set-DuneLandsraadTermControl -Ip '1.2.3.4' -FactionId 1 -DecreeId 6)
        ($global:DstSql | Where-Object { $_ -match 'UPDATE dune\.landsraad_decrees|INSERT INTO dune\.landsraad_decrees' }).Count | Should -Be 0
    }
}
