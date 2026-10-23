BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Status.ps1'
    function Read-DuneConfig {}
    function Invoke-DuneSshHidden {}
}
Describe 'Structured battlegroup transition status' {
    BeforeEach {
        $script:key = Join-Path $TestDrive 'key'
        Set-Content $script:key 'fixture'
        Mock Read-DuneConfig { @{ SshKey=$script:key } }
        $script:stopRequested = $false
        $script:phase = 'Healthy'
        $script:ready = 'false'
        Mock Invoke-DuneSshHidden {
            $json = @{items=@(@{metadata=@{name='world'};spec=@{stop=$script:stopRequested};status=@{phase=$script:phase}})} | ConvertTo-Json -Depth 6 -Compress
            @{Exit=0;Stderr='';Stdout=@('__DST_BG_STATUS_BEGIN__','Battlegroup: world','No resources found in world namespace.','Game Servers','Map Phase Ready Players Age','--- --- --- --- ---',"Survival_1 Startup $script:ready 0 2m",'__DST_BG_STATUS_END__','__DST_BG_JSON_BEGIN__',$json,'__DST_BG_JSON_END__')}
        }
    }
    It 'reports starting until the login map is ready despite a healthy control plane' {
        $r=Get-DuneBattlegroupSnapshotFresh @{exists=$true;running=$true;ip='192.0.2.1'}
        $r.state | Should -Be 'starting'
        $r.reason | Should -Match 'Hagga is not ready'
        @($r.gameServers).Count | Should -Be 1
    }
    It 'keeps stopping when server rows are absent or stale' {
        $script:stopRequested=$true
        $r=Get-DuneBattlegroupSnapshotFresh @{exists=$true;running=$true;ip='192.0.2.1'}
        $r.state | Should -Be 'stopping'
        $r.reason | Should -Not -Match 'namespace is empty'
    }
    It 'reports running only after the login map becomes ready' {
        $script:ready='true'
        (Get-DuneBattlegroupSnapshotFresh @{exists=$true;running=$true;ip='192.0.2.1'}).state | Should -Be 'running'
    }
    It 'reports a confirmed stop from the structured phase' {
        $script:stopRequested=$true; $script:phase='Stopped'
        (Get-DuneBattlegroupSnapshotFresh @{exists=$true;running=$true;ip='192.0.2.1'}).state | Should -Be 'stopped'
    }
}
