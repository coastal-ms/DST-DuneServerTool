[CmdletBinding()]
param([Parameter(Mandatory)][string]$AppRoot)
$ErrorActionPreference = 'Stop'
# Load only the pure catalog libraries: no application startup, listeners or game writes.
. (Join-Path $AppRoot 'server/lib/Gameplay.ps1')
. (Join-Path $AppRoot 'server/lib/Catalog.ps1')
$cosmetics = Get-DuneCosmeticsCatalog
$items = Get-DuneItemCatalog
if (-not $cosmetics.ok -or $cosmetics.total -ne @($cosmetics.templates).Count) {
    throw 'The runtime cosmetic catalog is incomplete.'
}
@{
    schemaVersion = 1
    cosmetics = @($cosmetics.templates)
    items = @($items.items)
} | ConvertTo-Json -Depth 12 -Compress
