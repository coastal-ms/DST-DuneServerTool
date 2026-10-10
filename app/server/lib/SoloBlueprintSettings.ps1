$script:DuneSoloBlueprintSection = '/Script/DuneSandbox.BuildingSettings'
$script:DuneSoloBlueprintValues = [ordered]@{
    m_DefaultBuildAndFillTimeInSeconds = '0.000000'
    m_BuildAndFillStartThresholdTimerInSeconds = '0.000000'
    m_BuildableBuildAndFillHoldTimes = '((Short, 0.000000),(Medium, 0.00000),(Long, 0.0000000),(VeryLong, 0.0000000))'
}

function Get-DuneSoloBlueprintPaths {
    $profile = Get-DuneSoloProfile
    # Reuse the verified Retail adapter's configuration directory; no caller-supplied paths.
    $engine = @(Get-DuneSoloEnginePaths -Profile $profile)[0]
    $path = Join-Path (Split-Path -Parent $engine) 'Game.ini'
    $token = Get-DuneSoloProfileToken -DbPath $path
    return @{ path = $path; state = Join-Path (Get-DuneSoloBackupRoot) "settings\blueprint-$token.json" }
}

function Get-DuneSoloBlueprintLines {
    param([string]$Text)
    $inside = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $inside = $Matches[1] -eq $script:DuneSoloBlueprintSection
        } elseif ($inside -and $line -match '^\s*([^;#][^=]*?)\s*=(.*)$') {
            if ($script:DuneSoloBlueprintValues.Contains($Matches[1].Trim())) { $line }
        }
    }
}

function Read-DuneSoloBlueprintSettings {
    Assert-DuneSoloSupportedPlatform
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath -or (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $profile.dbPath))) -ne 'FLS_retail') {
        return @{ ok = $true; supported = $false; enabled = $false; canRestore = $false; conflict = $false }
    }
    $paths = Get-DuneSoloBlueprintPaths
    $ancestor = $paths.path
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing a Solo Game.ini path containing a reparse point.'
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    Assert-DuneSoloNoReparsePath -Path $paths.state
    $text = if (Test-Path -LiteralPath $paths.path) { [IO.File]::ReadAllText($paths.path) } else { '' }
    $lines = @(Get-DuneSoloBlueprintLines -Text $text)
    $enabled = $lines.Count -eq $script:DuneSoloBlueprintValues.Count
    foreach ($key in $script:DuneSoloBlueprintValues.Keys) {
        if (@($lines | Where-Object { $_ -ceq "$key=$($script:DuneSoloBlueprintValues[$key])" }).Count -ne 1) { $enabled = $false }
    }
    $snapshot = if (Test-Path -LiteralPath $paths.state) { Get-Content -LiteralPath $paths.state -Raw | ConvertFrom-Json } else { $null }
    if ($snapshot -and ($snapshot.version -ne 1 -or $snapshot.path -ne $paths.path)) { throw 'Invalid Solo blueprint restoration record. The configuration was not changed.' }
    foreach ($line in @($snapshot.originalLines)) {
        if ($null -ne $line -and ($line -match '[\r\n]' -or $line -notmatch '^\s*([^;#][^=]*?)\s*=' -or -not $script:DuneSoloBlueprintValues.Contains($Matches[1].Trim()))) {
            throw 'Invalid Solo blueprint restoration values. The configuration was not changed.'
        }
    }
    # An interrupted write can leave the original values with a durable snapshot.
    $unchanged = $snapshot -and (($lines -join "`n") -ceq (@($snapshot.originalLines) -join "`n"))
    return @{ ok = $true; supported = $true; path = $paths.path; enabled = $enabled; canRestore = [bool]$snapshot; conflict = [bool]$snapshot -and -not $enabled -and -not $unchanged }
}

function Write-DuneSoloBlueprintFile {
    param([string]$Path, [string]$Text, [bool]$Bom)
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $temp = Join-Path $dir ".blueprint-$([guid]::NewGuid().ToString('N')).tmp"
    $previous = "$temp.previous"
    $existed = Test-Path -LiteralPath $Path
    $replaced = $false
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($Bom)))
        if ($existed) { Invoke-DuneSoloFileReplace -Source $temp -Destination $Path -Backup $previous; $replaced = $true }
        else { Move-Item -LiteralPath $temp -Destination $Path -ErrorAction Stop }
        if ([IO.File]::ReadAllText($Path) -cne $Text) { throw 'Solo blueprint setting verification failed.' }
        Remove-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue
    } catch {
        $failure = $_
        if ($replaced) {
            try { Invoke-DuneSoloFileReplace -Source $previous -Destination $Path -Backup $temp }
            catch { throw "Solo blueprint rollback failed. Recovery file retained at $previous" }
        } elseif (-not $existed) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        throw $failure
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Set-DuneSoloBlueprintSettings {
    param([Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][string]$Confirm)
    Assert-DuneSoloSupportedPlatform
    if ($Confirm -ne 'APPLY SOLO BLUEPRINT SETTINGS') { throw 'Confirm the Solo blueprint settings write before continuing.' }
    Assert-DuneSoloGameClosed
    $status = Read-DuneSoloBlueprintSettings
    if (-not $status.supported) { throw 'Blueprint settings require a verified Retail Solo profile.' }
    if ($status.conflict) { throw 'Blueprint settings changed outside DST. Restore the recorded instant-build values before continuing; your previous settings remain saved.' }
    if (($Enabled -and $status.canRestore) -or (-not $Enabled -and -not $status.canRestore)) { return @{ ok = $true; settings = $status; backupPath = '' } }
    $paths = Get-DuneSoloBlueprintPaths
    $text = if (Test-Path -LiteralPath $paths.path) { [IO.File]::ReadAllText($paths.path) } else { '' }
    $bom = $false
    if (Test-Path -LiteralPath $paths.path) {
        $bytes = [IO.File]::ReadAllBytes($paths.path)
        # Reject unknown encodings rather than silently converting a user's file.
        if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) { throw 'Solo Game.ini must use UTF-8 encoding.' }
        $null = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    }
    $original = @(Get-DuneSoloBlueprintLines -Text $text)
    $replacement = if ($Enabled) { @($script:DuneSoloBlueprintValues.Keys | ForEach-Object { "$_=$($script:DuneSoloBlueprintValues[$_])" }) }
        else { @((Get-Content -LiteralPath $paths.state -Raw | ConvertFrom-Json).originalLines) }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $result = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $written = $false
    foreach ($line in ($text -split '\r?\n')) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $inside = $Matches[1] -eq $script:DuneSoloBlueprintSection
            $result.Add($line)
            if ($inside -and -not $written) { foreach ($entry in $replacement) { $result.Add([string]$entry) }; $written = $true }
        } elseif ($inside -and $line -match '^\s*([^;#][^=]*?)\s*=') {
            if (-not $script:DuneSoloBlueprintValues.Contains($Matches[1].Trim())) { $result.Add($line) }
        } else { $result.Add($line) }
    }
    if (-not $written -and $replacement.Count -gt 0) {
        $result.Add("[$script:DuneSoloBlueprintSection]")
        foreach ($entry in $replacement) { $result.Add([string]$entry) }
        $result.Add('')
    }
    $updated = $result -join $newline
    $backupRoot = Split-Path -Parent $paths.state
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backup = Join-Path $backupRoot "Game-$([guid]::NewGuid().ToString('N')).ini"
    if (Test-Path -LiteralPath $paths.path) { Copy-Item -LiteralPath $paths.path -Destination $backup -ErrorAction Stop } else { $backup = '' }
    # Persist restoration before changing Game.ini. A crash cannot lose original values.
    if ($Enabled) {
        $snapshot = @{ version = 1; path = $paths.path; originalLines = $original; backupPath = $backup }
        Write-DuneSoloBlueprintFile -Path $paths.state -Text ($snapshot | ConvertTo-Json -Depth 5) -Bom $false
    }
    try {
        Assert-DuneSoloGameClosed
        Write-DuneSoloBlueprintFile -Path $paths.path -Text $updated -Bom $bom
    } catch {
        # Keep restoration evidence if rollback itself failed.
        if ($Enabled -and $_.Exception.Message -notlike '*rollback failed*') { Remove-Item -LiteralPath $paths.state -Force -ErrorAction SilentlyContinue }
        throw
    }
    if (-not $Enabled) { Remove-Item -LiteralPath $paths.state -Force -ErrorAction Stop }
    return @{ ok = $true; settings = Read-DuneSoloBlueprintSettings; backupPath = $backup }
}
