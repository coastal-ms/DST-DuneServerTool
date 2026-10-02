$script:DuneRetailServerSettingsSection = '/Script/DuneSandbox.UserServerCustomSettings'
$script:DuneRetailServerSettingsFileBrowserPath = '/srv/UserSettings/UserServerCustomSettings.ini'
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
    if ($Value -in @('True', 'False')) { return 'bool' }
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
        'bool' { return $Value -in @('True', 'False') }
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
    # A UTF-8 BOM decoded by the file browser is U+FEFF at the start of the
    # first line, which is not matched by \s in the section-header expression.
    foreach ($line in [regex]::Split($Raw.TrimStart([char]0xFEFF), '\r\n|\n|\r')) {
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

    $present = @{}
    foreach ($key in $values.Keys) { $present[$key] = $true }
    foreach ($group in $script:DuneRetailServerSettingGroups.Keys) {
        foreach ($key in $script:DuneRetailServerSettingGroups[$group]) {
            if (-not $present.ContainsKey($key)) { $values[$key] = '' }
        }
    }
    $settings = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $values.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        $definition = Get-DuneRetailServerSettingDefinition -Key $key
        $supported = $null -ne $definition
        $type = if ($supported) { [string]$definition.type } else { Get-DuneRetailServerInferredType -Value $value }
        $isPresent = $present.ContainsKey($key)
        $valid = if ($supported -and $isPresent) { Test-DuneRetailServerSettingValue -Definition $definition -Value $value } else { $true }
        $inverted = $supported -and [bool]$definition.inverted
        if ($type -eq 'bool' -and $value -in @('True', 'False')) {
            $value = if ($value -eq 'True') { 'True' } else { 'False' }
        }
        $displayValue = if (-not $isPresent) {
            'Not configured'
        } elseif ($type -eq 'bool' -and $valid) {
            $enabled = ($value -eq 'True')
            if ($inverted) { $enabled = -not $enabled }
            if ($enabled) { 'Enabled' } else { 'Disabled' }
        } else {
            $value
        }
        $settings.Add([ordered]@{
            key = $key
            present = $isPresent
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
    param([Parameter(Mandatory)][string]$Ip, $TargetOverride)

    $target = if ($TargetOverride) { $TargetOverride } else { Resolve-DuneRetailServerSettingsTarget -Ip $Ip }
    if (-not $target.available) {
        return [ordered]@{
            available = $false
            source = 'funcom-runtime-projection'
            reason = [string]$target.reason
            target = $target
        }
    }
    Assert-DuneRetailKubernetesName -Value ([string]$target.pod) -Label 'pod name'
    $cmd = @"
sudo kubectl exec -n '$($target.namespace)' '$($target.pod)' -- sh -lc '
f="$($target.path)"
if [ "`$(cat /srv/UserSettings/.dst-server-settings-file-authority-v1 2>/dev/null)" = file-authority-v1 ]; then echo __DST_FILE_AUTHORITY__; fi
if [ ! -f "`$f" ]; then echo __DST_MISSING__; exit 0; fi
echo __DST_META__
stat -c "%Y|%s" "`$f"
sha256sum "`$f" | cut -d" " -f1
echo __DST_CONTENT__
base64 "`$f" | tr -d "\n"
'
"@
    $output = (Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 30) -join "`n"
    $fileAuthority = $output -match '(?m)^__DST_FILE_AUTHORITY__$'
    $output = $output -replace '(?m)^__DST_FILE_AUTHORITY__\r?\n?', ''
    if ($output -match '(?m)^__DST_MISSING__$') {
        return Select-DuneRetailServerSettingsAuthority -FileAuthority $fileAuthority -Snapshot ([ordered]@{
            available = $true
            source = 'funcom-persistent-user-settings'
            authority = 'Linux UserSettings/UserServerCustomSettings.ini'
            fileExists = $false
            raw = ''
            revision = Get-DuneRetailServerSettingsTextSha256 -Value ''
            bytes = 0
            modifiedAt = ''
            target = $target
        })
    }
    if ($output -notmatch '(?ms)^__DST_META__\s*\n([^\n]+)\n([0-9a-f]{64})\s*\n__DST_CONTENT__\s*\n([A-Za-z0-9+/=]*)\s*$') {
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
    if ((Get-DuneRetailServerSettingsTextSha256 -Value $raw) -cne $revision) {
        throw 'Retail Server Settings file changed during read. Refresh and try again.'
    }
    return Select-DuneRetailServerSettingsAuthority -FileAuthority $fileAuthority -Snapshot ([ordered]@{
        available = $true
        source = 'funcom-persistent-user-settings'
        authority = 'Linux UserSettings/UserServerCustomSettings.ini'
        fileExists = $true
        raw = $raw
        revision = $revision
        modifiedAt = if ($modifiedEpoch -gt 0) {
            [DateTimeOffset]::FromUnixTimeSeconds($modifiedEpoch).UtcDateTime.ToString('o')
        } else {
            ''
        }
        bytes = $size
        target = $target
    })
}

function Get-DuneRetailServerSettings {
    param([Parameter(Mandatory)][string]$Ip, [switch]$ReadOperator)

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
    $operatorRevision = $null
    if ($ReadOperator) {
        if (-not $snapshot.target.upstreamConfigured -or [string]::IsNullOrWhiteSpace([string]$snapshot.target.upstreamContent)) {
            throw 'No existing YAML Server Settings are configured to read.'
        }
        $raw = [string]$snapshot.target.upstreamContent
        $operatorRevision = Get-DuneRetailServerSettingsTextSha256 -Value $raw
        $snapshot.source = 'operator-import-draft'
        $snapshot.authority = 'YAML settings draft (Save writes the Linux UserSettings file)'
        $snapshot.bytes = [Text.Encoding]::UTF8.GetByteCount($raw)
        $snapshot.modifiedAt = ''
    }
    $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $raw
    return [ordered]@{
        available = $true
        readOnly = $false
        source = [string]$snapshot.source
        authority = [string]$snapshot.authority
        revision = [string]$snapshot.revision
        operatorRevision = $operatorRevision
        operatorMismatch = $snapshot.target.upstreamConfigured -and
            (Get-DuneRetailServerSettingsTextSha256 -Value ([string]$snapshot.target.upstreamContent)) -cne [string]$snapshot.fileRevision
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
            backup = 'Saved/UserSettings/UserServerCustomSettings.ini.dstbak-<UTC timestamp>'
        }
        applyBehavior = [ordered]@{
            mode = 'operator-mounted'
            restartRequired = $true
            note = if ($snapshot.needsMigration) {
                'Existing YAML settings are preserved until they are backed up and migrated to the Linux UserSettings file on the next stopped-battlegroup Save or Start.'
            } else {
                'The Linux UserSettings file is authoritative. Start the stopped battlegroup to apply its values to the LinuxServer runtime file.'
            }
        }
    }
}

function ConvertTo-DuneRetailServerSettingsUpdatedRaw {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Raw,
        [Parameter(Mandatory)][hashtable]$Updates
    )
    $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $Raw
    $present = @{}
    foreach ($setting in $parsed.settings) {
        if ($setting.present) { $present[[string]$setting.key] = $true }
    }
    $normalized = @{}
    foreach ($keyValue in $Updates.GetEnumerator()) {
        $key = [string]$keyValue.Key
        $definition = Get-DuneRetailServerSettingDefinition -Key $key
        $value = ([string]$keyValue.Value).Trim()
        # Default Settings explicitly requests Custom, and can seed an absent
        # PvP mode. Preserve existing PvP rules and reject other preset writes.
        $defaultUpdate = ($key -ceq 'DifficultyLevel' -and $value -ceq 'Custom') -or
            ($key -ceq 'PVPMode' -and -not $present.ContainsKey($key) -and $value -ceq 'Limited')
        if (-not $definition -or (-not $definition.editable -and -not $defaultUpdate)) {
            throw "Retail setting $key is not editable."
        }
        if (-not (Test-DuneRetailServerSettingValue -Definition $definition -Value $value)) {
            throw "Retail setting $key has an invalid $($definition.type) value."
        }
        $normalized[$key] = if ($definition.type -eq 'bool') {
            if ($value -eq 'True') { 'True' } else { 'False' }
        } else { $value }
    }
    if ($normalized.Count -eq 0) { throw 'No editable Retail Server Settings were provided.' }

    $inside = $false
    $parts = [regex]::Split($Raw, '(\r\n|\n|\r)')
    $insertionIndex = -1
    $foundSection = $false
    for ($index = 0; $index -lt $parts.Length; $index += 2) {
        $line = $parts[$index]
        if ($line.TrimStart([char]0xFEFF) -match '^\s*\[(.+)\]\s*$') {
            if ($inside -and $insertionIndex -lt 0) { $insertionIndex = $index }
            $inside = ($Matches[1] -eq $script:DuneRetailServerSettingsSection)
            if ($inside) { $foundSection = $true }
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
    $missing = @($normalized.Keys | Where-Object { -not $present.ContainsKey($_) } | Sort-Object)
    if ($missing.Count -gt 0) {
        $newline = if ($Raw -match '\r\n|\n|\r') { $Matches[0] } else { "`n" }
        $additions = ($missing | ForEach-Object { "$_=$($normalized[$_])" }) -join $newline
        if ($insertionIndex -lt 0) { $insertionIndex = $parts.Length }
        $prefix = ($parts | Select-Object -First $insertionIndex) -join ''
        $suffix = ($parts | Select-Object -Skip $insertionIndex) -join ''
        if ($prefix.Length -gt 0 -and $prefix -notmatch '[\r\n]$' -and $prefix -ne [string][char]0xFEFF) {
            $prefix += $newline
        }
        if (-not $foundSection) { $prefix += "[$script:DuneRetailServerSettingsSection]$newline" }
        return "$prefix$additions$newline$suffix"
    }
    return $parts -join ''
}

function Backup-DuneRetailServerSettingsContent {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Raw
    )
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
    $backup = "$($Target.path).dstbak-$stamp"
    $expected = Get-DuneRetailServerSettingsTextSha256 -Value $Raw
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Raw))
    $cmd = "sudo kubectl exec -n '$($Target.namespace)' '$($Target.pod)' -- mkdir -p /srv/UserSettings && base64 -d | sudo kubectl exec -i -n '$($Target.namespace)' '$($Target.pod)' -- tee '$backup' >/dev/null && sudo kubectl exec -n '$($Target.namespace)' '$($Target.pod)' -- sha256sum '$backup'"
    $hashOutput = ((Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $payload -TimeoutSec 30) -join '').Trim()
    $actual = @($hashOutput -split '\s+' | Where-Object { $_ })[0]
    if ($actual -ne $expected) {
        throw 'Retail Server Settings backup verification failed; the operator configuration was not changed.'
    }
    return [ordered]@{ path = $backup; sha256 = $actual; timestamp = $stamp }
}

function Copy-DuneRetailServerSettingsMap {
    param([Parameter(Mandatory)]$Value)

    $copy = [ordered]@{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $copy[$key] = $Value[$key] }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    } else {
        throw 'Retail Server Settings expected an operator configuration object.'
    }
    return $copy
}

function Write-DuneRetailServerSettingsFile {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [bool]$ExpectedExists = $true,
        [switch]$Remove
    )
    $hash = Get-DuneRetailServerSettingsTextSha256 -Value $Content
    $exists = if ($ExpectedExists) { 'yes' } else { 'no' }
    $removeFile = if ($Remove) { 'yes' } else { 'no' }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
    # The temporary file stays on the same PVC. Check the original immediately
    # before atomic replacement; refuse rollback over a concurrent manual edit.
    $cmd = @"
base64 -d | sudo kubectl exec -i -n '$($Target.namespace)' '$($Target.pod)' -- sh -c '
set -eu
f="$($Target.path)"
mkdir -p /srv/UserSettings
mkdir -p "`$(dirname "`$f")"
t=`$(mktemp /srv/UserSettings/.dst-settings.XXXXXX)
# A cleanup function avoids backslash-escaped quotes, which are corrupted by
# the PS 5.1-compatible Windows SSH command-line transport.
cleanup() { rm -f "`$t"; }
trap cleanup EXIT
cat > "`$t"
[ "`$(sha256sum "`$t" | cut -d" " -f1)" = "$hash" ]
if [ -f "`$f" ]; then
  [ "$exists" = yes ] && [ "`$(sha256sum "`$f" | cut -d" " -f1)" = "$ExpectedRevision" ] || { echo __DST_CONFLICT__; exit 1; }
  chmod "`$(stat -c %a "`$f")" "`$t"
  chown "`$(stat -c %u "`$f"):`$(stat -c %g "`$f")" "`$t"
else
  [ "$exists" = no ] || { echo __DST_CONFLICT__; exit 1; }
  chmod 644 "`$t"
  chown "`$(stat -c %u /srv/UserSettings):`$(stat -c %g /srv/UserSettings)" "`$t"
fi
if [ "$removeFile" = yes ]; then rm -f "`$f"; else mv -f "`$t" "`$f"; fi
if [ "$removeFile" != yes ]; then [ "`$(sha256sum "`$f" | cut -d" " -f1)" = "$hash" ]; fi
echo __DST_FILE_SAVED__:$hash
'
"@
    $output = (Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $payload -TimeoutSec 30) -join "`n"
    if ($output -notmatch "(?m)^__DST_FILE_SAVED__:$hash`$") {
        throw 'Linux Server Settings file write failed or the file changed concurrently. Refresh before trying again.'
    }
}

function Set-DuneRetailServerSettingsFileAuthority {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$ExpectedRevision)
    $cmd = @"
sudo kubectl exec -n '$($Target.namespace)' '$($Target.pod)' -- sh -c '
set -eu
[ "`$(sha256sum "$($Target.path)" | cut -d" " -f1)" = "$ExpectedRevision" ]
m=/srv/UserSettings/.dst-server-settings-file-authority-v1
t=`$(mktemp /srv/UserSettings/.dst-authority.XXXXXX)
cleanup() { rm -f "`$t"; }
trap cleanup EXIT
printf "file-authority-v1\n" > "`$t"
chmod 644 "`$t"
mv -f "`$t" "`$m"
[ "`$(cat "`$m")" = file-authority-v1 ]
echo __DST_AUTHORITY_SAVED__
'
"@
    $output = (Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 30) -join "`n"
    if ($output -notmatch '(?m)^__DST_AUTHORITY_SAVED__$') {
        throw 'Linux file authority migration could not be verified.'
    }
}

function Get-DuneRetailServerSettingsRuntimeSnapshot {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)]$Target)
    $runtimeTarget = Copy-DuneRetailServerSettingsMap -Value $Target
    $runtimeTarget.path = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
    $runtimeTarget.upstreamConfigured = $false
    return Get-DuneRetailServerSettingsSnapshot -Ip $Ip -TargetOverride $runtimeTarget
}

function Set-DuneRetailServerSettings {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Updates,
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [string]$ImportOperatorRevision,
        [switch]$SynchronizeOnly
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
    if ($ImportOperatorRevision) {
        if (-not $target.upstreamConfigured -or
            (Get-DuneRetailServerSettingsTextSha256 -Value ([string]$target.upstreamContent)) -cne $ImportOperatorRevision) {
            throw [InvalidOperationException]::new('YAML settings changed since they were read. Read current settings again before saving.')
        }
        $raw = [string]$target.upstreamContent
    }
    $updated = if ($SynchronizeOnly -or ($ImportOperatorRevision -and $Updates.Count -eq 0)) { $raw } else {
        ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates $Updates
    }
    $updatedRevision = Get-DuneRetailServerSettingsTextSha256 -Value $updated
    $bg = Get-V6Battlegroup -Ip $Ip
    if ([string]$bg.Bg.metadata.resourceVersion -cne [string]$target.resourceVersion) {
        throw [InvalidOperationException]::new('Battlegroup configuration changed during save. No operator configuration was changed.')
    }
    $groupSpec = $bg.Bg.spec.serverGroup.template.spec
    $hadGlobal = if ($groupSpec -is [Collections.IDictionary]) {
        $groupSpec.Contains('global')
    } else {
        $null -ne $groupSpec.PSObject.Properties['global']
    }
    $originalGlobal = $groupSpec.global
    $globalMap = if ($null -eq $originalGlobal) { @{} } else {
        Copy-DuneRetailServerSettingsMap -Value $originalGlobal
    }
    if ($globalMap -isnot [Collections.IDictionary]) {
        throw 'Retail Server Settings cannot update an invalid operator global configuration.'
    }
    $hadUserIni = $globalMap.Contains('userIniConfig')
    $originalUserIni = $globalMap.userIniConfig
    $canonicalMount = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
    $userIni = if ($null -eq $originalUserIni) {
        @{ mountPath = $canonicalMount; files = @{} }
    } else {
        Copy-DuneRetailServerSettingsMap -Value $originalUserIni
    }
    if ($userIni -isnot [Collections.IDictionary] -or
        [string]::IsNullOrEmpty([string]$userIni.mountPath) -or
        ([string]$userIni.mountPath).TrimEnd('/') -cne $canonicalMount) {
        throw 'Retail Server Settings requires the existing userIniConfig mountPath to be the game LinuxServer config directory. The incompatible or missing mount path was not changed.'
    }
    $userIni.files = if ($null -eq $userIni.files) { @{} } else {
        Copy-DuneRetailServerSettingsMap -Value $userIni.files
    }
    if ($target.upstreamConfigured -and [string]$target.upstreamFileName -cne 'ServerCustomSettings.ini') {
        throw 'Retail Server Settings cannot update a nonstandard operator filename. No operator configuration was changed.'
    }
    $userIni.files['ServerCustomSettings.ini'] = $updated

    $globalPath = '/spec/serverGroup/template/spec/global'
    $patchPath = if ($null -eq $originalGlobal) { $globalPath } else { "$globalPath/userIniConfig" }
    $patchValue = if ($null -eq $originalGlobal) { @{ userIniConfig = $userIni } } else { $userIni }
    $patchObject = @(
        [ordered]@{ op = 'test'; path = '/metadata/resourceVersion'; value = [string]$bg.Bg.metadata.resourceVersion }
        [ordered]@{
            op = if (($null -eq $originalGlobal -and $hadGlobal) -or
                ($null -ne $originalGlobal -and $hadUserIni)) { 'replace' } else { 'add' }
            path = $patchPath
            value = $patchValue
        }
    )
    $fileRaw = if ($current.Contains('fileRaw')) { [string]$current.fileRaw } else { $raw }
    $fileRevision = Get-DuneRetailServerSettingsTextSha256 -Value $fileRaw
    $fileExisted = $current.fileExists -ne $false
    $runtime = Get-DuneRetailServerSettingsRuntimeSnapshot -Ip $Ip -Target $target
    if (-not $runtime.available) { throw 'The Linux runtime settings could not be inspected. No settings were changed.' }
    $backup = Backup-DuneRetailServerSettingsContent -Ip $Ip -Target $target -Raw $fileRaw
    $operatorRaw = [string]$target.upstreamContent
    if ($target.upstreamConfigured -and $operatorRaw -cne $fileRaw) {
        $operatorBackupTarget = Copy-DuneRetailServerSettingsMap -Value $target
        $operatorBackupTarget.path = "$($target.path).operator"
        $backup.operator = Backup-DuneRetailServerSettingsContent -Ip $Ip -Target $operatorBackupTarget -Raw $operatorRaw
    }
    $writeRuntime = -not $runtime.fileExists -or [string]$runtime.revision -cne $updatedRevision
    if ($writeRuntime) {
        $backup.runtime = Backup-DuneRetailServerSettingsContent -Ip $Ip -Target $runtime.target -Raw ([string]$runtime.raw)
    }
    $writeFile = -not $SynchronizeOnly -or $current.needsMigration
    if ($writeFile) {
        Write-DuneRetailServerSettingsFile -Ip $Ip -Target $target -Content $updated `
            -ExpectedRevision $fileRevision -ExpectedExists $fileExisted
    }
    $runtimeWritten = $false
    try {
        if ($writeRuntime) {
            Write-DuneRetailServerSettingsFile -Ip $Ip -Target $runtime.target -Content $updated `
                -ExpectedRevision $runtime.revision -ExpectedExists $runtime.fileExists
            $runtimeWritten = $true
        }
        $patch = ConvertTo-Json -InputObject $patchObject -Depth 100 -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patch))
        $patchCmd = "base64 -d | sudo kubectl patch battlegroup '$($target.battlegroup)' -n '$($target.namespace)' --type=json --patch-file=/dev/stdin 2>&1"
        $patched = ((Invoke-V6Ssh -Ip $Ip -Cmd $patchCmd -StdinData $payload -TimeoutSec 30) -join "`n").Trim()
        if ($patched -notmatch '\bpatched\b') {
            throw "Retail Server Settings operator patch failed; the verified backup was retained. $patched"
        }

        try {
            $verified = Get-V6Battlegroup -Ip $Ip
            $verifiedUserIni = $verified.Bg.spec.serverGroup.template.spec.global.userIniConfig
            $applied = [string]$verifiedUserIni.files.'ServerCustomSettings.ini'
            if ((Get-DuneRetailServerSettingsTextSha256 -Value $applied) -cne $updatedRevision) {
                throw 'Retail Server Settings operator readback did not match the requested file.'
            }
            if ([string]$verifiedUserIni.mountPath -cne [string]$userIni.mountPath) {
                throw 'Retail Server Settings operator readback did not preserve the mount path.'
            }
            $verifiedFiles = Copy-DuneRetailServerSettingsMap -Value $verifiedUserIni.files
            foreach ($file in $userIni.files.Keys) {
                if (-not $verifiedFiles.Contains($file) -or [string]$verifiedFiles[$file] -cne [string]$userIni.files[$file]) {
                    throw 'Retail Server Settings operator readback did not preserve all configured files.'
                }
            }
            if (-not $current.fileAuthority) {
                Set-DuneRetailServerSettingsFileAuthority -Ip $Ip -Target $target -ExpectedRevision $updatedRevision
            }
        } catch {
            $rollbackBg = Get-V6Battlegroup -Ip $Ip
            $hadPatchField = if ($null -eq $originalGlobal) { $hadGlobal } else { $hadUserIni }
            $rollbackChange = if ($hadPatchField) {
                [ordered]@{
                    op = 'replace'
                    path = $patchPath
                    value = if ($null -eq $originalGlobal) { $originalGlobal } else { $originalUserIni }
                }
            } else {
                [ordered]@{ op = 'remove'; path = $patchPath }
            }
            $rollbackObject = @(
                [ordered]@{ op = 'test'; path = '/metadata/resourceVersion'; value = [string]$rollbackBg.Bg.metadata.resourceVersion }
                [ordered]@{ op = 'test'; path = $patchPath; value = $patchValue }
                $rollbackChange
            )
            $rollbackJson = ConvertTo-Json -InputObject $rollbackObject -Depth 100 -Compress
            $rollbackPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rollbackJson))
            $rollbackResult = ((Invoke-V6Ssh -Ip $Ip -Cmd $patchCmd -StdinData $rollbackPayload -TimeoutSec 30) -join "`n").Trim()
            if ($rollbackResult -notmatch '\bpatched\b') {
                throw "Retail Server Settings verification failed and automatic rollback also failed or was refused to preserve concurrent operator changes. The verified backup was retained. $rollbackResult"
            }
            throw "Retail Server Settings verification failed; the original operator configuration was restored. $($_.Exception.Message)"
        }
    } catch {
        $saveError = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        if ($runtimeWritten) {
            try {
                Write-DuneRetailServerSettingsFile -Ip $Ip -Target $runtime.target -Content ([string]$runtime.raw) `
                    -ExpectedRevision $updatedRevision -ExpectedExists $true -Remove:(-not $runtime.fileExists)
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($writeFile) {
            try {
                Write-DuneRetailServerSettingsFile -Ip $Ip -Target $target -Content $fileRaw `
                    -ExpectedRevision $updatedRevision -ExpectedExists $true -Remove:(-not $fileExisted)
            } catch {
                $rollbackErrors.Add($_.Exception.Message)
            }
        }
        if ($rollbackErrors.Count) {
            throw "$saveError Linux file rollback failed or was refused to preserve concurrent edits. The verified backups were retained. $($rollbackErrors -join ' ')"
        }
        throw $saveError
    }

    $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $updated
    $savedTarget = Get-DuneRetailServerSettingsPublicTarget -Target $target
    $savedTarget.upstreamConfigured = $true
    $savedTarget.upstreamMountPath = [string]$userIni.mountPath
    $savedTarget.upstreamFileName = 'ServerCustomSettings.ini'
    return [ordered]@{
        ok = $true
        applied = if ($ImportOperatorRevision) { @($parsed.settings | Where-Object present).Count } else { $Updates.Count }
        revision = $updatedRevision
        backup = $backup
        restartRequired = $true
        message = 'Server Settings saved to Linux UserSettings and synchronized to Funcom operator configuration. Start the battlegroup to apply them.'
        settings = @($parsed.settings)
        target = $savedTarget
    }
}

function Sync-DuneRetailServerSettingsForStartup {
    param([Parameter(Mandatory)][string]$Ip)
    $snapshot = Get-DuneRetailServerSettingsSnapshot -Ip $Ip
    if (-not $snapshot.available) { throw [string]$snapshot.reason }
    if (-not $snapshot.fileExists -and -not $snapshot.needsMigration) {
        return @{ ok = $true; skipped = $true }
    }
    if (-not $snapshot.needsMigration -and $snapshot.target.upstreamConfigured -and
        [string]$snapshot.target.upstreamContent -ceq [string]$snapshot.raw) {
        $runtime = Get-DuneRetailServerSettingsRuntimeSnapshot -Ip $Ip -Target $snapshot.target
        if ($runtime.available -and $runtime.fileExists -and [string]$runtime.revision -ceq [string]$snapshot.revision) {
            return @{ ok = $true; unchanged = $true }
        }
    }
    return Set-DuneRetailServerSettings -Ip $Ip -Updates @{} `
        -ExpectedRevision $snapshot.revision -SynchronizeOnly
}

function Select-DuneRetailServerSettingsAuthority {
    param([Parameter(Mandatory)]$Snapshot, [bool]$FileAuthority)
    $Snapshot.fileRaw = [string]$Snapshot.raw
    $Snapshot.fileRevision = [string]$Snapshot.revision
    $Snapshot.fileAuthority = $FileAuthority
    $Snapshot.needsMigration = $Snapshot.target.upstreamConfigured -and -not $FileAuthority -and
        -not [string]::IsNullOrWhiteSpace([string]$Snapshot.target.upstreamContent)
    if ($Snapshot.needsMigration) {
        # Preserve existing YAML overrides on the first upgrade. Reading never
        # mutates the server; the stopped-BG save/start transaction migrates them.
        $Snapshot.raw = [string]$Snapshot.target.upstreamContent
        $Snapshot.revision = Get-DuneRetailServerSettingsTextSha256 -Value $Snapshot.raw
        $Snapshot.source = 'existing-operator-settings-pending-migration'
        $Snapshot.authority = 'Existing operator settings (Linux file migration pending)'
        $Snapshot.bytes = [Text.Encoding]::UTF8.GetByteCount($Snapshot.raw)
        $Snapshot.modifiedAt = ''
    }
    return $Snapshot
}
