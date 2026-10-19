BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMods.ps1'
}

Describe 'Bundled Solo Live Map selection' {
    BeforeEach {
        $script:DuneSoloModsRoot = Join-Path $TestDrive 'Mods'
        $script:DuneSoloLoaderRoot = Join-Path $TestDrive 'ModLoader'
        New-Item -ItemType Directory -Path (Join-Path $script:DuneSoloModsRoot 'dst-solo-live-map') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Get-DstRepoRoot) 'app\resources\solo-mods\dst-solo-live-map\mod.json') -Destination (Join-Path $script:DuneSoloModsRoot 'dst-solo-live-map\mod.json')
        Remove-Item -LiteralPath (Join-Path $script:DuneSoloLoaderRoot 'selection.json') -ErrorAction SilentlyContinue
    }

    It 'discovers the bundled mod disabled without creating a selection' {
        $mod = @((Get-DuneSoloMods).mods | Where-Object id -eq 'dst-solo-live-map')
        $mod.Count | Should -Be 1
        $mod[0].enabled | Should -BeFalse
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'selection.json') | Should -BeFalse
    }

    It 'preserves existing explicit selections when the bundled mod is discovered' {
        $selection = Join-Path $script:DuneSoloLoaderRoot 'selection.json'
        $content = '{"dst-solo-live-map":true,"another-mod":false}'
        [IO.File]::WriteAllText($selection, $content)
        $mod = @((Get-DuneSoloMods).mods | Where-Object id -eq 'dst-solo-live-map')
        $mod[0].enabled | Should -BeTrue
        [IO.File]::ReadAllText($selection) | Should -BeExactly $content
    }

    It 'installs the mod into Mods and excludes private runtime files' {
        $installer = Get-Content (Join-Path (Get-DstRepoRoot) 'app\installer\DuneServer.iss') -Raw
        $line = @($installer -split "`n" | Where-Object { $_ -like '*DestDir: "{app}\Mods\dst-solo-live-map"*' })
        $line.Count | Should -Be 1
        $line[0] | Should -Match 'dst-live-map-context.txt'
        $line[0] | Should -Match 'dst-native-build.txt'
        $line[0] | Should -Match '__pycache__'
        $line[0] | Should -Not -Match 'selection.json|mods.txt'
    }
}
