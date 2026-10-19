$soloModAppRoot = if($script:AppDir){$script:AppDir}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$script:DuneSoloModsRoot = Join-Path $soloModAppRoot 'Mods'
$script:DuneSoloLoaderRoot = Join-Path $soloModAppRoot 'ModLoader'
$script:DuneSoloRuntimeAssets = Join-Path $soloModAppRoot 'resources\solo-mod-runtime'
$script:DuneBundledSoloModsRoot = Join-Path $soloModAppRoot 'resources\solo-mods'

function Import-DuneSoloModUpload {
    param([string]$Filename, [string]$Base64, [switch]$CheckOverwrite, [switch]$Overwrite, [string]$ExpectedHash)
    Assert-DuneSoloGameClosed
    $limit = 16MB
    if ([string]::IsNullOrWhiteSpace($Filename) -or $Filename.Length -gt 180 -or
        $Filename -match '[\\/:*?"<>|\x00-\x1f]' -or
        [IO.Path]::GetExtension($Filename) -ine '.zip' -or
        $Filename -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\.' -or
        [string]::IsNullOrEmpty($Base64) -or $Base64.Length -gt 22369624) {
        throw 'Drop one ZIP up to 16 MB, or use Install mod ZIP for larger files.'
    }
    try { $bytes = [Convert]::FromBase64String($Base64) }
    catch { throw 'The dropped ZIP could not be read. Try Install mod ZIP instead.' }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) { throw 'Drop one ZIP up to 16 MB, or use Install mod ZIP for larger files.' }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $stage = Join-Path $tempRoot ('dst-mod-upload-' + [guid]::NewGuid().ToString('N'))
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($stage)) -cne $tempRoot) { throw 'Invalid mod upload staging location.' }
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    try {
        $zip = Join-Path $stage $Filename
        [IO.File]::WriteAllBytes($zip, $bytes)
        return Import-DuneSoloMod -Path $zip -CheckOverwrite:$CheckOverwrite -Overwrite:$Overwrite -ExpectedHash $ExpectedHash
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Get-DuneSoloRuntimeProfiles {
    # Add verified bundled releases here; keep existing entries for saved choices.
    return @(
        @{version='3.0.1-1140-gf58e8f84';label='1140 — default';folder='Runtime-1140';archive='runtime-1140.zip';hash='B954F036B10E9ABB0C0C41599311AB1ACCC53E30515AEED7E48EE22C5B3B1280'},
        @{version='3.0.1-1164-g5e627997';label='1164 — newer, optional';folder='Runtime';archive='runtime.zip';hash='3C72142A383E25E9F9553AC9E4D5677AA572E98CB369CAC57200EFB2E381E603'}
    )
}

function Get-DuneSoloRuntimeProfile($Mods, [switch]$TankOnly) {
    # Compatibility baseline for optional mods is the previous bundled runtime.
    # The newer runtime requires the user's explicit opt-in, not a mod declaration.
    $legacy = -not $TankOnly
    $choice=Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'runtime-choice.json') @{}
    if (-not $TankOnly -and $null -ne $choice.useNewerRuntime) { $legacy=-not [bool]$choice.useNewerRuntime }
    $version=if($legacy){'3.0.1-1140-gf58e8f84'}else{'3.0.1-1164-g5e627997'}
    $profiles=@(Get-DuneSoloRuntimeProfiles)
    if (-not $TankOnly -and $choice.version -and @($profiles | Where-Object version -eq $choice.version).Count -eq 1) {$version=[string]$choice.version}
    $fallback=Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'runtime-fallback.json') @{}
    if ($fallback.version -eq '3.0.1-1140-gf58e8f84') { $version=[string]$fallback.version }
    return @($profiles | Where-Object version -eq $version)[0]
}

function Test-DuneSoloRuntimeStartupFailure([string]$Log) {
    # Optional scans and individual mod errors are not runtime startup failures.
    return $Log -notmatch 'Event loop start' -and $Log -match '(?im)(UE4SS.*(?:initialization failed|fatal error)|(?:fatal error|failed to initialize).*UE4SS)'
}

function Set-DuneSoloLaunchRuntime($State,[bool]$WithMods) {
    $selected=if($WithMods){$State.mods}else{@($State.mods | Where-Object id -eq 'dst-regis-tanks')}
    $profile=Get-DuneSoloRuntimeProfile $selected -TankOnly:(-not $WithMods)
    $State.runtimeVersion=$profile.version
    $State.runtimePath=Join-Path $script:DuneSoloLoaderRoot $profile.folder
    $State.runtimeReady=Test-DuneSoloModRuntime -Path $State.runtimePath
    return $profile
}

function Install-DuneRegisTanksMod {
    Assert-DuneSoloGameClosed
    $source=Join-Path $script:DuneBundledSoloModsRoot 'dst-regis-tanks'
    $destination=Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks'
    if(-not(Test-Path -LiteralPath (Join-Path $source 'Scripts\main.lua'))){throw 'Bundled Regis Tanks mod is missing. Reinstall DST.'}
    if(Test-Path -LiteralPath $destination){throw 'Regis Tanks is already installed. Existing files were preserved.'}
    New-Item -ItemType Directory -Path $script:DuneSoloModsRoot -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -ErrorAction Stop
    return Get-DuneSoloMods
}

function Set-DuneRegisTanksLaunchContext([string]$GamePath,[string]$Platform) {
    if (-not (Test-DuneSoloRegisTankBuild -GamePath $GamePath -Platform $Platform)) { throw 'Select a Steam or Xbox PC Dune installation before launching Tanks.' }
    $context=Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks\Scripts\dst-launch-platform.txt'
    [IO.File]::WriteAllText($context,$Platform,[Text.UTF8Encoding]::new($false))
}

function Test-DuneSoloRegisTankBuild([string]$GamePath, [string]$Platform) {
    if ($Platform -notin @('steam','xbox') -or -not $GamePath) { return $false }
    $target = if ($Platform -eq 'xbox') { 'WinGDK' } else { 'Win64' }
    $exe = Join-Path $GamePath ('DuneSandbox\Binaries\'+$target+'\DuneSandbox-'+$target+'-Shipping.exe')
    # Tank compatibility is checked against reflected game contracts in Lua,
    # before any changes or spawn. Storefront identity is not a compatibility test.
    return Test-Path -LiteralPath $exe -PathType Leaf
}

function Enable-DuneSoloRegisTanks {
    param([bool]$WithMods=$true)
    Assert-DuneSoloGameClosed
    $state = Get-DuneSoloMods
    if (-not (Test-DuneSoloRegisTankBuild -GamePath $state.gamePath -Platform $state.platform)) { throw 'Select your Steam or Xbox PC game folder in Solo mods first.' }
    $profile=Set-DuneSoloLaunchRuntime $state $WithMods
    if (-not $state.runtimeReady) { Install-DuneSoloModRuntime -Profile $profile | Out-Null }
    if (-not @($state.mods | Where-Object id -eq 'dst-regis-tanks').Count) { Install-DuneRegisTanksMod | Out-Null }
    # Built-in support follows the installed DST version. Optional user mods
    # and custom settings are not replaced.
    $tankScript = Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks\Scripts\main.lua'
    if ((Get-Item -LiteralPath $tankScript).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Built-in Tank script cannot be a linked file.'}
    Copy-Item -LiteralPath (Join-Path $script:DuneBundledSoloModsRoot 'dst-regis-tanks\Scripts\main.lua') -Destination $tankScript -Force
    $state = Get-DuneSoloMods
    $mods = @($state.mods | ForEach-Object {
        @{folder=$_.folder;enabled=if($_.id -eq 'dst-regis-tanks'){$true}elseif($_.id -in @('dst-regis-tanks-trial','dst-regis-tanks-dart-trial','dst-regis-tanks-persistence-trial','dst-regis-tanks-fire-persistence-trial','dst-regis-tanks-probe')){$false}else{[bool]$_.enabled}}
    })
    return Set-DuneSoloModSelection @{mods=$mods;platform=$state.platform;gamePath=$state.gamePath}
}

function Read-DuneModJson([string]$Path, $Default) {
    if (Test-Path -LiteralPath $Path) { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    return $Default
}

function Expand-DuneModZip([string]$Path, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $prefix = [IO.Path]::GetFullPath($Destination).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        $total = [long]0
        if ($archive.Entries.Count -gt 20000) { throw 'ZIP contains too many files.' }
        foreach ($entry in $archive.Entries) {
            $total += $entry.Length
            if ($total -gt 2GB) { throw 'ZIP expands beyond the 2 GB import limit.' }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':')) { throw 'ZIP contains an unsafe file path.' }
            if (($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) { throw 'ZIP symbolic links are unsupported.' }
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($Path, $Destination)
    } finally { $archive.Dispose() }
}

function Resolve-DuneSoloXboxPackageFolder([string]$Path) {
    $folder=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($folder -and $folder.LinkType -eq 'Junction') {
        $target=[string](@($folder.Target)[0])
        if ($target -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath (Join-Path $target 'DuneSandbox\Binaries\WinGDK\DuneSandbox-WinGDK-Shipping.exe') -PathType Leaf)) {
            return $target.TrimEnd('\')
        }
    }
    return $Path
}

function Find-DuneSoloXboxInstallation {
    foreach ($package in @(Get-AppxPackage -Name FuncomOsloAS.ProjectSeabass -ErrorAction SilentlyContinue | Sort-Object Version -Descending)) {
        $root = [string]$package.InstallLocation
        if ($root -and (Test-Path -LiteralPath (Join-Path $root 'DuneSandbox\Binaries\WinGDK\DuneSandbox-WinGDK-Shipping.exe'))) { return Resolve-DuneSoloXboxPackageFolder $root }
    }
    return ''
}

function Test-DuneSoloModRuntime {
    param([string]$Path = (Join-Path $script:DuneSoloLoaderRoot 'Runtime'))
    foreach ($relative in @('dwmapi.dll','ue4ss\UE4SS.dll','ue4ss\UE4SS-settings.ini')) {
        $file = Join-Path $Path $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -le 0) { return $false }
    }
    return $true
}

function Get-DuneSoloMods {
    $gameRunning = $false
    if (Get-Command Get-DuneSoloGameProcesses -ErrorAction SilentlyContinue) { $gameRunning = @((Get-DuneSoloGameProcesses)).Count -gt 0 }
    $state = Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'selection.json') @{}
    $mods = @()
    if (Test-Path -LiteralPath $script:DuneSoloModsRoot) {
        foreach ($folder in Get-ChildItem -LiteralPath $script:DuneSoloModsRoot -Directory | Sort-Object Name) {
            try {
                $meta = Read-DuneModJson (Join-Path $folder.FullName 'mod.json') @{}
                $enabled = $false
                if ($state.PSObject.Properties.Name -contains $folder.Name) { $enabled = [bool]$state.($folder.Name) }
                $mods += [pscustomobject]@{ folder=$folder.Name; id=$(if($meta.id){[string]$meta.id}else{$folder.Name}); name=$(if($meta.name){[string]$meta.name}else{$folder.Name}); version=[string]$meta.version; enabled=$enabled; requires=@($meta.requires); loadAfter=@($meta.loadAfter); loadBefore=@($meta.loadBefore); conflicts=@($meta.conflicts); warnings=@($meta.warnings | Where-Object { $_ }); errors=@() }
            } catch { $mods += [pscustomobject]@{folder=$folder.Name;id=$folder.Name;name=$folder.Name;version='';enabled=$false;requires=@();loadAfter=@();loadBefore=@();conflicts=@();warnings=@();errors=@('Invalid mod.json: '+$_.Exception.Message)} }
        }
    }
    # PS5 emits a JSON array as one pipeline object; assign before normalizing.
    $savedOrder = Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'order.json') @()
    $savedOrder = @($savedOrder)
    $positions = @{}
    for ($i = 0; $i -lt $savedOrder.Count; $i++) { $positions[[string]$savedOrder[$i]] = $i }
    $mods = @($mods | Sort-Object @{Expression={if ($positions.ContainsKey($_.folder)) { $positions[$_.folder] } else { [int]::MaxValue }}}, folder)
    foreach ($mod in $mods) {
        if (-not $mod.enabled) { continue }
        foreach ($req in $mod.requires) {
            if (-not $req) { continue }
            if($req.optional){continue}
            $id = if($req -is [string]){$req}else{[string]$req.id}
            if ($id -in @('ue4ss','wps-launcher')) { continue }
            $found = @($mods | Where-Object { $_.id -eq $id -and $_.enabled })
            if ($found.Count -ne 1) { $mod.errors += "Missing or disabled dependency: $id"; continue }
            if($req.version -and $found[0].version -ne $req.version){$mod.errors += "Requires $id version $($req.version)"}
            if($req.maxVersion){
                try { if([version]$found[0].version -gt [version]$req.maxVersion){$mod.errors += "Requires $id <= $($req.maxVersion)"} }
                catch { $mod.errors += "Cannot verify required maximum version for $id" }
            }
            if ($req.minVersion) {
                try { if ([version]$found[0].version -lt [version]$req.minVersion) { $mod.errors += "Requires $id >= $($req.minVersion)" } }
                catch { $mod.errors += "Cannot verify required version for $id" }
            }
        }
        foreach ($id in $mod.conflicts) { if (@($mods | Where-Object { $_.enabled -and $_.id -eq $id }).Count) { $mod.errors += "Declared conflict: $id" } }
        if (@($mods | Where-Object id -eq $mod.id).Count -gt 1) { $mod.errors += "Duplicate mod ID: $($mod.id)" }
    }
    $settings = Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'settings.json') @{}
    $session = Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'session.json') $null
    $launchErrorPath=Join-Path $script:DuneSoloLoaderRoot 'launch-error.txt'
    $launchError=if(Test-Path $launchErrorPath){Get-Content $launchErrorPath -Raw}else{''}
    $logPath=Join-Path $script:DuneSoloLoaderRoot 'last-runtime.log'
    if($session -and $session.logPath -and (Test-Path $session.logPath)){$logPath=$session.logPath}
    $runtimeLog=if(Test-Path $logPath){(Get-Content $logPath -Tail 80) -join "`n"}else{''}
    $preferences=Get-DuneGameLaunchPreferences
    $platform = if ($settings.platform -eq 'xbox') { 'xbox' } else { 'steam' }
    $gamePath = [string]$settings.gamePath
    if ($platform -eq 'xbox' -and $gamePath.StartsWith((Join-Path $env:ProgramFiles 'WindowsApps')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        $gamePath=Resolve-DuneSoloXboxPackageFolder $gamePath
    }
    if ($platform -eq 'xbox' -and (-not $gamePath -or -not (Test-Path -LiteralPath (Join-Path $gamePath 'DuneSandbox\Binaries\WinGDK\DuneSandbox-WinGDK-Shipping.exe') -PathType Leaf))) {
        $detected = Find-DuneSoloXboxInstallation
        if ($detected) { $gamePath = $detected }
    }
    $profile=Get-DuneSoloRuntimeProfile $mods
    $runtimePath=Join-Path $script:DuneSoloLoaderRoot $profile.folder
    $choice=Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'runtime-choice.json') @{}
    $fallback=Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'runtime-fallback.json') @{}
    $useNewer=if($null -ne $choice.useNewerRuntime){[bool]$choice.useNewerRuntime}else{$profile.folder -eq 'Runtime'}
    $preference=if($choice.version){[string]$choice.version}elseif($useNewer){'3.0.1-1164-g5e627997'}else{'3.0.1-1140-gf58e8f84'}
    $runtimeWarnings=@(foreach($mod in @($mods | Where-Object enabled)){foreach($req in @($mod.requires)){if($req.id -eq 'ue4ss' -and $req.version -and $req.version -ne $profile.version){"$($mod.name) declares UE4SS $($req.version); selected runtime is $($profile.version)."}}})
    return @{ runtimeVersions=@(Get-DuneSoloRuntimeProfiles | ForEach-Object {@{version=$_.version;label=$_.label}});runtimePreferenceVersion=$preference;useNewerRuntime=$useNewer;runtimeFallback=($fallback.version -eq '3.0.1-1140-gf58e8f84');runtimeWarnings=$runtimeWarnings;runtimeVersion=$profile.version;runtimePath=$runtimePath;platform=$platform; gameRunning=$gameRunning; mods=$mods; folder=$script:DuneSoloModsRoot; gamePath=$gamePath; skipIntro=[bool]$preferences.skipIntro; soloArguments=[string]$preferences.soloArguments; runtimeReady=(Test-DuneSoloModRuntime -Path $runtimePath); session=$session; launchError=$launchError; runtimeLog=$runtimeLog }
}

function Get-DuneSoloRuntimeLog {
    $loader=[IO.Path]::GetFullPath($script:DuneSoloLoaderRoot)
    $path=Join-Path $loader 'last-runtime.log'
    $session=Read-DuneModJson (Join-Path $loader 'session.json') $null
    if ($session -and $session.root) {
        $root=[IO.Path]::GetFullPath([string]$session.root)
        if ([IO.Path]::GetDirectoryName($root) -ne $loader -or [IO.Path]::GetFileName($root) -notlike 'Session-*') { throw 'Invalid Solo log session.' }
        foreach($dir in @($root,(Join-Path $root 'ue4ss'))) {
            if ((Test-Path -LiteralPath $dir) -and ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid Solo log folder.' }
        }
        $current=Join-Path $root 'ue4ss\UE4SS.log'
        if (Test-Path -LiteralPath $current -PathType Leaf) { $path=$current }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{available=$false;content='';name='UE4SS.log'} }
    $file=Get-Item -LiteralPath $path
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Invalid Solo log file.' }
    if ($file.Length -gt 16MB) { throw "The UE4SS log is too large to display. File: $path" }
    return @{available=$true;content=[IO.File]::ReadAllText($path);name='UE4SS.log'}
}

function Open-DuneSoloModsFolder {
    param([switch]$Desktop)
    $path = [IO.Path]::GetFullPath($script:DuneSoloModsRoot)
    New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    if (-not $Desktop) {
        if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
            throw "Open Mods Folder requires the DST desktop window when the backend runs as a service. Folder: $path"
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+$path+'"') -ErrorAction Stop | Out-Null
    }
    return @{ok=$true;path=$path}
}

function Set-DuneSoloModPlatform([string]$Platform, [string]$GamePath='') {
    $settings = Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'settings.json') @{}
    $platform = if ($Platform) { $Platform } elseif ($settings.platform) { [string]$settings.platform } else { 'steam' }
    if ($platform -notin @('steam','xbox')) { throw 'Choose Steam or Xbox PC.' }
    $oldPlatform = if ($settings.platform -eq 'xbox') { 'xbox' } else { 'steam' }
    $paths = @{ steam=[string]$settings.steamPath; xbox=[string]$settings.xboxPath }
    if ($settings.gamePath) { $paths[$oldPlatform] = [string]$settings.gamePath }
    $path = $GamePath
    if (-not $PSBoundParameters.ContainsKey('GamePath') -and $platform -eq $oldPlatform) { $path = [string]$settings.gamePath }
    if ($platform -ne $oldPlatform -and -not $path) { $path = $paths[$platform] }
    $paths[$platform] = $path
    New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
    @{ gamePath=$path; platform=$platform; steamPath=$paths.steam; xboxPath=$paths.xbox } | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'settings.json') -Encoding utf8
}

function Set-DuneSoloModSelection($Body) {
    Assert-DuneSoloGameClosed
    if ($Body.runtimeVersion -and @((Get-DuneSoloRuntimeProfiles) | Where-Object version -eq $Body.runtimeVersion).Count -ne 1) {throw 'Select a bundled UE4SS runtime.'}
    Set-DuneSoloModPlatform -Platform ([string]$Body.platform) -GamePath ([string]$Body.gamePath)
    if ($Body.runtimeVersion -or $null -ne $Body.useNewerRuntime) {
        $version=if($Body.runtimeVersion){[string]$Body.runtimeVersion}elseif($Body.useNewerRuntime){'3.0.1-1164-g5e627997'}else{'3.0.1-1140-gf58e8f84'}
        @{version=$version;useNewerRuntime=($version -ne '3.0.1-1140-gf58e8f84')} | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'runtime-choice.json') -Encoding utf8
        $fallbackPath=Join-Path $script:DuneSoloLoaderRoot 'runtime-fallback.json'
        if(Test-Path -LiteralPath $fallbackPath){Remove-Item -LiteralPath $fallbackPath}
    }
    $state = @{}
    foreach ($item in @($Body.mods)) { $state[[string]$item.folder] = [bool]$item.enabled }
    ConvertTo-Json -InputObject @($Body.mods | ForEach-Object { [string]$_.folder }) | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'order.json') -Encoding utf8
    $state | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'selection.json') -Encoding utf8
    return Get-DuneSoloMods
}

function Import-DuneSoloMod {
    param([string]$Path, [switch]$CheckOverwrite, [switch]$Overwrite, [string]$ExpectedHash)
    Assert-DuneSoloGameClosed
    if ([IO.Path]::GetExtension($Path) -ne '.zip') { throw 'Select a mod ZIP.' }
    $archiveHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($Overwrite -and ($ExpectedHash -cne $archiveHash)) { throw 'The mod ZIP changed. Import it again and review the overwrite confirmation.' }
    $modsRoot = [IO.Path]::GetFullPath($script:DuneSoloModsRoot).TrimEnd('\','/')
    $loaderRoot = [IO.Path]::GetFullPath($script:DuneSoloLoaderRoot).TrimEnd('\','/')
    New-Item -ItemType Directory -Path $script:DuneSoloModsRoot -Force | Out-Null
    $stage = [IO.Path]::GetFullPath((Join-Path $loaderRoot ('Import-'+[guid]::NewGuid().ToString('N'))))
    if ([IO.Path]::GetDirectoryName($stage) -ine $loaderRoot) { throw 'Invalid mod import staging location.' }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $keepStage=$false
    try {
        $package = Join-Path $stage 'Package'
        New-Item -ItemType Directory -Path $package | Out-Null
        Expand-DuneModZip $Path $package
        $roots = @(Get-ChildItem -LiteralPath $package -Directory -Recurse | Where-Object { (Test-Path (Join-Path $_.FullName 'Scripts\main.lua')) -or (Test-Path (Join-Path $_.FullName 'dlls\main.dll')) -or (Test-Path (Join-Path $_.FullName 'mod.json')) })
        if ((Test-Path (Join-Path $package 'Scripts\main.lua')) -or (Test-Path (Join-Path $package 'mod.json')) -or (Test-Path (Join-Path $package 'dlls\main.dll'))) { $roots = @((Get-Item $package)) }
        $roots = @($roots | Where-Object { $candidate=$_.FullName; -not @($roots | Where-Object { $candidate.StartsWith($_.FullName+'\',[StringComparison]::OrdinalIgnoreCase) }).Count })
        if (-not $roots.Count) { throw 'No supported mod folder found. Expected mod.json, Scripts/main.lua, or dlls/main.dll.' }
        $plans = @()
        foreach ($root in $roots) {
            $meta = Read-DuneModJson (Join-Path $root.FullName 'mod.json') @{}
            $name = if($meta.id){[string]$meta.id}elseif($root.FullName -eq $package){[IO.Path]::GetFileNameWithoutExtension($Path)}else{$root.Name}
            if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_. -]{0,100}$' -or $name.EndsWith('.') -or $name.EndsWith(' ')) { throw 'Mod has an unsupported folder identifier.' }
            $dest = [IO.Path]::GetFullPath((Join-Path $modsRoot $name))
            if ([IO.Path]::GetDirectoryName($dest) -ine $modsRoot) { throw 'Invalid mod destination.' }
            if (Test-Path -LiteralPath $dest) {
                $linked = @((Get-Item -LiteralPath $dest -Force)) + @(Get-ChildItem -LiteralPath $dest -Recurse -Force)
                if (@($linked | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Cannot replace a mod containing linked files or folders.' }
                if (-not $Overwrite -and -not $CheckOverwrite) { throw "Already installed: $name. Existing files and INIs were preserved." }
            }
            if (@($plans | Where-Object destination -eq $dest).Count) { throw 'ZIP contains duplicate mod IDs.' }
            $plans += @{source=$root.FullName;destination=$dest;name=$name;backup=''}
        }
        $existing = @($plans | Where-Object { Test-Path -LiteralPath $_.destination } | ForEach-Object { $_.name })
        if ($existing.Count -and -not $Overwrite) { return @{overwriteRequired=$true;mods=$existing;archiveHash=$archiveHash} }
        $installed=@()
        try {
            foreach($plan in $plans){
                if(Test-Path -LiteralPath $plan.destination){
                    $backup=Join-Path $stage ('Previous-'+[guid]::NewGuid().ToString('N'))
                    Move-Item -LiteralPath $plan.destination -Destination $backup -ErrorAction Stop
                    $plan.backup=$backup
                }
                $installed += $plan
                Copy-Item -LiteralPath $plan.source -Destination $plan.destination -Recurse -ErrorAction Stop
            }
        } catch {
            $failure=$_
            try {
                foreach($plan in $installed){
                    if(Test-Path -LiteralPath $plan.destination){Remove-Item -LiteralPath $plan.destination -Recurse -Force -ErrorAction Stop}
                    if($plan.backup){Move-Item -LiteralPath $plan.backup -Destination $plan.destination -ErrorAction Stop}
                }
            } catch { $keepStage=$true; throw "Mod import recovery could not finish. Original files remain in $stage. $($_.Exception.Message)" }
            throw $failure
        }
        return Get-DuneSoloMods
    } finally { if(-not $keepStage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force} }
}

function Install-DuneSoloModRuntime {
    param($Profile=$null)
    Assert-DuneSoloGameClosed
    $root=[IO.Path]::GetFullPath($script:DuneSoloLoaderRoot).TrimEnd('\','/')
    $profile=if($Profile){$Profile}else{Get-DuneSoloRuntimeProfile (Get-DuneSoloMods).mods}
    $runtime = Join-Path $root $profile.folder
    $zip=Join-Path $script:DuneSoloRuntimeAssets $profile.archive
    $configs=Join-Path $script:DuneSoloRuntimeAssets 'configs.zip'
    if(-not (Test-Path -LiteralPath $zip) -or -not (Test-Path -LiteralPath $configs)){throw 'Bundled mod runtime is missing. Reinstall DST to restore it.'}
    if((Get-FileHash -LiteralPath $zip).Hash -ne $profile.hash){throw 'Bundled mod runtime checksum mismatch. Reinstall DST to restore it.'}
    if((Get-FileHash -LiteralPath $configs).Hash -ne '1B2420B7DEB237CD680D27306EADF26628699D992A322C89A963D80F580C9B78'){throw 'Bundled Dune configuration checksum mismatch. Reinstall DST to restore it.'}
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $stage=Join-Path $root ('Runtime-'+[guid]::NewGuid().ToString('N'))
    $configStage=Join-Path $root ('Configs-'+[guid]::NewGuid().ToString('N'))
    $previous = Join-Path $root ('Runtime-before-repair-'+[guid]::NewGuid().ToString('N'))
    foreach ($target in @($runtime,$stage,$configStage,$previous)) {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($target)) -cne $root) { throw 'Runtime staging path is outside the loader directory.' }
    }
    $replaced = $false
    try {
        Expand-DuneModZip $zip $stage
        Expand-DuneModZip $configs $configStage
        Copy-Item (Join-Path $configStage 'DuneAwakening\*.ini') (Join-Path $stage 'ue4ss') -Force -ErrorAction Stop
        if (-not (Test-DuneSoloModRuntime -Path $stage)) { throw 'Bundled mod runtime extraction is incomplete; existing runtime was preserved.' }
        if (Test-Path -LiteralPath $runtime) {
            if ((Get-Item -LiteralPath $runtime).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Runtime directory cannot be a linked directory.' }
            Move-Item -LiteralPath $runtime -Destination $previous -ErrorAction Stop
            $replaced = $true
        }
        try { Move-Item -LiteralPath $stage -Destination $runtime -ErrorAction Stop }
        catch {
            if ($replaced) { Move-Item -LiteralPath $previous -Destination $runtime -ErrorAction Stop }
            throw
        }
    } finally {
        foreach($temporary in @($stage,$configStage)){if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
    }
    return Get-DuneSoloMods
}

function Start-DuneSoloModGame([bool]$WithMods) {
    Assert-DuneSoloGameClosed
    $status=Get-DuneSoloMods
    Assert-DuneSoloLaunchArguments $status.soloArguments
    if($status.session){
        Restore-DuneSoloModSession
        $status=Get-DuneSoloMods
        if($status.session){throw 'The previous mod session could not be restored automatically.'}
    }
    if([string]::IsNullOrWhiteSpace($status.gamePath)){throw 'Select the Dune Awakening installation folder in Solo mods and save it before launching.'}
    $target = if ($status.platform -eq 'xbox') { 'WinGDK' } else { 'Win64' }
    $bin=Join-Path $status.gamePath ('DuneSandbox\Binaries\'+$target)
    $exe=Join-Path $bin ('DuneSandbox-'+$target+'-Shipping.exe')
    if(-not(Test-Path -LiteralPath $exe)){throw 'Select the Dune Awakening installation folder.'}
    $tankSupport = Test-DuneSoloRegisTankBuild -GamePath $status.gamePath -Platform $status.platform
    if ($tankSupport) { $status = Enable-DuneSoloRegisTanks -WithMods $WithMods }
    $null=Set-DuneSoloLaunchRuntime $status $WithMods
    if(-not $WithMods -and -not $tankSupport){Start-Process -FilePath $exe -WorkingDirectory $bin -ArgumentList (Get-DuneSoloLaunchArguments -SkipIntro $status.skipIntro -ExtraArguments $status.soloArguments);return @{ok=$true}}
    if(-not $status.runtimeReady){throw 'Install the mod runtime first.'}
    $selected=@($status.mods | Where-Object { $_.enabled -and (($WithMods -and $_.id -ne 'dst-regis-tanks') -or ($tankSupport -and $_.id -eq 'dst-regis-tanks')) })
    if(-not $selected.Count){throw 'Enable at least one mod.'}
    $errors=@($selected | ForEach-Object {$name=$_.name; $_.errors | ForEach-Object {"${name}: $_"}})
    if($errors.Count){throw ($errors -join "`n")}
    if (@($selected | Where-Object { $_.id -eq 'dst-solo-live-map' }).Count) {
        if ($status.platform -ne 'steam') { throw 'Solo Live Map currently supports Steam Solo.' }
        if (@($selected | Where-Object { $_.id -eq 'dst-solo-live-map' -and $_.folder -ne 'dst-solo-live-map' }).Count) { throw 'Solo Live Map must use its bundled folder identifier.' }
        Start-DuneSoloLiveMapCompanion
    }
    foreach($mod in $selected){
        $folder=Join-Path $script:DuneSoloModsRoot $mod.folder
        if($mod.id -eq 'dst-regis-tanks'){
            if($mod.folder -ne 'dst-regis-tanks'){throw 'Regis Tanks must use its bundled folder identifier.'}
            Set-DuneRegisTanksLaunchContext -GamePath $status.gamePath -Platform $status.platform
        }
        if(-not(Test-Path (Join-Path $folder 'Scripts\main.lua')) -and -not(Test-Path (Join-Path $folder 'dlls\main.dll'))){throw "$($mod.name): this runtime supports Lua and UE4SS native mods. This package has no loadable entry point."}
    }
    # Respect the user's saved load order; authors and users manage ordering requirements.
    $ordered = @($selected)
    $sessionRoot=Join-Path $script:DuneSoloLoaderRoot ('Session-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
    $runtime=Join-Path $sessionRoot 'ue4ss'
    if ($tankSupport) {
        [IO.File]::WriteAllText((Join-Path $script:DuneSoloModsRoot 'dst-regis-tanks\Scripts\dst-command-root.txt'), $sessionRoot, [Text.UTF8Encoding]::new($false))
    }
    Copy-Item (Join-Path $status.runtimePath 'ue4ss') $runtime -Recurse
    $ini=Join-Path $runtime 'UE4SS-settings.ini'
    $text=Get-Content $ini -Raw
    $text=[regex]::Replace($text,'(?m)^ModsFolderPath\s*=.*$',('ModsFolderPath = '+$script:DuneSoloModsRoot))
    $modsTxt=Join-Path $sessionRoot 'mods.txt'
    $text=[regex]::Replace($text,'(?m)^ControllingModsTxt\s*=.*$',('ControllingModsTxt = '+$modsTxt))
    [IO.File]::WriteAllText($ini, $text, [Text.UTF8Encoding]::new($false))
    Write-DuneSoloModLoadList -Path $modsTxt -Mods $ordered
    $records=@()
    foreach($file in @('dwmapi.dll','UE4SS.dll')){
        $dest=Join-Path $bin $file
        $backup=Join-Path $sessionRoot ($file+'.original')
        if(Test-Path $dest){Copy-Item -LiteralPath $dest -Destination $backup}
        $source=if($file -eq 'dwmapi.dll'){Join-Path $status.runtimePath 'dwmapi.dll'}else{Join-Path $runtime 'UE4SS.dll'}
        $records += @{path=$dest;backup=$backup;hash=(Get-FileHash $source).Hash;installed=$false;restored=$false}
    }
    # Some mods discover their peers through the launcher layout rather than
    # UE4SS's ControllingModsTxt. Publish the same actual session selection at
    # both established paths without changing the controlling load order.
    $compatList = Join-Path $sessionRoot 'active-mods.txt'
    $compatMods = @($status.mods | ForEach-Object { @{folder=$_.folder;enabled=($ordered.folder -ccontains $_.folder)} })
    Write-DuneSoloModLoadList -Path $compatList -Mods $compatMods -IncludeDisabled
    $stateRoot = Join-Path (Split-Path -Parent $script:DuneSoloModsRoot) 'State'
    foreach ($dest in @((Join-Path $script:DuneSoloModsRoot 'mods.txt'), (Join-Path $stateRoot 'active-mods.txt'))) {
        $parent = Split-Path -Parent $dest
        if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Mod-list compatibility path cannot be a linked directory.'}
        if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Mod-list compatibility file cannot be a linked file.'}
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $backup = Join-Path $sessionRoot ('mod-list-'+$records.Count+'.original')
        if (Test-Path -LiteralPath $dest) {Copy-Item -LiteralPath $dest -Destination $backup}
        $records += @{path=$dest;backup=$backup;source=$compatList;hash=(Get-FileHash -LiteralPath $compatList).Hash;installed=$false;restored=$false}
    }
    $session=@{runtimeVersion=$status.runtimeVersion;files=$records;root=$sessionRoot;tankSupport=$tankSupport;state='prepared';logPath=(Join-Path $runtime 'UE4SS.log');soloArguments=$status.soloArguments}
    $session | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'session.json') -Encoding utf8
    try {
        foreach($record in $records){
            $source=if($record.source){$record.source}elseif($record.path.EndsWith('dwmapi.dll')){Join-Path $status.runtimePath 'dwmapi.dll'}else{Join-Path $runtime 'UE4SS.dll'}
            # Journal intent before writing so an interrupted copy remains recoverable.
            $record.installed=$true
            $session | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'session.json') -Encoding utf8
            Copy-Item -LiteralPath $source -Destination $record.path -Force
        }
        $watcher=Join-Path $PSScriptRoot 'SoloModsWatcher.ps1'
        $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $watchArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$watcher+'"'),'-LoaderRoot',('"'+$script:DuneSoloLoaderRoot+'"'),'-GameExe',('"'+$exe+'"'),'-RuntimeDll',('"'+(Join-Path $runtime 'UE4SS.dll')+'"'))
        if($status.skipIntro){$watchArgs+='-SkipIntro'}
        Remove-Item -LiteralPath (Join-Path $script:DuneSoloLoaderRoot 'launch-error.txt') -ErrorAction SilentlyContinue
        Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $watchArgs -ErrorAction Stop
        return @{ok=$true}
    } catch { Restore-DuneSoloModSession;throw }
}

function Get-DuneSoloTankStatus {
    $ready=$false
    try {
        $session=Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'session.json') $null
        if($session -and $session.tankSupport -and $session.root -and @(Get-Process -Name DuneSandbox-Win64-Shipping,DuneSandbox-WinGDK-Shipping,AppDuneAwakeningShipping -ErrorAction SilentlyContinue).Count -gt 0){
            $root=[IO.Path]::GetFullPath([string]$session.root)
            if([IO.Path]::GetDirectoryName($root) -eq [IO.Path]::GetFullPath($script:DuneSoloLoaderRoot).TrimEnd('\','/') -and -not ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)){
                $file=Get-Item -LiteralPath (Join-Path $root 'tank-world-ready.txt') -ErrorAction SilentlyContinue
                if($file -and $file.Length -le 16 -and -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){
                    $age=([DateTime]::UtcNow-$file.LastWriteTimeUtc).TotalSeconds
                    $ready=($age -ge 0 -and $age -le 4 -and [IO.File]::ReadAllText($file.FullName) -ceq 'ready')
                }
            }
        }
    } catch { $ready=$false }
    return @{worldReady=$ready}
}

function Grant-DuneSoloRegisTank([string]$Preset) {
    if ($Preset -cnotin @('T6_CombatDart','T6_CombatFire')) {throw 'Select Dart or Flamethrower Tank.'}
    if(-not (Get-DuneSoloTankStatus).worldReady){throw 'Enter your Solo world before granting a Tank.'}
    $session = Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'session.json') $null
    if (-not $session -or -not $session.tankSupport) {throw 'Launch supported Solo through DST before granting a Tank.'}
    $root = [IO.Path]::GetFullPath([string]$session.root)
    if ([IO.Path]::GetDirectoryName($root) -ne [IO.Path]::GetFullPath($script:DuneSoloLoaderRoot).TrimEnd('\','/') -or
        (Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Solo session command path is invalid.'}
    $request = Join-Path $root 'tank-request.txt'
    $response = Join-Path $root 'tank-response.txt'
    if (Test-Path -LiteralPath $request) {throw 'A Tank grant is awaiting the game. Check the game before trying again.'}
    $id = [guid]::NewGuid().ToString('N')
    $temp = Join-Path $root ($id+'.tmp')
    try {
        [IO.File]::WriteAllText($temp, "$id|$Preset", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $request -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            if (Test-Path -LiteralPath $response) {
                $result = [IO.File]::ReadAllText($response).Split('|',3)
                if ($result.Count -eq 3 -and $result[0] -ceq $id) {
                    if ($result[1] -cne 'ok') {throw $result[2]}
                    return @{ok=$true;message='Tank grant sent to the Solo world. Check the open ground near your character.'}
                }
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'The game has not confirmed the grant. Enter your Solo world and check before trying again.'
    } finally {if (Test-Path -LiteralPath $temp) {Remove-Item -LiteralPath $temp -Force}}
}

function Get-DuneSoloLaunchArguments([switch]$SkipIntro, [string]$RuntimeDll='', [string]$ExtraArguments='') {
    Assert-DuneSoloLaunchArguments $ExtraArguments
    $arguments=@('-nobattleye')
    if($RuntimeDll){$arguments+=@('--ue4ss-path',('"'+$RuntimeDll+'"'))}else{$arguments+='--disable-ue4ss'}
    if($SkipIntro){$arguments+=@('-nosplash','-nostartupscreen')}
    if($ExtraArguments.Trim()){$arguments+=$ExtraArguments.Trim()}
    return $arguments
}

function Assert-DuneSoloLaunchArguments([string]$Arguments) {
    if($Arguments.Length -gt 8192 -or $Arguments -match '[\x00-\x1F]') { throw 'Launch arguments must be a single line of up to 8192 characters.' }
}

function Restore-DuneSoloModSession {
    Assert-DuneSoloGameClosed
    & (Join-Path $PSScriptRoot 'SoloModsWatcher.ps1') -LoaderRoot $script:DuneSoloLoaderRoot -RestoreOnly
    Remove-Item -LiteralPath (Join-Path $script:DuneSoloLoaderRoot 'launch-error.txt') -ErrorAction SilentlyContinue
    return Get-DuneSoloMods
}

function Get-DuneGameLaunchPreferences {
    return Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'launch-preferences.json') @{skipIntro=$false;soloArguments=''}
}
function Set-DuneGameLaunchPreferences($Body) {
    $current=Get-DuneGameLaunchPreferences
    $skipIntro=[bool]$current.skipIntro
    $soloArguments=[string]$current.soloArguments
    if($Body.Contains('skipIntro')){$skipIntro=[bool]$Body.skipIntro}
    if($Body.Contains('soloArguments')){$soloArguments=[string]$Body.soloArguments}
    Assert-DuneSoloLaunchArguments $soloArguments
    New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
    @{skipIntro=$skipIntro;soloArguments=$soloArguments} | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'launch-preferences.json') -Encoding utf8
    return Get-DuneGameLaunchPreferences
}

function Write-DuneSoloModLoadList([string]$Path, $Mods, [switch]$IncludeDisabled) {
    # UE4SS treats a UTF-8 BOM as part of the first mod name. PS 5.1 UTF8
    # Set-Content adds one, so use an explicit BOM-free encoding on all hosts.
    [string[]]$lines=@($Mods | ForEach-Object {
        $on = if ($IncludeDisabled -and -not $_.enabled) {0} else {1}
        "$($_.folder) : $on"
    })
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Remove-DuneSoloMod([string]$Folder) {
    Assert-DuneSoloGameClosed
    if (-not $Folder -or $Folder -in @('.', '..') -or $Folder.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Folder.Contains('/') -or $Folder.Contains('\')) { throw 'Select a valid installed mod folder.' }
    $root = [IO.Path]::GetFullPath($script:DuneSoloModsRoot).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath((Join-Path $root $Folder))
    if ([IO.Path]::GetDirectoryName($target) -ne $root) { throw 'Mod folder must be inside the Mods directory.' }
    $item = Get-Item -LiteralPath $target -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw 'Select an installed mod folder.' }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @(Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Cannot delete a mod folder containing linked files or directories.' }
    $current = Get-DuneSoloMods
    $remaining = @($current.mods | Where-Object { $_.folder -ne $Folder })
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    return Set-DuneSoloModSelection @{mods=$remaining;gamePath=$current.gamePath}
}

function New-DuneSoloModShortcut {
    $root = if ($script:AppDir) {$script:AppDir} else {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $launcher = Join-Path $PSScriptRoot '../tools/LaunchSoloMods.ps1'
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -LiteralPath $launcher)) { throw 'Desktop or mod launcher is unavailable.' }
    $shell = New-Object -ComObject WScript.Shell
    $path = Join-Path $desktop 'Dune - Launch with mods.lnk'
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launcher + '"'
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = 'Launch Dune with enabled Solo mods and saved launch settings.'
    $shortcut.IconLocation = (Join-Path $root 'assets\solo-mods.ico') + ',0'
    $shortcut.Save()
    return @{ok=$true;path=$path}
}
