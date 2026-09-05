function Get-DuneAugmentCatalogPath {
    $candidates = @()
    if ($script:AppDir) {
        $candidates += (Join-Path $script:AppDir 'data\augment-compatibility.json')
    }
    $candidates += (Join-Path $PSScriptRoot '..\..\data\augment-compatibility.json')
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        } catch {}
    }
    throw 'DST augment compatibility data is unavailable. Rebuild or reinstall DST.'
}

function Get-DuneAugmentCatalog {
    $path = Get-DuneAugmentCatalogPath
    $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    if (-not $script:DuneAugmentCatalog -or $script:DuneAugmentCatalogStamp -ne $stamp) {
        $script:DuneAugmentCatalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $script:DuneAugmentCatalogStamp = $stamp
    }
    return $script:DuneAugmentCatalog
}

function Get-DuneObjectPropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object -or -not $Name) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DuneAugmentItemTags {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$TemplateId
    )
    if ($TemplateId.EndsWith('_Schematic', [StringComparison]::OrdinalIgnoreCase)) {
        return @()
    }
    $tags = Get-DuneObjectPropertyValue -Object $Catalog.itemAliases -Name $TemplateId
    if ($null -eq $tags) {
        $displayName = Get-DuneGameplayItemName -TemplateId $TemplateId
        $tags = Get-DuneObjectPropertyValue -Object $Catalog.methodItems -Name $displayName
    }
    return @($tags | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Test-DuneAugmentTagMatch {
    param([string[]]$ItemTags, [string[]]$AugmentTags)
    foreach ($itemTag in @($ItemTags)) {
        foreach ($augmentTag in @($AugmentTags)) {
            if ($itemTag -ieq $augmentTag -or $itemTag.StartsWith("$augmentTag.", [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function New-DuneAugmentedItemStatsJson {
    param(
        [Parameter(Mandatory)][string]$TemplateId,
        [Parameter(Mandatory)][string[]]$Augments,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int]$AugmentQuality
    )
    $catalog = Get-DuneAugmentCatalog
    $itemTags = @(Get-DuneAugmentItemTags -Catalog $catalog -TemplateId $TemplateId)
    $slotLimit = if (@($itemTags | Where-Object { $_ -like 'Items.Clothes*' }).Count -gt 0) {
        2
    } elseif (@($itemTags | Where-Object { $_ -like 'Items.Holsters*' }).Count -gt 0) {
        3
    } else {
        0
    }
    $selected = @($Augments | Select-Object -Unique)
    if ($slotLimit -eq 0) { throw "DST has no verified augment compatibility mapping for $TemplateId." }
    if ($selected.Count -lt 1 -or $selected.Count -gt $slotLimit) {
        throw "$TemplateId supports between 1 and $slotLimit selected augment(s)."
    }

    $applied = @()
    $qualities = @()
    $rollData = @()
    foreach ($augmentId in $selected) {
        $entry = Get-DuneObjectPropertyValue -Object $catalog.augments -Name $augmentId
        if ($null -eq $entry) { throw "Unknown augment id: $augmentId" }
        if (-not (Test-DuneAugmentTagMatch -ItemTags $itemTags -AugmentTags @($entry.tags))) {
            throw "$augmentId is not compatible with $TemplateId."
        }
        $effects = Get-DuneObjectPropertyValue -Object $entry.gradeEffects -Name ([string]$AugmentQuality)
        $rollCount = @($effects).Count
        if ($rollCount -lt 1) {
            throw "$augmentId does not support augment grade $AugmentQuality."
        }
        $applied += [ordered]@{ Name = $augmentId }
        $qualities += $AugmentQuality
        $rollData += [ordered]@{
            StatRolls = @(1..$rollCount | ForEach-Object { 1.003398 })
            AppliedEffectIndices = @()
        }
    }

    $customizationPair = New-Object Collections.ArrayList
    [void]$customizationPair.Add([object[]]@())
    [void]$customizationPair.Add([ordered]@{})
    $augmentPair = New-Object Collections.ArrayList
    [void]$augmentPair.Add([object[]]@())
    [void]$augmentPair.Add([ordered]@{
        AppliedAugments = @($applied)
        AppliedAugmentQualities = @($qualities)
        AppliedAugmentRollData = @($rollData)
    })
    $durabilityPair = New-Object Collections.ArrayList
    [void]$durabilityPair.Add([object[]]@())
    [void]$durabilityPair.Add([ordered]@{})

    return ([ordered]@{
        FCustomizationStats = $customizationPair
        FAugmentedItemStats = $augmentPair
        FItemStackAndDurabilityStats = $durabilityPair
    } | ConvertTo-Json -Depth 12 -Compress)
}
