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
    $build = ''
    $managed = $false
    if ($image -cmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:(2147284|2156652|2160922)-0-shipping$') { $build = $Matches[1] }
    elseif ($image -cmatch '^localhost/dst-regis-tanks:(2147284|2156652|2160922)-(?:1|native-trial1)$') { $build = $Matches[1]; $managed = $true }
    $optedIn = $bg.Bg.metadata.annotations.'dst.duneservertool.com/tank-opt-in' -ceq 'v1'
    return @{ bg=$bg; index=$indices[0]; image=$image; build=$build; supported=([bool]$build); managed=$managed; optedIn=$optedIn }
}

function Set-DuneRegisTankCompatibility {
    param([string]$Ip, [bool]$Enabled, [switch]$AcknowledgeStoredTanks)
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available -or -not $target.stopped -or $target.serverPodCount -ne 0) { throw 'Stop the battlegroup completely before changing Tank compatibility.' }
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip
    if (-not $deployment.supported) { throw 'This server build or existing custom image is not supported by Regis Tanks. Nothing was changed.' }
    $officialImage = "registry.funcom.com/funcom/self-hosting/seabass-server:$($deployment.build)-0-shipping"
    if (-not $Enabled) {
        $officialBuilds = @($deployment.bg.Bg.spec.serverGroup.template.spec.sets | ForEach-Object {
            if ($_.image -cmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:([0-9]+)-0-shipping$') { [long]$Matches[1] }
        } | Sort-Object -Unique)
        if ($officialBuilds.Count -gt 1) { throw 'Official server builds disagree. Tank support was not changed.' }
        if ($officialBuilds.Count -eq 1 -and $officialBuilds[0] -gt [long]$deployment.build) {
            $officialImage = "registry.funcom.com/funcom/self-hosting/seabass-server:$($officialBuilds[0])-0-shipping"
        }
    }
    $enabledImage = "localhost/dst-regis-tanks:$($deployment.build)-1"
    $statePath = "/home/dune/.dst-regis-tanks/state-$($deployment.bg.Name).json"
    $state = $null
    $saved = Invoke-DuneRegisTankShell -Ip $Ip -Script "if [ -f '$statePath' ] && [ ! -L '$statePath' ]; then cat '$statePath'; fi"
    if ($saved) {
        $state = $saved | ConvertFrom-Json
        if ($state.namespace -cne $deployment.bg.Ns -or $state.battlegroup -cne $deployment.bg.Name -or $state.originalImage -cnotmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:(2147284|2156652|2160922)-0-shipping$') { throw 'Tank rollback state does not match the selected battlegroup.' }
    }
    if (-not $Enabled -and -not $deployment.managed) { return @{ok=$true;enabled=$false;message='Regis Tank compatibility is already disabled.'} }
    if ($Enabled) {
        $prepared = New-DuneRegisTankServerImage -Ip $Ip -Build $deployment.build
        if (-not $prepared.verified -or $prepared.tag -cne $enabledImage) { throw 'Prepared Tank image is not verified.' }
        $desired = [string]$prepared.tag
    } else {
        # Native rollback leaves database rows intact, but unmodified Funcom
        # code may not retain deprecated Tanks on the next start.
        if (-not $AcknowledgeStoredTanks) { throw 'Acknowledge that saved Tanks require compatibility before disabling it.' }
        $desired = $officialImage
    }
    $state = @{namespace=$deployment.bg.Ns;battlegroup=$deployment.bg.Name;originalImage=$officialImage;enabledImage=$enabledImage;previousImage=$deployment.image;previousResourceVersion=[string]$deployment.bg.Bg.metadata.resourceVersion}
    $state64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 8 -Compress)))
    Invoke-DuneRegisTankShell -Ip $Ip -Script "[ ! -L /home/dune/.dst-regis-tanks ] && mkdir -p /home/dune/.dst-regis-tanks && printf %s '$state64' | base64 -d > '$statePath.pending' && mv '$statePath.pending' '$statePath'" | Out-Null
    $path = "/spec/serverGroup/template/spec/sets/$($deployment.index)/image"
    $annotations = @{}
    if ($deployment.bg.Bg.metadata.annotations) {
        if ($deployment.bg.Bg.metadata.annotations -is [Collections.IDictionary]) {
            foreach ($key in $deployment.bg.Bg.metadata.annotations.Keys) { $annotations[$key] = $deployment.bg.Bg.metadata.annotations[$key] }
        } else {
            foreach ($property in $deployment.bg.Bg.metadata.annotations.PSObject.Properties) { $annotations[$property.Name] = $property.Value }
        }
    }
    $annotations['dst.duneservertool.com/tank-opt-in'] = if ($Enabled) { 'v1' } else { 'disabled' }
    $patch = @(
        @{op='test';path='/metadata/resourceVersion';value=[string]$deployment.bg.Bg.metadata.resourceVersion},
        @{op='test';path='/spec/stop';value=$true},
        @{op='test';path="/spec/serverGroup/template/spec/sets/$($deployment.index)/map";value='Survival_1'},
        @{op='test';path=$path;value=$deployment.image},
        @{op='replace';path=$path;value=$desired},
        @{op='add';path='/metadata/annotations';value=$annotations}
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
    # Legacy automatic activation is not an explicit choice. Only change the
    # stopped deployment; opening DST must never stop a running game server.
    if ($deployment.managed -and -not $deployment.optedIn) {
        Write-Warning 'Legacy automatic Tank support is disabled. Enable Tank support in Server Settings before starting if you want to retain saved Tanks.'
        return Set-DuneRegisTankCompatibility -Ip $Ip -Enabled $false -AcknowledgeStoredTanks
    }
    return @{ok=$true;supported=$deployment.supported;enabled=($deployment.managed -and $deployment.optedIn)}
}

function Prepare-DuneRegisTankServerUpdate {
    param([string]$Ip, [ValidateRange(0,900)][int]$StopTimeoutSec = 300)
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap
    if ($deployment.image -cnotmatch '^localhost/dst-regis-tanks:[0-9]+-(?:1|native-trial1)$') { return }
    if ($deployment.optedIn) {
        throw 'Disable Tank support in Server Settings before updating the server. The custom Tank image is outside Funcom''s normal update path. Re-enable support afterward only when DST supports the new build. Starting the official server can remove saved Tanks.'
    }
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available) { throw 'Cannot inspect the battlegroup before removing legacy automatic Tank support.' }
    $resume = -not $target.stopped
    if ($resume) { Invoke-DuneRegisTankShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup stop' | Out-Null }
    $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSec)
    while ($true) {
        $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
        if ($target.available -and $target.stopped -and $target.serverPodCount -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Game-server pods have not stopped. Legacy Tank image was not changed; update was not started.' }
        Start-Sleep -Seconds 2
    }
    $null = Initialize-DuneRegisTanksForStartup -Ip $Ip
    if ((Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap).image -cmatch '^localhost/dst-regis-tanks:') {
        throw 'The legacy Tank image could not be removed. Battlegroup left stopped; update was not started.'
    }
    if ($resume) { Invoke-DuneRegisTankShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup start' | Out-Null }
}

function Invoke-DuneRegisTankPreservingUpdate {
    param([string]$Ip, [Parameter(Mandatory)][scriptblock]$Update, [ValidateRange(0,900)][int]$StopTimeoutSec = 300)
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip
    if (-not $deployment.supported) { throw 'The existing server build is not supported for a Tank-preserving update.' }
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available) { throw 'Cannot inspect the battlegroup before the Tank update.' }
    $resume = -not $target.stopped
    if ($resume) { Invoke-DuneRegisTankShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup stop' | Out-Null }
    $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSec)
    while ($true) {
        $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
        if ($target.available -and $target.stopped -and $target.serverPodCount -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Game-server pods have not stopped. The Tank update was not started.' }
        Start-Sleep -Seconds 2
    }
    # Keep every map stopped throughout the official-image interval. Never
    # start in a finally block: any failure must preserve this stopped state.
    try {
        $null = Set-DuneRegisTankCompatibility -Ip $Ip -Enabled $false -AcknowledgeStoredTanks
        $result = & $Update
        if ($null -eq $result -or $null -eq $result.exitCode) { throw 'Server updater did not return a result.' }
        $null = Complete-DuneRegisTankServerUpdate -Ip $Ip -UpdateExitCode $result.exitCode -UpdateOutput $result.output
        $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
        if (-not $target.available -or -not $target.stopped -or $target.serverPodCount -ne 0) { throw 'The battlegroup must remain fully stopped until Tank support is restored.' }
        $null = Set-DuneRegisTankCompatibility -Ip $Ip -Enabled $true
        $verified = Get-DuneRegisTankDeployment -Ip $Ip
        if (-not $verified.managed -or -not $verified.optedIn) { throw 'Tank support readback failed.' }
    } catch {
        throw "Tank update did not finish. Do not start the official server if you want to retain saved Tanks. Restore Tank support first. $($_.Exception.Message)"
    }
    if ($resume) { Invoke-DuneRegisTankShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup start' | Out-Null }
    return @{ok=$true;restarted=$resume;message='Server update completed with Tank support enabled.'}
}

function Sync-DuneRegisTankServerUpdate {
    param([string]$Ip)
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap
    if ($deployment.managed -and -not $deployment.optedIn) {
        $null = Initialize-DuneRegisTanksForStartup -Ip $Ip
        return @{changed=$true;image=(Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap).image}
    }
    if ($deployment.image -cnotmatch '^localhost/dst-regis-tanks:([0-9]+)-(?:1|native-trial1)$') { return @{changed=$false} }
    $tankBuild = [long]$Matches[1]
    $official = @($deployment.bg.Bg.spec.serverGroup.template.spec.sets | ForEach-Object {
        if ($_.image -cmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:([0-9]+)-0-shipping$') {
            [long]$Matches[1]
        }
    } | Sort-Object -Unique)
    if ($official.Count -ne 1 -or $official[0] -le $tankBuild) { return @{changed=$false} }
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available -or -not $target.stopped -or $target.serverPodCount -ne 0) {
        throw 'Stop the battlegroup completely to finish applying the updated server image to Hagga.'
    }
    if ([string]$official[0] -cnotin @('2147284','2156652','2160922')) { throw 'Tank support is not available for the updated build. Existing Tank data has not been changed. Update DST for compatibility, or explicitly disable Tank support before starting the official server.' }
    $prepared = New-DuneRegisTankServerImage -Ip $Ip -Build ([string]$official[0])
    $desired = 'localhost/dst-regis-tanks:' + $official[0] + '-1'
    if (-not $prepared.verified -or $prepared.tag -cne $desired) { throw 'Updated Tank image is not verified. Nothing was changed.' }
    $path = '/spec/serverGroup/template/spec/sets/' + $deployment.index + '/image'
    $patch = @(
        @{op='test';path='/metadata/resourceVersion';value=[string]$deployment.bg.Bg.metadata.resourceVersion},
        @{op='test';path='/spec/stop';value=$true},
        @{op='test';path=('/spec/serverGroup/template/spec/sets/' + $deployment.index + '/map');value='Survival_1'},
        @{op='test';path=$path;value=$deployment.image},
        @{op='replace';path=$path;value=$desired}
    ) | ConvertTo-Json -Depth 8 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patch))
    Write-Host 'Applying Tank compatibility for the updated server build to Hagga.'
    $command = "p=`"`$(printf %s '$encoded' | base64 -d)`"; sudo -n /usr/local/bin/k3s kubectl -n '$($deployment.bg.Ns)' patch battlegroup '$($deployment.bg.Name)' --type=json -p `"`$p`""
    Invoke-DuneRegisTankShell -Ip $Ip -Script $command | Out-Null
    $after = Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap
    if ($after.image -cne $desired) { throw 'Updated Hagga server image readback failed.' }
    return @{changed=$true;image=$desired}
}


function Complete-DuneRegisTankServerUpdate {
    param([string]$Ip, [int]$UpdateExitCode, [string[]]$UpdateOutput,
          [ValidateRange(0,900)][int]$StopTimeoutSec = 300)
    $deployment = Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap
    $official = @($deployment.bg.Bg.spec.serverGroup.template.spec.sets | ForEach-Object {
        if ($_.image -cmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:([0-9]+)-0-shipping$') { [long]$Matches[1] }
    } | Sort-Object -Unique)

    if ($UpdateExitCode -ne 0) {
        # Funcom finishes by creating two existing command symlinks. Accept
        # only that exact trailing failure after an applied-build readback.
        $lines = @(($UpdateOutput -join "`n") -split "[\r\n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $finished = -1; $completedBuild = ''
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -cmatch '^Finished updating battlegroup to version ([0-9]+)-0-shipping$') { $finished=$i; $completedBuild=$Matches[1] }
        }
        $known = @('ln: /home/dune/.dune/bin/battlegroup: File exists', 'ln: /home/dune/.dune/bin/bg-util: File exists')
        foreach ($name in @('battlegroup','bg-util')) { $known += "ln: failed to create symbolic link '/home/dune/.dune/bin/${name}': File exists" }
        $trailer = if ($finished -ge 0 -and $finished -lt ($lines.Count-1)) { @($lines[($finished+1)..($lines.Count-1)]) } else { @() }
        if ($official.Count -ne 1 -or [string]$official[0] -cne $completedBuild -or $trailer.Count -eq 0 -or @($trailer | Where-Object { $known -cnotcontains $_ }).Count) {
            throw "Server updater exited with code $UpdateExitCode. Update completion could not be verified; no automatic image recovery was attempted."
        }
        Write-Warning 'The server update was applied; Funcom reported existing command links during final cleanup.'
    }

    if ($deployment.image -cnotmatch '^localhost/dst-regis-tanks:([0-9]+)-(?:1|native-trial1)$') { return @{ok=$true;changed=$false} }
    $tankBuild = [long]$Matches[1]
    if ($official.Count -ne 1 -or $official[0] -le $tankBuild) { return @{ok=$true;changed=$false} }
    if ([string]$official[0] -cnotin @('2147284','2156652','2160922')) { throw 'Tank support is not available for the updated build. Existing Tank data has not been changed. Update DST for compatibility, or explicitly disable Tank support before starting the official server.' }
    $officialImage = 'registry.funcom.com/funcom/self-hosting/seabass-server:' + $official[0] + '-0-shipping'
    $desired = 'localhost/dst-regis-tanks:' + $official[0] + '-1'
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available) { throw 'Cannot inspect the battlegroup to complete the Hagga server update.' }
    $resume = -not $target.stopped
    if ($resume) {
        Write-Warning 'Hagga still uses the previous Tank image. Restarting the battlegroup with Tank compatibility for the updated build.'
        Invoke-DuneRegisTankShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup stop' | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSec)
    while ($true) {
        $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
        if ($target.available -and $target.stopped -and $target.serverPodCount -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Game-server pods have not stopped. Hagga image was not changed; the update remains incomplete.' }
        Start-Sleep -Seconds 2
    }
    # Re-read the revision after stop so the existing compare-and-swap guard
    # applies to the stopped battlegroup, not its earlier running revision.
    $current = Get-DuneRegisTankDeployment -Ip $Ip -AllowUnsupportedMap
    $currentOfficial = @($current.bg.Bg.spec.serverGroup.template.spec.sets | Where-Object { $_.image -ceq $officialImage })
    if ($current.image -cne $deployment.image -or $currentOfficial.Count -eq 0) { throw 'Server images changed during update recovery. Battlegroup left stopped.' }
    $result = Sync-DuneRegisTankServerUpdate -Ip $Ip
    if (-not $result.changed -or $result.image -cne $desired) { throw 'Hagga update readback failed. Battlegroup left stopped.' }
    if ($resume) { Invoke-DuneRegisTankShell -Ip $Ip -Script '/home/dune/.dune/bin/battlegroup start' | Out-Null }
    return @{ok=$true;changed=$true;image=$desired;restarted=$resume}
}
