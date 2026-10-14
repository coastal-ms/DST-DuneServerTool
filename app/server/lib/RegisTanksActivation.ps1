function Get-DuneRegisTankDeployment {
    param([string]$Ip, [switch]$AllowUnsupportedMap)
    $bg = Get-V6Battlegroup -Ip $Ip
    Assert-DuneRetailKubernetesName -Value ([string]$bg.Ns) -Label namespace
    Assert-DuneRetailKubernetesName -Value ([string]$bg.Name) -Label battlegroup
    $sets = @($bg.Bg.spec.serverGroup.template.spec.sets)
    $indices = @(for($i=0; $i -lt $sets.Count; $i++) { if($sets[$i].map -ceq 'Survival_1') { $i } })
    if ($indices.Count -ne 1) {
        if ($AllowUnsupportedMap) { return @{bg=$bg;supported=$false;managed=$false;image=''} }
        throw 'Regis Tanks require one configured Hagga server group.'
    }
    $image = [string]$sets[$indices[0]].image
    $supported = $image -cin @('registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping','localhost/dst-regis-tanks:2147284-1','localhost/dst-regis-tanks:2147284-native-trial1')
    return @{ bg=$bg; index=$indices[0]; image=$image; supported=$supported; managed=($image -clike 'localhost/dst-regis-tanks:2147284-*') }
}

function Set-DuneRegisTankCompatibility {
    param([string]$Ip, [bool]$Enabled, [switch]$AcknowledgeStoredTanks)
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available -or -not $target.stopped -or $target.serverPodCount -ne 0) { throw 'Stop the battlegroup completely before changing Tank compatibility.' }
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip
    if (-not $deployment.supported) { throw 'This server build or existing custom image is not supported by Regis Tanks. Nothing was changed.' }
    $statePath = "/home/dune/.dst-regis-tanks/state-$($deployment.bg.Name).json"
    $state = $null
    $saved = Invoke-DuneRegisTankShell -Ip $Ip -Script "if [ -f '$statePath' ] && [ ! -L '$statePath' ]; then cat '$statePath'; fi"
    if ($saved) {
        $state = $saved | ConvertFrom-Json
        if ($state.namespace -cne $deployment.bg.Ns -or $state.battlegroup -cne $deployment.bg.Name -or $state.originalImage -cne 'registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping') { throw 'Tank rollback state does not match the selected battlegroup.' }
    }
    if (-not $Enabled -and -not $deployment.managed) { return @{ok=$true;enabled=$false;message='Regis Tank compatibility is already disabled.'} }
    if ($Enabled) {
        $prepared = New-DuneRegisTankServerImage -Ip $Ip
        if (-not $prepared.verified -or $prepared.tag -cne 'localhost/dst-regis-tanks:2147284-1') { throw 'Prepared Tank image is not verified.' }
        $desired = [string]$prepared.tag
    } else {
        # Native rollback leaves database rows intact, but unmodified Funcom
        # code may not retain deprecated Tanks on the next start.
        if (-not $AcknowledgeStoredTanks) { throw 'Acknowledge that saved Tanks require compatibility before disabling it.' }
        $desired = 'registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping'
    }
    $state = @{namespace=$deployment.bg.Ns;battlegroup=$deployment.bg.Name;originalImage='registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping';enabledImage='localhost/dst-regis-tanks:2147284-1';previousImage=$deployment.image;previousResourceVersion=[string]$deployment.bg.Bg.metadata.resourceVersion}
    $state64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 8 -Compress)))
    Invoke-DuneRegisTankShell -Ip $Ip -Script "[ ! -L /home/dune/.dst-regis-tanks ] && mkdir -p /home/dune/.dst-regis-tanks && printf %s '$state64' | base64 -d > '$statePath.pending' && mv '$statePath.pending' '$statePath'" | Out-Null
    $path = "/spec/serverGroup/template/spec/sets/$($deployment.index)/image"
    $patch = @(
        @{op='test';path='/metadata/resourceVersion';value=[string]$deployment.bg.Bg.metadata.resourceVersion},
        @{op='test';path='/spec/stop';value=$true},
        @{op='test';path="/spec/serverGroup/template/spec/sets/$($deployment.index)/map";value='Survival_1'},
        @{op='test';path=$path;value=$deployment.image},
        @{op='replace';path=$path;value=$desired}
    ) | ConvertTo-Json -Depth 8 -Compress
    $patch64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patch))
    $script = "printf %s '$patch64' | base64 -d > '$statePath.patch'`nsudo kubectl -n '$($deployment.bg.Ns)' patch battlegroup '$($deployment.bg.Name)' --type=json --patch-file '$statePath.patch'`nrm -f '$statePath.patch'"
    Invoke-DuneRegisTankShell -Ip $Ip -Script $script | Out-Null
    $after = Get-DuneRegisTankDeployment -Ip $Ip
    if ($after.image -cne $desired) { throw 'Tank compatibility image verification failed.' }
    return @{ok=$true;enabled=$Enabled;message=if($Enabled){'Regis Tank compatibility enabled. Start the battlegroup to apply it.'}else{'Official server image restored. Start the battlegroup to apply it.'}}
}

function Initialize-DuneRegisTanksForStartup {
    param([string]$Ip)
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap
    if (-not $deployment.supported) { return @{ok=$true;supported=$false} }
    if ($deployment.managed) { return @{ok=$true;supported=$true;enabled=$true} }
    return Set-DuneRegisTankCompatibility -Ip $Ip -Enabled $true
}

function Assert-DuneRegisTankUpdateAllowed {
    param([string]$Ip)
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip
    if ($deployment.image -clike 'localhost/dst-regis-tanks:*') { throw 'This server update needs qualified Tank compatibility for the new build. Saved Tanks require the current compatibility image.' }
}
