BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Atlas.ps1'
    Import-DstLib 'SoloLiveMap.ps1'
    function global:Read-DuneSoloState { @{dbPath='C:\Solo\game.db'} }
}
Describe 'Solo companion isolation and launch' {
    It 'keeps per-save state separate from self-hosted Atlas runtimes' {
        $one = Get-DuneSoloLiveMapRoot
        Mock Read-DuneSoloState { @{dbPath='C:\OtherSolo\game.db'} }
        $two = Get-DuneSoloLiveMapRoot
        $one | Should -Not -Be $two
        $one | Should -Match 'DuneServer\\solo-live-map\\[a-f0-9]{64}$'
    }
    It 'does not open a browser without a verified companion' {
        Mock Get-DuneSoloLiveMapReady { $null }
        Mock Start-Process {}
        { Open-DuneSoloLiveMap } | Should -Throw '*Solo Live Map mod*'
        Should -Invoke Start-Process -Times 0
    }
    It 'does not advertise stale snapshots as a running mod' {
        Mock Get-DuneSoloLiveMapReady { @{url='http://127.0.0.1:12345/?key=abcdefghijklmnopqrstuvwxyz123456'} }
        Mock Invoke-RestMethod { @{status='Capture paused'} }
        Mock Start-Process {}
        (Get-DuneSoloLiveMapStatus).available | Should -BeFalse
        { Open-DuneSoloLiveMap } | Should -Throw '*Enter the Deep Desert*'
        Should -Invoke Start-Process -Times 0
    }
    It 'opens the verified local map when the mod is live' {
        Mock Get-DuneSoloLiveMapReady { @{url='http://127.0.0.1:12345/?key=abcdefghijklmnopqrstuvwxyz123456'} }
        Mock Invoke-RestMethod { @{status='Live'} }
        Mock Start-Process {}
        (Open-DuneSoloLiveMap).ok | Should -BeTrue
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -like 'http://127.0.0.1:12345/*' }
    }
}
