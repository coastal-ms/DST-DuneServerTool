BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Atlas.ps1'
}
Describe 'Live Map player marker authorization' {
    It 'allows host and authenticated administrative principals' {
        foreach($type in @('local-host','legacy-token')) {
            Test-DuneAtlasPlayerMarkers @{type=$type} | Should -BeTrue
        }
        foreach($type in @('portal-account','legacy-remote','launch-token')) {
            foreach($role in @('owner','admin')) {
                Test-DuneAtlasPlayerMarkers @{type=$type;role=$role} | Should -BeTrue
            }
        }
    }
    It 'denies linked players, anonymous and missing principals' {
        foreach($principal in @(@{type='linked-player';role='admin'},@{type='portal-account';role='player'},@{type='anonymous';role='admin'},@{},$null)) {
            Test-DuneAtlasPlayerMarkers $principal | Should -BeFalse
        }
    }
}
