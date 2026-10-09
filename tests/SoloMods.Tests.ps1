BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMods.ps1'
    function global:Assert-DuneSoloGameClosed {}
    $script:ModTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('dst-mods-'+[guid]::NewGuid().ToString('N'))
    function New-ModZip([string]$Name,[hashtable]$Files){
        $path=Join-Path $script:ModTestRoot ($Name+'.zip')
        $z=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        foreach($key in $Files.Keys){$entry=$z.CreateEntry($key);$w=[IO.StreamWriter]::new($entry.Open());$w.Write([string]$Files[$key]);$w.Dispose()}
        $z.Dispose();return $path
    }
}
AfterAll { if($script:ModTestRoot.StartsWith([IO.Path]::GetTempPath())){Remove-Item -LiteralPath $script:ModTestRoot -Recurse -Force} }
Describe 'Solo mod import and dependencies' {
    It 'skips intros for normal and modded launches without requiring a mod' {
        $normal=@(Get-DuneSoloLaunchArguments -SkipIntro)
        $normal | Should -Contain '-nosplash'
        $normal | Should -Contain '-nostartupscreen'
        $normal | Should -Contain '--disable-ue4ss'
        $modded=@(Get-DuneSoloLaunchArguments -SkipIntro -RuntimeDll 'C:\runtime\UE4SS.dll')
        $modded | Should -Contain '-nosplash'
        $modded | Should -Contain '--ue4ss-path'
        @(Get-DuneSoloLaunchArguments) | Should -Not -Contain '-nosplash'
    }
BeforeEach {
    $case=Join-Path $script:ModTestRoot ([guid]::NewGuid().ToString('N'))
    $script:DuneSoloModsRoot=Join-Path $case 'Mods'
    $script:DuneSoloLoaderRoot=Join-Path $case 'Loader'
    New-Item -ItemType Directory -Path $script:ModTestRoot,$case -Force | Out-Null
}

    It 'keeps the global launch preference when mod selections change' {
        Set-DuneGameLaunchPreferences @{skipIntro=$true} | Out-Null
        Set-DuneSoloModSelection @{mods=@();gamePath='C:\Dune'} | Out-Null
        (Get-DuneSoloMods).skipIntro | Should -BeTrue
        Set-DuneGameLaunchPreferences @{skipIntro=$false} | Out-Null
        (Get-DuneSoloMods).skipIntro | Should -BeFalse
    }
    It 'imports nested packages while preserving the INI and Content directory' {
        $zip=New-ModZip 'nested' @{'Launcher/Mods/Test/Scripts/main.lua'='print(1)';'Launcher/Mods/Test/mod.ini'='speed=2';'Launcher/Mods/Test/Content/data.txt'='data'}
        $result=Import-DuneSoloMod $zip
        $result.mods.Count | Should -Be 1
        Get-Content (Join-Path $result.folder 'Test/mod.ini') | Should -Be 'speed=2'
        Test-Path (Join-Path $result.folder 'Test/Content/data.txt') | Should -BeTrue
    }
    It 'rejects traversal without writing outside the staging folder' {
        $zip=New-ModZip 'traversal' @{'../escaped.txt'='bad';'Test/Scripts/main.lua'='print(1)'}
        {Import-DuneSoloMod $zip} | Should -Throw '*unsafe*'
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'escaped.txt') | Should -BeFalse
    }
    It 'preserves existing mod settings when an import would overwrite them' {
        $zip=New-ModZip 'duplicate' @{'Test/Scripts/main.lua'='print(1)';'Test/mod.ini'='original'}
        Import-DuneSoloMod $zip | Out-Null
        'custom' | Set-Content (Join-Path $script:DuneSoloModsRoot 'Test/mod.ini')
        {Import-DuneSoloMod $zip} | Should -Throw '*Already installed*'
        Get-Content (Join-Path $script:DuneSoloModsRoot 'Test/mod.ini') | Should -Be 'custom'
    }
    It 'reports missing declared dependencies, then clears the error when enabled' {
        $zip=New-ModZip 'deps' @{'A/Scripts/main.lua'='print(1)';'A/mod.json'='{"id":"A","requires":[{"id":"B","minVersion":"1.0"}]}';'B/Scripts/main.lua'='print(2)';'B/mod.json'='{"id":"B","version":"1.1"}'}
        Import-DuneSoloMod $zip | Out-Null
        $result=Set-DuneSoloModSelection @{mods=@(@{folder='A';enabled=$true});gamePath=''}
        ($result.mods | Where-Object id -eq A).errors | Should -Contain 'Missing or disabled dependency: B'
        $result=Set-DuneSoloModSelection @{mods=@(@{folder='A';enabled=$true},@{folder='B';enabled=$true});gamePath=''}
        ($result.mods | Where-Object id -eq A).errors.Count | Should -Be 0
    }
    It 'reports launcher and runtime pins as nonblocking warnings without rewriting manifests' {
        $metadata='{"id":"VehicleSpeed","requires":[{"id":"wps-launcher"},{"id":"ue4ss","maxVersion":"3.0.1-1140-gf58e8f84"}]}'
        Import-DuneSoloMod (New-ModZip 'advisory' @{'VehicleSpeed/mod.json'=$metadata;'VehicleSpeed/Scripts/main.lua'='print(1)'}) | Out-Null
        $result=Set-DuneSoloModSelection @{mods=@(@{folder='VehicleSpeed';enabled=$true});gamePath=''}
        $result.mods[0].errors.Count | Should -Be 0
        $result.mods[0].warnings.Count | Should -Be 2
        Get-Content (Join-Path $script:DuneSoloModsRoot 'VehicleSpeed/mod.json') -Raw | Should -Be $metadata
    }
    It 'restores pre-existing launch files and removes only owned additions' {
        $root=$script:DuneSoloLoaderRoot;New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path=Join-Path $root 'proxy';$backup=Join-Path $root 'original';'new'|Set-Content $path;'old'|Set-Content $backup
        $owned=Join-Path $root 'owned';'owned'|Set-Content $owned
        @{files=@(@{path=$path;backup=$backup;hash=(Get-FileHash $path).Hash;installed=$true;restored=$false},@{path=$owned;backup=(Join-Path $root 'absent');hash=(Get-FileHash $owned).Hash;installed=$true;restored=$false})} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'session.json')
        & "$PSScriptRoot/../app/server/lib/SoloModsWatcher.ps1" -LoaderRoot $root -RestoreOnly
        Get-Content $path | Should -Be 'old'
        Test-Path $owned | Should -BeFalse
        Test-Path (Join-Path $root 'session.json') | Should -BeFalse
    }
    It 'preserves an externally changed launch file and retains recovery evidence' {
        $root=$script:DuneSoloLoaderRoot;New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path=Join-Path $root 'proxy';'external'|Set-Content $path
        @{files=@(@{path=$path;backup='absent';hash='different';installed=$true;restored=$false})} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'session.json')
        { & "$PSScriptRoot/../app/server/lib/SoloModsWatcher.ps1" -LoaderRoot $root -RestoreOnly } | Should -Throw '*changed outside*'
        Get-Content $path | Should -Be 'external'
        Test-Path (Join-Path $root 'session.json') | Should -BeTrue
    }
}

