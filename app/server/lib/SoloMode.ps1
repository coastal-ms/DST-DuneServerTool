$script:DuneSoloSection = '/Script/DuneSandbox.UserServerCustomSettings'
$script:DuneSoloSettingKeys = @(
    'DifficultyLevel',
    'PVPMode',
    'GatheringAmount',
    'CraftingCost',
    'WaterExtractionRate',
    'CraftingTimeMultiplier',
    'BuildingCostMultiplier',
    'ResourceRespawnSpeed',
    'LootRespawnSpeed',
    'FuelBurnTimeMultiplier',
    'InventoryVolumeMultiplier',
    'PlayerDamageToPlayer',
    'PlayerDamageToNPC',
    'PlayerDamageToVehicle',
    'PlayerStaminaDrain',
    'IntelPointsGainMultiplier',
    'NPCHealth',
    'NPCDamageToPlayer',
    'NPCDamageToNPC',
    'NPCRespawnMultiplier',
    'PVPDamageStructures',
    'GlobalXpMultiplier',
    'CombatXp',
    'GatheringXp',
    'MissionXp',
    'ItemDurabilityDrainMultiplier',
    'bEnableItemMaxDurabilityLoss',
    'PlayerShieldDamageAbsorptionMultiplier',
    'NPCShieldDamageAbsorptionMultiplier',
    'HeatBuildupRate',
    'ColdBuildupRate',
    'ThirstMultiplier',
    'DropEquipmentOnDeath',
    'bAllowDynamicBuildingDamage',
    'bAllowSandstorms',
    'bAllowSandworms',
    'SandwormConsequences',
    'PlayerDeathLootRule',
    'bIsBuildingRestrictionsEnabled',
    'FiefdomLimit',
    'BuildingPieceLimitMultiplier',
    'MaxLandclaimSegments',
    'bBuildingInfiniteStability',
    'BaseBackupToolTimeRestriction',
    'LandsraadContributionMultiplier',
    'LandsraadSpecializationXpMultiplier',
    'LandsraadFactionStandingMultiplier',
    'bLandsraadDisableDecreeRerollLimit'
)
$script:DuneSoloReadOnlySettingKeys = @('DifficultyLevel', 'PVPMode')
$script:DuneSoloBooleanSettingKeys = @(
    'bEnableItemMaxDurabilityLoss',
    'bAllowDynamicBuildingDamage',
    'bAllowSandstorms',
    'bAllowSandworms',
    'bIsBuildingRestrictionsEnabled',
    'bBuildingInfiniteStability',
    'bLandsraadDisableDecreeRerollLimit'
)
$script:DuneSoloIntegerSettingKeys = @('FiefdomLimit', 'MaxLandclaimSegments')
$script:DuneSoloSelectSettingOptions = @{
    DropEquipmentOnDeath = @('Default', 'None', 'Backpack', 'All')
    SandwormConsequences = @('Default', 'None', 'Backpack', 'All')
    PlayerDeathLootRule = @('DependsOnSecurityZone', 'NeverAllowOtherPlayers', 'AlwaysAllowOtherPlayers')
}
$script:DuneSoloConsoleSection = 'ConsoleVariables'
$script:DuneSoloConsoleSettings = @(
    [ordered]@{
        key = 'Hydration.SunExposureEnabled'
        type = 'bool01'
        default = '1'
        label = 'Sun Exposure Enabled'
        help = 'PTC Solo field-confirmed. Disabled prevents sun exposure and its water drain.'
        status = 'Confirmed'
    },
    [ordered]@{
        key = 'Vehicle.MaxVehiclesPerPlayer'
        type = 'int'
        min = 0
        max = 1000
        default = '10'
        label = 'Maximum Vehicles Per Player'
        help = 'Client-driven vehicle cap. 0 means unlimited.'
        status = 'Confirmed'
    },
    [ordered]@{
        key = 'Dune.DisableShieldOnShooting'
        type = 'bool01'
        default = '1'
        label = 'Shield Drops While Shooting'
        help = 'PTC Solo field-confirmed. Disabled keeps the player shield raised while firing.'
        status = 'Confirmed'
    }
)

function Test-DuneSoloSupportedPlatform {
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($isWindowsVariable) { return [bool]$isWindowsVariable.Value }
    return ($env:OS -eq 'Windows_NT')
}

function Assert-DuneSoloSupportedPlatform {
    if (-not (Test-DuneSoloSupportedPlatform)) {
        throw 'Solo Mode is available only on the Windows host running Dune: Awakening.'
    }
}

function Get-DuneSoloStatePath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    Join-Path $dir 'solo-mode.json'
}

function Get-DuneSoloBackupRoot {
    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    Join-Path $dir 'SoloBackups'
}

function Get-DuneSoloDefaultDataRoot {
    Join-Path $env:LOCALAPPDATA 'DuneSandbox\Saved'
}

function Get-DuneSoloHelperPath {
    $candidates = @()
    if ($script:AppDir) {
        $candidates += (Join-Path $script:AppDir 'tools\solo\DuneSoloDb.exe')
    }
    $candidates += (Join-Path $PSScriptRoot '..\..\tools\DuneSoloDb\bin\Release\net10.0-windows\win-x64\publish\DuneSoloDb.exe')
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        } catch {}
    }
    return $null
}

function Get-DuneSoloGameplayCatalogPath {
    $candidates = @()
    if ($script:AppDir) {
        $candidates += (Join-Path $script:AppDir 'data\gameplay-item-data.json')
    }
    $candidates += (Join-Path $PSScriptRoot '..\..\data\gameplay-item-data.json')
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        } catch {}
    }
    throw 'DST item metadata is unavailable. Rebuild or reinstall DST.'
}

function Get-DuneSoloDataFilePath {
    param([Parameter(Mandatory)][string]$Name)
    $candidates = @()
    if ($script:AppDir) {
        $candidates += (Join-Path $script:AppDir "data\$Name")
    }
    $candidates += (Join-Path $PSScriptRoot "..\..\data\$Name")
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        } catch {}
    }
    throw "DST data file is unavailable: $Name"
}

function Read-DuneSoloState {
    $path = Get-DuneSoloStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{
            dataRoot = if ($value.dataRoot) { [string]$value.dataRoot } else { '' }
            dbPath = if ($value.dbPath) { [string]$value.dbPath } else { '' }
            adapter = if ($value.adapter) { [string]$value.adapter } else { 'ptc-auto' }
        }
    } catch {
        throw "Solo Mode state is malformed: $($_.Exception.Message)"
    }
}

function Save-DuneSoloState {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$DbPath,
        [string]$Adapter = 'ptc-auto'
    )

    $statePath = Get-DuneSoloStatePath
    $dir = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload = [ordered]@{
        dataRoot = [IO.Path]::GetFullPath($DataRoot)
        dbPath = [IO.Path]::GetFullPath($DbPath)
        adapter = $Adapter
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $temp = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $payload | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $statePath -Force
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    return $payload
}

function Test-DuneSoloPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Resolve-DuneSoloDataRoot {
    param([Parameter(Mandatory)][string]$SelectedPath)

    $current = [IO.Path]::GetFullPath($SelectedPath)
    if (-not (Test-Path -LiteralPath $current -PathType Container)) {
        throw "Selected Solo folder does not exist: $current"
    }
    for ($i = 0; $i -lt 8 -and $current; $i++) {
        $hasConfig = Test-Path -LiteralPath (Join-Path $current 'Config') -PathType Container
        $hasCloud = Test-Path -LiteralPath (Join-Path $current 'Cloud') -PathType Container
        if ($hasConfig -or $hasCloud -or ([IO.Path]::GetFileName($current) -eq 'Saved')) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return [IO.Path]::GetFullPath($SelectedPath)
}

function Find-DuneSoloProfiles {
    param([Parameter(Mandatory)][string]$DataRoot)

    $root = [IO.Path]::GetFullPath($DataRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $searchRoot = Join-Path $root 'Cloud\PlayerClientStorage'
    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
        $searchRoot = $root
    }
    $files = @(Get-ChildItem -LiteralPath $searchRoot -Filter 'game.db' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 20)
    $profiles = foreach ($file in $files) {
        $profileDir = Split-Path -Parent $file.FullName
        $channelDir = Split-Path -Parent $profileDir
        [pscustomobject]@{
            id = [IO.Path]::GetFileName($profileDir)
            channel = [IO.Path]::GetFileName($channelDir)
            dbPath = $file.FullName
            modifiedAt = $file.LastWriteTimeUtc.ToString('o')
            bytes = [long]$file.Length
        }
    }
    return @($profiles)
}

function Get-DuneSoloDiscovery {
    param([Parameter(Mandatory)][string]$SelectedPath)

    Assert-DuneSoloSupportedPlatform
    $selectedFull = [IO.Path]::GetFullPath($SelectedPath)
    $dataRoot = Resolve-DuneSoloDataRoot -SelectedPath $selectedFull
    $profiles = @(Find-DuneSoloProfiles -DataRoot $dataRoot)
    $directDb = Join-Path $selectedFull 'game.db'
    $suggestedDb = ''
    if (Test-Path -LiteralPath $directDb -PathType Leaf) {
        $suggestedDb = $directDb
    } elseif ($profiles.Count -eq 1) {
        $suggestedDb = [string]$profiles[0].dbPath
    }
    return @{
        ok = $true
        dataRoot = $dataRoot
        settingsPath = Join-Path $dataRoot 'Config\Windows\ServerCustomSettings.ini'
        profiles = $profiles
        suggestedDbPath = $suggestedDb
    }
}

function Get-DuneSoloGameProcesses {
    $names = @('DuneSandbox', 'DuneSandbox_BE', 'DuneSandbox-Win64-Shipping')
    $found = @()
    foreach ($name in $names) {
        try {
            $found += @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ name = $_.ProcessName; pid = [int]$_.Id }
            })
        } catch {}
    }
    return @($found | Sort-Object pid -Unique)
}

function Assert-DuneSoloGameClosed {
    $processes = @(Get-DuneSoloGameProcesses)
    if ($processes.Count -gt 0) {
        $names = ($processes | ForEach-Object { "$($_.name) (PID $($_.pid))" }) -join ', '
        throw "Dune: Awakening is still running: $names. Close the game completely before writing Solo data."
    }
}

function Invoke-DuneSoloHelper {
    param(
        [Parameter(Mandatory)][ValidateSet('inspect','backup','restore','grant-items','set-currencies','fill-water','max-augment-attributes','max-specializations','complete-fremen','enable-skills')][string]$Command,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $helper = Get-DuneSoloHelperPath
    if (-not $helper) {
        throw 'DuneSoloDb.exe is unavailable. Rebuild or reinstall DST with Solo Mode support.'
    }
    $cli = @('--command', $Command)
    foreach ($key in ($Arguments.Keys | Sort-Object)) {
        $cli += "--$key"
        $cli += [string]$Arguments[$key]
    }
    $output = @(& $helper @cli 2>&1)
    $exitCode = $LASTEXITCODE
    $raw = ($output -join "`n").Trim()
    $result = $null
    if ($raw) {
        try { $result = $raw | ConvertFrom-Json } catch {}
    }
    if ($exitCode -ne 0) {
        $message = if ($result -and $result.error) { [string]$result.error } elseif ($raw) { $raw } else { "DuneSoloDb failed with exit code $exitCode." }
        throw $message
    }
    if (-not $result -or -not $result.ok) {
        throw 'DuneSoloDb returned an invalid result.'
    }
    return $result
}

function Assert-DuneSoloPtcAdapter {
    param([Parameter(Mandatory)][hashtable]$Profile)
    $profileDir = Split-Path -Parent ([string]$Profile.dbPath)
    $channel = [IO.Path]::GetFileName((Split-Path -Parent $profileDir))
    if ($channel -ne 'FLS_beta') {
        throw "Progression actions are enabled only for the verified PTC FLS_beta adapter; found '$channel'."
    }
}

function Invoke-DuneSoloProgressionAction {
    param(
        [Parameter(Mandatory)][ValidateSet('max-specializations','complete-fremen','enable-skills')][string]$Action,
        [Parameter(Mandatory)][string]$Confirm,
        [Parameter(Mandatory)][string]$ExpectedConfirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne $ExpectedConfirm) {
        throw 'Confirm the offline Solo progression action before continuing.'
    }
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before changing progression.'
    }
    Assert-DuneSoloPtcAdapter -Profile $profile
    $safetyDir = Join-Path (Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath) 'pre-progression'
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $safety = Join-Path $safetyDir "game-before-$Action-$stamp.db"
    $arguments = @{
        input = $profile.dbPath
        'safety-backup' = $safety
        adapter = Get-DuneSoloDataFilePath -Name 'solo-ptc-v1.json'
    }
    if ($Action -eq 'max-specializations') {
        $arguments['keystones'] = Get-DuneSoloDataFilePath -Name 'dune-keystones.json'
    } elseif ($Action -eq 'enable-skills') {
        $arguments['skills'] = Get-DuneSoloDataFilePath -Name 'dune-skills-catalog.json'
    }
    return Invoke-DuneSoloHelper -Command $Action -Arguments $arguments
}

function Fill-DuneSoloWaterContainer {
    param(
        [Parameter(Mandatory)][long]$ItemId,
        [Parameter(Mandatory)][string]$Confirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'FILL SOLO WATER') {
        throw 'Confirm the offline water-container fill before continuing.'
    }
    Assert-DuneSoloGameClosed
    if ($ItemId -le 0) { throw 'Choose a water container to fill.' }
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before filling a water container.'
    }
    $safetyDir = Join-Path (Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath) 'pre-fill'
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $safety = Join-Path $safetyDir "game-before-water-fill-$stamp.db"
    return Invoke-DuneSoloHelper -Command 'fill-water' -Arguments @{
        input = $profile.dbPath
        'safety-backup' = $safety
        'item-id' = $ItemId
        adapter = Get-DuneSoloDataFilePath -Name 'solo-ptc-v1.json'
    }
}

function Set-DuneSoloCurrencies {
    param(
        [Parameter(Mandatory)][long]$Solari,
        [Parameter(Mandatory)][long]$Scrip,
        [Parameter(Mandatory)][string]$Confirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'SET SOLO CURRENCIES') {
        throw 'Confirm the offline currency write before continuing.'
    }
    Assert-DuneSoloGameClosed
    foreach ($entry in @(@{ name = 'Solari'; value = $Solari }, @{ name = 'Landsraad Scrip'; value = $Scrip })) {
        if ($entry.value -lt 0 -or $entry.value -gt 2000000000) {
            throw "$($entry.name) must be between 0 and 2000000000."
        }
    }
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before setting currencies.'
    }
    $safetyDir = Join-Path (Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath) 'pre-currency'
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $safety = Join-Path $safetyDir "game-before-currency-$stamp.db"
    return Invoke-DuneSoloHelper -Command 'set-currencies' -Arguments @{
        input = $profile.dbPath
        'safety-backup' = $safety
        solari = $Solari
        scrip = $Scrip
    }
}

function Invoke-DuneSoloGiveItems {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$Confirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'GIVE SOLO ITEMS') {
        throw 'Confirm the offline item grant before continuing.'
    }
    Assert-DuneSoloGameClosed
    if (-not $Destination.Trim()) { throw 'Choose a Solo inventory destination.' }
    if ($Items.Count -lt 1 -or $Items.Count -gt 200) {
        throw 'Grant between 1 and 200 item templates per operation.'
    }

    $normalized = @()
    foreach ($item in $Items) {
        $template = ''
        $quantity = 0
        $quality = 0
        if ($item -is [hashtable]) {
            if ($item.ContainsKey('templateId')) { $template = [string]$item.templateId }
            if ($item.ContainsKey('quantity')) { $quantity = [int]$item.quantity }
            if ($item.ContainsKey('quality')) { $quality = [int]$item.quality }
        } else {
            if ($item.PSObject.Properties.Name -contains 'templateId') { $template = [string]$item.templateId }
            if ($item.PSObject.Properties.Name -contains 'quantity') { $quantity = [int]$item.quantity }
            if ($item.PSObject.Properties.Name -contains 'quality') { $quality = [int]$item.quality }
        }
        $template = $template.Trim()
        if (-not $template) { throw 'Item id is required.' }
        if ($template -match '^\d+$') {
            throw "Invalid item id '$template' - choose an item class from the catalog, not a number."
        }
        if ($quantity -lt 1 -or $quantity -gt 100000) {
            throw "Quantity for $template must be between 1 and 100000."
        }
        if ($quality -lt 0 -or $quality -gt 5) {
            throw "Quality for $template must be between 0 and 5."
        }
        $normalized += [ordered]@{
            templateId = $template.Trim()
            quantity = $quantity
            quality = $quality
        }
    }

    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before giving items.'
    }
    $profileBackupRoot = Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath
    $safetyDir = Join-Path $profileBackupRoot 'pre-grant'
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $safety = Join-Path $safetyDir "game-before-item-grant-$stamp.db"
    $plan = [ordered]@{
        destination = $Destination.Trim()
        items = @($normalized)
    }
    $planPath = Join-Path $env:TEMP "dune-solo-grant-$([guid]::NewGuid().ToString('N')).json"
    try {
        $json = $plan | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($planPath, $json, (New-Object Text.UTF8Encoding($false)))
        return Invoke-DuneSoloHelper -Command 'grant-items' -Arguments @{
            input = $profile.dbPath
            'safety-backup' = $safety
            plan = $planPath
            catalog = Get-DuneSoloGameplayCatalogPath
        }
    } finally {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DuneSoloMaxAugmentAttributes {
    param([Parameter(Mandatory)][string]$Confirm)

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'MAX SOLO AUGMENT ATTRIBUTES') {
        throw 'Confirm the offline augment update before continuing.'
    }
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before maximizing augment attributes.'
    }
    $profileBackupRoot = Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath
    $safetyDir = Join-Path $profileBackupRoot 'pre-augment'
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $safety = Join-Path $safetyDir "game-before-augment-max-$stamp.db"
    return Invoke-DuneSoloHelper -Command 'max-augment-attributes' -Arguments @{
        input = $profile.dbPath
        'safety-backup' = $safety
    }
}

function Get-DuneSoloProfile {
    $state = Read-DuneSoloState
    $dataRoot = if ($state.dataRoot) { [string]$state.dataRoot } else { Get-DuneSoloDefaultDataRoot }
    $profiles = @(Find-DuneSoloProfiles -DataRoot $dataRoot)
    $dbPath = if ($state.dbPath) { [string]$state.dbPath } else { '' }
    if ($dbPath -and -not (Test-DuneSoloPathWithinRoot -Path $dbPath -Root $dataRoot)) {
        throw 'Saved Solo database path is outside the configured data root.'
    }
    if (-not $dbPath -and $profiles.Count -eq 1) {
        $dbPath = [string]$profiles[0].dbPath
    }
    $settingsPath = Join-Path $dataRoot 'Config\Windows\ServerCustomSettings.ini'
    return @{
        dataRoot = $dataRoot
        dbPath = $dbPath
        settingsPath = $settingsPath
        adapter = if ($state.adapter) { [string]$state.adapter } else { 'ptc-auto' }
        profiles = $profiles
    }
}

function Connect-DuneSoloProfile {
    param(
        [Parameter(Mandatory)][string]$SelectedPath,
        [string]$DbPath = ''
    )

    Assert-DuneSoloSupportedPlatform
    $discovery = Get-DuneSoloDiscovery -SelectedPath $SelectedPath
    $dataRoot = [string]$discovery.dataRoot
    $profiles = @($discovery.profiles)
    if (-not $DbPath -and $discovery.suggestedDbPath) {
        $DbPath = [string]$discovery.suggestedDbPath
    }
    if ($DbPath) {
        $DbPath = [IO.Path]::GetFullPath($DbPath)
        if (-not (Test-DuneSoloPathWithinRoot -Path $DbPath -Root $dataRoot)) {
            throw 'Selected Solo database is outside the chosen data root.'
        }
        if (-not (Test-Path -LiteralPath $DbPath -PathType Leaf)) {
            throw "Selected Solo database was not found: $DbPath"
        }
    } elseif ($profiles.Count -eq 1) {
        $DbPath = [string]$profiles[0].dbPath
    } elseif ($profiles.Count -eq 0) {
        throw 'No game.db was found below the selected Solo data folder.'
    } else {
        throw "Found $($profiles.Count) Solo saves. Select one profile explicitly."
    }

    $inspection = Invoke-DuneSoloHelper -Command inspect -Arguments @{ input = $DbPath }
    Save-DuneSoloState -DataRoot $dataRoot -DbPath $DbPath -Adapter 'ptc-auto' | Out-Null
    return Get-DuneSoloStatus
}

function Get-DuneSoloStatus {
    $runtime = Get-DuneSoloRuntime
    if (-not $runtime.supported) {
        return @{
            ok = $true
            supported = $false
            platform = $runtime.platform
            connected = $false
            dataRoot = ''
            dbPath = ''
            profileToken = ''
            settingsPath = ''
            adapter = ''
            profiles = @()
            gameRunning = $false
            processes = @()
            helperAvailable = $false
            inspection = $null
            inspectionError = 'Solo Mode is available only on Windows.'
            backupRoot = ''
        }
    }
    $profile = Get-DuneSoloProfile
    $processes = @($runtime.processes)
    $connected = [bool]($profile.dbPath -and (Test-Path -LiteralPath $profile.dbPath -PathType Leaf))
    $inspection = $null
    $inspectionError = ''
    if ($connected) {
        try {
            $inspection = Invoke-DuneSoloHelper -Command inspect -Arguments @{
                input = $profile.dbPath
                catalog = Get-DuneSoloGameplayCatalogPath
                adapter = Get-DuneSoloDataFilePath -Name 'solo-ptc-v1.json'
            }
        } catch {
            $inspectionError = $_.Exception.Message
        }
    }
    return @{
        ok = $true
        supported = $true
        platform = $runtime.platform
        connected = $connected
        dataRoot = $profile.dataRoot
        dbPath = $profile.dbPath
        profileToken = if ($profile.dbPath) { Get-DuneSoloProfileToken -DbPath $profile.dbPath } else { '' }
        settingsPath = $profile.settingsPath
        adapter = $profile.adapter
        profiles = @($profile.profiles)
        gameRunning = ($processes.Count -gt 0)
        processes = $processes
        helperAvailable = [bool]$runtime.helperAvailable
        inspection = $inspection
        inspectionError = $inspectionError
        backupRoot = Get-DuneSoloBackupRoot
    }
}

function Get-DuneSoloRuntime {
    $supported = Test-DuneSoloSupportedPlatform
    $processes = @()
    if ($supported) {
        $processes = @(Get-DuneSoloGameProcesses)
    }
    return @{
        ok = $true
        supported = $supported
        platform = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        gameRunning = ($processes.Count -gt 0)
        processes = $processes
        helperAvailable = ($supported -and [bool](Get-DuneSoloHelperPath))
    }
}

function Read-DuneSoloSettings {
    param([string]$Path = '')

    Assert-DuneSoloSupportedPlatform
    if (-not $Path) { $Path = [string](Get-DuneSoloProfile).settingsPath }
    $values = @{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $inside = $false
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^\s*\[(.+)\]\s*$') {
                $inside = ($Matches[1] -eq $script:DuneSoloSection)
                continue
            }
            if ($inside -and $line -match '^\s*([^;#][^=]*?)\s*=(.*)$') {
                $values[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
    }
    $entries = foreach ($key in $script:DuneSoloSettingKeys) {
        [pscustomobject]@{
            key = $key
            value = if ($values.ContainsKey($key)) { [string]$values[$key] } else { '' }
            present = $values.ContainsKey($key)
        }
    }
    return @{
        ok = $true
        path = $Path
        exists = (Test-Path -LiteralPath $Path -PathType Leaf)
        section = $script:DuneSoloSection
        entries = @($entries)
    }
}

function Set-DuneSoloSettings {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Confirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'APPLY SOLO SETTINGS') {
        throw 'Type APPLY SOLO SETTINGS to confirm the offline write.'
    }
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { throw 'Connect a Solo save before applying settings.' }

    $allowed = @{}
    foreach ($key in $script:DuneSoloSettingKeys) { $allowed[$key] = $true }
    $normalized = @{}
    foreach ($key in $Settings.Keys) {
        $name = [string]$key
        if (-not $allowed.ContainsKey($name)) { throw "Unsupported Solo setting: $name" }
        $value = [string]$Settings[$key]
        if ($value.Length -gt 128 -or $value -match '[\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') {
            throw "Invalid value for Solo setting $name."
        }
        $trimmed = $value.Trim()
        if ($script:DuneSoloReadOnlySettingKeys -contains $name) {
            throw "Solo setting $name is controlled by the game and cannot be written by DST."
        }
        if ($script:DuneSoloBooleanSettingKeys -contains $name) {
            if ($trimmed -cnotin @('True', 'False')) {
                throw "Solo setting $name must be True or False."
            }
        } elseif ($script:DuneSoloSelectSettingOptions.ContainsKey($name)) {
            if ($trimmed -cnotin @($script:DuneSoloSelectSettingOptions[$name])) {
                throw "Solo setting $name has an unsupported option."
            }
        } elseif ($script:DuneSoloIntegerSettingKeys -contains $name) {
            if ($trimmed -notmatch '^-?\d+$') {
                throw "Solo setting $name must be a whole number."
            }
        } elseif ($trimmed -notmatch '^-?(?:\d+(?:\.\d*)?|\.\d+)$') {
            throw "Solo setting $name must be a number."
        }
        $normalized[$name] = $trimmed
    }
    if ($normalized.Count -eq 0) { throw 'No Solo settings were provided.' }

    $path = [string]$profile.settingsPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $lines = if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::ReadAllLines($path) } else { @() }
    $result = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $foundSection = $false
    $written = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($inside) {
                foreach ($key in $script:DuneSoloSettingKeys) {
                    if ($normalized.ContainsKey($key) -and -not $written.ContainsKey($key)) {
                        $result.Add("$key=$($normalized[$key])")
                        $written[$key] = $true
                    }
                }
            }
            $inside = ($Matches[1] -eq $script:DuneSoloSection)
            if ($inside) { $foundSection = $true }
            $result.Add($line)
            continue
        }
        if ($inside -and $line -match '^\s*([^;#][^=]*?)\s*=') {
            $key = $Matches[1].Trim()
            if ($normalized.ContainsKey($key)) {
                $result.Add("$key=$($normalized[$key])")
                $written[$key] = $true
                continue
            }
        }
        $result.Add($line)
    }
    if ($inside) {
        foreach ($key in $script:DuneSoloSettingKeys) {
            if ($normalized.ContainsKey($key) -and -not $written.ContainsKey($key)) {
                $result.Add("$key=$($normalized[$key])")
                $written[$key] = $true
            }
        }
    }
    if (-not $foundSection) {
        if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') { $result.Add('') }
        $result.Add("[$script:DuneSoloSection]")
        foreach ($key in $script:DuneSoloSettingKeys) {
            if ($normalized.ContainsKey($key)) {
                $result.Add("$key=$($normalized[$key])")
            }
        }
    }

    $backupRoot = Join-Path (Get-DuneSoloBackupRoot) 'settings'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $backupPath = Join-Path $backupRoot "ServerCustomSettings-$stamp.ini"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Copy-Item -LiteralPath $path -Destination $backupPath -ErrorAction Stop
    }

    $temp = Join-Path $dir ".ServerCustomSettings.$([guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = Join-Path $dir ".ServerCustomSettings.$([guid]::NewGuid().ToString('N')).previous"
    $targetExisted = Test-Path -LiteralPath $path -PathType Leaf
    $replaced = $false
    try {
        $hasBom = $false
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        }
        [IO.File]::WriteAllLines($temp, $result.ToArray(), (New-Object System.Text.UTF8Encoding($hasBom)))
        if ($targetExisted) {
            [IO.File]::Replace($temp, $path, $replaceBackup, $true)
            $replaced = $true
        } else {
            Move-Item -LiteralPath $temp -Destination $path
        }
        $verified = Read-DuneSoloSettings -Path $path
        foreach ($entry in $verified.entries) {
            if ($normalized.ContainsKey($entry.key) -and ([string]$normalized[$entry.key] -ne [string]$entry.value)) {
                throw "Solo setting verification failed for $($entry.key)."
            }
        }
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        return @{
            ok = $true
            settings = $verified
            backupPath = if (Test-Path -LiteralPath $backupPath) { $backupPath } else { '' }
        }
    } catch {
        if ($replaced -and (Test-Path -LiteralPath $replaceBackup -PathType Leaf)) {
            $failedCopy = Join-Path $dir ".ServerCustomSettings.$([guid]::NewGuid().ToString('N')).failed"
            try {
                [IO.File]::Replace($replaceBackup, $path, $failedCopy, $true)
            } finally {
                Remove-Item -LiteralPath $failedCopy -Force -ErrorAction SilentlyContinue
            }
        } elseif (-not $targetExisted -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-DuneSoloPtcEnginePaths {
    param([Parameter(Mandatory)][hashtable]$Profile)
    Assert-DuneSoloPtcAdapter -Profile $Profile
    return @(
        (Join-Path ([string]$Profile.dataRoot) 'Config\Windows\Engine.ini')
        (Join-Path ([string]$Profile.dataRoot) 'Config\WindowsClient\Engine.ini')
    )
}

function Invoke-DuneSoloFileReplace {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Backup
    )
    [IO.File]::Replace($Source, $Destination, $Backup, $true)
}

function Read-DuneSoloConsoleSettings {
    param([string]$Path = '')

    Assert-DuneSoloSupportedPlatform
    $profile = Get-DuneSoloProfile
    $profileDir = if ($profile.dbPath) { Split-Path -Parent ([string]$profile.dbPath) } else { '' }
    $channel = if ($profileDir) { [IO.Path]::GetFileName((Split-Path -Parent $profileDir)) } else { '' }
    if ($channel -ne 'FLS_beta') {
        return @{
            ok = $true
            supported = $false
            adapter = $channel
            path = ''
            exists = $false
            section = $script:DuneSoloConsoleSection
            entries = @()
        }
    }
    $paths = @(Get-DuneSoloPtcEnginePaths -Profile $profile)
    # WindowsClient is the player-visible authority for these controls. Writes
    # mirror both observed PTC files, while reads display the local-client value.
    if (-not $Path) { $Path = $paths[-1] }

    $values = @{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $inside = $false
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^\s*\[(.+)\]\s*$') {
                $inside = ($Matches[1] -eq $script:DuneSoloConsoleSection)
                continue
            }
            if ($inside -and $line -match '^\s*([^;#][^=]*?)\s*=(.*)$') {
                $values[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
    }
    $entries = foreach ($field in $script:DuneSoloConsoleSettings) {
        $key = [string]$field.key
        [pscustomobject]@{
            key = $key
            value = if ($values.ContainsKey($key)) { [string]$values[$key] } else { [string]$field.default }
            present = $values.ContainsKey($key)
            type = [string]$field.type
            default = [string]$field.default
            min = if ($field.Contains('min')) { [int]$field.min } else { $null }
            max = if ($field.Contains('max')) { [int]$field.max } else { $null }
            label = [string]$field.label
            help = [string]$field.help
            status = [string]$field.status
        }
    }
    return @{
        ok = $true
        supported = $true
        adapter = $channel
        path = $Path
        paths = $paths
        exists = (Test-Path -LiteralPath $Path -PathType Leaf)
        section = $script:DuneSoloConsoleSection
        entries = @($entries)
    }
}

function Set-DuneSoloConsoleSettings {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Confirm,
        [string]$Path = '',
        [switch]$SingleFile
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'APPLY SOLO CONSOLE SETTINGS') {
        throw 'Confirm the PTC Solo Engine.ini write before continuing.'
    }
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { throw 'Connect a Solo save before applying PTC console settings.' }
    $paths = @(Get-DuneSoloPtcEnginePaths -Profile $profile)

    $schema = @{}
    foreach ($field in $script:DuneSoloConsoleSettings) { $schema[[string]$field.key] = $field }
    $normalized = @{}
    foreach ($rawKey in $Settings.Keys) {
        $key = [string]$rawKey
        if (-not $schema.ContainsKey($key)) { throw "Unsupported PTC Solo console setting: $key" }
        $value = ([string]$Settings[$rawKey]).Trim()
        $field = $schema[$key]
        if ($field.type -eq 'bool01') {
            if ($value -notin @('0', '1')) { throw "$key must be 0 or 1." }
        } elseif ($field.type -eq 'int') {
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number) -or
                $number -lt [int]$field.min -or $number -gt [int]$field.max) {
                throw "$key must be between $($field.min) and $($field.max)."
            }
            $value = [string]$number
        }
        $normalized[$key] = $value
    }
    if ($normalized.Count -eq 0) { throw 'No PTC Solo console settings were provided.' }

    if (-not $SingleFile) {
        $completed = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($targetPath in $paths) {
                $write = Set-DuneSoloConsoleSettings -Settings $normalized `
                    -Confirm $Confirm -Path $targetPath -SingleFile
                [void]$completed.Add($write)
            }
        } catch {
            $writeError = $_
            $rollbackErrors = New-Object System.Collections.Generic.List[string]
            for ($index = $completed.Count - 1; $index -ge 0; $index--) {
                $write = $completed[$index]
                try {
                    if ($write.targetExisted -and $write.backupPath) {
                        $rollbackTemp = "$($write.path).$([guid]::NewGuid().ToString('N')).rollback"
                        $failedCopy = "$($write.path).$([guid]::NewGuid().ToString('N')).failed"
                        try {
                            Copy-Item -LiteralPath $write.backupPath -Destination $rollbackTemp -ErrorAction Stop
                            Invoke-DuneSoloFileReplace -Source $rollbackTemp `
                                -Destination $write.path -Backup $failedCopy
                        } finally {
                            Remove-Item -LiteralPath $rollbackTemp, $failedCopy -Force -ErrorAction SilentlyContinue
                        }
                    } elseif (Test-Path -LiteralPath $write.path -PathType Leaf) {
                        Remove-Item -LiteralPath $write.path -Force -ErrorAction Stop
                    }
                } catch {
                    [void]$rollbackErrors.Add("$($write.path): $($_.Exception.Message)")
                }
            }
            if ($rollbackErrors.Count -gt 0) {
                throw "PTC Solo Engine.ini write failed ($($writeError.Exception.Message)); rollback failed: $($rollbackErrors -join '; ')"
            }
            throw $writeError
        }
        return @{
            ok = $true
            settings = Read-DuneSoloConsoleSettings
            paths = $paths
            backupPaths = @($completed | ForEach-Object { [string]$_.backupPath } | Where-Object { $_ })
            backupPath = [string](@($completed | ForEach-Object { $_.backupPath } | Where-Object { $_ } | Select-Object -First 1)[0])
        }
    }
    if (-not $Path) { throw 'PTC Solo Engine.ini target path is required.' }
    $path = [IO.Path]::GetFullPath($Path)

    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $lines = if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::ReadAllLines($path) } else { @() }
    $result = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $foundSection = $false
    $written = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($inside) {
                foreach ($key in $normalized.Keys) {
                    if (-not $written.ContainsKey($key)) {
                        $result.Add("$key=$($normalized[$key])")
                        $written[$key] = $true
                    }
                }
            }
            $inside = ($Matches[1] -eq $script:DuneSoloConsoleSection)
            if ($inside) { $foundSection = $true }
            $result.Add($line)
            continue
        }
        if ($inside -and $line -match '^\s*([^;#][^=]*?)\s*=') {
            $key = $Matches[1].Trim()
            if ($normalized.ContainsKey($key)) {
                if (-not $written.ContainsKey($key)) {
                    $result.Add("$key=$($normalized[$key])")
                    $written[$key] = $true
                }
                continue
            }
        }
        $result.Add($line)
    }
    if ($inside) {
        foreach ($key in $normalized.Keys) {
            if (-not $written.ContainsKey($key)) {
                $result.Add("$key=$($normalized[$key])")
                $written[$key] = $true
            }
        }
    }
    if (-not $foundSection) {
        if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') { $result.Add('') }
        $result.Add("[$script:DuneSoloConsoleSection]")
        foreach ($key in $normalized.Keys) { $result.Add("$key=$($normalized[$key])") }
    }

    $backupRoot = Join-Path (Get-DuneSoloBackupRoot) 'settings'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $targetFolder = [IO.Path]::GetFileName((Split-Path -Parent $path))
    $backupPath = Join-Path $backupRoot "Engine-$targetFolder-$stamp-$([guid]::NewGuid().ToString('N')).ini"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Copy-Item -LiteralPath $path -Destination $backupPath -ErrorAction Stop
    }

    $temp = Join-Path $dir ".Engine.$([guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = Join-Path $dir ".Engine.$([guid]::NewGuid().ToString('N')).previous"
    $targetExisted = Test-Path -LiteralPath $path -PathType Leaf
    $replaced = $false
    try {
        $hasBom = $false
        if ($targetExisted) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        }
        [IO.File]::WriteAllLines($temp, $result.ToArray(), (New-Object Text.UTF8Encoding($hasBom)))
        if ($targetExisted) {
            Invoke-DuneSoloFileReplace -Source $temp -Destination $path -Backup $replaceBackup
            $replaced = $true
        } else {
            Move-Item -LiteralPath $temp -Destination $path -ErrorAction Stop
        }
        $verified = Read-DuneSoloConsoleSettings -Path $path
        foreach ($key in $normalized.Keys) {
            $entry = @($verified.entries | Where-Object key -eq $key)
            if ($entry.Count -ne 1 -or -not $entry[0].present -or
                [string]$normalized[$key] -ne [string]$entry[0].value) {
                throw "PTC Solo console setting verification failed for $key."
            }
            $occurrences = 0
            $verifyInside = $false
            foreach ($line in [IO.File]::ReadAllLines($path)) {
                if ($line -match '^\s*\[(.+)\]\s*$') {
                    $verifyInside = ($Matches[1] -eq $script:DuneSoloConsoleSection)
                    continue
                }
                if ($verifyInside -and
                    $line -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                    $occurrences++
                }
            }
            if ($occurrences -ne 1) {
                throw "PTC Solo console setting verification found $occurrences copies of $key."
            }
        }
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        return @{
            ok = $true
            settings = $verified
            path = $path
            targetExisted = $targetExisted
            backupPath = if (Test-Path -LiteralPath $backupPath) { $backupPath } else { '' }
        }
    } catch {
        $writeError = $_
        if ($targetExisted -and $replaced -and (Test-Path -LiteralPath $replaceBackup -PathType Leaf)) {
            $failedCopy = Join-Path $dir ".Engine.$([guid]::NewGuid().ToString('N')).failed"
            try {
                Invoke-DuneSoloFileReplace -Source $replaceBackup `
                    -Destination $path -Backup $failedCopy
                Remove-Item -LiteralPath $failedCopy -Force -ErrorAction SilentlyContinue
            } catch {
                throw "PTC Solo Engine.ini write failed ($($writeError.Exception.Message)); rollback also failed. Recovery file retained at $replaceBackup"
            }
        } elseif (-not $targetExisted -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            try {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            } catch {
                throw "PTC Solo Engine.ini write failed ($($writeError.Exception.Message)); the newly created file could not be removed."
            }
        }
        throw $writeError
    } finally {
        # A failed rollback must retain replaceBackup for manual recovery.
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function New-DuneSoloSaveBackup {
    Assert-DuneSoloSupportedPlatform
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before creating a backup.'
    }
    $dir = Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $output = Join-Path $dir "game-$stamp.db"
    return Invoke-DuneSoloHelper -Command backup -Arguments @{ input = $profile.dbPath; output = $output }
}

function Get-DuneSoloProfileBackupRoot {
    param([Parameter(Mandatory)][string]$DbPath)

    $fullDb = [IO.Path]::GetFullPath($DbPath)
    $profileDir = Split-Path -Parent $fullDb
    $channelDir = Split-Path -Parent $profileDir
    $profileId = ([IO.Path]::GetFileName($profileDir) -replace '[^A-Za-z0-9._-]', '_')
    $channel = ([IO.Path]::GetFileName($channelDir) -replace '[^A-Za-z0-9._-]', '_')
    $token = Get-DuneSoloProfileToken -DbPath $fullDb
    Join-Path (Get-DuneSoloBackupRoot) "$channel-$profileId-$($token.Substring(0, 12))"
}

function Get-DuneSoloProfileToken {
    param([Parameter(Mandatory)][string]$DbPath)

    $fullDb = [IO.Path]::GetFullPath($DbPath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullDb.ToLowerInvariant()))
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-DuneSoloExpectedProfile {
    param([Parameter(Mandatory)][string]$ExpectedProfileToken)

    if (-not $ExpectedProfileToken.Trim()) {
        throw 'Missing expected Solo profile token. Refresh Solo Mode and try again.'
    }
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) {
        throw 'No active Solo profile is connected.'
    }
    $actual = Get-DuneSoloProfileToken -DbPath $profile.dbPath
    if ($actual -ne $ExpectedProfileToken.Trim().ToLowerInvariant()) {
        throw 'The active Solo profile changed in another window. Refresh Solo Mode before writing.'
    }
}

function Get-DuneSoloBackups {
    Assert-DuneSoloSupportedPlatform
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { return @() }
    $root = Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    Assert-DuneSoloNoReparsePath -Path $root
    return @(Get-ChildItem -LiteralPath $root -Filter '*.db' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                if ($_.FullName -like '*\.delete-staging\*') { return $false }
                Assert-DuneSoloNoReparsePath -Path $_.FullName
                $true
            } catch { $false }
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 100 |
        ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                relativePath = $_.FullName.Substring($root.TrimEnd('\').Length + 1)
                bytes = [long]$_.Length
                createdAt = $_.CreationTimeUtc.ToString('o')
                modifiedAt = $_.LastWriteTimeUtc.ToString('o')
            }
        })
}

function Assert-DuneSoloNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)

    $stop = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'DuneServer'))
    $currentPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-DuneSoloPathWithinRoot -Path $currentPath -Root $stop) -and
        -not $currentPath.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Solo backup path is outside the DST local data directory.'
    }
    while ($currentPath -and
           ($currentPath.Equals($stop, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-DuneSoloPathWithinRoot -Path $currentPath -Root $stop))) {
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a Solo backup path containing a reparse point: $currentPath"
            }
        }
        if ($currentPath.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $currentPath
        if (-not $parent -or $parent -eq $currentPath) { break }
        $currentPath = $parent
    }
}

function Remove-DuneSoloBackup {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Confirm
    )

    if ($Confirm -ne 'DELETE SOLO BACKUP') {
        throw 'Confirm the Solo backup deletion before continuing.'
    }
    $result = Remove-DuneSoloBackups -RelativePaths @($RelativePath) `
        -Confirm 'DELETE SOLO BACKUPS'
    return @{
        ok = $true
        deleted = $RelativePath
        deletedCount = $result.deletedCount
    }
}

function Remove-DuneSoloBackupFile {
    param([Parameter(Mandatory)][string]$Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Remove-DuneSoloBackups {
    param(
        [Parameter(Mandatory)][string[]]$RelativePaths,
        [Parameter(Mandatory)][string]$Confirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'DELETE SOLO BACKUPS') {
        throw 'Confirm the selected Solo backup deletions before continuing.'
    }
    $requested = @($RelativePaths |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique)
    if ($requested.Count -lt 1 -or $requested.Count -gt 100) {
        throw 'Select between 1 and 100 Solo backups to delete.'
    }
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { throw 'Connect a Solo profile before deleting backups.' }
    $root = Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath
    $listed = @{}
    foreach ($entry in @(Get-DuneSoloBackups)) {
        $listed[[string]$entry.relativePath] = $entry
    }
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in $requested) {
        if ([IO.Path]::IsPathRooted($relativePath)) {
            throw 'Choose valid relative Solo backup paths.'
        }
        if ([IO.Path]::GetExtension($relativePath) -ne '.db') {
            throw 'Only Solo .db backup files can be deleted.'
        }
        $target = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        if (-not (Test-DuneSoloPathWithinRoot -Path $target -Root $root)) {
            throw 'Backup path is outside the connected Solo profile backup directory.'
        }
        $entry = @($listed.Keys | Where-Object {
            $_.Equals($relativePath, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Solo backup was not found in the connected profile backup list: $relativePath"
        }
        Assert-DuneSoloNoReparsePath -Path $target
        [void]$targets.Add([pscustomobject]@{
            relativePath = $relativePath
            original = $target
            staged = ''
        })
    }

    $stageParent = Join-Path $root '.delete-staging'
    if (Test-Path -LiteralPath $stageParent) {
        Assert-DuneSoloNoReparsePath -Path $stageParent
    }
    $stageRoot = Join-Path $stageParent ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageRoot -Force -ErrorAction Stop | Out-Null
    Assert-DuneSoloNoReparsePath -Path $stageRoot
    $moved = New-Object System.Collections.Generic.List[object]
    try {
        for ($index = 0; $index -lt $targets.Count; $index++) {
            $target = $targets[$index]
            $staged = Join-Path $stageRoot ('{0:D3}-{1}' -f $index, [IO.Path]::GetFileName($target.original))
            Move-Item -LiteralPath $target.original -Destination $staged -ErrorAction Stop
            $target.staged = $staged
            [void]$moved.Add($target)
        }
    } catch {
        $moveError = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        for ($index = $moved.Count - 1; $index -ge 0; $index--) {
            $target = $moved[$index]
            try {
                if (Test-Path -LiteralPath $target.staged -PathType Leaf) {
                    Move-Item -LiteralPath $target.staged -Destination $target.original -ErrorAction Stop
                }
            } catch {
                [void]$rollbackErrors.Add("$($target.relativePath): $($_.Exception.Message)")
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Solo backup staging failed ($($moveError.Exception.Message)); rollback failed: $($rollbackErrors -join '; '). Recovery directory: $stageRoot"
        }
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw $moveError
    }

    $deleted = New-Object System.Collections.Generic.List[string]
    $retained = New-Object System.Collections.Generic.List[string]
    foreach ($target in $targets) {
        try {
            Remove-DuneSoloBackupFile -Path $target.staged
            [void]$deleted.Add([string]$target.relativePath)
        } catch {
            [void]$retained.Add([string]$target.relativePath)
        }
    }
    if ($retained.Count -gt 0) {
        throw "Solo backup deletion was partial. Permanently deleted: $($deleted -join ', '). Retained for recovery: $($retained -join ', '). Recovery directory: $stageRoot"
    }
    Remove-Item -LiteralPath $stageRoot -Force -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $stageParent -PathType Container) -and
        @(Get-ChildItem -LiteralPath $stageParent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $stageParent -Force -ErrorAction SilentlyContinue
    }
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target.original) {
            throw "Solo backup deletion could not be verified: $($target.relativePath)"
        }
    }
    return @{
        ok = $true
        deleted = @($deleted)
        deletedCount = $deleted.Count
    }
}

function Restore-DuneSoloBackup {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Confirm
    )

    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'RESTORE SOLO SAVE') {
        throw 'Type RESTORE SOLO SAVE to confirm the offline restore.'
    }
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or -not (Test-Path -LiteralPath $profile.dbPath -PathType Leaf)) {
        throw 'Connect a valid Solo save before restoring.'
    }
    $root = Get-DuneSoloProfileBackupRoot -DbPath $profile.dbPath
    $backup = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not (Test-DuneSoloPathWithinRoot -Path $backup -Root $root)) {
        throw 'Backup path is outside the connected Solo profile backup directory.'
    }
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        throw "Solo backup was not found: $RelativePath"
    }
    Assert-DuneSoloNoReparsePath -Path $backup
    $safetyDir = Join-Path $root 'pre-restore'
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $safety = Join-Path $safetyDir "game-before-restore-$stamp.db"
    return Invoke-DuneSoloHelper -Command restore -Arguments @{
        input = $backup
        target = $profile.dbPath
        'safety-backup' = $safety
    }
}
