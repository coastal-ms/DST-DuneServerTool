# ItemPackages.ps1 — admin-defined item package store.
#
# Backs the Players page "Give Package" action: an admin assembles a named
# package of items (each with template_id, quantity, and quality/grade Mk1-Mk6),
# saves it, then hands the whole bundle to any player in one click via the
# existing give-items bulk path. Packages are shared (not per-player) and persist
# as JSON beside the other DST config files so they survive app restarts and are
# visible from the remote portal too. Mirrors the GameplayBot config store's
# read-modify-write-to-disk pattern.

# ----------------------------------------------------------------------------
# Store file: %APPDATA%\DuneServer\item-packages.json
#   { "packages": [ { id, name, items: [ { template, qty, quality } ] } ] }
# ----------------------------------------------------------------------------
function Get-DuneItemPackagesPath {
    Join-Path $env:APPDATA 'DuneServer\item-packages.json'
}

$script:DuneItemPackageMaxPackages = 200
$script:DuneItemPackageMaxItems    = 100
$script:DuneItemPackageMaxNameLen  = 80

# Coerce one raw item (PSCustomObject from ConvertFrom-Json, or hashtable) into a
# clean ordered entry, or $null if it has no usable template id.
function ConvertTo-DuneItemPackageEntry {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    function _Field($obj, [string]$name) {
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
        }
        $p = $obj.PSObject.Properties[$name]
        if ($p) { return $p.Value } else { return $null }
    }
    $tpl = [string](_Field $Raw 'template')
    if ([string]::IsNullOrWhiteSpace($tpl)) { return $null }
    $tpl = $tpl.Trim()

    $qtyRaw = _Field $Raw 'qty'
    $qty = 1
    if ($null -ne $qtyRaw) { try { $qty = [int]$qtyRaw } catch { $qty = 1 } }
    if ($qty -lt 1)     { $qty = 1 }
    if ($qty -gt 100000) { $qty = 100000 }

    $qualRaw = _Field $Raw 'quality'
    $qual = 0
    if ($null -ne $qualRaw) { try { $qual = [int]$qualRaw } catch { $qual = 0 } }
    if ($qual -lt 0) { $qual = 0 }
    if ($qual -gt 5) { $qual = 5 }

    return [ordered]@{ template = $tpl; qty = $qty; quality = $qual }
}

# Read all packages from disk as an array of ordered hashtables. Returns @() when
# the store is missing or unreadable.
function Read-DuneItemPackages {
    $path = Get-DuneItemPackagesPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch { return @() }
    $rawList = $null
    if ($null -ne $json) {
        if ($json.PSObject.Properties['packages']) { $rawList = $json.packages }
        elseif ($json -is [System.Array]) { $rawList = $json }
    }
    if ($null -eq $rawList) { return @() }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($rawList)) {
        if ($null -eq $p) { continue }
        $id   = [string]$p.id
        $name = [string]$p.name
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Untitled' }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($it in @($p.items)) {
            $entry = ConvertTo-DuneItemPackageEntry -Raw $it
            if ($null -ne $entry) { $items.Add($entry) }
        }
        $out.Add([ordered]@{ id = $id.Trim(); name = $name.Trim(); items = @($items.ToArray()) })
    }
    return @($out.ToArray())
}

function _Write-DuneItemPackages {
    param([object[]]$Packages)
    $path = Get-DuneItemPackagesPath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload = [ordered]@{ packages = @($Packages) }
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
}

# Upsert one package from an incoming (parsed-JSON) object. Generates an id when
# none is supplied. Returns the saved package (ordered hashtable). Throws on
# invalid input so the route surfaces a 400/500.
function Save-DuneItemPackage {
    param($Incoming)
    if ($null -eq $Incoming) { throw 'Package body is required.' }
    function _Field($obj, [string]$name) {
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
        }
        $p = $obj.PSObject.Properties[$name]
        if ($p) { return $p.Value } else { return $null }
    }

    $name = [string](_Field $Incoming 'name')
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Package name is required.' }
    $name = $name.Trim()
    if ($name.Length -gt $script:DuneItemPackageMaxNameLen) {
        $name = $name.Substring(0, $script:DuneItemPackageMaxNameLen)
    }

    $rawItems = _Field $Incoming 'items'
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($rawItems)) {
        $entry = ConvertTo-DuneItemPackageEntry -Raw $it
        if ($null -ne $entry) {
            $items.Add($entry)
            if ($items.Count -ge $script:DuneItemPackageMaxItems) { break }
        }
    }
    if ($items.Count -eq 0) { throw 'Package must contain at least one item.' }

    $id = [string](_Field $Incoming 'id')
    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = 'pkg_' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
    } else {
        $id = $id.Trim()
    }

    $saved = [ordered]@{ id = $id; name = $name; items = @($items.ToArray()) }

    $existing = @(Read-DuneItemPackages)
    $next = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    foreach ($p in $existing) {
        if ($p.id -eq $id) { $next.Add($saved); $replaced = $true }
        else { $next.Add($p) }
    }
    if (-not $replaced) {
        if ($next.Count -ge $script:DuneItemPackageMaxPackages) {
            throw "Package limit reached ($script:DuneItemPackageMaxPackages)."
        }
        $next.Add($saved)
    }
    _Write-DuneItemPackages -Packages @($next.ToArray())
    return $saved
}

# Delete a package by id. Returns $true if it existed and was removed.
function Remove-DuneItemPackage {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { throw 'Package id is required.' }
    $Id = $Id.Trim()
    $existing = @(Read-DuneItemPackages)
    $next = New-Object System.Collections.Generic.List[object]
    $removed = $false
    foreach ($p in $existing) {
        if ($p.id -eq $Id) { $removed = $true } else { $next.Add($p) }
    }
    if ($removed) { _Write-DuneItemPackages -Packages @($next.ToArray()) }
    return $removed
}
