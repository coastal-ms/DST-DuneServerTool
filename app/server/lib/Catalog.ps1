# Catalog lib — exposes the item catalog (app\data\item-catalog.json, ~979
# items) and the character-domain definitions (stat list, currencies, spec
# tracks, writable inventory types, stack limits, equipment prefixes).
#
# Catalog is lazily loaded and cached for the lifetime of the process.

$script:DuneItemCatalog       = $null  # array of @{templateId; name; category}
$script:DuneItemCategories    = $null  # sorted unique category strings
$script:DuneItemCatalogMeta   = $null  # {total; source; scraped} from JSON

function Get-DuneItemCatalogPath {
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot '..\..\data\item-catalog.json'),                  # installed layout
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\data\item-catalog.json') # dev fallback
    )) {
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
        if ($resolved) { return $resolved }
    }
    return $null
}

function Load-DuneItemCatalog {
    if ($script:DuneItemCatalog) { return }
    $path = Get-DuneItemCatalogPath
    if (-not $path) {
        $script:DuneItemCatalog    = @()
        $script:DuneItemCategories = @()
        $script:DuneItemCatalogMeta = @{ total = 0; source = $null; scraped = $null }
        return
    }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $list = [System.Collections.Generic.List[object]]::new()
        $cats = @{}
        foreach ($prop in $json.items.PSObject.Properties) {
            $entry = @{
                templateId = $prop.Name
                name       = $prop.Value.name
                category   = $prop.Value.category
            }
            if ($prop.Value.PSObject.Properties['gradeable'] -and $prop.Value.gradeable) {
                $entry['gradeable'] = $true
                if ($null -ne $prop.Value.tier) { $entry['tier'] = [int]$prop.Value.tier }
            }
            [void]$list.Add($entry)
            if ($prop.Value.category) { $cats[$prop.Value.category] = $true }
        }
        $script:DuneItemCatalog    = $list.ToArray()
        $script:DuneItemCategories = @($cats.Keys | Sort-Object)
        $script:DuneItemCatalogMeta = @{
            total   = $json._meta.total
            source  = $json._meta.source
            scraped = $json._meta.scraped
        }
    } catch {
        $script:DuneItemCatalog    = @()
        $script:DuneItemCategories = @()
        $script:DuneItemCatalogMeta = @{ total = 0; source = $null; scraped = $null; error = $_.Exception.Message }
    }
}

function Get-DuneItemCatalog {
    Load-DuneItemCatalog
    return @{
        meta       = $script:DuneItemCatalogMeta
        categories = $script:DuneItemCategories
        items      = $script:DuneItemCatalog
    }
}

function Get-DuneStackLimitForCategory {
    param([string]$Category)
    if (-not $Category) { return $script:DuneDefaultStackLimit }
    if ($script:DuneStackLimits.ContainsKey($Category)) { return $script:DuneStackLimits[$Category] }
    return $script:DuneDefaultStackLimit
}

function Test-DuneIsEquipmentCategory {
    param([string]$Category)
    if (-not $Category) { return $false }
    foreach ($p in $script:DuneEquipmentCategoryPrefixes) {
        if ($Category.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DuneCharacterDefs {
    @{
        stats                     = @($script:DuneCharStatDefs | ForEach-Object {
            @{
                key      = $_.Key
                label    = $_.Label
                field    = $_.Field
                path     = $_.Path
                min      = $_.Min
                max      = $_.Max
                step     = $_.Step
                default  = $_.Default
            }
        })
        specTracks                = $script:DuneSpecTracks
        specKeystonePrefixes      = $script:DuneSpecKeystonePrefixes
        currencies                = @($script:DuneCurrencyDefs    | ForEach-Object { @{ id = $_.Id; label = $_.Label } })
        writableInvTypes          = @($script:DuneWritableInvTypes | ForEach-Object { @{ type = $_.Type; label = $_.Label } })
        stackLimits               = $script:DuneStackLimits
        defaultStackLimit         = $script:DuneDefaultStackLimit
        equipmentCategoryPrefixes = $script:DuneEquipmentCategoryPrefixes
    }
}
