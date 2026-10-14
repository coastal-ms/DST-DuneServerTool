BeforeAll {
    Add-Type -AssemblyName System.IO.Compression.FileSystem, System.IO.Compression
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
    It 'sends a button grant to the current session and waits for matching game acknowledgement' {
        $script:TankCommandTestRoot=Join-Path $script:DuneSoloLoaderRoot ('Session-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TankCommandTestRoot -Force | Out-Null
        @{root=$script:TankCommandTestRoot;tankSupport=$true} | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'session.json')
        Mock Start-Sleep {
            $request=[IO.File]::ReadAllText((Join-Path $script:TankCommandTestRoot 'tank-request.txt')).Split('|')
            $request[1] | Should -Be 'T6_CombatDart'
            [IO.File]::WriteAllText((Join-Path $script:TankCommandTestRoot 'tank-response.txt'),($request[0]+'|ok|Grant requested'))
        }
        (Grant-DuneSoloRegisTank -Preset 'T6_CombatDart').ok | Should -BeTrue
    }
    It 'rejects unsupported variants before queuing a game command' {
        {Grant-DuneSoloRegisTank -Preset 'OtherVehicle'} | Should -Throw '*Select Dart*'
    }
    It 'includes built-in Tanks in normal Solo launch and preserves optional mod selections' -ForEach @(@{WithMods=$false;Expected=1},@{WithMods=$true;Expected=2}) {
        $script:DuneBundledSoloModsRoot=Join-Path (Get-DstRepoRoot) 'app/resources/solo-mods'
        $library=Join-Path $script:ModTestRoot ([guid]::NewGuid().ToString('N')+'/steamapps')
        $game=Join-Path $library 'common/DuneAwakening'
        $bin=Join-Path $game 'DuneSandbox/Binaries/Win64'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $exe=Join-Path $bin 'DuneSandbox-Win64-Shipping.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        '"buildid" "25789117"' | Set-Content (Join-Path $library 'appmanifest_1172710.acf')
        Import-DuneSoloMod (New-ModZip ([guid]::NewGuid().ToString('N')) @{'UserMod/Scripts/main.lua'='print(1)'}) | Out-Null
        Set-DuneSoloModSelection @{mods=@(@{folder='UserMod';enabled=$true});gamePath=$game;platform='steam'} | Out-Null
        Mock Get-FileHash { @{Hash='B9A77E7A178CFA8D88D65743BCBB04EF9D45E13539DB0BBD148E172BDA86A9E9'} } -ParameterFilter { $LiteralPath -eq $exe }
        Mock Start-Process {}
        $statePath = Join-Path (Split-Path -Parent $script:DuneSoloModsRoot) 'State/active-mods.txt'
        if ($WithMods) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
            [IO.File]::WriteAllText($statePath, 'prior-state-list')
            [IO.File]::WriteAllText((Join-Path $script:DuneSoloModsRoot 'mods.txt'), 'prior-mod-list')
        }
        Start-DuneSoloModGame $WithMods | Out-Null
        $status=Get-DuneSoloMods
        $list=@(Get-Content (Join-Path $status.session.root 'mods.txt'))
        $list.Count | Should -Be $Expected
        $list | Should -Contain 'dst-regis-tanks : 1'
        @($status.mods | Where-Object id -eq 'UserMod')[0].enabled | Should -BeTrue
        if (-not $WithMods) { $list | Should -Not -Contain 'UserMod : 1' }
        $compat = @(Get-Content (Join-Path $script:DuneSoloModsRoot 'mods.txt'))
        $compat | Should -Contain 'dst-regis-tanks : 1'
        $compat | Should -Contain ('UserMod : '+[int]$WithMods)
        @(Get-Content (Join-Path (Split-Path -Parent $script:DuneSoloModsRoot) 'State/active-mods.txt')) | Should -Be $compat
        Mock Get-Process {}
        & (Join-Path (Get-DstRepoRoot) 'app/server/lib/SoloModsWatcher.ps1') -LoaderRoot $script:DuneSoloLoaderRoot -RestoreOnly
        if ($WithMods) {
            [IO.File]::ReadAllText($statePath) | Should -BeExactly 'prior-state-list'
            [IO.File]::ReadAllText((Join-Path $script:DuneSoloModsRoot 'mods.txt')) | Should -BeExactly 'prior-mod-list'
        } else {
            Test-Path -LiteralPath $statePath | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:DuneSoloModsRoot 'mods.txt') | Should -BeFalse
        }
    }
    It 'installs bundled tanks disabled and preserves an existing installation' {
        $script:DuneBundledSoloModsRoot=Join-Path (Get-DstRepoRoot) 'app/resources/solo-mods'
        $result=Install-DuneRegisTanksMod
        $tank=@($result.mods | Where-Object id -eq 'dst-regis-tanks')[0]
        $tank.enabled | Should -BeFalse
        $tank.warnings.Count | Should -BeGreaterThan 0
        $settings=Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks/custom.ini'
        'kept' | Set-Content $settings
        { Install-DuneRegisTanksMod } | Should -Throw '*already installed*'
        Get-Content $settings | Should -Be 'kept'
    }
    It 'blocks tank installation while Dune is running' {
        Mock Assert-DuneSoloGameClosed { throw 'Close Dune first' }
        { Install-DuneRegisTanksMod } | Should -Throw '*Close Dune*'
        Test-Path (Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks') | Should -BeFalse
    }
    It 'writes launch context for a supported Steam library outside the default installation' {
        $script:DuneBundledSoloModsRoot=Join-Path (Get-DstRepoRoot) 'app/resources/solo-mods'
        Install-DuneRegisTanksMod | Out-Null
        $library=Join-Path $script:ModTestRoot 'Custom Library/steamapps'
        $game=Join-Path $library 'common/DuneAwakening'
        New-Item -ItemType Directory -Path $game -Force | Out-Null
        '"buildid" "25789117"' | Set-Content (Join-Path $library 'appmanifest_1172710.acf')
        Mock Get-FileHash { @{Hash='B9A77E7A178CFA8D88D65743BCBB04EF9D45E13539DB0BBD148E172BDA86A9E9'} }
        Set-DuneRegisTanksLaunchContext -GamePath $game -Platform steam
        Get-Content (Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks/Scripts/dst-steam-manifest.txt') | Should -Be (Join-Path $library 'appmanifest_1172710.acf')
    }
    It 'blocks Xbox and changed executables before writing tank launch context' {
        { Set-DuneRegisTanksLaunchContext -GamePath 'C:/OtherGame' -Platform xbox } | Should -Throw '*Steam Solo only*'
        Mock Get-FileHash { @{Hash='CHANGED'} }
        { Set-DuneRegisTanksLaunchContext -GamePath 'C:/OtherGame' -Platform steam } | Should -Throw '*does not support this game build*'
        Test-Path (Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks/Scripts/dst-steam-manifest.txt') | Should -BeFalse
    }
    It 'switches connected platforms without touching mod selections and recalls both folders' {
        Set-DuneSoloModSelection @{mods=@(@{folder='Kept';enabled=$true});platform='steam';gamePath='C:\Steam\Dune'} | Out-Null
        Set-DuneSoloModPlatform -Platform xbox -GamePath 'C:\Xbox\Dune'
        Set-DuneSoloModPlatform -Platform steam
        (Get-DuneSoloMods).gamePath | Should -Be 'C:\Steam\Dune'
        Set-DuneSoloModPlatform -Platform xbox
        (Get-DuneSoloMods).gamePath | Should -Be 'C:\Xbox\Dune'
        Set-DuneSoloModPlatform -Platform xbox
        (Get-DuneSoloMods).gamePath | Should -Be 'C:\Xbox\Dune'
        (Get-Content (Join-Path $script:DuneSoloLoaderRoot 'selection.json') -Raw | ConvertFrom-Json).Kept | Should -BeTrue
    }
    It 'discovers the registered Xbox installation only when its executable exists' {
        $root=Join-Path $script:ModTestRoot 'RegisteredXbox'
        $bin=Join-Path $root 'DuneSandbox/Binaries/WinGDK'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Mock Get-AppxPackage { @([pscustomobject]@{InstallLocation=$root;Version='2.0.11.0'}) }
        Find-DuneSoloXboxInstallation | Should -Be ''
        New-Item -ItemType File -Path (Join-Path $bin 'DuneSandbox-WinGDK-Shipping.exe') -Force | Out-Null
        Find-DuneSoloXboxInstallation | Should -Be $root
    }
    It 'detects Xbox without replacing Steam paths or changing mod selection' {
        Mock Find-DuneSoloXboxInstallation { 'C:\Xbox\Dune' }
        $mods=@(@{folder='Alpha';enabled=$true},@{folder='Beta';enabled=$false})
        Set-DuneSoloModSelection @{mods=$mods;gamePath='C:\Steam\Dune';platform='steam'} | Out-Null
        $xbox=Set-DuneSoloModSelection @{mods=$mods;gamePath='';platform='xbox'}
        $xbox.gamePath | Should -Be 'C:\Xbox\Dune'
        $xbox.platform | Should -Be 'xbox'
        $steam=Set-DuneSoloModSelection @{mods=$mods;gamePath='';platform='steam'}
        $steam.gamePath | Should -Be 'C:\Steam\Dune'
        $selection=Get-Content (Join-Path $script:DuneSoloLoaderRoot 'selection.json') -Raw | ConvertFrom-Json
        $selection.Alpha | Should -BeTrue
        $selection.Beta | Should -BeFalse
    }
    It 'launches the Xbox executable and never the Steam executable' {
        $game=Join-Path $script:ModTestRoot 'XboxGame'
        $bin=Join-Path $game 'DuneSandbox/Binaries/WinGDK'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $bin 'DuneSandbox-WinGDK-Shipping.exe') -Force | Out-Null
        Set-DuneSoloModSelection @{mods=@();gamePath=$game;platform='xbox'} | Out-Null
        Mock Start-Process {}
        Start-DuneSoloModGame $false | Out-Null
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath.EndsWith('DuneSandbox-WinGDK-Shipping.exe') }
    }
    It 'preserves quoted custom arguments in normal and modded launch arguments' {
        $extra='-example="two words" -another=3'
        foreach($runtime in @('', 'C:\runtime\UE4SS.dll')) {
            $args=@(Get-DuneSoloLaunchArguments -ExtraArguments $extra -RuntimeDll $runtime)
            $args[0] | Should -Be '-nobattleye'
            $args[-1] | Should -Be $extra
        }
    }
    It 'saves Solo arguments independently of the shared skip intro preference' {
        Set-DuneGameLaunchPreferences @{skipIntro=$true} | Out-Null
        Set-DuneGameLaunchPreferences @{soloArguments='-example="two words"'} | Out-Null
        (Get-DuneGameLaunchPreferences).skipIntro | Should -BeTrue
        (Get-DuneSoloMods).soloArguments | Should -Be '-example="two words"'
        Set-DuneGameLaunchPreferences @{skipIntro=$false} | Out-Null
        (Get-DuneGameLaunchPreferences).soloArguments | Should -Be '-example="two words"'
        Set-DuneGameLaunchPreferences @{soloArguments=''} | Out-Null
        (Get-DuneGameLaunchPreferences).soloArguments | Should -Be ''
    }
    It 'rejects multiline arguments without replacing saved preferences' {
        Set-DuneGameLaunchPreferences @{soloArguments='-log'} | Out-Null
        { Set-DuneGameLaunchPreferences @{soloArguments="-log`n-other"} } | Should -Throw '*single line*'
        (Get-DuneGameLaunchPreferences).soloArguments | Should -Be '-log'
    }
    It 'passes saved arguments to the game executable during normal Solo launch' {
        $game=Join-Path $script:ModTestRoot 'Game'
        $bin=Join-Path $game 'DuneSandbox/Binaries/Win64'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $bin 'DuneSandbox-Win64-Shipping.exe') -Force | Out-Null
        Set-DuneSoloModSelection @{mods=@();gamePath=$game} | Out-Null
        Set-DuneGameLaunchPreferences @{soloArguments='-example="two words"'} | Out-Null
        Mock Start-Process {}
        Start-DuneSoloModGame $false | Out-Null
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath.EndsWith('DuneSandbox-Win64-Shipping.exe') -and $ArgumentList[-1] -eq '-example="two words"'
        }
    }
    It 'passes journaled arguments directly to the modded game executable' {
        $root=$script:DuneSoloLoaderRoot
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        @{files=@();soloArguments='-example="two words"'} | ConvertTo-Json | Set-Content (Join-Path $root 'session.json')
        Mock Start-Process { $process=New-Object PSObject; $process | Add-Member ScriptMethod WaitForExit {}; return $process }
        Mock Get-Process {}
        & "$PSScriptRoot/../app/server/lib/SoloModsWatcher.ps1" -LoaderRoot $root -GameExe 'C:\Game\Dune.exe' -RuntimeDll 'C:\runtime\UE4SS.dll'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Game\Dune.exe' -and $ArgumentList[-1] -eq '-example="two words"' -and $ArgumentList -contains '--ue4ss-path'
        }
    }
    It 'automatically restores a leftover session and continues normal launch' {
        $game=Join-Path $script:ModTestRoot 'RecoveredGame'
        $bin=Join-Path $game 'DuneSandbox/Binaries/Win64'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $bin 'DuneSandbox-Win64-Shipping.exe') -Force | Out-Null
        Set-DuneSoloModSelection @{mods=@();gamePath=$game} | Out-Null
        @{files=@()} | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'session.json')
        Mock Get-Process {}
        Mock Start-Process {}
        Start-DuneSoloModGame $false | Out-Null
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'session.json') | Should -BeFalse
        Should -Invoke Start-Process -Times 1 -Exactly
    }
    It 'clears leftover restoration state before checking mod runtime requirements' {
        $game=Join-Path $script:ModTestRoot 'RecoveredModGame'
        $bin=Join-Path $game 'DuneSandbox/Binaries/Win64'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $bin 'DuneSandbox-Win64-Shipping.exe') -Force | Out-Null
        Set-DuneSoloModSelection @{mods=@();gamePath=$game} | Out-Null
        @{files=@()} | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'session.json')
        Set-Content (Join-Path $script:DuneSoloLoaderRoot 'launch-error.txt') 'Old launch error'
        Mock Get-Process {}
        { Start-DuneSoloModGame $true } | Should -Throw '*Install the mod runtime first*'
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'session.json') | Should -BeFalse
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'launch-error.txt') | Should -BeFalse
    }
    It 'rejects a missing installation folder before either launch can touch runtime files' -ForEach @(
        @{ WithMods=$true; GamePath='' }
        @{ WithMods=$false; GamePath='' }
        @{ WithMods=$true; GamePath='   ' }
        @{ WithMods=$false; GamePath='   ' }
    ) {
        Set-DuneSoloModSelection @{mods=@();gamePath=$GamePath} | Out-Null
        { Start-DuneSoloModGame $WithMods } | Should -Throw '*installation folder in Solo mods and save it*'
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'session.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:DuneSoloLoaderRoot -Directory -Filter 'Session-*').Count | Should -Be 0
    }
    It 'deletes only the selected mod and removes it from saved order' {
        Import-DuneSoloMod (New-ModZip 'delete' @{'Alpha/Scripts/main.lua'='print(1)';'Alpha/mod.ini'='speed=2';'Zulu/Scripts/main.lua'='print(2)'}) | Out-Null
        Set-DuneSoloModSelection @{mods=@(@{folder='Zulu';enabled=$true},@{folder='Alpha';enabled=$true});gamePath='C:\Dune'} | Out-Null
        Remove-DuneSoloMod 'Alpha' | Out-Null
        Test-Path (Join-Path $script:DuneSoloModsRoot 'Alpha') | Should -BeFalse
        Test-Path (Join-Path $script:DuneSoloModsRoot 'Zulu/Scripts/main.lua') | Should -BeTrue
        @((Get-DuneSoloMods).mods.folder) | Should -Be @('Zulu')
        (Get-DuneSoloMods).mods[0].enabled | Should -BeTrue
        (Get-Content (Join-Path $script:DuneSoloLoaderRoot 'order.json') -Raw | ConvertFrom-Json) | Should -Be @('Zulu')
    }
    It 'rejects paths outside the mod folder and deletion while the game is running' {
        { Remove-DuneSoloMod '..' } | Should -Throw
        { Remove-DuneSoloMod '../Other' } | Should -Throw
        Import-DuneSoloMod (New-ModZip 'running' @{'Alpha/Scripts/main.lua'='print(1)'}) | Out-Null
        Mock Assert-DuneSoloGameClosed { throw 'Close Dune first' }
        { Remove-DuneSoloMod 'Alpha' } | Should -Throw '*Close Dune first*'
        Test-Path (Join-Path $script:DuneSoloModsRoot 'Alpha') | Should -BeTrue
    }
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
    $script:DuneSoloRuntimeAssets=Join-Path (Get-DstRepoRoot) 'app/resources/solo-mod-runtime'
}

    It 'installs the tested bundled runtime without network access' {
        Mock Invoke-RestMethod { throw 'Unexpected network request' }
        Mock Invoke-WebRequest { throw 'Unexpected network request' }
        $selection=Join-Path $script:DuneSoloLoaderRoot 'selection.json'
        New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
        Set-Content $selection '{"Kept":true}'
        Install-DuneSoloModRuntime | Out-Null
        Test-Path (Join-Path $script:DuneSoloLoaderRoot 'Runtime/ue4ss/UE4SS.dll') | Should -BeTrue
        $archive=[IO.Compression.ZipFile]::OpenRead((Join-Path $script:DuneSoloRuntimeAssets 'configs.zip'))
        try {
            $reader=[IO.StreamReader]::new($archive.GetEntry('DuneAwakening/UE4SS-settings.ini').Open())
            try { $expected=$reader.ReadToEnd() } finally { $reader.Dispose() }
            (Get-Content (Join-Path $script:DuneSoloLoaderRoot 'Runtime/ue4ss/UE4SS-settings.ini') -Raw) | Should -Be $expected
        } finally { $archive.Dispose() }
        (Get-Content $selection -Raw).Trim() | Should -Be '{"Kept":true}'
        @(Get-ChildItem $script:DuneSoloLoaderRoot -Directory -Filter 'Configs-*').Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        { Install-DuneSoloModRuntime } | Should -Throw '*already installed*'
    }

    It 'rejects corrupt bundled archives before creating a runtime' {
        $script:DuneSoloRuntimeAssets=Join-Path $case 'BrokenAssets'
        New-Item -ItemType Directory $script:DuneSoloRuntimeAssets | Out-Null
        Set-Content (Join-Path $script:DuneSoloRuntimeAssets 'runtime.zip') 'corrupt'
        Copy-Item (Join-Path (Get-DstRepoRoot) 'app/resources/solo-mod-runtime/configs.zip') $script:DuneSoloRuntimeAssets
        { Install-DuneSoloModRuntime } | Should -Throw '*checksum mismatch*'
        Test-Path $script:DuneSoloLoaderRoot | Should -BeFalse
    }

    It 'keeps the global launch preference when mod selections change' {
        Set-DuneGameLaunchPreferences @{skipIntro=$true} | Out-Null
        Set-DuneSoloModSelection @{mods=@();gamePath='C:\Dune'} | Out-Null
        (Get-DuneSoloMods).skipIntro | Should -BeTrue
        Set-DuneGameLaunchPreferences @{skipIntro=$false} | Out-Null
        (Get-DuneSoloMods).skipIntro | Should -BeFalse
    }
    It 'writes a BOM-free loader list so the first enabled mod can load on PS5' {
        $path=Join-Path $script:DuneSoloLoaderRoot 'mods.txt'
        New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
        Write-DuneSoloModLoadList -Path $path -Mods @(@{folder='DuneVehicleSpeed'},@{folder='Other'})
        $bytes=[IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be 68
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Match '^DuneVehicleSpeed : 1'
        Get-Content $path | Should -HaveCount 2
    }
    It 'persists user order across refresh and imports without changing enabled selections' {
        Import-DuneSoloMod (New-ModZip 'order' @{'Alpha/Scripts/main.lua'='print(1)';'Zulu/Scripts/main.lua'='print(2)'}) | Out-Null
        Set-DuneSoloModSelection @{mods=@(@{folder='Zulu';enabled=$true},@{folder='Alpha';enabled=$false});gamePath='C:\Dune'} | Out-Null
        $result=Get-DuneSoloMods
        @($result.mods.folder) | Should -Be @('Zulu','Alpha')
        $result.mods[0].enabled | Should -BeTrue
        $result.mods[1].enabled | Should -BeFalse
        Import-DuneSoloMod (New-ModZip 'new-order' @{'Beta/Scripts/main.lua'='print(3)'}) | Out-Null
        @((Get-DuneSoloMods).mods.folder) | Should -Be @('Zulu','Alpha','Beta')
        $path=Join-Path $script:DuneSoloLoaderRoot 'ordered.txt'
        Write-DuneSoloModLoadList -Path $path -Mods @((Get-DuneSoloMods).mods | Where-Object enabled)
        Get-Content $path | Should -Be 'Zulu : 1'
        Set-DuneSoloModSelection @{mods=@(@{folder='Zulu';enabled=$true},@{folder='Alpha';enabled=$true});gamePath='C:\Dune'} | Out-Null
        Write-DuneSoloModLoadList -Path $path -Mods @((Get-DuneSoloMods).mods | Where-Object enabled)
        @(Get-Content $path) | Should -Be @('Zulu : 1','Alpha : 1')
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
    It 'ignores launcher and runtime declarations without rewriting manifests' {
        $metadata='{"id":"VehicleSpeed","requires":[{"id":"wps-launcher"},{"id":"ue4ss","maxVersion":"3.0.1-1140-gf58e8f84"}]}'
        Import-DuneSoloMod (New-ModZip 'advisory' @{'VehicleSpeed/mod.json'=$metadata;'VehicleSpeed/Scripts/main.lua'='print(1)'}) | Out-Null
        $result=Set-DuneSoloModSelection @{mods=@(@{folder='VehicleSpeed';enabled=$true});gamePath=''}
        $result.mods[0].errors.Count | Should -Be 0
        $result.mods[0].warnings.Count | Should -Be 0
        Get-Content (Join-Path $script:DuneSoloModsRoot 'VehicleSpeed/mod.json') -Raw | Should -Be $metadata
    }
    It 'restores pre-existing launch files and removes only owned additions' {
        Mock Get-Process {}
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
        Mock Get-Process {}
        $root=$script:DuneSoloLoaderRoot;New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path=Join-Path $root 'proxy';'external'|Set-Content $path
        @{files=@(@{path=$path;backup='absent';hash='different';installed=$true;restored=$false})} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'session.json')
        { & "$PSScriptRoot/../app/server/lib/SoloModsWatcher.ps1" -LoaderRoot $root -RestoreOnly } | Should -Throw '*changed outside*'
        Get-Content $path | Should -Be 'external'
        Test-Path (Join-Path $root 'session.json') | Should -BeTrue
    }
}

