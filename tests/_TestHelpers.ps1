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

    # Snapshot existing function names so we can detect what was added.
    $before = @{}
    foreach ($f in Get-ChildItem function:) { $before[$f.Name] = $true }

    . $full

    # Promote any newly defined function to global scope.
    foreach ($f in Get-ChildItem function:) {
        if (-not $before.ContainsKey($f.Name)) {
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
