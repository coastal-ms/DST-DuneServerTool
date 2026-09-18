$script:DuneRetailServerSettingsSection = '/Script/DuneSandbox.UserServerCustomSettings'
$script:DuneRetailServerSettingsFileBrowserPath = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
$script:DuneRetailServerSettingsGamePath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer/ServerCustomSettings.ini'

$script:DuneRetailServerSettingGroups = [ordered]@{
    'World and economy' = @(
        'DifficultyLevel', 'PVPMode', 'GatheringAmount', 'CraftingCost',
        'WaterExtractionRate', 'CraftingTimeMultiplier', 'BuildingCostMultiplier',
        'ResourceRespawnSpeed', 'LootRespawnSpeed', 'FuelBurnTimeMultiplier',
        'InventoryVolumeMultiplier'
    )
    'Player and NPC balance' = @(
        'PlayerDamageToPlayer', 'PlayerDamageToNPC', 'PlayerDamageToVehicle',
        'PlayerStaminaDrain', 'IntelPointsGainMultiplier', 'NPCHealth',
        'NPCDamageToPlayer', 'NPCDamageToNPC', 'NPCRespawnMultiplier',
        'PVPDamageStructures', 'PlayerShieldDamageAbsorptionMultiplier',
        'NPCShieldDamageAbsorptionMultiplier'
    )
    'Experience and survival' = @(
        'GlobalXpMultiplier', 'CombatXp', 'GatheringXp', 'MissionXp',
        'ItemDurabilityDrainMultiplier', 'bEnableItemMaxDurabilityLoss',
        'HeatBuildupRate', 'ColdBuildupRate', 'ThirstMultiplier',
        'DropEquipmentOnDeath', 'PlayerDeathLootRule'
    )
    'World threats and building' = @(
        'bAllowDynamicBuildingDamage', 'bAllowSandstorms', 'bAllowSandworms',
        'SandwormConsequences', 'bIsBuildingRestrictionsEnabled', 'FiefdomLimit',
        'BuildingPieceLimitMultiplier', 'bBuildingInfiniteStability',
        'BaseBackupToolTimeRestriction'
    )
    'Landsraad' = @(
        'LandsraadContributionMultiplier', 'LandsraadSpecializationXpMultiplier',
        'LandsraadFactionStandingMultiplier', 'bLandsraadDisableDecreeRerollLimit'
    )
}

$script:DuneRetailServerBooleanKeys = @(
    'bEnableItemMaxDurabilityLoss',
    'bAllowDynamicBuildingDamage',
    'bAllowSandstorms',
    'bAllowSandworms',
    'bIsBuildingRestrictionsEnabled',
    'bBuildingInfiniteStability',
    'bLandsraadDisableDecreeRerollLimit'
)
$script:DuneRetailServerIntegerKeys = @('FiefdomLimit')
$script:DuneRetailServerTextKeys = @('DifficultyLevel', 'PVPMode')
$script:DuneRetailServerSelectOptions = @{
    DropEquipmentOnDeath = @('Default', 'None', 'Backpack', 'All')
    SandwormConsequences = @('Default', 'None', 'Backpack', 'All')
    PlayerDeathLootRule = @('DependsOnSecurityZone', 'NeverAllowOtherPlayers', 'AlwaysAllowOtherPlayers')
}
$script:DuneRetailServerLabels = @{
    DifficultyLevel = 'Difficulty Level'
    PVPMode = 'PvP Mode'
    GatheringAmount = 'Gathering Amount'
    CraftingCost = 'Crafting Cost'
    WaterExtractionRate = 'Water Extraction Rate'
    CraftingTimeMultiplier = 'Crafting Time'
    BuildingCostMultiplier = 'Building Cost'
    ResourceRespawnSpeed = 'Resource Respawn Speed'
    LootRespawnSpeed = 'Loot Respawn Speed'
    FuelBurnTimeMultiplier = 'Fuel Burn Time'
    InventoryVolumeMultiplier = 'Inventory Volume'
    PlayerDamageToPlayer = 'Player Damage to Players'
    PlayerDamageToNPC = 'Player Damage to NPCs'
    PlayerDamageToVehicle = 'Player Damage to Vehicles'
    PlayerStaminaDrain = 'Player Stamina Drain'
    IntelPointsGainMultiplier = 'Intel Point Gain'
    NPCHealth = 'NPC Health'
    NPCDamageToPlayer = 'NPC Damage to Players'
    NPCDamageToNPC = 'NPC Damage to NPCs'
    NPCRespawnMultiplier = 'NPC Respawn'
    PVPDamageStructures = 'PvP Structure Damage'
    GlobalXpMultiplier = 'Global XP'
    CombatXp = 'Combat XP'
    GatheringXp = 'Gathering XP'
    MissionXp = 'Mission XP'
    ItemDurabilityDrainMultiplier = 'Item Durability Drain'
    bEnableItemMaxDurabilityLoss = 'Maximum Durability Loss'
    PlayerShieldDamageAbsorptionMultiplier = 'Player Shield Damage Absorption'
    NPCShieldDamageAbsorptionMultiplier = 'NPC Shield Damage Absorption'
    HeatBuildupRate = 'Heat Buildup Rate'
    ColdBuildupRate = 'Cold Buildup Rate'
    ThirstMultiplier = 'Thirst'
    DropEquipmentOnDeath = 'Equipment Dropped on Death'
    bAllowDynamicBuildingDamage = 'Dynamic Building Damage'
    bAllowSandstorms = 'Sandstorms'
    bAllowSandworms = 'Sandworms'
    SandwormConsequences = 'Sandworm Consequences'
    PlayerDeathLootRule = 'Player Death Loot Rule'
    bIsBuildingRestrictionsEnabled = 'General Building Restrictions'
    FiefdomLimit = 'Maximum Sub-Fief Amount'
    BuildingPieceLimitMultiplier = 'Building Piece Limit'
    bBuildingInfiniteStability = 'Building Stability Limits'
    BaseBackupToolTimeRestriction = 'Base Backup Tool Time Restriction'
    LandsraadContributionMultiplier = 'Landsraad Contribution'
    LandsraadSpecializationXpMultiplier = 'Landsraad Specialization XP'
    LandsraadFactionStandingMultiplier = 'Landsraad Faction Standing'
    bLandsraadDisableDecreeRerollLimit = 'Unlimited Landsraad Decree Rerolls'
}

function Get-DuneRetailServerSettingKeyMap {
    $keys = @{}
    foreach ($group in $script:DuneRetailServerSettingGroups.Keys) {
        foreach ($key in $script:DuneRetailServerSettingGroups[$group]) {
            $keys[$key] = $group
        }
    }
    return $keys
}

function Get-DuneRetailServerSettingDefinition {
    param([Parameter(Mandatory)][string]$Key)

    $keyMap = Get-DuneRetailServerSettingKeyMap
    if (-not $keyMap.ContainsKey($Key)) { return $null }
    $type = if ($script:DuneRetailServerBooleanKeys -contains $Key) {
        'bool'
    } elseif ($script:DuneRetailServerIntegerKeys -contains $Key) {
        'int'
    } elseif ($script:DuneRetailServerSelectOptions.ContainsKey($Key)) {
        'select'
    } elseif ($script:DuneRetailServerTextKeys -contains $Key) {
        'string'
    } else {
        'float'
    }
    return [ordered]@{
        key = $Key
        label = [string]$script:DuneRetailServerLabels[$Key]
        group = [string]$keyMap[$Key]
        type = $type
        options = if ($script:DuneRetailServerSelectOptions.ContainsKey($Key)) {
            @($script:DuneRetailServerSelectOptions[$Key])
        } else {
            @()
        }
        editable = ($script:DuneRetailServerTextKeys -notcontains $Key)
        inverted = ($Key -eq 'bBuildingInfiniteStability')
    }
}

function Get-DuneRetailServerInferredType {
    param([AllowEmptyString()][string]$Value)
    if ($Value -cin @('True', 'False')) { return 'bool' }
    if ($Value -match '^-?\d+$') { return 'int' }
    $number = 0.0
    if ([double]::TryParse(
        $Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    ) -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) {
        return 'float'
    }
    return 'string'
}

function Test-DuneRetailServerSettingValue {
    param(
        [Parameter(Mandatory)][hashtable]$Definition,
        [AllowEmptyString()][string]$Value
    )
    switch ([string]$Definition.type) {
        'bool' { return $Value -cin @('True', 'False') }
        'int' { return $Value -match '^-?\d+$' }
        'float' {
            $number = 0.0
            return [double]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$number
            ) -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
        }
        'select' { return $Value -cin @($Definition.options) }
        default { return $Value.Length -le 256 -and $Value -notmatch '[\x00-\x08\x0B\x0C\x0E-\x1F]' }
    }
}

function Split-DuneRetailServerSettingValue {
    param([AllowEmptyString()][string]$Content)

    if ($Content -notmatch '^(\s*)(.*?)(\s*(?:[;#].*)?)$') {
        return [ordered]@{ leading = ''; value = $Content; trailing = '' }
    }
    return [ordered]@{
        leading = $Matches[1]
        value = $Matches[2]
        trailing = $Matches[3]
    }
}

function ConvertFrom-DuneRetailServerSettingsRaw {
    param([AllowEmptyString()][string]$Raw)

    $values = [ordered]@{}
    $inside = $false
    $sectionFound = $false
    $malformed = New-Object 'System.Collections.Generic.List[object]'
    $lineNumber = 0
    foreach ($line in [regex]::Split($Raw, '\r\n|\n|\r')) {
        $lineNumber++
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $inside = ($Matches[1] -eq $script:DuneRetailServerSettingsSection)
            if ($inside) { $sectionFound = $true }
            continue
        }
        if (-not $inside -or $line -match '^\s*(?:;|#|$)') { continue }
        if ($line -notmatch '^\s*([^=]+?)\s*=(.*)$') {
            $malformed.Add(@{ line = $lineNumber; raw = $line })
            continue
        }
        $key = $Matches[1].Trim()
        $value = (Split-DuneRetailServerSettingValue -Content $Matches[2]).value.Trim()
        if (-not $key) {
            $malformed.Add(@{ line = $lineNumber; raw = $line })
            continue
        }
        $values[$key] = $value
    }

    $settings = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $values.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        $definition = Get-DuneRetailServerSettingDefinition -Key $key
        $supported = $null -ne $definition
        $type = if ($supported) { [string]$definition.type } else { Get-DuneRetailServerInferredType -Value $value }
        $valid = if ($supported) { Test-DuneRetailServerSettingValue -Definition $definition -Value $value } else { $true }
        $inverted = $supported -and [bool]$definition.inverted
        $displayValue = if ($type -eq 'bool' -and $value -cin @('True', 'False')) {
            $enabled = ($value -ceq 'True')
            if ($inverted) { $enabled = -not $enabled }
            if ($enabled) { 'Enabled' } else { 'Disabled' }
        } else {
            $value
        }
        $settings.Add([ordered]@{
            key = $key
            value = $value
            displayValue = $displayValue
            label = if ($supported) { [string]$definition.label } else { $key }
            group = if ($supported) { [string]$definition.group } else { 'Other values' }
            type = $type
            options = if ($supported) { @($definition.options) } else { @() }
            inverted = [bool]$inverted
            supported = [bool]$supported
            valid = [bool]$valid
            validationError = if ($valid) { '' } else { "Unexpected $type value '$value'." }
            editable = ($supported -and [bool]$definition.editable)
            readOnly = -not ($supported -and [bool]$definition.editable)
        })
    }
    return [ordered]@{
        section = $script:DuneRetailServerSettingsSection
        sectionFound = $sectionFound
        settings = $settings.ToArray()
        malformedLines = $malformed.ToArray()
    }
}

function Assert-DuneRetailKubernetesName {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Value -notmatch '^[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?$') {
        throw "Retail Server Settings received an invalid $Label from Kubernetes."
    }
}

function Resolve-DuneRetailServerSettingsTarget {
    param([Parameter(Mandatory)][string]$Ip)

    $bg = Get-V6Battlegroup -Ip $Ip
    $namespace = [string]$bg.Ns
    $name = [string]$bg.Name
    Assert-DuneRetailKubernetesName -Value $namespace -Label 'namespace'
    Assert-DuneRetailKubernetesName -Value $name -Label 'battlegroup name'
    $upstream = $bg.Bg.spec.serverGroup.template.spec.global.userIniConfig
    $upstreamFiles = if ($upstream -and $upstream.PSObject.Properties['files']) { $upstream.files } else { $null }
    $upstreamFileName = ''
    $upstreamContent = ''
    if ($upstreamFiles) {
        $upstreamFileName = @($upstreamFiles.PSObject.Properties.Name |
            Where-Object { [IO.Path]::GetFileName("$_") -eq 'ServerCustomSettings.ini' } |
            Select-Object -First 1)
        if ($upstreamFileName) {
            $upstreamContent = [string]$upstreamFiles.PSObject.Properties[[string]$upstreamFileName].Value
        }
    }

    $podJson = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo kubectl get pods -n '$namespace' -o json 2>/dev/null" -TimeoutSec 30) -join "`n"
    if ([string]::IsNullOrWhiteSpace($podJson) -or $podJson.TrimStart().StartsWith('ERROR:')) {
        throw 'Retail Server Settings could not list the battlegroup pods.'
    }
    $pods = $podJson | ConvertFrom-Json -ErrorAction Stop
    $pod = @($pods.items | Where-Object {
        "$($_.metadata.name)" -like "$name-fb-deploy-*" -and
        @($_.spec.containers | Where-Object name -eq 'filebrowser').Count -eq 1
    } | Select-Object -First 1)
    if ($pod.Count -ne 1) {
        return [ordered]@{
            available = $false
            namespace = $namespace
            battlegroup = $name
            reason = 'Funcom File Browser pod was not found.'
            upstreamField = 'spec.serverGroup.template.spec.global.userIniConfig'
            upstreamConfigured = [bool]$upstreamFileName
        }
    }

    $mount = @($pod[0].spec.containers |
        Where-Object name -eq 'filebrowser' |
        ForEach-Object { $_.volumeMounts } |
        Where-Object { "$($_.mountPath)" -eq '/srv' -and "$($_.subPath)" -eq 'Saved' } |
        Select-Object -First 1)
    if ($mount.Count -ne 1) {
        return [ordered]@{
            available = $false
            namespace = $namespace
            battlegroup = $name
            reason = 'Funcom File Browser does not expose the Saved PVC at /srv.'
            upstreamField = 'spec.serverGroup.template.spec.global.userIniConfig'
            upstreamConfigured = [bool]$upstreamFileName
        }
    }
    $volume = @($pod[0].spec.volumes | Where-Object name -eq "$($mount[0].name)" | Select-Object -First 1)
    $claim = if ($volume.Count -eq 1) { [string]$volume[0].persistentVolumeClaim.claimName } else { '' }
    if (-not $claim) {
        return [ordered]@{
            available = $false
            namespace = $namespace
            battlegroup = $name
            reason = 'Funcom File Browser Saved mount is not backed by a persistent-volume claim.'
            upstreamField = 'spec.serverGroup.template.spec.global.userIniConfig'
            upstreamConfigured = [bool]$upstreamFileName
        }
    }

    return [ordered]@{
        available = $true
        namespace = $namespace
        battlegroup = $name
        pod = [string]$pod[0].metadata.name
        persistentVolumeClaim = $claim
        mountPath = '/srv'
        mountSubPath = 'Saved'
        path = $script:DuneRetailServerSettingsFileBrowserPath
        gamePath = $script:DuneRetailServerSettingsGamePath
        upstreamField = 'spec.serverGroup.template.spec.global.userIniConfig'
        upstreamConfigured = [bool]$upstreamFileName
        upstreamMountPath = if ($upstream) { [string]$upstream.mountPath } else { '' }
        upstreamFileName = [string]$upstreamFileName
        upstreamContent = $upstreamContent
        resourceVersion = [string]$bg.Bg.metadata.resourceVersion
        stopped = [bool]$bg.Bg.spec.stop
        serverPodCount = @($pods.items | Where-Object {
            "$($_.metadata.labels.role)" -eq 'igw-server'
        }).Count
    }
}

function Get-DuneRetailServerSettingsPublicTarget {
    param([Parameter(Mandatory)]$Target)
    return [ordered]@{
        available = [bool]$Target.available
        namespace = [string]$Target.namespace
        battlegroup = [string]$Target.battlegroup
        pod = [string]$Target.pod
        persistentVolumeClaim = [string]$Target.persistentVolumeClaim
        mountPath = [string]$Target.mountPath
        mountSubPath = [string]$Target.mountSubPath
        path = [string]$Target.path
        gamePath = [string]$Target.gamePath
        upstreamField = [string]$Target.upstreamField
        upstreamConfigured = [bool]$Target.upstreamConfigured
        upstreamMountPath = [string]$Target.upstreamMountPath
        upstreamFileName = [string]$Target.upstreamFileName
        stopped = [bool]$Target.stopped
        serverPodCount = [int]$Target.serverPodCount
    }
}

function Get-DuneRetailServerSettingsTextSha256 {
    param([AllowEmptyString()][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        )).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-DuneRetailServerSettingsSnapshot {
    param([Parameter(Mandatory)][string]$Ip)

    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    if (-not $target.available) {
        return [ordered]@{
            available = $false
            source = 'funcom-runtime-projection'
            reason = [string]$target.reason
            target = $target
        }
    }
    if ($target.upstreamConfigured) {
        $raw = [string]$target.upstreamContent
        return [ordered]@{
            available = $true
            source = 'funcom-servergroup-user-ini-config'
            authority = 'Funcom BattleGroup operator configuration'
            raw = $raw
            revision = Get-DuneRetailServerSettingsTextSha256 -Value $raw
            modifiedAt = ''
            bytes = [Text.Encoding]::UTF8.GetByteCount($raw)
            target = $target
        }
    }
    Assert-DuneRetailKubernetesName -Value ([string]$target.pod) -Label 'pod name'
    $cmd = @"
sudo kubectl exec -n '$($target.namespace)' '$($target.pod)' -- sh -lc '
f="$($target.path)"
if [ ! -f "`$f" ]; then echo __DST_MISSING__; exit 0; fi
echo __DST_META__
stat -c "%Y|%s" "`$f"
sha256sum "`$f" | cut -d" " -f1
echo __DST_CONTENT__
base64 "`$f" | tr -d "\n"
'
"@
    $output = (Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 30) -join "`n"
    if ($output -match '(?m)^__DST_MISSING__$') {
        return [ordered]@{
            available = $false
            source = 'funcom-runtime-projection'
            reason = "Funcom runtime file is missing: $($target.path)"
            target = $target
        }
    }
    if ($output -notmatch '(?ms)^__DST_META__\s*\n([^\n]+)\n([0-9a-f]{64})\s*\n__DST_CONTENT__\s*\n([A-Za-z0-9+/=]+)\s*$') {
        throw 'Retail Server Settings returned an incomplete runtime-file response.'
    }
    $metadata = $Matches[1] -split '\|', 2
    $modifiedEpoch = 0L
    $size = 0L
    [void][long]::TryParse($metadata[0], [ref]$modifiedEpoch)
    if ($metadata.Count -gt 1) { [void][long]::TryParse($metadata[1], [ref]$size) }
    $revision = $Matches[2]
    try {
        $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[3]))
    } catch {
        throw 'Retail Server Settings runtime file was not valid base64/UTF-8.'
    }
    return [ordered]@{
        available = $true
        source = 'funcom-runtime-projection'
        authority = 'Funcom-managed live server output'
        raw = $raw
        revision = $revision
        modifiedAt = if ($modifiedEpoch -gt 0) {
            [DateTimeOffset]::FromUnixTimeSeconds($modifiedEpoch).UtcDateTime.ToString('o')
        } else {
            ''
        }
        bytes = $size
        target = $target
    }
}

function Get-DuneRetailServerSettings {
    param([Parameter(Mandatory)][string]$Ip)

    $snapshot = Get-DuneRetailServerSettingsSnapshot -Ip $Ip
    if (-not $snapshot.available) {
        return [ordered]@{
            available = $false
            readOnly = $false
            source = [string]$snapshot.source
            reason = [string]$snapshot.reason
            target = Get-DuneRetailServerSettingsPublicTarget -Target $snapshot.target
            settings = @()
            malformedLines = @()
        }
    }
    $raw = [string]$snapshot.raw
    $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $raw
    return [ordered]@{
        available = $true
        readOnly = $false
        source = [string]$snapshot.source
        authority = [string]$snapshot.authority
        revision = [string]$snapshot.revision
        modifiedAt = [string]$snapshot.modifiedAt
        bytes = [long]$snapshot.bytes
        observedAt = [DateTime]::UtcNow.ToString('o')
        target = Get-DuneRetailServerSettingsPublicTarget -Target $snapshot.target
        section = $parsed.section
        sectionFound = [bool]$parsed.sectionFound
        settings = @($parsed.settings)
        malformedLines = @($parsed.malformedLines)
        writeBehavior = [ordered]@{
            supported = $true
            requiresStoppedBattlegroup = $true
            backup = 'Saved/Config/LinuxServer/ServerCustomSettings.ini.dstbak-<UTC timestamp>'
        }
        applyBehavior = [ordered]@{
            mode = 'operator-mounted'
            restartRequired = $true
            note = if ($snapshot.source -eq 'funcom-servergroup-user-ini-config') {
                'Start the stopped battlegroup after saving. Funcom mounts the configured file into every game pod.'
            } else {
                'Stop the battlegroup before saving, then start it. Funcom mounts the configured file into every game pod.'
            }
        }
    }
}

function ConvertTo-DuneRetailServerSettingsUpdatedRaw {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][hashtable]$Updates
    )
    $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $Raw
    if (-not $parsed.sectionFound) {
        throw "Retail settings section [$script:DuneRetailServerSettingsSection] was not found."
    }
    $present = @{}
    foreach ($setting in $parsed.settings) { $present[[string]$setting.key] = $true }
    $normalized = @{}
    foreach ($keyValue in $Updates.GetEnumerator()) {
        $key = [string]$keyValue.Key
        $definition = Get-DuneRetailServerSettingDefinition -Key $key
        if (-not $definition -or -not $definition.editable) {
            throw "Retail setting $key is not editable."
        }
        if (-not $present.ContainsKey($key)) {
            throw "Retail setting $key is not present in the current official file."
        }
        $value = ([string]$keyValue.Value).Trim()
        if (-not (Test-DuneRetailServerSettingValue -Definition $definition -Value $value)) {
            throw "Retail setting $key has an invalid $($definition.type) value."
        }
        $normalized[$key] = $value
    }
    if ($normalized.Count -eq 0) { throw 'No editable Retail Server Settings were provided.' }

    $inside = $false
    $parts = [regex]::Split($Raw, '(\r\n|\n|\r)')
    for ($index = 0; $index -lt $parts.Length; $index += 2) {
        $line = $parts[$index]
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $inside = ($Matches[1] -eq $script:DuneRetailServerSettingsSection)
            continue
        }
        if ($inside -and $line -match '^(\s*([^=]+?)\s*=)(.*)$') {
            $prefix = $Matches[1]
            $key = $Matches[2].Trim()
            $valueParts = Split-DuneRetailServerSettingValue -Content $Matches[3]
            if ($normalized.ContainsKey($key)) {
                $parts[$index] = "$prefix$($valueParts.leading)$($normalized[$key])$($valueParts.trailing)"
            }
        }
    }
    return $parts -join ''
}

function Backup-DuneRetailServerSettingsContent {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Raw
    )
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
    $backup = "$($Target.path).dstbak-$stamp"
    $expected = Get-DuneRetailServerSettingsTextSha256 -Value $Raw
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Raw))
    $cmd = "base64 -d | sudo kubectl exec -i -n '$($Target.namespace)' '$($Target.pod)' -- tee '$backup' >/dev/null && sudo kubectl exec -n '$($Target.namespace)' '$($Target.pod)' -- sha256sum '$backup'"
    $hashOutput = ((Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $payload -TimeoutSec 30) -join '').Trim()
    $actual = @($hashOutput -split '\s+' | Where-Object { $_ })[0]
    if ($actual -ne $expected) {
        throw 'Retail Server Settings backup verification failed; the operator configuration was not changed.'
    }
    return [ordered]@{ path = $backup; sha256 = $actual; timestamp = $stamp }
}

function Set-DuneRetailServerSettings {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][hashtable]$Updates,
        [Parameter(Mandatory)][string]$ExpectedRevision
    )
    $current = Get-DuneRetailServerSettingsSnapshot -Ip $Ip
    if (-not $current.available) { throw [InvalidOperationException]::new([string]$current.reason) }
    if (-not $ExpectedRevision -or $ExpectedRevision -cne [string]$current.revision) {
        throw [InvalidOperationException]::new('Retail Server Settings changed since they were loaded. Refresh and review the current values before saving.')
    }
    if (-not $current.target.stopped -or [int]$current.target.serverPodCount -ne 0) {
        throw [InvalidOperationException]::new('Stop the battlegroup fully before saving Official Retail Server Settings.')
    }

    $target = $current.target
    $raw = [string]$current.raw
    $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates $Updates
    $updatedRevision = Get-DuneRetailServerSettingsTextSha256 -Value $updated
    $backup = Backup-DuneRetailServerSettingsContent -Ip $Ip -Target $target -Raw $raw

    $bg = Get-V6Battlegroup -Ip $Ip
    if ([string]$bg.Bg.metadata.resourceVersion -cne [string]$target.resourceVersion) {
        throw [InvalidOperationException]::new('Battlegroup configuration changed during save. The verified backup was retained, but no operator configuration was changed.')
    }
    $originalGlobal = $bg.Bg.spec.serverGroup.template.spec.global
    $originalUserIni = if ($originalGlobal) { $originalGlobal.userIniConfig } else { $null }
    $userIni = [ordered]@{
        mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
        files = [ordered]@{ 'ServerCustomSettings.ini' = $updated }
    }
    $patchObject = [ordered]@{
        metadata = [ordered]@{ resourceVersion = [string]$bg.Bg.metadata.resourceVersion }
        spec = [ordered]@{
            serverGroup = [ordered]@{
                template = [ordered]@{
                    spec = [ordered]@{
                        global = [ordered]@{ userIniConfig = $userIni }
                    }
                }
            }
        }
    }
    $patch = $patchObject | ConvertTo-Json -Depth 14 -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patch))
    $patchCmd = "echo '$payload' | base64 -d | sudo kubectl patch battlegroup '$($target.battlegroup)' -n '$($target.namespace)' --type=merge -p `"`$(cat)`" 2>&1"
    $patched = ((Invoke-V6Ssh -Ip $Ip -Cmd $patchCmd -TimeoutSec 30) -join "`n").Trim()
    if ($patched -notmatch '\bpatched\b') {
        throw "Retail Server Settings operator patch failed; the verified backup was retained. $patched"
    }

    try {
        $verified = Get-V6Battlegroup -Ip $Ip
        $applied = [string]$verified.Bg.spec.serverGroup.template.spec.global.userIniConfig.files.'ServerCustomSettings.ini'
        if ((Get-DuneRetailServerSettingsTextSha256 -Value $applied) -cne $updatedRevision) {
            throw 'Retail Server Settings operator readback did not match the requested file.'
        }
    } catch {
        $rollbackBg = Get-V6Battlegroup -Ip $Ip
        $rollbackGlobal = if ($null -eq $originalGlobal) {
            $null
        } else {
            [ordered]@{ userIniConfig = $originalUserIni }
        }
        $rollbackObject = [ordered]@{
            metadata = [ordered]@{ resourceVersion = [string]$rollbackBg.Bg.metadata.resourceVersion }
            spec = [ordered]@{
                serverGroup = [ordered]@{
                    template = [ordered]@{
                        spec = [ordered]@{
                            global = $rollbackGlobal
                        }
                    }
                }
            }
        }
        $rollbackJson = $rollbackObject | ConvertTo-Json -Depth 14 -Compress
        $rollbackPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rollbackJson))
        $rollbackCmd = "echo '$rollbackPayload' | base64 -d | sudo kubectl patch battlegroup '$($target.battlegroup)' -n '$($target.namespace)' --type=merge -p `"`$(cat)`" 2>&1"
        $rollbackResult = ((Invoke-V6Ssh -Ip $Ip -Cmd $rollbackCmd -TimeoutSec 30) -join "`n").Trim()
        if ($rollbackResult -notmatch '\bpatched\b') {
            throw "Retail Server Settings verification failed and automatic rollback also failed. $rollbackResult"
        }
        throw "Retail Server Settings verification failed; the original operator configuration was restored. $($_.Exception.Message)"
    }

    $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $updated
    return [ordered]@{
        ok = $true
        applied = $Updates.Count
        revision = $updatedRevision
        backup = $backup
        restartRequired = $true
        message = 'Official Retail Server Settings saved to Funcom operator configuration. Start the battlegroup to apply them.'
        settings = @($parsed.settings)
    }
}
