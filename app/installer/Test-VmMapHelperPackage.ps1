$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\VmMapHelper'
$definition=[IO.File]::ReadAllText((Join-Path $root 'manifest.json')) | ConvertFrom-Json
if ($definition.schemaVersion -ne 1) { throw 'Invalid VM map package manifest.' }
$expected=@($definition.files.PSObject.Properties.Name | Sort-Object)
$actual=@(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in @('.py','.ps1') -and $_.Name -notlike 'test_*' } | ForEach-Object Name | Sort-Object)
if (($expected -join '|') -cne ($actual -join '|')) { throw 'VM map package inventory does not match its manifest.' }
foreach ($entry in $definition.files.PSObject.Properties) {
    if ($entry.Name -notmatch '^[A-Za-z0-9_.-]+$' -or $entry.Name.Contains('..') -or
        (Get-FileHash -LiteralPath (Join-Path $root $entry.Name) -Algorithm SHA256).Hash -ine [string]$entry.Value) {
        throw "VM map package verification failed: $($entry.Name)"
    }
}

$atlasRoot=Join-Path (Split-Path -Parent $root) 'DuneAtlas'
$atlasDefinition=[IO.File]::ReadAllText((Join-Path $atlasRoot 'manifest.json')) | ConvertFrom-Json
foreach ($entry in $atlasDefinition.files.PSObject.Properties) {
    if ([IO.Path]::IsPathRooted($entry.Name) -or $entry.Name.Contains('..') -or $entry.Name.Contains(':') -or
        (Get-FileHash -LiteralPath (Join-Path $atlasRoot $entry.Name) -Algorithm SHA256).Hash -ine [string]$entry.Value) {
        throw "VM map asset verification failed: $($entry.Name)"
    }
}
