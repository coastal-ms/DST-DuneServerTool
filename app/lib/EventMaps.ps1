# Restore missing event map definitions without replacing operator settings.
function New-DuneEventMapRepairPlan {
    param([Parameter(Mandatory)]$Battlegroup)
    $map = 'CB_Halloween_Event_Shipwreck_01'
    $sets = @($Battlegroup.spec.serverGroup.template.spec.sets)
    $worlds = @($Battlegroup.spec.database.template.spec.deployment.spec.worldPartitions)
    $existingSets = @($sets | Where-Object map -eq $map)
    $existingWorlds = @($worlds | Where-Object map -eq $map)
    if ($existingSets.Count -gt 1 -or $existingWorlds.Count -gt 1) { throw 'Duplicate event map definitions require review.' }
    if ($existingSets.Count -eq 1 -and $existingWorlds.Count -eq 1) { return @{ changed=$false; operations=@(); map=$map } }
    $version = [string]$Battlegroup.metadata.resourceVersion
    if ($version -notmatch '^\d+$') { throw 'Battlegroup revision is unavailable.' }
    $operations = New-Object System.Collections.Generic.List[object]
    $operations.Add(@{op='test';path='/metadata/resourceVersion';value=$version})
    if ($existingWorlds.Count -eq 0) {
        $ids = @($worlds | ForEach-Object { $_.partitions } | ForEach-Object { $_.id })
        if ($ids.Count -eq 0 -or @($ids | Where-Object { $_ -isnot [int] -and $_ -isnot [long] }).Count -gt 0) { throw 'Database partition IDs could not be verified.' }
        $maximum = [long]($ids | Measure-Object -Maximum).Maximum
        if ($maximum -lt 1 -or $maximum -ge [int]::MaxValue) { throw 'Database partition ID range is invalid.' }
        $partition = @{map=$map;partitions=@(@{dimension=0;disable=$false;id=($maximum+1);minX=0;minY=0;maxX=1;maxY=1})}
        $operations.Add(@{op='add';path='/spec/database/template/spec/deployment/spec/worldPartitions/-';value=$partition})
    }
    if ($existingSets.Count -eq 0) {
        $templates = @($sets | Where-Object map -eq 'DLC_Story_LostHarvest_EcolabB')
        if ($templates.Count -ne 1) { throw 'The standard on-demand map template is unavailable.' }
        $template = $templates[0]
        if ($template.dedicatedScaling -ne $true -or $template.connectionMode -ne 'AutoDiscovery' -or -not $template.image -or -not $template.arguments -or -not $template.messageQueues) { throw 'The standard on-demand map template is not supported.' }
        $entry = ($template | ConvertTo-Json -Depth 40) | ConvertFrom-Json
        $entry.map = $map
        $entry.replicas = 0
        $operations.Add(@{op='add';path='/spec/serverGroup/template/spec/sets/-';value=$entry})
    }
    return @{changed=$true;operations=@($operations.ToArray());map=$map}
}

function Repair-DuneEventMapDefinitions {
    param([Parameter(Mandatory)][string]$Ip)
    try {
        if (-not (Get-Command Get-V6Battlegroup -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'K8s.ps1') }
        $info = Get-V6Battlegroup -Ip $Ip
        $plan = New-DuneEventMapRepairPlan -Battlegroup $info.Bg
        if (-not $plan.changed) { return @{ok=$true;changed=$false;message='Event map definitions are already present.'} }
        if ($info.Ns -notmatch '^[a-z0-9][a-z0-9.-]*$' -or $info.Name -notmatch '^[a-z0-9][a-z0-9.-]*$') { throw 'Invalid battlegroup identity.' }
        # The retained original can contain private configuration. Never log it.
        $backupRoot = Join-Path $env:APPDATA 'DuneServer\backups\map-config'
        [void](New-Item -ItemType Directory -Path $backupRoot -Force)
        $backup = Join-Path $backupRoot ($info.Name+'-'+[Guid]::NewGuid().ToString('N')+'.json')
        [IO.File]::WriteAllText($backup, ($info.Bg | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $payload = ConvertTo-Json -InputObject @($plan.operations) -Depth 40 -Compress
        $command = 'sudo kubectl -n '+$info.Ns+' patch battlegroup '+$info.Name+' --type=json --patch-file=/dev/stdin'
        $dry = Invoke-V6Ssh -Ip $Ip -Cmd ($command+' --dry-run=server -o json') -StdinData $payload -TimeoutSec 30
        $null = ($dry -join "`n") | ConvertFrom-Json -ErrorAction Stop
        $raw = Invoke-V6Ssh -Ip $Ip -Cmd ($command+' -o json') -StdinData $payload -TimeoutSec 30
        $result = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
        $confirmed = New-DuneEventMapRepairPlan -Battlegroup $result
        if ($confirmed.changed) { throw 'Event map repair was not confirmed.' }
        return @{ok=$true;changed=$true;message='Restored the Wreck of the Hieronymus on-demand map definition. Travel to the wreck to start it.'}
    } catch {
        return @{ok=$false;changed=$false;message='Could not confirm the event map repair. Refresh and retry the on-demand map repair; existing map definitions were not replaced.'}
    }
}
