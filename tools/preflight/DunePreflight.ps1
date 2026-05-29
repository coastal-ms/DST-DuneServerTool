# DunePreflight.ps1
#
# Self-contained preflight checker for the Simple Dune Server Management Tool.
# Verifies every Windows component, runtime tool, security setting, and
# install-dir file the launcher needs, then pops a WinForms results window
# with PASS / WARN / FAIL per check, color-coded.
#
# Usage:
#   - Double-click DunePreflight.bat in the same folder (handles UAC + ps1 unblock).
#   - Or right-click this .ps1 -> Run with PowerShell (if ExecutionPolicy allows).
#
# Output:
#   - WinForms results window with sortable rows + copy/save buttons
#   - dune-preflight.txt on the user's Desktop (also copied to clipboard)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# ---------- Verify admin (do NOT auto-elevate) --------------------------------
# User runs this via DunePreflight.bat (right-click -> Run as administrator),
# or directly as a .ps1 from an already-elevated terminal. We refuse to run
# unelevated so that all the Hyper-V / Defender / URL-ACL queries return
# meaningful results instead of "Access denied".
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object System.Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -EA Stop
        [System.Windows.Forms.MessageBox]::Show(
            "DunePreflight needs to run as administrator so it can query Hyper-V, the local firewall, and HTTP.sys.`r`n`r`nClose this window, right-click DunePreflight.bat (or this .ps1), and choose 'Run as administrator'.",
            'Dune Preflight', 'OK', 'Warning') | Out-Null
    } catch {
        Write-Host 'DunePreflight needs to run as administrator. Right-click DunePreflight.bat and choose "Run as administrator".' -ForegroundColor Yellow
    }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================================================================
#                                  C H E C K S
# =============================================================================

$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [ValidateSet('PASS','WARN','FAIL','HEAD')][string]$Status,
        [string]$Category,
        [string]$Check,
        [string]$Details,
        [string]$Fix = ''
    )
    [void]$script:Results.Add([pscustomobject]@{
        Status   = $Status
        Category = $Category
        Check    = $Check
        Details  = $Details
        Fix      = $Fix
    })
}

function Header { param($t) Add-Result -Status HEAD -Category $t -Check '' -Details '' }
function Pass   { param($cat, $check, $details) Add-Result -Status PASS -Category $cat -Check $check -Details $details }
function Warn   { param($cat, $check, $details, $fix='') Add-Result -Status WARN -Category $cat -Check $check -Details $details -Fix $fix }
function Fail   { param($cat, $check, $details, $fix='') Add-Result -Status FAIL -Category $cat -Check $check -Details $details -Fix $fix }

function Invoke-DunePreflight {
    $script:Results.Clear()

    # ------------------------------------------------------------------ Core
    Header 'Core environment'

    Pass 'Core' 'Elevation' 'Running as administrator'

    $os = Get-CimInstance Win32_OperatingSystem
    $ubr = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).UBR
    Pass 'Core' 'OS' "$($os.Caption)  build $($os.BuildNumber).$ubr"
    if ([int]$os.BuildNumber -lt 17134) {
        Fail 'Core' 'OS build floor' "Build $($os.BuildNumber) is older than 17134 (Win10 1803)" 'Run Windows Update — tar.exe and many APIs require 1803+'
    }

    $pwshHere = $PSVersionTable.PSVersion
    if ($pwshHere.Major -ge 7) {
        Pass 'Core' 'Host PowerShell' "v$pwshHere (running this script)"
    } else {
        Warn 'Core' 'Host PowerShell' "v$pwshHere (the launcher needs pwsh 7 — install it separately, see below)"
    }

    try {
        $member = $false
        try {
            $hvGroup = Get-LocalGroupMember -Group 'Hyper-V Administrators' -EA Stop
            $userQual = "$env:USERDOMAIN\$env:USERNAME","$env:COMPUTERNAME\$env:USERNAME"
            $member = [bool]($hvGroup | Where-Object { $userQual -contains $_.Name })
        } catch { }
        if ($member) { Pass 'Core' 'Hyper-V Admins group' "$env:USERNAME is a member" }
        else { Warn 'Core' 'Hyper-V Admins group' "$env:USERNAME is NOT in the local 'Hyper-V Administrators' group (OK — UAC covers it)" }
    } catch { Warn 'Core' 'Hyper-V Admins group' "Could not enumerate: $($_.Exception.Message)" }

    # ------------------------------------------------------- Windows features
    Header 'Windows features'

    function FeatureCheck {
        param([string]$Feature, [string]$Friendly, [switch]$Required)
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Feature -EA SilentlyContinue
        if (-not $f) {
            if ($Required) { Fail 'Features' $Friendly 'Feature not present on this Windows SKU' 'Requires Windows Pro / Enterprise / Education' }
            else { Warn 'Features' $Friendly 'Feature not present on this SKU' }
            return
        }
        if ($f.State -eq 'Enabled') {
            Pass 'Features' $Friendly 'Enabled'
        } elseif ($Required) {
            Fail 'Features' $Friendly "State = $($f.State)" "Run as admin: Enable-WindowsOptionalFeature -Online -FeatureName $Feature -All  (reboot when prompted)"
        } else {
            Warn 'Features' $Friendly "State = $($f.State)"
        }
    }

    FeatureCheck 'Microsoft-Hyper-V-All'                   'Hyper-V (umbrella)' -Required
    FeatureCheck 'Microsoft-Hyper-V-Hypervisor'            'Hyper-V Hypervisor'
    FeatureCheck 'Microsoft-Hyper-V-Management-PowerShell' 'Hyper-V PowerShell module'
    FeatureCheck 'Microsoft-Hyper-V-Services'              'Hyper-V Services'
    FeatureCheck 'VirtualMachinePlatform'                  'Virtual Machine Platform'

    try {
        Import-Module Hyper-V -EA Stop
        $vms = Get-VM -EA Stop
        Pass 'Features' 'Get-VM cmdlet' "$($vms.Count) VM(s) visible"
        $duneVm = $vms | Where-Object Name -eq 'dune-awakening'
        if ($duneVm) { Pass 'Features' 'dune-awakening VM' "Present, state = $($duneVm.State)" }
        else { Warn 'Features' 'dune-awakening VM' "Not imported yet (OK if you haven't run Funcom's self-hosted installer)" }
    } catch {
        Fail 'Features' 'Hyper-V cmdlets' $_.Exception.Message 'Reboot after enabling Hyper-V; or run elevated'
    }

    # OpenSSH Client (required for the tool's VM access)
    try {
        $cap = Get-WindowsCapability -Online -EA SilentlyContinue | Where-Object Name -like 'OpenSSH.Client~~~~*' | Select-Object -First 1
        if (-not $cap) { Warn 'Features' 'OpenSSH Client' 'Capability not found in catalog' }
        elseif ($cap.State -eq 'Installed') { Pass 'Features' 'OpenSSH Client' "Installed ($($cap.Name))" }
        else { Fail 'Features' 'OpenSSH Client' "State = $($cap.State)" "Add-WindowsCapability -Online -Name '$($cap.Name)'" }
    } catch { Warn 'Features' 'OpenSSH Client' "Lookup failed: $($_.Exception.Message)" }

    # WSL (informational — competes with Hyper-V for RAM)
    $wsl = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -EA SilentlyContinue
    if ($wsl -and $wsl.State -eq 'Enabled') { Warn 'Features' 'WSL' 'Enabled — informational; competes with Hyper-V VMs for host RAM' }
    else { Pass 'Features' 'WSL' 'Not enabled (no Hyper-V memory contention)' }

    # ------------------------------------------------------ Runtime tools
    Header 'Runtime tools (must be on PATH)'

    function ToolCheck {
        param([string]$Exe, [string]$Friendly, [string]$Fix, [switch]$Optional)
        $g = Get-Command $Exe -EA SilentlyContinue
        if ($g) {
            $ver = ''
            try { $ver = (& $g.Source --version 2>$null | Select-Object -First 1) } catch { }
            Pass 'Tools' $Friendly "$($g.Source)  $ver"
        } elseif ($Optional) {
            Warn 'Tools' $Friendly 'Not on PATH (optional)' $Fix
        } else {
            Fail 'Tools' $Friendly 'Not on PATH' $Fix
        }
    }
    ToolCheck 'pwsh.exe'    'PowerShell 7'   'https://github.com/PowerShell/PowerShell/releases/latest  (PowerShell-7.x.x-win-x64.msi)'
    ToolCheck 'ssh.exe'     'OpenSSH client' 'Settings -> Apps -> Optional features -> OpenSSH Client -> Install'
    ToolCheck 'tar.exe'     'tar (bsdtar)'   'Ships with Win10 1803+. If missing, update Windows or repair system32 PATH.'
    ToolCheck 'curl.exe'    'curl'           'Ships with Win10 1803+ (informational only)' -Optional
    ToolCheck 'git.exe'     'git'            'winget install -e --id Git.Git  (only needed for the sane-pricing auto-apply feature)' -Optional
    ToolCheck 'go.exe'      'go'             'winget install -e --id GoLang.Go  (only needed for the sane-pricing auto-apply feature)' -Optional
    ToolCheck 'kubectl.exe' 'kubectl'        'Not required on host — kubectl lives on the VM' -Optional

    # ------------------------------------------------------ .NET smoke tests
    Header '.NET / HTTP runtime'

    try {
        Add-Type -AssemblyName System.Windows.Forms -EA Stop
        Pass 'Runtime' 'WinForms assembly' 'System.Windows.Forms loaded (MessageBox available)'
    } catch { Fail 'Runtime' 'WinForms assembly' $_.Exception.Message 'Reinstall .NET Framework 4.8 from microsoft.com' }

    try {
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add('http://127.0.0.1:47823/')
        $l.Start(); $l.Stop(); $l.Close()
        Pass 'Runtime' 'HttpListener bind test' 'Bound + released http://127.0.0.1:47823/ successfully'
    } catch [System.Net.HttpListenerException] {
        if ($_.Exception.ErrorCode -eq 5) {
            Fail 'Runtime' 'HttpListener bind test' 'Access denied (HTTP.sys URL ACL)' 'You should already be admin. If still failing: netsh http add urlacl url=http://+:47823/ user=Everyone'
        } elseif ($_.Exception.ErrorCode -eq 183) {
            Warn 'Runtime' 'HttpListener bind test' 'Port 47823 already in use (the launcher falls back to 47824+; informational)'
        } else {
            Fail 'Runtime' 'HttpListener bind test' $_.Exception.Message 'Restart Windows; HTTP.sys driver may be wedged'
        }
    } catch {
        Fail 'Runtime' 'HttpListener bind test' $_.Exception.Message 'Reboot — HTTP.sys driver may have wedged'
    }

    try {
        $acl = & netsh http show urlacl url='http://+:47823/' 2>$null | Out-String
        if ($acl -match 'http://\+:47823/') {
            Warn 'Runtime' 'Pre-existing URL ACL' 'A reservation for http://+:47823/ exists (could be from another app)'
        } else {
            Pass 'Runtime' 'Pre-existing URL ACL' 'No reservation on :47823'
        }
    } catch { Warn 'Runtime' 'URL ACL query' 'netsh failed (rarely a problem)' }

    # ------------------------------------------------------- Security / AV
    Header 'Security / AV / SmartScreen'

    try {
        $av = Get-MpPreference -EA Stop
        if ($av.DisableRealtimeMonitoring) { Warn 'Security' 'Defender real-time' 'DISABLED (some other AV may be in charge)' }
        else { Pass 'Security' 'Defender real-time' 'Enabled' }
        $exclusions = @($av.ExclusionPath) | Where-Object { $_ -like '*Dune Server*' -or $_ -like '*DuneServer*' }
        if ($exclusions) { Pass 'Security' 'Defender exclusions' "Dune Server: $($exclusions -join '; ')" }
        else { Warn 'Security' 'Defender exclusions' "No exclusions for Dune Server (only matters if AV is locking files; add via Windows Security -> Virus & threat protection -> Exclusions -> 'C:\Program Files\Dune Server' and '%LOCALAPPDATA%\DuneServer')" }
    } catch { Warn 'Security' 'Defender' "Get-MpPreference unavailable (third-party AV?)" }

    $exe = 'C:\Program Files\Dune Server\DuneServer.exe'
    $root = 'C:\Program Files\Dune Server'
    if (Test-Path -LiteralPath $exe) {
        # Check EXE itself first
        $exeZone = $null
        try { $exeZone = Get-Content -LiteralPath $exe -Stream Zone.Identifier -EA Stop } catch { }

        # Then sweep every shipped .ps1 — MOTW on them is what actually causes
        # the v6.1.22-era "window opens and closes" symptom under
        # RemoteSigned + LocalMachine=Restricted, not MOTW on the .exe itself.
        $blocked = @()
        Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1','*.psm1','*.psd1' -EA SilentlyContinue | ForEach-Object {
            $z = $null
            try { $z = Get-Content -LiteralPath $_.FullName -Stream Zone.Identifier -EA Stop } catch { }
            if ($z) { $blocked += $_.FullName }
        }

        if ($exeZone -and $blocked.Count -gt 0) {
            Fail 'Security' 'Mark-of-the-Web' "DuneServer.exe AND $($blocked.Count) bundled .ps1 file(s) are flagged as downloaded from the internet — under RemoteSigned, every dot-source will be blocked and the launcher will silently exit" "Run as admin: Get-ChildItem -LiteralPath '$root' -Recurse -File | Unblock-File"
        } elseif ($blocked.Count -gt 0) {
            Fail 'Security' 'Mark-of-the-Web' "$($blocked.Count) bundled .ps1 file(s) are flagged as downloaded from the internet — RemoteSigned will block them and the launcher will silently exit" "Run as admin: Get-ChildItem -LiteralPath '$root' -Recurse -File | Unblock-File"
        } elseif ($exeZone) {
            Warn 'Security' 'Mark-of-the-Web' 'DuneServer.exe is flagged as downloaded from the internet (informational — bundled .ps1 files are clean)' "Unblock-File -LiteralPath '$exe'"
        } else {
            Pass 'Security' 'Mark-of-the-Web' 'No Zone.Identifier streams on EXE or bundled .ps1 files'
        }
    } else {
        Warn 'Security' 'Mark-of-the-Web' "DuneServer.exe not at expected path — can't test"
    }

    $ep = (Get-ExecutionPolicy -List | Where-Object { $_.ExecutionPolicy -ne 'Undefined' } | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join '; '
    if (-not $ep) { $ep = 'all scopes Undefined (default — equivalent to Restricted)' }

    # v6.1.23: detect the exact policy combination that caused the silent
    # startup crash. The CurrentUser / Process / UserPolicy / MachinePolicy
    # scopes win over LocalMachine. If none of those override LocalMachine
    # and LocalMachine is Restricted or AllSigned, our unsigned bundled
    # .ps1 files cannot be dot-sourced — launcher dies before logging.
    $userScope = (Get-ExecutionPolicy -Scope CurrentUser -EA SilentlyContinue)
    $machineScope = (Get-ExecutionPolicy -Scope LocalMachine -EA SilentlyContinue)
    $effective = Get-ExecutionPolicy
    $userOverride = $userScope -and $userScope -ne 'Undefined' -and $userScope -notin @('Restricted','AllSigned')
    if (-not $userOverride -and $effective -in @('Restricted','AllSigned','Default')) {
        Fail 'Security' 'PowerShell execution policy' "Effective policy is '$effective' (CurrentUser=$userScope, LocalMachine=$machineScope). The Dune Server Tool launcher cannot dot-source its bundled .ps1 modules under this policy and will appear to ""open and close"" with no log. (v6.1.23+ self-bypasses for the process, so this only bites pre-v6.1.23 builds — but the policy is still a foot-gun for any other unsigned PowerShell scripts.)" "Run as admin: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force"
    } else {
        Pass 'Security' 'PowerShell execution policy' "$ep   (effective: $effective)"
    }

    try {
        $applocker = Get-AppLockerPolicy -Effective -EA SilentlyContinue
        if ($applocker -and $applocker.RuleCollections) {
            $any = $applocker.RuleCollections | Where-Object { $_.EnforcementMode -eq 'Enabled' }
            if ($any) { Warn 'Security' 'AppLocker' "Enforcing rules: $($any.RuleCollectionType -join ', ')" 'AppLocker may block the bundled .ps1 scripts or pwsh.exe; talk to your IT admin about whitelisting C:\Program Files\Dune Server\' }
            else { Pass 'Security' 'AppLocker' 'No enforcing rules' }
        } else { Pass 'Security' 'AppLocker' 'Not configured' }
    } catch { Pass 'Security' 'AppLocker' 'Not configured / not applicable' }

    # --------------------------------------------- Dune Server install dir
    Header 'Dune Server install'

    $root = 'C:\Program Files\Dune Server'
    if (-not (Test-Path -LiteralPath $root)) {
        Fail 'Install' 'Install dir' "Not found: $root" 'Install from https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool/releases/latest (download DuneServerSetup.exe and run it)'
    } else {
        $req = @(
            'DuneServer.exe',
            'dune-server.ps1',
            'server\HttpServer.ps1',
            'server\lib\DuneLog.ps1',
            'server\lib\Config.ps1',
            'server\routes\Status.ps1',
            'server\routes\DuneAdmin.ps1',
            'lib\Db-Postgres.ps1',
            'webui\dist\index.html',
            'resources\dune-admin-patches\0001-sane-pricing-100k-cap.patch'
        )
        $missing = $req | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) }
        if (-not $missing) { Pass 'Install' 'Required files' "All $($req.Count) present under $root" }
        else { Fail 'Install' 'Required files' "Missing: $($missing -join ', ')" 'Uninstall via Settings -> Apps -> "Dune Server", reboot, reinstall fresh.' }

        if (Test-Path -LiteralPath $exe) {
            $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
            $sz  = [math]::Round((Get-Item -LiteralPath $exe).Length / 1KB, 0)
            Pass 'Install' 'Version' "DuneServer.exe v$($fvi.FileVersion)  ($sz KB)"
        }
    }

    # ------------------------------------------------------- Local ports
    Header 'Local TCP ports'

    $inUse = (Get-NetTCPConnection -State Listen -EA SilentlyContinue | Where-Object { $_.LocalPort -ge 47823 -and $_.LocalPort -le 47872 }).LocalPort | Select-Object -Unique
    $free  = 50 - (@($inUse).Count)
    if ($free -gt 0) { Pass 'Ports' 'Local range 47823-47872' "$free free, $((@($inUse).Count)) in use" }
    else { Fail 'Ports' 'Local range 47823-47872' 'All 50 ports in range are taken' 'Reboot or stop whatever is squatting on those ports' }

    # ------------------------------------------------------ Browser
    Header 'Default browser'

    try {
        $bk = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice'
        $browser = (Get-ItemProperty -Path $bk -Name 'ProgId' -EA Stop).ProgId
        Pass 'Browser' 'http:// association' "ProgId = $browser"
    } catch { Warn 'Browser' 'http:// association' "No default browser registered. Open Settings -> Apps -> Default apps and set one." }

    # ------------------------------------------------------ State + log
    Header 'State directory + log'

    $state = Join-Path $env:LOCALAPPDATA 'DuneServer'
    try {
        if (-not (Test-Path $state)) { New-Item -ItemType Directory -Path $state -Force | Out-Null }
        $probe = Join-Path $state 'preflight-probe.tmp'
        'ok' | Set-Content -LiteralPath $probe -EA Stop
        Remove-Item -LiteralPath $probe -Force
        Pass 'State' 'State dir writable' $state
    } catch { Fail 'State' 'State dir' $_.Exception.Message "AV or permissions issue under $state — add AV exclusion" }

    $logFile = Join-Path $state 'dune-server.log'
    if (Test-Path $logFile) {
        $lines = (Get-Content $logFile -EA SilentlyContinue).Count
        Pass 'State' 'dune-server.log' "$logFile  ($lines lines — the Open Log button below will display it)"
    } else {
        Warn 'State' 'dune-server.log' 'Not yet created — launcher has never run far enough to log anything'
    }

    $urlFile = Join-Path $state 'last-url.txt'
    if (Test-Path $urlFile) { Pass 'State' 'last-url.txt' (Get-Content $urlFile -Raw).Trim() }
    else { Warn 'State' 'last-url.txt' 'Not yet created — launcher never bound a port' }

    $running = Get-Process -Name DuneServer -EA SilentlyContinue
    if ($running) { Warn 'State' 'Running DuneServer.exe' "$($running.Count) process(es) up:  PIDs $($running.Id -join ', ')" 'Stop-Process -Id <PID>  if you want a clean slate' }
    else { Pass 'State' 'Running DuneServer.exe' 'None' }
}

# =============================================================================
#                                G U I
# =============================================================================

function Format-ReportText {
    # v6.1.23: PII scrubbed in the SAVED/CLIPBOARD output. The live GUI rows
    # show real values so the user can act locally; we only redact when the
    # report leaves their machine (clipboard / save-to-file). Specifically:
    #   - Username        -> <user>
    #   - Hostname        -> <host>
    #   - IPv4 addresses  -> <ip>
    #   - User profile path C:\Users\<name>\... -> C:\Users\<user>\...
    #   - Battlegroup IDs sh-<hex>-<suffix> -> sh-<bg-id>
    function Redact { param([string]$s)
        if (-not $s) { return $s }
        $u = $env:USERNAME
        $h = $env:COMPUTERNAME
        if ($u) { $s = $s -replace ([regex]::Escape($u)), '<user>' }
        if ($h) { $s = $s -replace ([regex]::Escape($h)), '<host>' }
        $s = $s -replace '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b', '<ip>'
        $s = $s -replace 'C:\\Users\\<user>\\([^\\<>"''\s]+)', 'C:\Users\<user>\<path>'
        $s = $s -replace '\bsh-[0-9a-f]{16,}-[0-9a-z]{4,}\b', 'sh-<bg-id>'
        return $s
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("===== Dune Server Tool preflight =====")
    [void]$sb.AppendLine("Run at: $(Get-Date -Format 's')   User: <user>   Host: <host>")
    [void]$sb.AppendLine("(PII redacted: username, hostname, IPs, user-profile paths, battlegroup IDs)")
    [void]$sb.AppendLine()
    $counts = @{ PASS = 0; WARN = 0; FAIL = 0 }
    foreach ($r in $script:Results) {
        if ($r.Status -eq 'HEAD') {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("----- $($r.Category) -----")
        } else {
            $counts[$r.Status]++
            [void]$sb.AppendLine("  [{0}] {1,-32}  {2}" -f $r.Status, (Redact $r.Check), (Redact $r.Details))
            if ($r.Fix) { [void]$sb.AppendLine("         Fix: $(Redact $r.Fix)") }
        }
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("===== Summary: PASS=$($counts.PASS)  WARN=$($counts.WARN)  FAIL=$($counts.FAIL) =====")
    return $sb.ToString()
}

function Show-ResultsWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Dune Server Tool — Preflight Results'
    $form.Size = New-Object System.Drawing.Size(1100, 720)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize  = New-Object System.Drawing.Size(800, 500)
    try { $form.Icon = [System.Drawing.SystemIcons]::Information } catch { }

    # --- Top header (summary) ---
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 56
    $header.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)
    $form.Controls.Add($header)

    $summary = New-Object System.Windows.Forms.Label
    $summary.AutoSize = $false
    $summary.Dock = 'Fill'
    $summary.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
    $summary.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $header.Controls.Add($summary)

    # --- Bottom button row ---
    $buttons = New-Object System.Windows.Forms.Panel
    $buttons.Dock = 'Bottom'
    $buttons.Height = 48
    $form.Controls.Add($buttons)

    function NewBtn { param($text, $width = 140)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Width = $width; $b.Height = 32
        $b.Top = 8
        return $b
    }
    $btnCopy   = NewBtn 'Copy to clipboard'
    $btnSave   = NewBtn 'Save report'
    $btnLog    = NewBtn 'Open dune log'
    $btnReveal = NewBtn 'Open install dir'
    $btnReRun  = NewBtn 'Re-run preflight'
    $btnClose  = NewBtn 'Close' 100

    # Lay out left-to-right
    $x = 12
    foreach ($b in @($btnCopy, $btnSave, $btnLog, $btnReveal, $btnReRun)) {
        $b.Left = $x; $buttons.Controls.Add($b); $x += $b.Width + 8
    }
    $btnClose.Anchor = 'Top, Right'
    $btnClose.Left = $buttons.ClientSize.Width - $btnClose.Width - 12
    $buttons.Controls.Add($btnClose)
    $buttons.Add_Resize({ $btnClose.Left = $buttons.ClientSize.Width - $btnClose.Width - 12 })

    # --- ListView in the middle ---
    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.HideSelection = $false
    $list.Dock = 'Fill'
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    [void]$list.Columns.Add('Status',   70)
    [void]$list.Columns.Add('Category', 100)
    [void]$list.Columns.Add('Check',    220)
    [void]$list.Columns.Add('Details',  430)
    [void]$list.Columns.Add('Fix',      400)
    $form.Controls.Add($list)
    $list.BringToFront()

    # Selecting a row shows the full Details + Fix in a tooltip-style banner
    $detailPanel = New-Object System.Windows.Forms.Panel
    $detailPanel.Dock = 'Bottom'
    $detailPanel.Height = 110
    $detailPanel.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 252)
    $form.Controls.Add($detailPanel)

    $detailText = New-Object System.Windows.Forms.TextBox
    $detailText.Multiline = $true
    $detailText.ReadOnly  = $true
    $detailText.ScrollBars = 'Vertical'
    $detailText.Dock = 'Fill'
    $detailText.BorderStyle = 'None'
    $detailText.BackColor = $detailPanel.BackColor
    $detailText.Font = New-Object System.Drawing.Font('Consolas', 9)
    $detailPanel.Controls.Add($detailText)
    $detailPanel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)

    function Render {
        $list.BeginUpdate()
        $list.Items.Clear()
        $counts = @{ PASS = 0; WARN = 0; FAIL = 0 }
        foreach ($r in $script:Results) {
            if ($r.Status -eq 'HEAD') {
                $li = New-Object System.Windows.Forms.ListViewItem('')
                [void]$li.SubItems.Add($r.Category)
                [void]$li.SubItems.Add(''); [void]$li.SubItems.Add(''); [void]$li.SubItems.Add('')
                $li.BackColor = [System.Drawing.Color]::FromArgb(230, 234, 240)
                $li.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9, [System.Drawing.FontStyle]::Bold)
                [void]$list.Items.Add($li)
            } else {
                $counts[$r.Status]++
                $li = New-Object System.Windows.Forms.ListViewItem($r.Status)
                [void]$li.SubItems.Add($r.Category)
                [void]$li.SubItems.Add($r.Check)
                [void]$li.SubItems.Add($r.Details)
                [void]$li.SubItems.Add($r.Fix)
                switch ($r.Status) {
                    'PASS' { $li.BackColor = [System.Drawing.Color]::FromArgb(225, 245, 225); $li.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 0) }
                    'WARN' { $li.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 200); $li.ForeColor = [System.Drawing.Color]::FromArgb(120, 80, 0) }
                    'FAIL' { $li.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220); $li.ForeColor = [System.Drawing.Color]::FromArgb(140, 0, 0) }
                }
                [void]$list.Items.Add($li)
            }
        }
        $list.EndUpdate()
        $summary.Text = "$($counts.PASS) PASS    $($counts.WARN) WARN    $($counts.FAIL) FAIL     ·     Click a row for full details. Use the buttons below to copy/save the report or open the dune log."
        if ($counts.FAIL -gt 0) { $summary.ForeColor = [System.Drawing.Color]::FromArgb(140, 0, 0) }
        elseif ($counts.WARN -gt 0) { $summary.ForeColor = [System.Drawing.Color]::FromArgb(120, 80, 0) }
        else { $summary.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0) }
    }

    $list.add_SelectedIndexChanged({
        $detailText.Text = ''
        if ($list.SelectedItems.Count -gt 0) {
            $li = $list.SelectedItems[0]
            $status = $li.Text
            if ($status -eq '') { return }  # Header row
            $cat    = $li.SubItems[1].Text
            $chk    = $li.SubItems[2].Text
            $det    = $li.SubItems[3].Text
            $fix    = $li.SubItems[4].Text
            $body = "[$status] $cat — $chk`r`n`r`n$det"
            if ($fix) { $body += "`r`n`r`nFix:`r`n$fix" }
            $detailText.Text = $body
        }
    })

    $btnCopy.Add_Click({
        $txt = Format-ReportText
        [System.Windows.Forms.Clipboard]::SetText($txt)
        [System.Windows.Forms.MessageBox]::Show('Report copied to clipboard. Paste it into Discord / email and send to Neil.', 'Dune Preflight', 'OK', 'Information') | Out-Null
    })

    $btnSave.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.FileName = "dune-preflight-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
        $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Format-ReportText | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("Saved to:`r`n$($dlg.FileName)", 'Dune Preflight', 'OK', 'Information') | Out-Null
        }
    })

    $btnLog.Add_Click({
        $logFile = Join-Path $env:LOCALAPPDATA 'DuneServer\dune-server.log'
        if (Test-Path -LiteralPath $logFile) {
            Start-Process notepad.exe -ArgumentList "`"$logFile`""
        } else {
            [System.Windows.Forms.MessageBox]::Show("No log file yet:`r`n$logFile`r`n`r`nThis means the launcher has not been run successfully, or it crashed before logging started.", 'Dune Preflight', 'OK', 'Warning') | Out-Null
        }
    })

    $btnReveal.Add_Click({
        $root = 'C:\Program Files\Dune Server'
        if (Test-Path -LiteralPath $root) { Start-Process explorer.exe -ArgumentList "`"$root`"" }
        else { [System.Windows.Forms.MessageBox]::Show("Install dir not found:`r`n$root", 'Dune Preflight', 'OK', 'Warning') | Out-Null }
    })

    $btnReRun.Add_Click({
        Invoke-DunePreflight
        Render
    })

    $btnClose.Add_Click({ $form.Close() })

    # Initial run + paint
    Invoke-DunePreflight
    Render

    # Auto-save to Desktop + clipboard on first paint, so the user already has
    # something to send Neil without clicking anything.
    try {
        $txt = Format-ReportText
        $desktopPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'dune-preflight.txt'
        $txt | Set-Content -LiteralPath $desktopPath -Encoding UTF8
        [System.Windows.Forms.Clipboard]::SetText($txt)
    } catch { }

    [void]$form.ShowDialog()
}

Show-ResultsWindow
