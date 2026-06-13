# /api/diagnostics — build a redacted ZIP of logs the user can attach to a
# GitHub bug report. Triggered from the React "Help → Create GitHub Issue +
# Save Logs" menu item and from the CLI `report-issue` command.
#
# Hard rules:
#   - Everything that lands in the ZIP runs through Invoke-DstRedaction first.
#     We never write the user's real VM IP, SSH key path, or Windows username
#     into a file they're about to attach to a public issue.
#   - Failures on individual sources (missing log, locked file, OneDrive
#     Desktop read-only) are recorded in manifest.txt as warnings; the ZIP
#     still builds with whatever did succeed.
#   - The ZIP is staged under %TEMP% and only renamed into place after a
#     successful Compress-Archive — no partial files on the user's Desktop.

# --- Sanitization ------------------------------------------------------------

# Returns a copy of $Text with anything personally identifying replaced.
# Cheap to call on every line / every file we include in the bundle.
function Invoke-DstRedaction {
    param(
        [string]$Text,
        [string]$WindowsUser,
        [string]$SshKeyPath,
        [string]$SteamPath
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text

    # 1) ?t=<token>  -> ?t=<redacted>   (the local-portal auth token)
    $out = [regex]::Replace($out, '([?&;])t=[^&\s"''<>]+', '$1t=<redacted>')

    # 2) IPv4 addresses (but leave 127.0.0.1 / 0.0.0.0 / 255.255.255.255 alone —
    #    those carry no identifying info and matter for log readability).
    $out = [regex]::Replace($out, '\b(?!(?:127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255)\b)(?:\d{1,3}\.){3}\d{1,3}\b', '<ip>')

    # 3) IPv6 addresses (anything with two or more colon-separated hex groups,
    #    minus the loopback ::1).
    $out = [regex]::Replace($out, '(?<![:\w])(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}(?![:\w])', {
        param($m) if ($m.Value -eq '::1') { return '::1' } else { return '<ipv6>' }
    })

    # 4) Specific config paths we know carry the username.
    if ($WindowsUser) {
        $out = [regex]::Replace($out, [regex]::Escape($WindowsUser), '<user>', 'IgnoreCase')
    }
    if ($SshKeyPath) {
        $out = [regex]::Replace($out, [regex]::Escape($SshKeyPath), '<ssh-key-path>', 'IgnoreCase')
    }
    if ($SteamPath) {
        $out = [regex]::Replace($out, [regex]::Escape($SteamPath), '<steam-path>', 'IgnoreCase')
    }
    # 5) Generic Windows user-profile path:  C:\Users\<anyone>\  ->  C:\Users\<user>\
    $out = [regex]::Replace($out, '([A-Za-z]):\\Users\\[^\\/:*?"<>|\r\n]+', '$1:\Users\<user>', 'IgnoreCase')

    # 6) SshKey=<value> / SteamPath=<value> / WindowsUser=<value> lines in
    #    INI-style config files. Belt-and-braces in case the value didn't
    #    match the explicit redactions above.
    foreach ($k in @('SshKey', 'WindowsUser', 'SteamPath', 'PortCheckUrlTemplate')) {
        $out = [regex]::Replace($out, "(?m)^(\s*$k\s*=\s*).+$", "`${1}<redacted>")
    }

    return $out
}

# Returns the section-header names that appear more than once in an INI body,
# formatted "Name xN". Pure (no SSH/IO) so it's unit-testable. Duplicate
# headers are the root cause of the "DST override silently ignored" class of
# Game Config bugs (UE5 honours the first header + last-key-wins), so surfacing
# them at the top of each snapshot makes triage a one-liner.
function Get-DstIniDuplicateHeaders {
    param([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return @() }
    $headers = [regex]::Matches($Raw, '(?m)^\s*\[(.+?)\]\s*$') | ForEach-Object { $_.Groups[1].Value }
    return @(
        $headers | Group-Object | Where-Object { $_.Count -gt 1 } |
            ForEach-Object { "$($_.Name) x$($_.Count)" }
    )
}

# --- Bundle builder ----------------------------------------------------------

function Get-DstDesktopPath {
    # Resolve Desktop via .NET (respects OneDrive / Group Policy redirection).
    # Falls back to %APPDATA%\DuneServer\Diagnostics if Desktop is unwritable.
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop -and (Test-Path -LiteralPath $desktop)) {
            $probe = Join-Path $desktop ".dst-diag-write-test-$([guid]::NewGuid().ToString('N'))"
            try {
                Set-Content -LiteralPath $probe -Value 'x' -Encoding ASCII -ErrorAction Stop
                Remove-Item -LiteralPath $probe -ErrorAction SilentlyContinue
                return @{ path = $desktop; fallback = $false }
            } catch {}
        }
    } catch {}
    $fallback = Join-Path $env:APPDATA 'DuneServer\Diagnostics'
    [void](New-Item -ItemType Directory -Force -Path $fallback -ErrorAction SilentlyContinue)
    return @{ path = $fallback; fallback = $true }
}

function Get-DstWebView2Version {
    foreach ($p in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )) {
        try {
            $v = (Get-ItemProperty -Path $p -Name 'pv' -ErrorAction Stop).pv
            if ($v -and $v -ne '0.0.0.0') { return $v }
        } catch {}
    }
    return '(not installed / not detected)'
}

# Read a file that may be open for append (logs). Returns the LAST $MaxBytes
# of content, or $null on failure. Uses FileShare.ReadWrite so a writer that
# holds the file open doesn't block us.
function Read-DstLogTail {
    param([string]$Path, [int]$MaxBytes = 204800)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                            [System.IO.FileAccess]::Read,
                                            [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -gt $MaxBytes) {
                [void]$fs.Seek($len - $MaxBytes, [System.IO.SeekOrigin]::Begin)
            }
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return $null
    }
}

# Builds the diagnostic bundle. Returns a hashtable with the same shape the
# /api/diagnostics/bundle handler echoes back to the React client (so the CLI
# `report-issue` command can use the exact same code path).
function New-DstDiagnosticBundle {
    [CmdletBinding()]
    param()

    $warnings = New-Object System.Collections.Generic.List[string]
    $included = New-Object System.Collections.Generic.List[hashtable]

    # 1) Pick the on-disk destination ----------------------------------------
    $destInfo = Get-DstDesktopPath
    if ($destInfo.fallback) {
        $warnings.Add("Desktop is not writable (OneDrive / Group Policy?). Saved under %APPDATA%\DuneServer\Diagnostics instead.")
    }
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $finalZip = Join-Path $destInfo.path "dst-diagnostics-$ts.zip"
    # NB: Compress-Archive ONLY accepts a destination ending in ".zip". Under
    # Windows PowerShell 5.1 (which the packaged DuneServer.exe runs on) a
    # ".tmp" destination throws ".tmp is not a supported archive file format",
    # which silently failed the whole bundle. Stage to a real .zip name in
    # %TEMP%, then move it onto the final path.
    $stageZip = Join-Path $env:TEMP "dst-diagnostics-$ts.partial.zip"

    # Stage everything in %TEMP% so writes to the user's Desktop are atomic
    # (we Compress-Archive into the staging .zip, then move on success).
    $stageDir = Join-Path $env:TEMP "dst-diagnostics-$ts"
    [void](New-Item -ItemType Directory -Force -Path $stageDir -ErrorAction SilentlyContinue)

    # 2) Resolve config so we know what to redact ----------------------------
    $cfg = $null
    try { $cfg = Read-DuneConfigRaw } catch { $warnings.Add("Could not read dune-server.config: $($_.Exception.Message)") }
    $redactArgs = @{
        WindowsUser  = if ($cfg) { [string]$cfg.WindowsUser  } else { '' }
        SshKeyPath   = if ($cfg) { [string]$cfg.SshKey       } else { '' }
        SteamPath    = if ($cfg) { [string]$cfg.SteamPath    } else { '' }
    }

    # 3) env.txt -------------------------------------------------------------
    $envInfo = [System.Collections.Generic.List[string]]::new()
    $envInfo.Add("Tool version       : v$script:DuneToolVersion")
    $envInfo.Add("PowerShell         : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
    $envInfo.Add("OS                 : Windows $([System.Environment]::OSVersion.Version)")
    $envInfo.Add("WebView2 runtime   : $(Get-DstWebView2Version)")
    $envInfo.Add("AppDir             : $script:AppDir")
    $envInfo.Add("UserDataFolder     : $(Join-Path $env:LOCALAPPDATA 'DuneServer\webview2')")
    $envInfo.Add("Config dir         : $(Join-Path $env:APPDATA 'DuneServer')")
    $envInfo.Add("Generated          : $(Get-Date -Format 'o')")
    $envText = Invoke-DstRedaction -Text ($envInfo -join "`r`n") @redactArgs
    $envPath = Join-Path $stageDir 'env.txt'
    Set-Content -LiteralPath $envPath -Value $envText -Encoding UTF8
    $included.Add(@{ name = 'env.txt'; bytes = (Get-Item -LiteralPath $envPath).Length })

    # 4) Sanitized config copy -----------------------------------------------
    $cfgPath = Get-DuneConfigPath
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw  = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop
            $san  = Invoke-DstRedaction -Text $raw @redactArgs
            $out  = Join-Path $stageDir 'dune-server.config.sanitized.txt'
            Set-Content -LiteralPath $out -Value $san -Encoding UTF8
            $included.Add(@{ name = 'dune-server.config.sanitized.txt'; bytes = (Get-Item -LiteralPath $out).Length })
        } catch {
            $warnings.Add("Failed to sanitize dune-server.config: $($_.Exception.Message)")
        }
    } else {
        $warnings.Add("dune-server.config not found at $cfgPath.")
    }

    # 5) WebView2 debug log (tail, sanitized) --------------------------------
    $wv2 = Join-Path $env:APPDATA 'DuneServer\webview2-debug.log'
    $wv2Tail = Read-DstLogTail -Path $wv2 -MaxBytes 204800
    if ($null -ne $wv2Tail) {
        try {
            $wv2Bytes  = (Get-Item -LiteralPath $wv2 -ErrorAction Stop).Length
            $header    = "# webview2-debug.log (tail, sanitized; source size: $wv2Bytes bytes)`r`n# Path: $wv2`r`n`r`n"
            $san       = $header + (Invoke-DstRedaction -Text $wv2Tail @redactArgs)
            $out       = Join-Path $stageDir 'webview2-debug.log'
            Set-Content -LiteralPath $out -Value $san -Encoding UTF8
            $included.Add(@{ name = 'webview2-debug.log'; bytes = (Get-Item -LiteralPath $out).Length })
            if ($wv2Bytes -gt 204800) { $warnings.Add('webview2-debug.log was truncated to the last 200 KB.') }
        } catch {
            $warnings.Add("Failed to copy webview2-debug.log: $($_.Exception.Message)")
        }
    } else {
        $warnings.Add('webview2-debug.log not present — the desktop app may not have been launched on this machine yet.')
    }

    # 6) Recent CLI logs (last 3 dune-server-*.log) --------------------------
    $logRoots = @(
        (Join-Path (Split-Path -Parent $script:AppDir) '.logs'),
        (Join-Path $env:APPDATA 'DuneServer\.logs')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $foundCliLogs = $false
    foreach ($root in $logRoots) {
        $logs = Get-ChildItem -LiteralPath $root -Filter 'dune-server-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 3
        foreach ($lg in $logs) {
            $foundCliLogs = $true
            $tail = Read-DstLogTail -Path $lg.FullName -MaxBytes 51200   # 50 KB each
            if ($null -ne $tail) {
                $header = "# $($lg.Name) (tail, sanitized; source size: $($lg.Length) bytes)`r`n# Path: $($lg.FullName)`r`n`r`n"
                $san    = $header + (Invoke-DstRedaction -Text $tail @redactArgs)
                $out    = Join-Path $stageDir $lg.Name
                Set-Content -LiteralPath $out -Value $san -Encoding UTF8
                $included.Add(@{ name = $lg.Name; bytes = (Get-Item -LiteralPath $out).Length })
            } else {
                $warnings.Add("Could not read $($lg.FullName).")
            }
        }
    }
    if (-not $foundCliLogs) {
        $warnings.Add('No dune-server-*.log CLI transcripts found.')
    }

    # 6b) Live game-config INI snapshot (best-effort over SSH) ----------------
    # The duplicate-section-header / "my setting didn't apply" class of bug can
    # only be diagnosed from the ACTUAL on-disk UserGame.ini / UserEngine.ini,
    # so pull a redacted copy when the VM is reachable. Never fatal — an absent
    # or unreachable VM is a warning and the rest of the bundle still builds.
    if ((Get-Command Get-DuneGameConfigContext -ErrorAction SilentlyContinue) -and
        (Get-Command Get-DuneGameConfig -ErrorAction SilentlyContinue)) {
        try {
            $ctx = Get-DuneGameConfigContext
            if ($ctx.ok) {
                $gc = Get-DuneGameConfig -Ip $ctx.ip
                foreach ($pair in @(
                    @{ key = 'game';   file = 'UserGame.ini' },
                    @{ key = 'engine'; file = 'UserEngine.ini' }
                )) {
                    $node = $gc[$pair.key]
                    $raw  = if ($node) { [string]$node.raw } else { '' }
                    if ([string]::IsNullOrWhiteSpace($raw)) {
                        $warnings.Add("Game config: $($pair.file) came back empty (source: $($gc.source)).")
                        continue
                    }
                    $dupes   = Get-DstIniDuplicateHeaders -Raw $raw
                    $dupLine = if ($dupes.Count -gt 0) { 'DUPLICATE SECTION HEADERS: ' + ($dupes -join '; ') } else { 'No duplicate section headers detected.' }
                    $header  = "# $($pair.file) snapshot (sanitized; source: $($gc.source); path: $($node.path))`r`n# $dupLine`r`n`r`n"
                    $san     = $header + (Invoke-DstRedaction -Text $raw @redactArgs)
                    $outName = "$($pair.file).snapshot.txt"
                    $out     = Join-Path $stageDir $outName
                    Set-Content -LiteralPath $out -Value $san -Encoding UTF8
                    $included.Add(@{ name = $outName; bytes = (Get-Item -LiteralPath $out).Length })
                }
            } else {
                $warnings.Add("Game config INI snapshot skipped: $($ctx.message)")
            }
        } catch {
            $warnings.Add("Game config INI snapshot failed: $($_.Exception.Message)")
        }
    } else {
        $warnings.Add('Game config helpers not loaded — INI snapshot skipped.')
    }

    # 7) Manifest ------------------------------------------------------------
    $manLines = [System.Collections.Generic.List[string]]::new()
    $manLines.Add("Dune Server Tool diagnostic bundle")
    $manLines.Add("Generated $(Get-Date -Format 'o') by v$script:DuneToolVersion")
    $manLines.Add('')
    $manLines.Add('Sanitization applied to every text file in this bundle:')
    $manLines.Add('  - IPv4 / IPv6 addresses (except loopback) -> <ip> / <ipv6>')
    $manLines.Add('  - C:\Users\<anyone>\... paths              -> C:\Users\<user>\...')
    $manLines.Add('  - WindowsUser / SshKey / SteamPath values    -> <user> / <ssh-key-path> / <steam-path>')
    $manLines.Add('  - ?t=<token> query params                  -> ?t=<redacted>')
    $manLines.Add('  - INI key=value redaction for the keys above as a safety net')
    $manLines.Add('')
    $manLines.Add('Game config snapshots (UserGame.ini / UserEngine.ini) are pulled live from')
    $manLines.Add('the VM when reachable, sanitized, and headlined with a duplicate-section check.')
    $manLines.Add('')
    $manLines.Add('Files included:')
    foreach ($f in $included) {
        $manLines.Add(("  {0,-40} {1,10} bytes" -f $f.name, $f.bytes))
    }
    if ($warnings.Count -gt 0) {
        $manLines.Add('')
        $manLines.Add('Warnings:')
        foreach ($w in $warnings) { $manLines.Add("  - $w") }
    }
    $manPath = Join-Path $stageDir 'manifest.txt'
    Set-Content -LiteralPath $manPath -Value ($manLines -join "`r`n") -Encoding UTF8
    $included.Add(@{ name = 'manifest.txt'; bytes = (Get-Item -LiteralPath $manPath).Length })

    # 8) Compress into a staging .zip then move into place ------------------
    if (Test-Path -LiteralPath $stageZip) { Remove-Item -LiteralPath $stageZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $finalZip) { Remove-Item -LiteralPath $finalZip -Force -ErrorAction SilentlyContinue }
    try {
        Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $stageZip -Force -ErrorAction Stop
        Move-Item -LiteralPath $stageZip -Destination $finalZip -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $stageZip) { Remove-Item -LiteralPath $stageZip -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to build diagnostic ZIP: $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue

    $zipSize = (Get-Item -LiteralPath $finalZip).Length

    # 9) Best-effort: pop Explorer with the ZIP selected ---------------------
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$finalZip`"" -ErrorAction Stop | Out-Null
    } catch {
        $warnings.Add("Could not open Explorer to reveal the ZIP: $($_.Exception.Message)")
    }

    return @{
        ok        = $true
        path      = $finalZip
        sizeBytes = $zipSize
        fileCount = $included.Count
        sanitized = $true
        warnings  = @($warnings)
    }
}

# --- Route -------------------------------------------------------------------

# POST /api/diagnostics/bundle — build the ZIP and reveal it in Explorer.
Register-DuneRoute -Method POST -Path '/api/diagnostics/bundle' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = New-DstDiagnosticBundle
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
