function Get-DuneRegisTankAppRoot {
    if ($script:AppDir) { return $script:AppDir }
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

function Get-DuneRegisTankCacheRoot {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DuneServer\regis-tanks'
}

function Get-DuneRegisTankRecipe {
    param([ValidateSet('2147284','2156652','2160922','2162777')][string]$Build = '2147284')
    $path = Join-Path (Get-DuneRegisTankAppRoot) "resources\regis-tanks\$Build.json"
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Invoke-DuneRegisTankShell {
    param([string]$Ip, [string]$Script, [int]$TimeoutSec = 120)
    $Script = $Script -replace "`r", ''
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("set -euo pipefail`n$Script`nprintf '\n__DST_REGIS_OK__\n'`n"))
    # ctr utilities inherit stdin. Run the decoded script from a temporary file
    # so a utility cannot consume the remaining commands or success marker.
    $command = 't=$(mktemp); trap ''rm -f "$t"'' EXIT; base64 -d > "$t" && bash "$t" </dev/null 2>&1'
    $raw = (Invoke-V6Ssh -Ip $Ip -Cmd $command -StdinData $payload -TimeoutSec $TimeoutSec) -join "`n"
    if ($raw -notmatch '(?m)^__DST_REGIS_OK__\r?$') { throw "Tank compatibility preparation failed: $($raw.Substring([Math]::Max(0,$raw.Length-1000)))" }
    return ($raw -replace '(?m)^__DST_REGIS_OK__\r?\n?','').Trim()
}

function Send-DuneRegisTankFile {
    param([string]$Ip, [string]$Path, [string]$RemotePath)
    if ($RemotePath -cnotmatch '^/home/dune/\.dst-regis-tanks/build-[a-f0-9]{32}/[a-zA-Z0-9_.-]+$') { throw 'Invalid managed Tank preparation path.' }
    $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $cmd = "base64 -d > '$RemotePath' && printf '%s' __DST_UPLOAD_OK__ && sha256sum '$RemotePath'"
    $result = (Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $encoded -TimeoutSec 120) -join ''
    if ($result -cnotmatch "^__DST_UPLOAD_OK__$hash\s") { throw 'Tank preparation upload verification failed.' }
}

function New-DuneRegisTankServerImage {
    param([string]$Ip, [ValidateSet('2147284','2156652','2160922','2162777')][string]$Build = '2147284')
    $recipe = Get-DuneRegisTankRecipe -Build $Build
    if ($recipe.schema -ne 1 -or $recipe.build -cne $Build -or $recipe.baseImage -cne "registry.funcom.com/funcom/self-hosting/seabass-server:$Build-0-shipping" -or $recipe.baseDigest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $recipe.cleanExecutableSha256 -cnotmatch '^[a-f0-9]{64}$' -or $recipe.patchedExecutableSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Unsupported Tank compatibility recipe.' }
    $cache = Get-DuneRegisTankCacheRoot
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    foreach ($tool in $recipe.tools) {
        if ($tool.name -cnotmatch '^[a-zA-Z0-9_.-]+$' -or $tool.url -cnotmatch '^https://github\.com/(?:trumank/retoc|atenfyr/UAssetGUI|WorkingRobot/OodleUE)/' -or $tool.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid Tank tool pin.' }
        $file = Join-Path $cache $tool.name
        if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -cne $tool.sha256) {
            $temporary = "$file.download"
            Invoke-WebRequest -Uri $tool.url -OutFile $temporary -UseBasicParsing
            if ((Get-FileHash -LiteralPath $temporary).Hash.ToLowerInvariant() -cne $tool.sha256) { throw "Tank tool checksum mismatch: $($tool.name)" }
            Move-Item -LiteralPath $temporary -Destination $file -Force
        }
    }
    $job = 'build-' + [guid]::NewGuid().ToString('N')
    $work = "/home/dune/.dst-regis-tanks/$job"
    $local = Join-Path $cache $job
    New-Item -ItemType Directory -Path $local | Out-Null
    $ctr = 'sudo -n /usr/local/bin/k3s ctr -n k8s.io'
    # Require the exact official manifest already installed by Funcom. Build in
    # a utility container with no game entrypoint and no Saved/PVC mount.
    $prepare = @'
[ ! -L /home/dune/.dst-regis-tanks ]
mkdir -p '__WORK__'
chmod 755 /home/dune/.dst-regis-tanks '__WORK__'
__CTR__ content get '__DIGEST__' > '__WORK__/base-manifest.json'
[ "$(sha256sum '__WORK__/base-manifest.json' | cut -d' ' -f1)" = '__HASH__' ]
base64 -w0 '__WORK__/base-manifest.json'
'@.Replace('__WORK__',$work).Replace('__CTR__',$ctr).Replace('__DIGEST__',[string]$recipe.baseDigest).Replace('__HASH__',([string]$recipe.baseDigest).Substring(7))
    $manifest = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Invoke-DuneRegisTankShell -Ip $Ip -Script $prepare))) | ConvertFrom-Json
    if ($manifest.config.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid official image config digest.' }
    $configEncoded = Invoke-DuneRegisTankShell -Ip $Ip -Script "$ctr content get '$($manifest.config.digest)' | base64 -w0"
    $configBytes = [Convert]::FromBase64String($configEncoded)
    $configHash = [Security.Cryptography.SHA256]::Create()
    try { $actualConfigHash = ([BitConverter]::ToString($configHash.ComputeHash($configBytes))).Replace('-','').ToLowerInvariant() } finally { $configHash.Dispose() }
    if ("sha256:$actualConfigHash" -cne $manifest.config.digest) { throw 'Official image config checksum mismatch.' }
    $config = [Text.Encoding]::UTF8.GetString($configBytes) | ConvertFrom-Json
    if ($config.architecture -cne 'amd64' -or $config.os -cne 'linux') { throw 'Regis Tanks require the supported Linux x64 server.' }
    foreach ($name in @('retoc.tar.xz','liboo2corelinux64.so.9')) { Send-DuneRegisTankFile -Ip $Ip -Path (Join-Path $cache $name) -RemotePath "$work/$name" }
    $mount = "type=bind,src=$work,dst=/work,options=rbind:rw"
    $utility = "$ctr run --rm --mount '$mount' '$($recipe.baseImage)'"
    $extract = @'
mkdir -p /work/tools
tar -xJf /work/retoc.tar.xz -C /work/tools
mapfile -t binaries < <(find /work/tools -type f -name retoc)
[ "${#binaries[@]}" -eq 1 ]
cp "${binaries[0]}" /work/retoc
cp /work/liboo2corelinux64.so.9 /work/tools/liboo2corelinux64.so.9
chmod 755 /work/retoc
[ "$(sha256sum /work/retoc | cut -d' ' -f1)" = aa649cd8751a212ee946fa9c27f883770a9d67ca8d5f0b0c76ad856f44cf5eab ]
cp /home/dune/server/DuneSandbox/Binaries/Linux/DuneSandboxServer-Linux-Shipping /work/source.bin
[ "$(sha256sum /work/source.bin | cut -d' ' -f1)" = __CLEAN__ ]
/work/retoc to-legacy /home/dune/server/DuneSandbox/Content/Paks /work/stock --filter DT_Tank_Modules --no-shaders --no-parallel
/work/retoc to-legacy /home/dune/server/DuneSandbox/Content/Paks /work/stock --filter BP_Tank_CHOAM --no-shaders --no-parallel
'@.Replace('__CLEAN__',[string]$recipe.cleanExecutableSha256)
    $script64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($extract -replace "`r", '')))
    Invoke-DuneRegisTankShell -Ip $Ip -Script "$utility '$job-extract' bash -c 'echo $script64 | base64 -d | bash'" | Out-Null
    $patch = "cp '$work/source.bin' '$work/patched.bin'`n"
    foreach ($site in $recipe.sites) {
        $offset = [long]$site[0]; $before = [string]$site[1]; $after = [string]$site[2]
        if ($offset -lt 0 -or $before -cnotmatch '^(?:[a-f0-9]{2})+$' -or $after -cnotmatch '^(?:[a-f0-9]{2})+$' -or $before.Length -ne $after.Length) { throw 'Invalid guarded native patch site.' }
        $bytes = New-Object byte[] ($after.Length/2)
        for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($after.Substring($i*2,2),16) }
        $b64 = [Convert]::ToBase64String($bytes)
        $patch += "[ `"`$(dd if='$work/patched.bin' bs=1 skip=$offset count=$($bytes.Length) 2>/dev/null | od -An -v -tx1 | tr -d ' `n')`" = '$before' ]`n"
        $patch += "printf %s '$b64' | base64 -d | dd of='$work/patched.bin' bs=1 seek=$offset conv=notrunc 2>/dev/null`n"
    }
    $patch += "[ `"`$(sha256sum '$work/patched.bin' | cut -d' ' -f1)`" = '$($recipe.patchedExecutableSha256)' ]"
    Invoke-DuneRegisTankShell -Ip $Ip -Script $patch | Out-Null
    foreach ($file in $recipe.stockFiles.PSObject.Properties) {
        if ($file.Name -cnotmatch '^DuneSandbox/Content/Dune/Systems/Vehicles/(?:Modules/DT_Tank_Modules|Blueprints/GroundVehicles/BP_Tank_CHOAM)\.(?:uasset|uexp)$') { throw 'Unexpected stock Tank package path.' }
        $encoded = Invoke-DuneRegisTankShell -Ip $Ip -Script "base64 -w0 '$work/stock/$($file.Name)'"
        $destination = Join-Path $local $file.Name
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        [IO.File]::WriteAllBytes($destination,[Convert]::FromBase64String($encoded))
        if ((Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant() -cne $file.Value) { throw 'Stock Tank asset checksum mismatch.' }
    }
    $helper = Join-Path (Get-DuneRegisTankAppRoot) 'tools\tanks\DuneRegisTanks.exe'
    if (-not (Test-Path -LiteralPath $helper)) { $helper = Join-Path (Get-DuneRegisTankAppRoot) 'tools\DuneRegisTanks\bin\Release\net10.0-windows\win-x64\publish\DuneRegisTanks.exe' }
    if (-not (Test-Path -LiteralPath $helper)) { throw 'Reinstall DST with Regis Tank support.' }
    $gui = Join-Path $cache 'UAssetGUI.exe'
    foreach ($kind in @('modules','blueprint')) {
        $stem = if ($kind -eq 'modules') { 'DuneSandbox/Content/Dune/Systems/Vehicles/Modules/DT_Tank_Modules' } else { 'DuneSandbox/Content/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM' }
        $input = Join-Path $local "$stem.uasset"
        $json = Join-Path $local "$kind-stock.json"
        $changed = Join-Path $local "$kind-generated.json"
        $output = Join-Path $local "generated/$stem.uasset"
        New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
        & $gui tojson $input $json VER_UE5_2 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $json)) { throw 'Could not decode stock Tank package.' }
        & $helper $kind $json $changed | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not generate Tank compatibility properties.' }
        & $gui fromjson $changed $output | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw 'Could not serialize Tank compatibility package.' }
        foreach ($extension in @('uasset','uexp')) {
            $payload = [IO.Path]::ChangeExtension($output,$extension)
            $remote = "$work/$kind.$extension"
            Send-DuneRegisTankFile -Ip $Ip -Path $payload -RemotePath $remote
            $parent = $stem.Substring(0,$stem.LastIndexOf('/'))
            Invoke-DuneRegisTankShell -Ip $Ip -Script "mkdir -p '$work/generated/$parent' && mv '$remote' '$work/generated/$stem.$extension'" | Out-Null
        }
    }
    $package = "$utility '$job-pack' /work/retoc to-zen /work/generated /work/pakchunk999-DSTRegisTank-2147284-LinuxServer_P.utoc --version UE5_2 --no-parallel"
    Invoke-DuneRegisTankShell -Ip $Ip -Script $package | Out-Null
    return Complete-DuneRegisTankServerImage -Ip $Ip -Work $work -Config $config -Manifest $manifest -Recipe $recipe
}

function Complete-DuneRegisTankServerImage {
    param([string]$Ip, [string]$Work, $Config, $Manifest, $Recipe)
    if ($Work -cnotmatch '^/home/dune/\.dst-regis-tanks/build-[a-f0-9]{32}$') { throw 'Invalid managed image preparation folder.' }
    $root = 'home/dune/server/DuneSandbox'
    $stem = 'pakchunk999-DSTRegisTank-2147284-LinuxServer_P'
    $hashes = @{
        pak='75e7144577253917f6da7312ef5e585b12fb728226a22b0938323751a6b555cd'
        ucas='13011a68170df5a9320782691768b0b0bd568610bc682ec1979e979de534c01e'
        utoc='12781c923dcace79204bfecaf0ff4ea49c41ec6a07e68fe81fd3feb96767ced5'
    }
    $layer = "mkdir -p '$Work/layer/$root/Binaries/Linux' '$Work/layer/$root/Content/Paks'`n"
    $layer += "cp '$Work/patched.bin' '$Work/layer/$root/Binaries/Linux/DuneSandboxServer-Linux-Shipping'`nchmod 755 '$Work/layer/$root/Binaries/Linux/DuneSandboxServer-Linux-Shipping'`n"
    foreach ($extension in $hashes.Keys) {
        $file = "$Work/$stem.$extension"
        $layer += "[ `"`$(sha256sum '$file' | cut -d' ' -f1)`" = '$($hashes[$extension])' ]`ncp '$file' '$Work/layer/$root/Content/Paks/'`n"
    }
    $layer += "tar --format=gnu --owner=1000 --group=1000 --mtime=@0 -cf '$Work/layer.tar' -C '$Work/layer' '$root/Binaries/Linux/DuneSandboxServer-Linux-Shipping' '$root/Content/Paks/$stem.pak' '$root/Content/Paks/$stem.ucas' '$root/Content/Paks/$stem.utoc'`ngzip -n -3 -c '$Work/layer.tar' > '$Work/layer.tar.gz'`nsha256sum '$Work/layer.tar' '$Work/layer.tar.gz'`nstat -c %s '$Work/layer.tar.gz'"
    $raw = (Invoke-DuneRegisTankShell -Ip $Ip -Script $layer) -split '\r?\n'
    if ($raw.Count -ne 3 -or $raw[0] -cnotmatch '^([a-f0-9]{64})\s' -or $raw[1] -cnotmatch '^([a-f0-9]{64})\s' -or $raw[2] -notmatch '^\d+$') { throw 'Generated image layer could not be verified.' }
    $diff = ($raw[0] -split '\s+')[0]; $compressed = ($raw[1] -split '\s+')[0]; $size = [long]$raw[2]
    $Config.rootfs.diff_ids = @($Config.rootfs.diff_ids) + @("sha256:$diff")
    $Config.history = @($Config.history) + @(@{created_by='DST locally generated Regis Tank compatibility'})
    $cache = Get-DuneRegisTankCacheRoot
    $job = Join-Path $cache ($Work -split '/')[-1]
    $configFile = Join-Path $job 'config.json'
    [IO.File]::WriteAllText($configFile,($Config | ConvertTo-Json -Depth 60 -Compress),[Text.UTF8Encoding]::new($false))
    $configHash = (Get-FileHash -LiteralPath $configFile).Hash.ToLowerInvariant()
    $Manifest.config.digest = "sha256:$configHash"; $Manifest.config.size = (Get-Item -LiteralPath $configFile).Length
    $Manifest.layers = @($Manifest.layers) + @(@{mediaType='application/vnd.oci.image.layer.v1.tar+gzip';digest="sha256:$compressed";size=$size})
    $manifestFile = Join-Path $job 'manifest.json'
    [IO.File]::WriteAllText($manifestFile,($Manifest | ConvertTo-Json -Depth 60 -Compress),[Text.UTF8Encoding]::new($false))
    $manifestHash = (Get-FileHash -LiteralPath $manifestFile).Hash.ToLowerInvariant()
    $tag = "localhost/dst-regis-tanks:$($Recipe.build)-1"
    $index = @{schemaVersion=2;manifests=@(@{mediaType=$Manifest.mediaType;digest="sha256:$manifestHash";size=(Get-Item -LiteralPath $manifestFile).Length;annotations=@{'org.opencontainers.image.ref.name'=$tag};platform=@{os='linux';architecture='amd64'}})}
    $indexFile = Join-Path $job 'index.json'
    [IO.File]::WriteAllText($indexFile,($index | ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($false))
    foreach ($file in @('config.json','manifest.json','index.json')) { Send-DuneRegisTankFile -Ip $Ip -Path (Join-Path $job $file) -RemotePath "$Work/$file" }
    $import = @'
mkdir -p '__WORK__/oci/blobs/sha256'
printf %s '{"imageLayoutVersion":"1.0.0"}' > '__WORK__/oci/oci-layout'
cp '__WORK__/index.json' '__WORK__/oci/index.json'
cp '__WORK__/config.json' '__WORK__/oci/blobs/sha256/__CONFIG__'
cp '__WORK__/manifest.json' '__WORK__/oci/blobs/sha256/__MANIFEST__'
cp '__WORK__/layer.tar.gz' '__WORK__/oci/blobs/sha256/__LAYER__'
tar -cf '__WORK__/image.oci.tar' -C '__WORK__/oci' oci-layout index.json blobs
sudo -n /usr/local/bin/k3s ctr -n k8s.io images import --no-unpack '__WORK__/image.oci.tar'
for part in db-utils bg-director gateway rabbitmq text-router; do
  sudo -n /usr/local/bin/k3s ctr -n k8s.io images tag --force "registry.funcom.com/funcom/self-hosting/seabass-server-$part:__BUILD__-0-shipping" "localhost/dst-regis-tanks-$part:__BUILD__-1"
done
sudo -n /usr/local/bin/k3s ctr -n k8s.io run --rm '__TAG__' '__JOB__-verify' sha256sum /home/dune/server/DuneSandbox/Binaries/Linux/DuneSandboxServer-Linux-Shipping
'@.Replace('__WORK__',$Work).Replace('__CONFIG__',$configHash).Replace('__MANIFEST__',$manifestHash).Replace('__LAYER__',$compressed).Replace('__TAG__',$tag).Replace('__JOB__',($Work -split '/')[-1]).Replace('__BUILD__',[string]$Recipe.build)
    $verified = Invoke-DuneRegisTankShell -Ip $Ip -Script $import
    if ($verified -cnotmatch $Recipe.patchedExecutableSha256) { throw 'Prepared native image failed verification.' }
    $report = @{tag=$tag;manifestDigest="sha256:$manifestHash";baseDigest=$Recipe.baseDigest;build=$Recipe.build;verified=$true;work=$Work}
    $reportFile = Join-Path $job 'image-verification.json'
    [IO.File]::WriteAllText($reportFile,($report | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    Send-DuneRegisTankFile -Ip $Ip -Path $reportFile -RemotePath "$Work/image-verification.json"
    # Only temporary files inside this exact, newly generated job are removed.
    # Keep the verification record; imported image content remains in containerd.
    Invoke-DuneRegisTankShell -Ip $Ip -Script "rm -f '$Work/source.bin' '$Work/patched.bin' '$Work/layer.tar' '$Work/layer.tar.gz' '$Work/image.oci.tar' '$Work/oci/blobs/sha256/$compressed' '$Work/layer/$root/Binaries/Linux/DuneSandboxServer-Linux-Shipping'" | Out-Null
    return $report
}
