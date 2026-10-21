BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'GameplayWorld.ps1'
    $script:realStorageRowMaps = (Get-Command ConvertTo-DuneRowMaps).ScriptBlock
    function global:Invoke-DuneSqlQuery { }
    function global:ConvertTo-DuneRowMaps { param($Result); ,@($Result.rows) }
}
AfterAll {
    Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    Remove-Item Function:\global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
}
Describe 'Selected storage box repair' {
    BeforeEach {
        $script:repairSql=''
        $script:repairLookup=''
        $script:repairBulk=$false
        $script:repairRows=@(@{id='11';template_id='Equipment';m='200';c='20';d='150';has_c='true';original_stats='{"FItemStackAndDurabilityStats":[0,{"MaxDurability":200,"CurrentDurability":20,"DecayedMaxDurability":150}],"Other":"keep"}'})
        Mock Get-DuneItemCatalogMaxDurability { 100 }
        Mock Invoke-DuneSqlQuery {
            param($Sql,$ReadOnly,[switch]$Bulk)
            if($ReadOnly){$script:repairLookup=$Sql;return @{ok=$true;rows=$script:repairRows}}
            $script:repairSql=$Sql;$script:repairBulk=[bool]$Bulk;return @{ok=$true}
        }
    }
    It 'uses existing durability rules and guards both lookup and update to the selected real box' {
        $result=Invoke-DuneStorageRepairAll -Ip 'test' -ContainerId 123
        $result.ok | Should -BeTrue
        $result.repaired | Should -Be 1
        $result.message | Should -Match 'DD Atlas > Lifecycle'
        $result.message | Should -Match 'Restart Hagga or Restart Deep Desert'
        $result.message | Should -Match 'Players on that map will be disconnected'
        $script:repairLookup | Should -Match 'p.id = 123::bigint'
        $script:repairLookup | Should -Match 'inv.inventory_type = 4'
        $script:repairLookup | Should -Match 'is_hologram = false'
        $script:repairSql | Should -Match '\(11::bigint,200::float8'
        $script:repairSql | Should -Match 'inv.actor_id IN'
        $script:repairSql | Should -Match 'i.stats = v.original_stats'
        $script:repairSql | Should -Match 'GET DIAGNOSTICS repaired = ROW_COUNT'
        $script:repairSql | Should -Match 'RAISE EXCEPTION'
        $script:repairSql | Should -Match 'DO \$repair\$'
        $script:repairBulk | Should -BeTrue
    }
    It 'repairs real CSV rows with current-only belt durability and the actual conversion helper' {
        Mock ConvertTo-DuneRowMaps {param($Result); & $script:realStorageRowMaps $Result}
        Mock Invoke-DuneSqlQuery {
            param($Sql,$ReadOnly)
            if($ReadOnly){return @{ok=$true;columns=@('id','template_id','m','c','d','has_c','original_stats');rows=@(,@('67043488','FullStabilizationBelt','0','28.669025','56.992908','t','{"FItemStackAndDurabilityStats":[[],{"CurrentDurability":28.669025,"DecayedMaxDurability":56.992908}]}'))}}
            $script:repairSql=$Sql;return @{ok=$true}
        }
        $result=Invoke-DuneStorageRepairAll -Ip test -ContainerId 6516
        $result.ok | Should -BeTrue
        $result.repaired | Should -Be 1
        $script:repairSql | Should -Match '67043488::bigint,100::float8'
    }
    It 'rejects missing or non-storage actors without writing' {
        $script:repairRows=@()
        (Invoke-DuneStorageRepairAll -Ip test -ContainerId 123).ok | Should -BeFalse
        $script:repairSql | Should -Be ''
    }
    It 'leaves empty boxes and non-equipment contents unchanged' {
        $script:repairRows=@(@{id=$null})
        $result=Invoke-DuneStorageRepairAll -Ip test -ContainerId 123
        $result.ok | Should -BeTrue
        $result.repaired | Should -Be 0
        $script:repairSql | Should -Be ''
    }
    It 'rejects invalid IDs before querying' {
        (Invoke-DuneStorageRepairAll -Ip test -ContainerId 0).ok | Should -BeFalse
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }
    It 'preserves unknown equipment without usable durability' {
        Mock Get-DuneItemCatalogMaxDurability {0}
        $script:repairRows[0].m='0';$script:repairRows[0].c='0';$script:repairRows[0].d='0';$script:repairRows[0].has_c='false'
        (Invoke-DuneStorageRepairAll -Ip test -ContainerId 123).repaired | Should -Be 0
        $script:repairSql | Should -Be ''
    }
    It 'reports database errors instead of claiming repair succeeded' {
        Mock Invoke-DuneSqlQuery {param($ReadOnly);if($ReadOnly){return @{ok=$true;rows=$script:repairRows}};return @{ok=$false;error='Container contents changed'}}
        $result=Invoke-DuneStorageRepairAll -Ip test -ContainerId 123
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'Container contents changed'
    }
    It 'refuses a truncated lookup instead of partially repairing the box' {
        Mock Invoke-DuneSqlQuery {return @{ok=$true;rows=$script:repairRows;truncated=$true}}
        (Invoke-DuneStorageRepairAll -Ip test -ContainerId 123).ok | Should -BeFalse
        $script:repairSql | Should -Be ''
    }
}

Describe 'Storage repair route' {
    It 'enriches cached item occurrences with the current catalog base maximum' {
        $maximum = & {
            . (Join-Path (Get-DstRepoRoot) 'app/server/lib/InventoryCache.ps1')
            function Invoke-DuneInventoryCacheOccurrenceQuery {
                @{available=$true;generation='fixture';data=@{items=@(@{templateId='FullStabilizationBelt';metadata=@{}});players=@();locations=@();selectedPlayerValid=$true;selectedLocationValid=$true}}
            }
            function ConvertTo-DuneInventoryCacheFreshness { @{} }
            function Get-DuneGameplayItemRule { @{max_durability=100} }
            $result=Invoke-DuneInventoryOccurrenceCachePage -TemplateId 'FullStabilizationBelt'
            $result.items[0].metadata.baseMaxDurability
        }
        $maximum | Should -Be 100
    }
    It 'uses the live write wrapper and forwards only the selected container' {
        $result=& {
            function Register-DuneRoute {param($Method,$Path,$Handler);[pscustomobject]@{path=$Path;handler=$Handler}}
            function Get-DuneBodyInt {param($Body,$Name);$Body[$Name]}
            function Invoke-DunePlayerWriteRoute {param($Response,$Action); & $Action 'test-ip'}
            function Invoke-DuneStorageRepairAll {param($Ip,$ContainerId);@{ip=$Ip;id=$ContainerId}}
            function Write-DuneError {param($Response,$Status,$Message);throw $Message}
            $route=@(. (Join-Path (Get-DstRepoRoot) 'app/server/routes/GameplayWorld.ps1'))|Where-Object path -eq '/api/gameplay/storage/repair-all'
            & $route.handler $null $null $null @{container_id=123}
        }
        $result.id | Should -Be 123
        $result.ip | Should -Be 'test-ip'
    }
    It 'rejects invalid container IDs before entering the write wrapper' {
        $result=& {
            function Register-DuneRoute {param($Method,$Path,$Handler);[pscustomobject]@{path=$Path;handler=$Handler}}
            function Get-DuneBodyInt {$null}
            function Invoke-DunePlayerWriteRoute {throw 'Write wrapper must not run'}
            function Write-DuneError {param($Response,$Status,$Message);@{status=$Status}}
            $route=@(. (Join-Path (Get-DstRepoRoot) 'app/server/routes/GameplayWorld.ps1'))|Where-Object path -eq '/api/gameplay/storage/repair-all'
            & $route.handler $null $null $null @{}
        }
        $result.status | Should -Be 400
    }
}
