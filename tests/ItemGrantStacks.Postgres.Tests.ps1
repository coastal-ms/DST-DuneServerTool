BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . "$PSScriptRoot\_PostgresFixture.ps1"
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    function Invoke-StackFixture([string]$Sql) {
        $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.sql')
        [IO.File]::WriteAllText($path,$Sql)
        Invoke-TestPostgresFile -SqlPath $path -TuplesOnly
    }
}
Describe 'Self-hosted grants fill stacks before allocating slots' -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
    BeforeEach {
        $script:ownsSchema=$false
        $result=Invoke-StackFixture @'
CREATE SCHEMA dune;
CREATE TABLE dune.inventories(id bigint PRIMARY KEY,actor_id bigint,inventory_type int,max_item_count bigint);
INSERT INTO dune.inventories VALUES(1,10,0,10);
CREATE TABLE dune.items(id bigserial PRIMARY KEY,inventory_id bigint,stack_size bigint,position_index bigint,template_id text,quality_level bigint,acquisition_time bigint,stats jsonb);
'@
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $script:ownsSchema=$result.ExitCode -eq 0
    }
    AfterEach { if($script:ownsSchema){(Invoke-StackFixture 'DROP SCHEMA dune CASCADE;').ExitCode | Should -Be 0} }
    It 'handles <Case> atomically with exact quantities and bounded stack sizes' -ForEach @(
        @{Case='partial stack and overflow';Seed="INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,450,0,'WeldingMaterial',0,'{}');";Quantity=100;Limit=500;Quality=0;Expected='2|550|500'}
        @{Case='several partial stacks';Seed="INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,100,0,'WeldingMaterial',0,'{}'),(1,200,1,'WeldingMaterial',0,'{}');";Quantity=500;Limit=500;Quality=0;Expected='2|800|500'}
        @{Case='empty inventory';Seed='';Quantity=1001;Limit=500;Quality=0;Expected='3|1001|500'}
        @{Case='quality isolation';Seed="INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,450,0,'WeldingMaterial',1,'{}');";Quantity=100;Limit=500;Quality=0;Expected='2|550|450'}
        @{Case='non-stackable items';Seed="INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,1,0,'WeldingMaterial',0,'{}');";Quantity=3;Limit=1;Quality=0;Expected='4|4|1'}
        @{Case='full inventory with stack room';Seed="UPDATE dune.inventories SET max_item_count=1; INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,450,0,'WeldingMaterial',0,'{}');";Quantity=50;Limit=500;Quality=0;Expected='1|500|500'}
        @{Case='overflow without free slot';Seed="UPDATE dune.inventories SET max_item_count=1; INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,450,0,'WeldingMaterial',0,'{}');";Quantity=51;Limit=500;Quality=0;Expected='1|450|450'}
        @{Case='augmented stack isolation';Seed="INSERT INTO dune.items(inventory_id,stack_size,position_index,template_id,quality_level,stats) VALUES(1,450,0,'WeldingMaterial',0,jsonb_build_object('FAugmentedItemStats',jsonb_build_array()));";Quantity=50;Limit=500;Quality=0;Expected='2|500|450'}
    ) {
        if($Seed){$seedResult=Invoke-StackFixture $Seed;$seedResult.ExitCode | Should -Be 0 -Because $seedResult.Error}
        $sql=Get-DuneStackedItemGrantSql -InventoryQuery 'SELECT id,max_item_count AS maxc FROM dune.inventories WHERE id=1 FOR UPDATE' -Template WeldingMaterial -Qty $Quantity -Quality $Quality -StatsJson '{}' -StackMax $Limit
        $result=Invoke-StackFixture $sql
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $summary=Invoke-StackFixture 'SELECT COUNT(*),SUM(stack_size),MAX(stack_size) FROM dune.items;'
        $summary.Output.Trim() | Should -Be $Expected
    }
}
