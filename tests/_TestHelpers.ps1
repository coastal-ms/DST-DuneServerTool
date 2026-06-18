# Shared helpers for Pester tests. Dot-sourced by each *.Tests.ps1.

$script:DstRepoRoot = $env:DST_REPO_ROOT
if (-not $script:DstRepoRoot -or -not (Test-Path $script:DstRepoRoot)) {
    $script:DstRepoRoot = Split-Path $PSScriptRoot -Parent
}

function Get-DstRepoRoot { return $script:DstRepoRoot }

# Dot-source one lib file into GLOBAL scope. Functions defined by the lib
# become visible to Pester `It` blocks (which run in a different scope from
# the `BeforeAll` that called this helper).
function Import-DstLib {
    param([Parameter(Mandatory)][string] $RelativePath)
    $full = Join-Path (Get-DstRepoRoot) (Join-Path 'app\server\lib' $RelativePath)
    if (-not (Test-Path $full)) { throw "Missing lib: $RelativePath ($full)" }

    . $full

    $fullResolved = (Resolve-Path -LiteralPath $full).Path

    # Promote functions from the sourced file to global scope. Re-promoting
    # existing names matters when a prior test imported the same lib before its
    # dependencies; otherwise Pester keeps stale global closures across files.
    foreach ($f in Get-ChildItem function:) {
        if ($f.ScriptBlock.File -eq $fullResolved) {
            Set-Item -Path "function:global:$($f.Name)" -Value $f.ScriptBlock
        }
    }
}

# Dot-source one route file (app\server\routes) into GLOBAL scope, stubbing the
# HTTP registration shims first so the file's Register-DuneRoute calls no-op.
# Mirrors Import-DstLib's function-promotion so `It` blocks see the functions.
function Import-DstRoute {
    param([Parameter(Mandatory)][string] $RelativePath)
    Register-DstStubs
    $full = Join-Path (Get-DstRepoRoot) (Join-Path 'app\server\routes' $RelativePath)
    if (-not (Test-Path $full)) { throw "Missing route: $RelativePath ($full)" }

    . $full

    $fullResolved = (Resolve-Path -LiteralPath $full).Path

    foreach ($f in Get-ChildItem function:) {
        if ($f.ScriptBlock.File -eq $fullResolved) {
            Set-Item -Path "function:global:$($f.Name)" -Value $f.ScriptBlock
        }
    }
}

# Stub the HTTP-server registration shims so route files can load in tests.
function Register-DstStubs {
    if (-not (Get-Command Register-DuneRoute -ErrorAction SilentlyContinue)) {
        function global:Register-DuneRoute { param($Method, $Path, $Handler, [switch] $Inline) }
    }
    if (-not (Get-Command Register-DuneWebSocket -ErrorAction SilentlyContinue)) {
        function global:Register-DuneWebSocket { param($Path, $Handler, [switch] $LocalOnly) }
    }
}
