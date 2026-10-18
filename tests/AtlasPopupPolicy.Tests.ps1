BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    if (-not ('DuneShell.AtlasPopupPolicy' -as [type])) {
        Add-Type -Path (Join-Path (Get-DstRepoRoot) 'app/desktop/DuneShell/AtlasPopupPolicy.cs')
    }
}

Describe 'Atlas native popup routing' {
    It 'opens only the map-only view in a separate window on the current portal origin' {
        [DuneShell.AtlasPopupPolicy]::IsAtlasPopup(
            [uri]'http://127.0.0.1:47823/',
            [uri]'http://127.0.0.1:47823/api/v1/maps/atlas/view?t=test&embedded=1&view=map'
        ) | Should -BeTrue
    }
    It 'leaves other portal flows and foreign origins out of the Atlas window' -ForEach @(
        @{Url='http://127.0.0.1:47823/map?view=live'},
        @{Url='http://127.0.0.1:47823/api/v1/maps/atlas/view?embedded=1'},
        @{Url='http://127.0.0.1:47823/api/v1/maps/atlas/view?view=atlas'},
        @{Url='http://127.0.0.1:47823/api/v1/maps/atlas/view/other?view=map'},
        @{Url='http://127.0.0.1:47824/api/v1/maps/atlas/view?view=map'},
        @{Url='https://127.0.0.1:47823/api/v1/maps/atlas/view?view=map'},
        @{Url='http://example.com:47823/api/v1/maps/atlas/view?view=map'},
        @{Url='http://user@127.0.0.1:47823/api/v1/maps/atlas/view?view=map'}
    ) {
        [DuneShell.AtlasPopupPolicy]::IsAtlasPopup([uri]'http://127.0.0.1:47823/', [uri]$Url) | Should -BeFalse
    }
}
