BeforeAll {
    . (Join-Path $PSScriptRoot '../app/lib/EventMaps.ps1')
    function Get-V6Battlegroup { param($Ip) }
    function Invoke-V6Ssh { param($Ip,$Cmd,$StdinData,$TimeoutSec) }
    function New-EventFixture {
        @'
{"metadata":{"resourceVersion":"123"},"spec":{"serverGroup":{"template":{"spec":{"sets":[{"map":"DLC_Story_LostHarvest_EcolabB","image":"example/game:current","dedicatedScaling":true,"replicas":0,"connectionMode":"AutoDiscovery","arguments":["original-argument"],"messageQueues":[{"mode":"Internal"}],"resources":{"limits":{"memory":"2Gi"}}}]}}},"database":{"template":{"spec":{"deployment":{"spec":{"worldPartitions":[{"map":"Existing","partitions":[{"id":8},{"id":42}]}]}}}}},"utilities":{"director":{"spec":{"configFiles":{"files":{"director.ini":"original"}}}}}}}
'@ | ConvertFrom-Json
    }
}
Describe 'Missing event map repair' {
    BeforeEach {
        $script:bg = New-EventFixture
        $script:oldAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
    }
    AfterEach { $env:APPDATA = $script:oldAppData }
    It 'adds only a new partition and on-demand server with a revision precondition' {
        $before = $script:bg | ConvertTo-Json -Depth 30 -Compress
        $p = New-DuneEventMapRepairPlan $script:bg
        $p.operations.Count | Should -Be 3
        $p.operations[0].path | Should -Be '/metadata/resourceVersion'
        $p.operations[0].value | Should -Be '123'
        $p.operations[1].value.partitions[0].id | Should -Be 43
        $p.operations[2].value.map | Should -Be 'CB_Halloween_Event_Shipwreck_01'
        $p.operations[2].value.replicas | Should -Be 0
        $p.operations[2].value.image | Should -Be 'example/game:current'
        $p.operations[2].value.arguments[0] | Should -Be 'original-argument'
        ($script:bg | ConvertTo-Json -Depth 30 -Compress) | Should -Be $before
        @($p.operations | Where-Object path -Match 'director|MinServers') | Should -HaveCount 0
    }
    It 'preserves existing event definitions exactly' {
        $p = New-DuneEventMapRepairPlan $script:bg
        $script:bg.spec.serverGroup.template.spec.sets += $p.operations[2].value
        $script:bg.spec.database.template.spec.deployment.spec.worldPartitions += $p.operations[1].value
        $script:bg.spec.serverGroup.template.spec.sets[1].replicas = 7
        (New-DuneEventMapRepairPlan $script:bg).changed | Should -BeFalse
        $script:bg.spec.serverGroup.template.spec.sets[1].replicas | Should -Be 7
    }
    It 'repairs only the missing half of a partial definition' {
        $p = New-DuneEventMapRepairPlan $script:bg
        $script:bg.spec.serverGroup.template.spec.sets += $p.operations[2].value
        $partial = New-DuneEventMapRepairPlan $script:bg
        $partial.operations.Count | Should -Be 2
        $partial.operations[1].path | Should -Be '/spec/database/template/spec/deployment/spec/worldPartitions/-'
    }
    It 'rejects duplicate event definitions' {
        $p = New-DuneEventMapRepairPlan $script:bg
        $script:bg.spec.serverGroup.template.spec.sets += @($p.operations[2].value,$p.operations[2].value)
        { New-DuneEventMapRepairPlan $script:bg } | Should -Throw '*Duplicate*'
    }
    It 'rejects invalid allocation or missing template before any server access' {
        $script:bg.spec.database.template.spec.deployment.spec.worldPartitions[0].partitions[0].id = 'bad'
        { New-DuneEventMapRepairPlan $script:bg } | Should -Throw '*IDs*'
        $script:bg = New-EventFixture
        $script:bg.spec.serverGroup.template.spec.sets = @()
        { New-DuneEventMapRepairPlan $script:bg } | Should -Throw '*template*'
    }
    It 'backs up the original and validates the patch before applying it' {
        Mock Get-V6Battlegroup { @{Ns='test-ns';Name='test-bg';Bg=$script:bg} }
        Mock Invoke-V6Ssh {
            param($Cmd,$StdinData)
            $patch = $StdinData | ConvertFrom-Json
            $patch[0].op | Should -Be 'test'
            $returned = ($script:bg | ConvertTo-Json -Depth 30) | ConvertFrom-Json
            $returned.spec.database.template.spec.deployment.spec.worldPartitions += $patch[1].value
            $returned.spec.serverGroup.template.spec.sets += $patch[2].value
            $returned | ConvertTo-Json -Depth 30
        }
        $r = Repair-DuneEventMapDefinitions -Ip '127.0.0.1'
        $r.ok | Should -BeTrue
        @(Get-ChildItem "$TestDrive/DuneServer/backups/map-config" -Filter '*.json') | Should -HaveCount 1
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter { $Cmd -match '--dry-run=server' }
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter { $Cmd -notmatch '--dry-run=server' }
    }
    It 'does not apply after a rejected dry run or retry a conflict' {
        Mock Get-V6Battlegroup { @{Ns='test-ns';Name='test-bg';Bg=$script:bg} }
        Mock Invoke-V6Ssh { throw 'Conflict' }
        (Repair-DuneEventMapDefinitions -Ip '127.0.0.1').ok | Should -BeFalse
        Should -Invoke Invoke-V6Ssh -Times 1
    }
}
