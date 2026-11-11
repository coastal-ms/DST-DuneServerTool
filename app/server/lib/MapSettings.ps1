# Native Funcom per-partition podSpecs userIniConfig overrides. Reads never modify the VM.
$script:DuneMapSettingsFiles=@{server='ServerCustomSettings.ini'}
# PSObject-wrapped JSON strings must remain scalar, including inside argument arrays.
function Copy-DuneMapSettingsValue {
    param($Value)
    if($null -eq $Value){return $null}
    if($Value -is [string] -or $Value -is [ValueType]){return $Value}
    if($Value -is [Collections.IDictionary]){$out=@{};foreach($key in $Value.Keys){$out[$key]=Copy-DuneMapSettingsValue $Value[$key]};return $out}
    if($Value -is [Collections.IEnumerable]){return ,@(foreach($item in $Value){Copy-DuneMapSettingsValue $item})}
    $out=@{};foreach($property in $Value.PSObject.Properties){$out[$property.Name]=Copy-DuneMapSettingsValue $property.Value};return $out
}
function Get-DuneMapSettingsFields {
    param([string]$File,[AllowEmptyString()][string]$Raw)
    if($File -ne 'server'){throw 'Game.ini and Engine.ini are available only under Global settings.'}
    return @((ConvertFrom-DuneRetailServerSettingsRaw -Raw $Raw).settings | ForEach-Object {
        $field=Copy-DuneRetailServerSettingsMap $_;$field.id=$field.key
        if($field.key -cne 'SandwormConsequences' -and $field.key -match '(?i)sandworm|coriolis|season|wipe'){$field.editable=$false}
        $field
    })
}

# Saved files are independent of the active Funcom battlegroup specification.
function Get-DuneSavedMapSettings {
    param([string]$Ip,$Bg)
    $name='dst-saved-map-settings-'+(Get-DuneGameConfigTextSha256 -Value ([string]$Bg.Bg.metadata.uid)).Substring(0,20)
    $cmd="sudo kubectl get configmap '$name' -n '$($Bg.Ns)' --ignore-not-found -o json && printf '\n__DST_MAP_STAGE_READ_OK__\n'"
    $output=(Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 30)-join "`n"
    if($output -notmatch '(?m)^__DST_MAP_STAGE_READ_OK__\r?$'){throw 'Saved map settings could not be read from the VM. Refresh before saving or restarting.'}
    $json=($output -replace '(?m)^__DST_MAP_STAGE_READ_OK__\r?\n?','').Trim()
    if(-not $json){return @{exists=$false;name=$name;data=@{worldUid=[string]$Bg.Bg.metadata.uid;enabled='true'}}}
    $object=Copy-DuneMapSettingsValue ($json|ConvertFrom-Json)
    if($object.data.worldUid -cne [string]$Bg.Bg.metadata.uid){throw 'Saved map settings belong to another world.'}
    return @{exists=$true;name=$name;data=$object.data;resourceVersion=[string]$object.metadata.resourceVersion}
}
function Install-DuneMapSettingsApplyHook {
    param([string]$Ip)
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../tools/VmMapSettings/apply.sh')) -replace "`r",''
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $cmd='base64 -d | sudo sh -c ''set -eu; umask 077; mkdir -p /usr/local/lib/dune-server; t=$(mktemp /usr/local/lib/dune-server/map-settings.XXXXXX); cat > "$t"; if cmp -s "$t" /usr/local/lib/dune-server/map-settings-apply.sh; then rm "$t"; else chmod 755 "$t"; mv "$t" /usr/local/lib/dune-server/map-settings-apply.sh; fi; echo __DST_MAP_HOOK_READY__'''
    $output=(Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $payload -TimeoutSec 30)-join "`n"
    if($output -notmatch '(?m)^__DST_MAP_HOOK_READY__\r?$'){throw 'The saved-map restart helper could not be prepared. No active map settings were changed.'}
}
function Set-DuneSavedMapSettingsEnabled {
    param([string]$Ip,[bool]$Enabled)
    $bg=Get-V6Battlegroup -Ip $Ip;$store=Get-DuneSavedMapSettings -Ip $Ip -Bg $bg
    if(-not $store.exists -or $store.data.enabled -ceq $Enabled.ToString().ToLowerInvariant()){return}
    $patch=@(@{op='test';path='/metadata/resourceVersion';value=$store.resourceVersion};@{op='add';path='/data/enabled';value=$Enabled.ToString().ToLowerInvariant()})
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $patch -Depth 100 -Compress)))
    $reply=(Invoke-V6Ssh -Ip $Ip -Cmd "base64 -d | sudo kubectl patch configmap '$($store.name)' -n '$($bg.Ns)' --type=json --patch-file=/dev/stdin 2>&1" -StdinData $payload -TimeoutSec 30)-join "`n"
    if($reply -notmatch '\bpatched\b'){throw 'Saved map configuration management change was not confirmed. Refresh before retrying.'}
}
function Sync-DuneSavedMapSettingsForStartup {
    param([string]$Ip)
    if(-not (Test-DuneConfigurationInjectionEnabled)){return @{skipped=$true}}
    $bg=Get-V6Battlegroup -Ip $Ip;$store=Get-DuneSavedMapSettings -Ip $Ip -Bg $bg
    if(-not $store.exists){return @{skipped=$true}}
    $target=Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if(-not $target.available -or -not $target.stopped -or [int]$target.serverPodCount -ne 0){throw 'Saved map settings are applied only after all game pods have stopped.'}
    Set-DuneSavedMapSettingsEnabled -Ip $Ip -Enabled $true
    Install-DuneMapSettingsApplyHook -Ip $Ip
    $reply=(Invoke-V6Ssh -Ip $Ip -Cmd 'sudo /bin/sh /usr/local/lib/dune-server/map-settings-apply.sh --stopped 2>&1' -TimeoutSec 60)-join "`n"
    if($reply -notmatch '(?m)^DST_MAP_SETTINGS_(APPLIED|UNCHANGED)='){throw "Saved map settings were not applied; battlegroup start was held. $reply"}
    return @{ok=$true}
}

function Get-DuneMapSettingsSnapshot {
    param([string]$Ip,[string]$Target,[ValidateSet('server')][string]$File='server')
    $bg=Get-V6Battlegroup -Ip $Ip
    Assert-DuneRetailKubernetesName -Value $bg.Ns -Label 'namespace';Assert-DuneRetailKubernetesName -Value $bg.Name -Label 'battlegroup'
    $sets=@($bg.Bg.spec.serverGroup.template.spec.sets)
    # Partition IDs, rather than map names or live pods, identify individual instances.
    $targets=@(foreach($world in @($bg.Bg.spec.database.template.spec.deployment.spec.worldPartitions)){
        if([string]$world.map -cnotmatch '^(Survival|DeepDesert)_[1-9][0-9]*$'){continue}
        foreach($partition in @($world.partitions)){
            if($partition.disable -eq $true -or $null -eq $partition.id -or [int]$partition.id -le 0){continue}
            $pidValue=[int]$partition.id
            $eligible=@(for($i=0;$i -lt $sets.Count;$i++){
                if([string]$sets[$i].map -ceq [string]$world.map -and $pidValue -in @($sets[$i].partitions)){$i}
            })
            if($eligible.Count -eq 0){$eligible=@(for($i=0;$i -lt $sets.Count;$i++){
                if([string]$sets[$i].map -ceq [string]$world.map -and @($sets[$i].partitions|Where-Object {$null -ne $_}).Count -eq 0){$i}
            })}
            if($eligible.Count -eq 0){continue}
            if($eligible.Count -ne 1){throw "Partition $pidValue has an ambiguous ServerSet assignment. Review the battlegroup configuration."}
            $setIndex=$eligible[0];$display=if([string]$world.map -match '^Survival_'){'Hagga'}else{'Deep Desert'}
            foreach($pod in @($sets[$setIndex].podSpecs|Where-Object {$null -ne $_ -and [int]$_.index -eq $pidValue})){
                foreach($arg in @($pod.arguments)){if([string]$arg -match "Bgd\.ServerDisplayName\s+'([^']*)'"){$display="$display - $($Matches[1])";break}}
            }
            @{id="$($bg.Bg.metadata.uid):${setIndex}:$pidValue";label="$display - partition $pidValue";setIndex=$setIndex;partition=$pidValue;map=[string]$world.map}
        }
    })
    if(@($targets.id|Select-Object -Unique).Count -ne $targets.Count){throw 'Duplicate configured partitions must be resolved before editing map settings.'}
    if(-not $Target){return @{targets=$targets}}
    $selected=@($targets|Where-Object {$_.id -ceq $Target})
    if($selected.Count -ne 1){throw 'Choose one supported map instance from this battlegroup.'}
    $selected=$selected[0];$set=$sets[$selected.setIndex];$filename=$script:DuneMapSettingsFiles[$File]
    $pods=@(foreach($pod in @($set.podSpecs)){if($null -ne $pod){Copy-DuneMapSettingsValue $pod}})
    $podIndexes=@(for($i=0;$i -lt $pods.Count;$i++){if([int]$pods[$i].index -eq $selected.partition){$i}})
    if($podIndexes.Count -gt 1){throw 'Duplicate partition overrides must be resolved before editing.'}
    $pod=if($podIndexes.Count){$pods[$podIndexes[0]]}else{@{index=$selected.partition}}
    if($pod.map -and $pod.map -cne $selected.map){throw 'This partition overrides its map assignment. Review its configuration before editing.'}
    $global=Get-DuneRetailServerSettingsSnapshot -Ip $Ip
    if(-not $global.available){throw $global.reason}
    $mount='/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
    $ini=if($pod.userIniConfig){Copy-DuneMapSettingsValue $pod.userIniConfig}else{@{mountPath=$mount;files=@{}}}
    if($ini.mountPath -cne $mount){throw 'This instance uses an unsupported INI mount path.'}
    if(-not $ini.files){$ini.files=@{}}
    $overridden=$ini.files.Contains($filename)
    $raw=if($File -eq 'server'){[string]$global.raw}else{[string](Get-DuneGameConfig -Ip $Ip)[$File].raw}
    foreach($parent in @($bg.Bg.spec.serverGroup.template.spec.global.userIniConfig,$set.userIniConfig)){
        if($parent){$parent=Copy-DuneMapSettingsValue $parent
            if($parent.files -and $parent.files.Contains($filename)){
                if($parent.mountPath -cne $mount){throw 'An inherited INI uses an unsupported mount path.'}
                $raw=[string]$parent.files[$filename]
            }
        }
    }
    $inheritedRaw=$raw
    if($overridden){$raw=[string]$ini.files[$filename]}
    $appliedHash=Get-DuneGameConfigTextSha256 -Value $(if($overridden){'override:'+$raw}else{'inherit'})
    $store=Get-DuneSavedMapSettings -Ip $Ip -Bg $bg;$key="partition-$($selected.partition).json";$saved=$null;$pending=$false
    if($store.data.ContainsKey($key)){
        $saved=Copy-DuneMapSettingsValue ($store.data[$key]|ConvertFrom-Json)
        if($saved.schema -ne 1 -or $saved.worldUid -cne [string]$bg.Bg.metadata.uid -or $saved.map -cne $selected.map -or [int]$saved.partition -ne $selected.partition -or $saved.inherit -isnot [bool] -or $saved.baseAppliedHash -notmatch '^[a-f0-9]{64}$'){throw 'The saved map file is invalid or belongs to another partition. Restore its recovery copy before applying.'}
        $desiredHash=Get-DuneGameConfigTextSha256 -Value $(if($saved.inherit){'inherit'}else{'override:'+[string]$saved.raw})
        $pending=$desiredHash -cne $appliedHash
        $overridden=-not $saved.inherit;$raw=if($saved.inherit){$inheritedRaw}else{[string]$saved.raw}
    }
    $revision=Get-DuneGameConfigTextSha256 -Value (@([string]$bg.Bg.metadata.uid,($bg.Bg.spec|ConvertTo-Json -Depth 100 -Compress),$Target,$File,$overridden,$raw,[string]$store.resourceVersion)|ConvertTo-Json -Compress)
    return @{targets=$targets;target=$Target;file=$File;raw=$raw;revision=$revision;overridden=$overridden;fields=@(Get-DuneMapSettingsFields -File $File -Raw $raw);
        canSave=[bool](Test-DuneConfigurationInjectionEnabled);saveDisabledReason='Configuration management is off. Enable it in Management & recovery before saving.';restartRequired=$pending;pendingRestart=$pending;store=$store;saved=$saved;appliedHash=$appliedHash;bg=$bg;index=$selected.setIndex;map=$selected.map;partition=$selected.partition;pods=$pods;pod=$pod;podIndex=$podIndexes;ini=$ini}
}
function Get-DuneMapSettingsPublic {
    param([hashtable]$Snapshot)
    $result=@{};foreach($key in 'targets','target','file','raw','revision','overridden','fields','canSave','saveDisabledReason','restartRequired','pendingRestart'){if($Snapshot.ContainsKey($key)){$result[$key]=$Snapshot[$key]}};return $result
}
function Save-DuneMapSettings {
    param([string]$Ip,[hashtable]$Request)
    if($Request.file -cne 'server' -or $Request.target -isnot [string] -or $Request.inherit -isnot [bool] -or
        $Request.updates -isnot [hashtable] -or $Request.revision -notmatch '^[a-f0-9]{64}$'){throw 'Review the map, settings group and current revision.'}
    if(-not (Test-DuneConfigurationInjectionEnabled)){throw 'Enable managed server settings before saving per-map overrides.'}
    $current=Get-DuneMapSettingsSnapshot -Ip $Ip -Target $Request.target -File $Request.file
    if($current.revision -cne $Request.revision){throw 'Map settings changed since loading. Refresh and review before saving.'}
    if($Request.inherit -and -not $current.overridden){return Get-DuneMapSettingsPublic $current}
    if(-not $Request.inherit){
        foreach($id in $Request.updates.Keys){if(@($current.fields|Where-Object {$_.id -ceq $id -and $_.editable}).Count -ne 1){throw 'This setting requires its existing global or specialized editor.'}}
        $raw=ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $current.raw -Updates $Request.updates
        if($raw -ceq $current.raw){return Get-DuneMapSettingsPublic $current}
    }
    $entry=@{schema=1;worldUid=[string]$current.bg.Bg.metadata.uid;map=$current.map;partition=$current.partition;inherit=$Request.inherit;raw=if($Request.inherit){''}else{$raw};baseAppliedHash=$current.appliedHash}
    $dir=Join-Path (Get-DuneGameConfigClientBackupRoot) 'Map Settings';[void][IO.Directory]::CreateDirectory($dir)
    $backup=Join-Path $dir (([guid]::NewGuid().ToString('N'))+'.json')
    $before=@{namespace=$current.bg.Ns;battlegroup=$current.bg.Name;target=$Request.target;userIniConfig=$current.ini;previousSaved=$current.saved;requestedSaved=$entry;at=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($backup,$before,[Text.UTF8Encoding]::new($false));if([IO.File]::ReadAllText($backup) -cne $before){throw 'Recovery copy verification failed.'}
    Install-DuneMapSettingsApplyHook -Ip $Ip
    $key="partition-$($current.partition).json";$value=ConvertTo-Json -InputObject $entry -Depth 100 -Compress
    if($current.store.exists){
        $body=@(@{op='test';path='/metadata/resourceVersion';value=$current.store.resourceVersion};@{op='add';path="/data/$key";value=$value};@{op='add';path='/data/enabled';value='true'})
        $cmd="base64 -d | sudo kubectl patch configmap '$($current.store.name)' -n '$($current.bg.Ns)' --type=json --patch-file=/dev/stdin 2>&1"
    }else{
        $data=@{worldUid=[string]$current.bg.Bg.metadata.uid;enabled='true'};$data[$key]=$value
        $body=@{apiVersion='v1';kind='ConfigMap';metadata=@{name=$current.store.name;namespace=$current.bg.Ns};data=$data}
        $cmd='base64 -d | sudo kubectl create -f /dev/stdin 2>&1'
    }
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 100 -Compress)))
    $reply=(Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $payload -TimeoutSec 30)-join "`n"
    if($reply -notmatch '\b(created|patched)\b'){throw 'Saving the map file was not confirmed. Refresh before retrying. Active map settings were not changed.'}
    $fresh=Get-DuneMapSettingsSnapshot -Ip $Ip -Target $Request.target -File $Request.file
    if(($Request.inherit -and $fresh.overridden) -or (-not $Request.inherit -and $fresh.raw -cne $raw)){throw 'The saved map file readback differs. Recovery copy retained; refresh before applying.'}
    return Get-DuneMapSettingsPublic $fresh
}
