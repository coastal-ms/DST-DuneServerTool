$soloModAppRoot = if($script:AppDir){$script:AppDir}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$script:DuneSoloModsRoot = Join-Path $soloModAppRoot 'Mods'
$script:DuneSoloLoaderRoot = Join-Path $soloModAppRoot 'ModLoader'

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
                $mods += [pscustomobject]@{ folder=$folder.Name; id=$(if($meta.id){[string]$meta.id}else{$folder.Name}); name=$(if($meta.name){[string]$meta.name}else{$folder.Name}); version=[string]$meta.version; enabled=$enabled; requires=@($meta.requires); loadAfter=@($meta.loadAfter); loadBefore=@($meta.loadBefore); conflicts=@($meta.conflicts); warnings=@(); errors=@() }
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
    return @{ gameRunning=$gameRunning; mods=$mods; folder=$script:DuneSoloModsRoot; gamePath=[string]$settings.gamePath; skipIntro=[bool](Get-DuneGameLaunchPreferences).skipIntro; runtimeReady=(Test-Path (Join-Path $script:DuneSoloLoaderRoot 'Runtime\ue4ss\UE4SS.dll')); session=$session; launchError=$launchError; runtimeLog=$runtimeLog }
}

function Set-DuneSoloModSelection($Body) {
    Assert-DuneSoloGameClosed
    New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
    $state = @{}
    foreach ($item in @($Body.mods)) { $state[[string]$item.folder] = [bool]$item.enabled }
    ConvertTo-Json -InputObject @($Body.mods | ForEach-Object { [string]$_.folder }) | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'order.json') -Encoding utf8
    $state | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'selection.json') -Encoding utf8
    @{ gamePath=[string]$Body.gamePath } | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'settings.json') -Encoding utf8
    return Get-DuneSoloMods
}

function Import-DuneSoloMod([string]$Path) {
    Assert-DuneSoloGameClosed
    if ([IO.Path]::GetExtension($Path) -ne '.zip') { throw 'Select a mod ZIP.' }
    New-Item -ItemType Directory -Path $script:DuneSoloModsRoot -Force | Out-Null
    $stage = Join-Path $script:DuneSoloLoaderRoot ('Import-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-DuneModZip $Path $stage
        $roots = @(Get-ChildItem -LiteralPath $stage -Directory -Recurse | Where-Object { (Test-Path (Join-Path $_.FullName 'Scripts\main.lua')) -or (Test-Path (Join-Path $_.FullName 'dlls\main.dll')) -or (Test-Path (Join-Path $_.FullName 'mod.json')) })
        if ((Test-Path (Join-Path $stage 'Scripts\main.lua')) -or (Test-Path (Join-Path $stage 'mod.json')) -or (Test-Path (Join-Path $stage 'dlls\main.dll'))) { $roots = @((Get-Item $stage)) }
        $roots = @($roots | Where-Object { $candidate=$_.FullName; -not @($roots | Where-Object { $candidate.StartsWith($_.FullName+'\',[StringComparison]::OrdinalIgnoreCase) }).Count })
        if (-not $roots.Count) { throw 'No supported mod folder found. Expected mod.json, Scripts/main.lua, or dlls/main.dll.' }
        $plans = @()
        foreach ($root in $roots) {
            $meta = Read-DuneModJson (Join-Path $root.FullName 'mod.json') @{}
            $name = if($meta.id){[string]$meta.id}elseif($root.FullName -eq $stage){[IO.Path]::GetFileNameWithoutExtension($Path)}else{$root.Name}
            if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_. -]{0,100}$' -or $name.EndsWith('.') -or $name.EndsWith(' ')) { throw 'Mod has an unsupported folder identifier.' }
            $dest = Join-Path $script:DuneSoloModsRoot $name
            if (Test-Path -LiteralPath $dest) { throw "Already installed: $name. Existing files and INIs were preserved." }
            if (@($plans | Where-Object destination -eq $dest).Count) { throw 'ZIP contains duplicate mod IDs.' }
            $plans += @{source=$root.FullName;destination=$dest}
        }
        $installed=@()
        try { foreach($plan in $plans){ $installed += $plan.destination; Copy-Item -LiteralPath $plan.source -Destination $plan.destination -Recurse -ErrorAction Stop } }
        catch { foreach($dest in $installed){Remove-Item -LiteralPath $dest -Recurse -Force}; throw }
        return Get-DuneSoloMods
    } finally { if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force} }
}

function Install-DuneSoloModRuntime {
    Assert-DuneSoloGameClosed
    $root=$script:DuneSoloLoaderRoot
    if(Test-Path (Join-Path $root 'Runtime')){throw 'Runtime already installed.'}
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $release=Invoke-RestMethod 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest'
    $asset=@($release.assets | Where-Object name -eq 'UE4SS_v3.0.1-1164-g5e627997.zip')
    if($asset.Count -ne 1){throw 'Tested upstream runtime is no longer available. Runtime was not changed.'}
    $zip=Join-Path $root 'runtime.zip'
    Invoke-WebRequest $asset[0].browser_download_url -OutFile $zip
    if((Get-FileHash $zip).Hash -ne '3C72142A383E25E9F9553AC9E4D5677AA572E98CB369CAC57200EFB2E381E603'){throw 'Runtime download checksum mismatch.'}
    $configs=Join-Path $root 'configs.zip'
    $configAsset=$release.assets | Where-Object name -eq 'zCustomGameConfigs.zip'
    Invoke-WebRequest $configAsset.browser_download_url -OutFile $configs
    if((Get-FileHash $configs).Hash -ne '1B2420B7DEB237CD680D27306EADF26628699D992A322C89A963D80F580C9B78'){throw 'Dune configuration checksum mismatch.'}
    $stage=Join-Path $root ('Runtime-'+[guid]::NewGuid().ToString('N'))
    Expand-DuneModZip $zip $stage
    $configStage=Join-Path $root ('Configs-'+[guid]::NewGuid().ToString('N'))
    Expand-DuneModZip $configs $configStage
    Copy-Item (Join-Path $configStage 'DuneAwakening\*.ini') (Join-Path $stage 'ue4ss') -Force
    if(Test-Path (Join-Path $root 'Runtime')){throw 'Runtime already installed.'}
    Move-Item -LiteralPath $stage -Destination (Join-Path $root 'Runtime')
    return Get-DuneSoloMods
}

function Start-DuneSoloModGame([bool]$WithMods) {
    Assert-DuneSoloGameClosed
    $status=Get-DuneSoloMods
    if($status.session){throw 'A previous mod session needs restoration. Use Restore normal launch first.'}
    $bin=Join-Path $status.gamePath 'DuneSandbox\Binaries\Win64'
    $exe=Join-Path $bin 'DuneSandbox-Win64-Shipping.exe'
    if(-not(Test-Path -LiteralPath $exe)){throw 'Select the Dune Awakening installation folder.'}
    if(-not $WithMods){Start-Process -FilePath $exe -WorkingDirectory $bin -ArgumentList (Get-DuneSoloLaunchArguments -SkipIntro $status.skipIntro);return @{ok=$true}}
    if(-not $status.runtimeReady){throw 'Install the mod runtime first.'}
    $selected=@($status.mods | Where-Object enabled)
    if(-not $selected.Count){throw 'Enable at least one mod.'}
    $errors=@($selected | ForEach-Object {$name=$_.name; $_.errors | ForEach-Object {"${name}: $_"}})
    if($errors.Count){throw ($errors -join "`n")}
    foreach($mod in $selected){
        $folder=Join-Path $script:DuneSoloModsRoot $mod.folder
        if(-not(Test-Path (Join-Path $folder 'Scripts\main.lua')) -and -not(Test-Path (Join-Path $folder 'dlls\main.dll'))){throw "$($mod.name): this runtime supports Lua and UE4SS native mods. This package has no loadable entry point."}
    }
    # Respect the user's saved load order; authors and users manage ordering requirements.
    $ordered = @($selected)
    $sessionRoot=Join-Path $script:DuneSoloLoaderRoot ('Session-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
    $runtime=Join-Path $sessionRoot 'ue4ss'
    Copy-Item (Join-Path $script:DuneSoloLoaderRoot 'Runtime\ue4ss') $runtime -Recurse
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
        $source=if($file -eq 'dwmapi.dll'){Join-Path $script:DuneSoloLoaderRoot 'Runtime\dwmapi.dll'}else{Join-Path $runtime 'UE4SS.dll'}
        $records += @{path=$dest;backup=$backup;hash=(Get-FileHash $source).Hash;installed=$false;restored=$false}
    }
    $session=@{files=$records;root=$sessionRoot;state='prepared';logPath=(Join-Path $runtime 'UE4SS.log')}
    $session | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'session.json') -Encoding utf8
    try {
        foreach($record in $records){
            $source=if($record.path.EndsWith('dwmapi.dll')){Join-Path $script:DuneSoloLoaderRoot 'Runtime\dwmapi.dll'}else{Join-Path $runtime 'UE4SS.dll'}
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

function Get-DuneSoloLaunchArguments([switch]$SkipIntro, [string]$RuntimeDll='') {
    $arguments=@('-nobattleye')
    if($RuntimeDll){$arguments+=@('--ue4ss-path',('"'+$RuntimeDll+'"'))}else{$arguments+='--disable-ue4ss'}
    if($SkipIntro){$arguments+=@('-nosplash','-nostartupscreen')}
    return $arguments
}

function Restore-DuneSoloModSession {
    Assert-DuneSoloGameClosed
    & (Join-Path $PSScriptRoot 'SoloModsWatcher.ps1') -LoaderRoot $script:DuneSoloLoaderRoot -RestoreOnly
    return Get-DuneSoloMods
}

function Get-DuneGameLaunchPreferences {
    return Read-DuneModJson (Join-Path $script:DuneSoloLoaderRoot 'launch-preferences.json') @{skipIntro=$false}
}
function Set-DuneGameLaunchPreferences($Body) {
    New-Item -ItemType Directory -Path $script:DuneSoloLoaderRoot -Force | Out-Null
    @{skipIntro=[bool]$Body.skipIntro} | ConvertTo-Json | Set-Content (Join-Path $script:DuneSoloLoaderRoot 'launch-preferences.json') -Encoding utf8
    return Get-DuneGameLaunchPreferences
}

function Write-DuneSoloModLoadList([string]$Path, $Mods) {
    # UE4SS treats a UTF-8 BOM as part of the first mod name. PS 5.1 UTF8
    # Set-Content adds one, so use an explicit BOM-free encoding on all hosts.
    [string[]]$lines=@($Mods | ForEach-Object {"$($_.folder) : 1"})
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
