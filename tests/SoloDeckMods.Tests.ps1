BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMods.ps1'
    Import-DstLib 'SoloDeckMods.ps1'
    function global:Assert-DuneSoloGameClosed {}
}
Describe 'Deck enabled-mod package' {
    BeforeEach {
        $script:DuneSoloRuntimeAssets=Join-Path (Get-DstRepoRoot) 'app/resources/solo-mod-runtime'
        $script:bundleRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:bundleRoot | Out-Null
        foreach($name in @('Alpha','Beta','Disabled')) {
            $folder=Join-Path $script:bundleRoot ($name+'/Scripts')
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $folder 'main.lua'),'-- fixture')
            [IO.File]::WriteAllBytes((Join-Path $folder 'empty.lua'),[byte[]]@())
            [IO.File]::WriteAllText((Join-Path (Split-Path $folder) 'settings.ini'),'preserve=yes')
        }
        $script:bundleStatus=@{folder=$script:bundleRoot;runtimeVersion='3.0.1-1140-gf58e8f84';skipIntro=$true;soloArguments='-example="two words"';mods=@(
            @{folder='Beta';name='Beta';version='1';enabled=$true;errors=@()},
            @{folder='Alpha';name='Alpha';version='1';enabled=$true;errors=@()},
            @{folder='Disabled';name='Disabled';version='1';enabled=$false;errors=@()}
        )}
    }
    It 'packages only enabled mods in PC order, retains INIs and uses deterministic archive bytes' {
        $first=New-DuneSoloDeckModBundle $script:bundleStatus (Join-Path $script:bundleRoot 'one.zip')
        $second=New-DuneSoloDeckModBundle $script:bundleStatus (Join-Path $script:bundleRoot 'two.zip')
        $first.sha256 | Should -BeExactly $second.sha256
        @($first.enabled) | Should -Be @('Beta','Alpha')
        $archive=[IO.Compression.ZipFile]::OpenRead((Join-Path $script:bundleRoot 'one.zip'))
        try {
            $archive.Entries.FullName | Should -Not -Contain 'Mods/Disabled/Scripts/main.lua'
            $archive.Entries.FullName | Should -Contain 'Mods/Alpha/settings.ini'
            $archive.Entries.FullName | Should -Contain 'runtime/dwmapi.dll'
            $stream=[IO.StreamReader]::new($archive.GetEntry('manifest.json').Open())
            try {$manifest=$stream.ReadToEnd()|ConvertFrom-Json}finally{$stream.Dispose()}
            $manifest.launchOptions | Should -Contain '-nobattleye'
            $manifest.launchOptions | Should -Contain '-example=two words'
            $manifest.launchOptions | Should -Contain '-nosplash'
            @($manifest.files.PSObject.Properties).Count | Should -Be ($archive.Entries.Count-1)
        } finally {$archive.Dispose()}
        Get-Content (Join-Path $script:bundleRoot 'Alpha/settings.ini') | Should -Be 'preserve=yes'
    }
    It 'changes the package identity when PC settings or enabled order change' {
        $before=New-DuneSoloDeckModBundle $script:bundleStatus (Join-Path $script:bundleRoot 'before.zip')
        [IO.File]::WriteAllText((Join-Path $script:bundleRoot 'Alpha/settings.ini'),'changed=yes')
        $after=New-DuneSoloDeckModBundle $script:bundleStatus (Join-Path $script:bundleRoot 'after.zip')
        $after.sha256 | Should -Not -Be $before.sha256
    }
    It 'rejects unresolved selection and unsupported quoted arguments without dispatching' {
        $script:bundleStatus.mods[0].errors=@('Missing dependency')
        {New-DuneSoloDeckModBundle $script:bundleStatus (Join-Path $script:bundleRoot 'invalid.zip')} | Should -Throw '*Resolve*'
        $script:bundleStatus.mods[0].errors=@()
        $script:bundleStatus.soloArguments='-bad="unfinished'
        {New-DuneSoloDeckModBundle $script:bundleStatus (Join-Path $script:bundleRoot 'invalid.zip')} | Should -Throw '*quote*'
    }
}
