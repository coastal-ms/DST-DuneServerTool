BeforeAll {
    $script:previousLocalAppData=$env:LOCALAPPDATA
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'PortalAuth.ps1'
    Import-DstLib 'RetailServerSettings.ps1'
    Import-DstLib 'GameConfig.ps1'
    Import-DstLib 'MapSettings.ps1'
    function global:Get-V6Battlegroup { param($Ip) }
    function global:Invoke-V6Ssh { param($Ip,$Cmd,$StdinData,$TimeoutSec) }
}
AfterAll {$env:LOCALAPPDATA=$script:previousLocalAppData}
Describe 'Native per-map settings transactions' {
    BeforeEach {
        $env:LOCALAPPDATA=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:globalRaw="[/Script/DuneSandbox.UserServerCustomSettings]`nCraftingCost=1.0`nUnknownKey=keep`n"
        $script:bg=@{Ns='funcom-test';Name='sh-test';Bg=('{"metadata":{"uid":"world-uid","resourceVersion":"7"},"spec":{"serverGroup":{"template":{"spec":{"global":{"manual":"untouched"},"sets":[{"map":"Survival_1","arguments":["keep-me"]},{"map":"DeepDesert_1","userIniConfig":{"mountPath":"/home/dune/server/DuneSandbox/Saved/Config/LinuxServer","files":{"Engine.ini":"other map"}}}]}}}}}'|ConvertFrom-Json)}
        $script:bg.Bg.spec | Add-Member -NotePropertyName database -NotePropertyValue ([pscustomobject]@{template=@{spec=@{deployment=@{spec=@{worldPartitions=@(@{map='Survival_1';partitions=@(@{id=1},@{id=17})},@{map='DeepDesert_1';partitions=@(@{id=8},@{id=21})})}}}}})
        Mock Get-DuneGameConfigClientBackupRoot {Join-Path $env:LOCALAPPDATA 'INI Backups'}
        Mock Get-V6Battlegroup { $script:bg }
        Mock Get-DuneRetailServerSettingsSnapshot { @{available=$true;raw=$script:globalRaw;target=@{stopped=$true;serverPodCount=0}} }
        Mock Test-DuneConfigurationInjectionEnabled { $true }
        Mock Get-DuneGameConfig { @{game=@{raw="[/Script/DuneSandbox.PlayerSettings]`nExisting=keep`n"};engine=@{raw="[Other]`nExisting=keep`n"}} }
        $script:store=@{exists=$false;name='dst-saved-map-settings-test';data=@{worldUid='world-uid';enabled='true'}}
        Mock Get-DuneSavedMapSettings { Copy-DuneMapSettingsValue $script:store }
        Mock Install-DuneMapSettingsApplyHook {}
        Mock Invoke-V6Ssh {
            param($Cmd,$StdinData)
            # An operator may restart maps on ANY active battlegroup spec mutation.
            $Cmd|Should -Not -Match 'patch battlegroup|delete|rollout|--maintenance|--stopped|battlegroup (start|restart|stop)'
            $body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData))|ConvertFrom-Json
            @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'INI Backups/Map Settings') -Filter '*.json').Count|Should -BeGreaterThan 0
            if($Cmd -match 'kubectl create'){
                $body.kind|Should -Be ConfigMap
                $body.metadata.PSObject.Properties.Name|Should -Not -Contain ownerReferences
                $script:store=@{exists=$true;name=$body.metadata.name;resourceVersion='1';data=(Copy-DuneMapSettingsValue $body.data)}
                'configmap created'
            }else{
                $Cmd|Should -Match 'patch configmap'
                $body[0].path|Should -Be '/metadata/resourceVersion'
                $body[0].value|Should -Be $script:store.resourceVersion
                foreach($op in @($body|Select-Object -Skip 1)){$script:store.data[$op.path.Substring(6)]=$op.value}
                $script:store.resourceVersion=([int]$script:store.resourceVersion+1).ToString()
                'configmap patched'
            }
        }
    }
    It 'lists only supported maps and exposes inherited global values without writing' {
        $catalog=Get-DuneMapSettingsSnapshot -Ip test
        @($catalog.targets).Count|Should -Be 4
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        $snapshot.overridden|Should -BeFalse;$snapshot.raw|Should -BeExactly $script:globalRaw
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'stages only the selected map and preserves manual values, arguments and other maps' {
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        $saved=Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{CraftingCost='0.5'};inherit=$false}
        $saved.overridden|Should -BeTrue;$saved.raw|Should -Match 'CraftingCost=0.5';$saved.raw|Should -Match 'UnknownKey=keep'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[1].userIniConfig.files.'Engine.ini'|Should -Be 'other map'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0].arguments[0]|Should -Be 'keep-me'
        $script:bg.Bg.spec.serverGroup.template.spec.global.manual|Should -Be 'untouched'
    }
    It 'rejects stale configuration drafts before writing recovery or operator data' {
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0].arguments=@('changed externally')
        {Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{CraftingCost='0.5'};inherit=$false}}|Should -Throw '*changed since*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'rejects unknown maps and fields without silently changing global settings' {
        {Get-DuneMapSettingsSnapshot -Ip test -Target '../other'}|Should -Throw '*supported map*'
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        {Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{Unlisted='1'};inherit=$false}}|Should -Throw '*specialized editor*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'stages inheritance without removing the active override until restart' {
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0]|Add-Member -NotePropertyName podSpecs -NotePropertyValue @([pscustomobject]@{index=1;userIniConfig=[pscustomobject]@{mountPath='/home/dune/server/DuneSandbox/Saved/Config/LinuxServer';files=[pscustomobject]@{'ServerCustomSettings.ini'=$script:globalRaw;'Engine.ini'='keep selected engine'}}})
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        $saved=Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{};inherit=$true}
        $saved.overridden|Should -BeFalse
        $saved.pendingRestart|Should -BeTrue
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0].podSpecs[0].userIniConfig.files.'ServerCustomSettings.ini'|Should -BeExactly $script:globalRaw
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0].podSpecs[0].userIniConfig.files.'Engine.ini'|Should -Be 'keep selected engine'
    }
    It 'keeps multiple sietches and stopped Deep Deserts distinct and preserves other partition overrides' {
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0]|Add-Member -NotePropertyName podSpecs -NotePropertyValue @([pscustomobject]@{index=17;arguments=@('other arguments');userIniConfig=@{mountPath='/home/dune/server/DuneSandbox/Saved/Config/LinuxServer';files=@{'ServerCustomSettings.ini'='other sietch'}}})
        $catalog=Get-DuneMapSettingsSnapshot -Ip test
        @($catalog.targets|Where-Object map -EQ DeepDesert_1).Count|Should -Be 2
        $catalog.targets.label -join ','|Should -Match 'partition 21'
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{CraftingCost='0.5'};inherit=$false}|Out-Null
        $other=$script:bg.Bg.spec.serverGroup.template.spec.sets[0].podSpecs|Where-Object index -EQ 17
        $other.arguments[0]|Should -Be 'other arguments'
        $other.userIniConfig.files.'ServerCustomSettings.ini'|Should -Be 'other sietch'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[1].userIniConfig.files.'Engine.ini'|Should -Be 'other map'
    }
    It 'inherits a set override and refuses a stale partition assignment' {
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0]|Add-Member -NotePropertyName userIniConfig -NotePropertyValue @{mountPath='/home/dune/server/DuneSandbox/Saved/Config/LinuxServer';files=@{'ServerCustomSettings.ini'=$script:globalRaw.Replace('1.0','2.0')}}
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        $snapshot.raw|Should -Match 'CraftingCost=2.0'
        $script:bg.Bg.spec.database.template.spec.deployment.spec.worldPartitions[0].partitions=@(@{id=17})
        {Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{CraftingCost='0.5'};inherit=$false}}|Should -Throw '*supported map*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'refuses ambiguous assignments rather than writing the same map across sets' {
        $sets=$script:bg.Bg.spec.serverGroup.template.spec.sets
        $script:bg.Bg.spec.serverGroup.template.spec.sets=@($sets)+@([pscustomobject]@{map='Survival_1'})
        {Get-DuneMapSettingsSnapshot -Ip test}|Should -Throw '*ambiguous*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'saves one of several Deep Deserts without touching its sibling or either sietch' {
        $script:bg.Bg.spec.serverGroup.template.spec.sets[1]|Add-Member -NotePropertyName podSpecs -NotePropertyValue @([pscustomobject]@{index=8;arguments=@('keep dd');userIniConfig=@{mountPath='/home/dune/server/DuneSandbox/Saved/Config/LinuxServer';files=@{'ServerCustomSettings.ini'='sibling dd'}}})
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:1:21'
        Save-DuneMapSettings -Ip test -Request @{target='world-uid:1:21';file='server';revision=$snapshot.revision;updates=@{CraftingCost='0.8'};inherit=$false}|Out-Null
        $script:bg.Bg.spec.serverGroup.template.spec.sets[1].podSpecs[0].userIniConfig.files.'ServerCustomSettings.ini'|Should -Be 'sibling dd'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0].arguments[0]|Should -Be 'keep-me'
        @($script:bg.Bg.spec.serverGroup.template.spec.sets[0].podSpecs|Where-Object {$null -ne $_}).Count|Should -Be 0
        $script:store.data.Keys|Should -Contain 'partition-21.json'
    }

    It 'resolves separate ServerSets running the same map by their explicit partition assignments' {
        $sets=$script:bg.Bg.spec.serverGroup.template.spec.sets
        $sets[0]|Add-Member -NotePropertyName partitions -NotePropertyValue @(1)
        $script:bg.Bg.spec.serverGroup.template.spec.sets=@($sets)+@([pscustomobject]@{map='Survival_1';partitions=@(17);arguments=@('second set')})
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:2:17'
        Save-DuneMapSettings -Ip test -Request @{target='world-uid:2:17';file='server';revision=$snapshot.revision;updates=@{CraftingCost='0.9'};inherit=$false}|Out-Null
        $script:store.data.Keys|Should -Contain 'partition-17.json'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0].arguments[0]|Should -Be 'keep-me'
        $script:bg.Bg.spec.serverGroup.template.spec.sets[2].arguments[0]|Should -Be 'second set'
    }

    It 'rejects Game and Engine map writes before any recovery copy or mutation' {
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        foreach($file in @('game','engine')){
            {Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file=$file;revision=$snapshot.revision;updates=@{CraftingCost='2'};inherit=$false}}|Should -Throw
            {Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1' -File $file}|Should -Throw
        }
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'lists only used, enabled configured partitions' {
        $script:bg.Bg.spec.serverGroup.template.spec.sets[0]|Add-Member -NotePropertyName partitions -NotePropertyValue @(1)
        $script:bg.Bg.spec.database.template.spec.deployment.spec.worldPartitions[1].partitions[1].disable=$true
        $catalog=Get-DuneMapSettingsSnapshot -Ip test
        @($catalog.targets).Count|Should -Be 2
        $catalog.targets.id|Should -Contain 'world-uid:0:1'
        $catalog.targets.id|Should -Contain 'world-uid:1:8'
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'saves while running without lifecycle commands and ignores status-only resourceVersion changes' {
        Mock Get-DuneRetailServerSettingsSnapshot { @{available=$true;raw=$script:globalRaw;target=@{stopped=$false;serverPodCount=3}} }
        $snapshot=Get-DuneMapSettingsSnapshot -Ip test -Target 'world-uid:0:1'
        $snapshot.canSave|Should -BeTrue
        $before=$script:bg.Bg.spec|ConvertTo-Json -Depth 100 -Compress
        $script:bg.Bg.metadata.resourceVersion='999'
        $saved=Save-DuneMapSettings -Ip test -Request @{target='world-uid:0:1';file='server';revision=$snapshot.revision;updates=@{PVPMode='NoPVP';SandwormConsequences='Backpack'};inherit=$false}
        $saved.raw|Should -Match 'PVPMode=NoPVP'
        $saved.raw|Should -Match 'SandwormConsequences=Backpack'
        $saved.restartRequired|Should -BeTrue
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter {$Cmd -match 'kubectl create'}
        $saved.pendingRestart|Should -BeTrue
        ($script:bg.Bg.spec|ConvertTo-Json -Depth 100 -Compress)|Should -BeExactly $before
    }

}
Describe 'Saved map storage and start guards' {
    BeforeEach {
        $script:world=@{Ns='test';Name='world';Bg=@{metadata=@{uid='world-uid'}}}
        Mock Get-V6Battlegroup {$script:world}
        Mock Test-DuneConfigurationInjectionEnabled {$true}
        Mock Install-DuneMapSettingsApplyHook {}
        Mock Resolve-DuneRetailServerSettingsTarget {@{available=$true;stopped=$true;serverPodCount=0}}
    }
    It 'does not treat a failed empty SSH read as an absent store' {
        Mock Invoke-V6Ssh {''}
        {Get-DuneSavedMapSettings -Ip test -Bg $script:world}|Should -Throw '*could not be read*'
    }
    It 'accepts a missing store only with the remote completion marker' {
        Mock Invoke-V6Ssh {'__DST_MAP_STAGE_READ_OK__'}
        (Get-DuneSavedMapSettings -Ip test -Bg $script:world).exists|Should -BeFalse
    }
    It 'rejects a store owned by a different world' {
        Mock Invoke-V6Ssh {"{`"metadata`":{`"resourceVersion`":`"1`"},`"data`":{`"worldUid`":`"other`"}}`n__DST_MAP_STAGE_READ_OK__"}
        {Get-DuneSavedMapSettings -Ip test -Bg $script:world}|Should -Throw '*another world*'
    }
    It 'blocks applying pending files while a game pod remains' {
        Mock Get-DuneSavedMapSettings {@{exists=$true;data=@{enabled='true'}}}
        Mock Resolve-DuneRetailServerSettingsTarget {@{available=$true;stopped=$true;serverPodCount=1}}
        Mock Invoke-V6Ssh {throw 'must not run'}
        {Sync-DuneSavedMapSettingsForStartup -Ip test}|Should -Throw '*all game pods*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'applies pending files only in an explicit stopped start context' {
        Mock Get-DuneSavedMapSettings {@{exists=$true;data=@{enabled='true'}}}
        Mock Invoke-V6Ssh {'DST_MAP_SETTINGS_APPLIED=1'}
        (Sync-DuneSavedMapSettingsForStartup -Ip test).ok|Should -BeTrue
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter {$Cmd -match 'map-settings-apply.sh --stopped' -and $Cmd -notmatch 'battlegroup (start|restart|stop)'}
    }
    It 'does not apply or read pending files when configuration management is disabled' {
        Mock Test-DuneConfigurationInjectionEnabled {$false}
        Mock Get-DuneSavedMapSettings {throw 'must not read'}
        (Sync-DuneSavedMapSettingsForStartup -Ip test).skipped|Should -BeTrue
        Should -Invoke Get-DuneSavedMapSettings -Times 0
    }
}
