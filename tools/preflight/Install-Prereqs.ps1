# Install-Prereqs.ps1
#
# The sane-pricing market patch compiles a patched dune-admin.exe (which embeds a
# freshly-built web UI). That needs a build toolchain:
#   * Node.js LTS - builds the embedded web UI (also provides corepack -> pnpm)
#   * Go          - compiles dune-admin.exe
#   * Git         - applies the patch + lets Go stamp VCS info
#
# The DST installer calls this at install time:
#   -CheckOnly : detect only. Exit 0 = all present, 10 = something missing.
#   (no flag)  : install the missing tools via winget. Exit 0 = ok, non-zero =
#                something failed (the installer shows that as an error and the
#                user fixes it on their end).
#
# Deliberately simple: it installs the prerequisites or reports a failure. It
# does not try to recover from every possible machine problem.

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'   # corepack must never prompt
$env:CI = '1'

if (-not $LogPath) {
    $logDir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    try { if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch { }
    $LogPath = Join-Path $logDir 'prereq-install.log'
}
function Log { param([string]$m)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# Check PATH, then the standard machine install locations (winget installs there;
# a fresh PATH won't show until a new session, so resolve by path too).
function Find-Tool { param([string]$Exe, [string[]]$Candidates)
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach ($c in $Candidates) {
        $e = [Environment]::ExpandEnvironmentVariables($c)
        if ($e -and (Test-Path -LiteralPath $e)) { return $e }
    }
    return $null
}
function Get-NodeExe { Find-Tool 'node.exe' @("$env:ProgramFiles\nodejs\node.exe","$env:LOCALAPPDATA\Programs\nodejs\node.exe","${env:ProgramFiles(x86)}\nodejs\node.exe") }
function Get-GoExe   { Find-Tool 'go.exe'   @("$env:ProgramFiles\Go\bin\go.exe","$env:LOCALAPPDATA\Programs\Go\bin\go.exe") }
function Get-GitExe  { Find-Tool 'git.exe'  @("$env:ProgramFiles\Git\cmd\git.exe","${env:ProgramFiles(x86)}\Git\cmd\git.exe") }

$node = Get-NodeExe; $go = Get-GoExe; $git = Get-GitExe
Log ("Detected: node={0} go={1} git={2}" -f ($(if($node){'yes'}else{'MISSING'})), ($(if($go){'yes'}else{'MISSING'})), ($(if($git){'yes'}else{'MISSING'})))

if ($CheckOnly) {
    if ($node -and $go -and $git) { Log 'Check: all prerequisites present.'; exit 0 }
    Log 'Check: one or more prerequisites missing.'
    exit 10
}

# --- Install missing tools via winget ----------------------------------------
$winget = Find-Tool 'winget.exe' @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")
if (-not $winget) {
    Log 'winget (App Installer) not found - cannot auto-install. Install Node.js, Go and Git manually.'
    exit 20
}

function Install-Pkg { param([string]$Id, [string]$Friendly)
    Log "Installing $Friendly ($Id)..."
    $out = & $winget install --exact --id $Id --scope machine `
        --accept-package-agreements --accept-source-agreements `
        --silent --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    foreach ($l in @($out)) { if ("$l".Trim()) { Log "    winget> $l" } }
    if ($code -eq 0) { Log "    $Friendly OK."; return $true }
    Log "    $Friendly winget exit $code."
    return $false
}

$ok = $true
if (-not $git)  { if (-not (Install-Pkg 'Git.Git'          'Git'))         { $ok = $false } }
if (-not $go)   { if (-not (Install-Pkg 'GoLang.Go'        'Go'))          { $ok = $false } }
if (-not $node) { if (-not (Install-Pkg 'OpenJS.NodeJS.LTS' 'Node.js LTS')) { $ok = $false } }

# Enable pnpm via corepack (ships with Node).
$node = Get-NodeExe
if ($node) {
    $corepack = Find-Tool 'corepack.cmd' @((Join-Path (Split-Path -Parent $node) 'corepack.cmd'))
    if ($corepack) {
        try { & $corepack enable pnpm 2>&1 | ForEach-Object { Log "    corepack> $_" } ; Log '    pnpm enabled.' }
        catch { Log "    corepack enable failed: $($_.Exception.Message)" }
    }
}

if ($ok) { Log '==== Done (all prerequisites installed) ===='; exit 0 }
Log '==== Done with errors (one or more installs failed) ===='
exit 21
