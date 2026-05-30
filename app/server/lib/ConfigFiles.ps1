# ConfigFiles — local DST (Dune Server Tool) config-file store.
#
# Collects every file DST needs from the user's OS into one writable,
# upgrade-surviving folder so DST can read them locally instead of hunting
# around the filesystem each run. The store lives next to dune-server.config:
#
#     %APPDATA%\DuneServer\configFiles\
#
# We use %APPDATA% (not the Program Files install dir) because the install dir
# is read-only at runtime without admin, and an upgrade/reinstall would wipe a
# store kept there. %APPDATA% is per-user, always writable, and survives
# upgrades.
#
# What gets collected:
#   * sshKey (+ sshKey.pub if present) — the FRESHEST of the configured SshKey
#     path or %LOCALAPPDATA%\DuneAwakeningServer\sshKey (picked by mtime). The
#     SSH key is the one thing that changes dynamically (rotate-ssh-key), so a
#     repull re-captures it AND re-dumps it into the dune-admin folder, which
#     needs ./sshKey sitting next to dune-admin.exe.
#   * dune-server.config — a copy of the DST config itself.
#   * dune-admin-config.yaml — a read-only backup of ~/.dune-admin/config.yaml.
#
# Nothing here throws: every copy is best-effort and reported in the manifest so
# a single bad ACL or missing source never breaks the whole sync.

function Get-DstConfigFilesDir {
    return (Join-Path $env:APPDATA 'DuneServer\configFiles')
}

# Returns the freshest available SSH key source file (FileInfo) or $null.
function Get-DstFreshestSshKey {
    $cfg = Read-DuneConfigRaw
    $configured = $null
    if ($cfg -and $cfg.Contains('SshKey')) { $configured = [string]$cfg['SshKey'] }
    $appDataKey = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey'

    $candidates = @()
    if ($configured -and (Test-Path -LiteralPath $configured)) {
        $candidates += Get-Item -LiteralPath $configured
    }
    if (Test-Path -LiteralPath $appDataKey) {
        $resolved = (Resolve-Path -LiteralPath $appDataKey).Path
        if (-not ($candidates | Where-Object { $_.FullName -eq $resolved })) {
            $candidates += Get-Item -LiteralPath $appDataKey
        }
    }
    if (-not $candidates -or $candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function New-DstManifestEntry {
    param(
        [string]$Name,
        [string]$Source,
        [string]$Dest,
        [bool]$Copied,
        [string]$Status,
        [string]$Message
    )
    $mtime = $null
    if ($Dest -and (Test-Path -LiteralPath $Dest)) {
        try { $mtime = (Get-Item -LiteralPath $Dest).LastWriteTimeUtc.ToString('o') } catch { }
    }
    return [pscustomobject]@{
        name    = $Name
        source  = $Source
        dest    = $Dest
        copied  = $Copied
        status  = $Status      # 'copied' | 'skipped' | 'missing' | 'error'
        message = $Message
        mtime   = $mtime
    }
}

# Collects/refreshes the local config-file store. Returns a result object with a
# per-file manifest. Safe to call repeatedly (this is the "repull").
function Sync-DstConfigFiles {
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{
        ok        = $true
        dir       = $null
        sshKeyDir = $null   # dune-admin folder the key was also dumped into
        files     = @()
        message   = $null
    }
    $manifest = [System.Collections.Generic.List[object]]::new()

    try {
        $dir = Get-DstConfigFilesDir
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $result.dir = $dir

        # --- 1. SSH key (+ .pub) -------------------------------------------
        $keyItem = Get-DstFreshestSshKey
        if ($keyItem) {
            try {
                $destKey = Join-Path $dir 'sshKey'
                Copy-Item -LiteralPath $keyItem.FullName -Destination $destKey -Force
                $manifest.Add((New-DstManifestEntry -Name 'sshKey' -Source $keyItem.FullName -Dest $destKey -Copied $true -Status 'copied' -Message "From $($keyItem.FullName)"))

                $pubSrc = "$($keyItem.FullName).pub"
                if (Test-Path -LiteralPath $pubSrc) {
                    $destPub = Join-Path $dir 'sshKey.pub'
                    Copy-Item -LiteralPath $pubSrc -Destination $destPub -Force
                    $manifest.Add((New-DstManifestEntry -Name 'sshKey.pub' -Source $pubSrc -Dest $destPub -Copied $true -Status 'copied' -Message $null))
                }
            } catch {
                $result.ok = $false
                $manifest.Add((New-DstManifestEntry -Name 'sshKey' -Source $keyItem.FullName -Dest $null -Copied $false -Status 'error' -Message $_.Exception.Message))
            }
        } else {
            $manifest.Add((New-DstManifestEntry -Name 'sshKey' -Source $null -Dest $null -Copied $false -Status 'missing' -Message 'No SSH key found (neither configured SshKey nor %LOCALAPPDATA%\DuneAwakeningServer\sshKey).'))
        }

        # --- 2. Re-dump the key into the dune-admin folder -----------------
        # The SSH key is the one thing that changes dynamically; whenever we
        # repull it we must also refresh the copy next to dune-admin.exe.
        $exePath = Get-DuneAdminConfiguredPath
        if ($exePath) {
            $adminDir = Split-Path -Parent $exePath
            if ($adminDir -and (Test-Path -LiteralPath $adminDir)) {
                $copy = Copy-DuneAdminSshKey -TargetDir $adminDir
                $result.sshKeyDir = $adminDir
                $status = if ($copy.ok) { if ($copy.skipped) { 'skipped' } else { 'copied' } } else { 'error' }
                if (-not $copy.ok) { $result.ok = $false }
                $manifest.Add((New-DstManifestEntry -Name 'sshKey -> dune-admin' -Source $copy.source -Dest $copy.dest -Copied ([bool]$copy.ok) -Status $status -Message $copy.message))
            } else {
                $manifest.Add((New-DstManifestEntry -Name 'sshKey -> dune-admin' -Source $null -Dest $adminDir -Copied $false -Status 'missing' -Message 'dune-admin folder does not exist yet; key not dumped there.'))
            }
        } else {
            $manifest.Add((New-DstManifestEntry -Name 'sshKey -> dune-admin' -Source $null -Dest $null -Copied $false -Status 'missing' -Message 'DuneAdminExe not configured; key not dumped to dune-admin folder.'))
        }

        # --- 3. dune-server.config copy ------------------------------------
        $cfgPath = Get-DuneConfigPath
        if ($cfgPath -and (Test-Path -LiteralPath $cfgPath)) {
            try {
                $destCfg = Join-Path $dir 'dune-server.config'
                Copy-Item -LiteralPath $cfgPath -Destination $destCfg -Force
                $manifest.Add((New-DstManifestEntry -Name 'dune-server.config' -Source $cfgPath -Dest $destCfg -Copied $true -Status 'copied' -Message $null))
            } catch {
                $result.ok = $false
                $manifest.Add((New-DstManifestEntry -Name 'dune-server.config' -Source $cfgPath -Dest $null -Copied $false -Status 'error' -Message $_.Exception.Message))
            }
        } else {
            $manifest.Add((New-DstManifestEntry -Name 'dune-server.config' -Source $cfgPath -Dest $null -Copied $false -Status 'missing' -Message 'dune-server.config does not exist yet.'))
        }

        # --- 4. dune-admin config.yaml backup ------------------------------
        $yamlPath = Join-Path $env:USERPROFILE '.dune-admin\config.yaml'
        if (Test-Path -LiteralPath $yamlPath) {
            try {
                $destYaml = Join-Path $dir 'dune-admin-config.yaml'
                Copy-Item -LiteralPath $yamlPath -Destination $destYaml -Force
                $manifest.Add((New-DstManifestEntry -Name 'dune-admin-config.yaml' -Source $yamlPath -Dest $destYaml -Copied $true -Status 'copied' -Message 'Backup of ~/.dune-admin/config.yaml'))
            } catch {
                $result.ok = $false
                $manifest.Add((New-DstManifestEntry -Name 'dune-admin-config.yaml' -Source $yamlPath -Dest $null -Copied $false -Status 'error' -Message $_.Exception.Message))
            }
        } else {
            $manifest.Add((New-DstManifestEntry -Name 'dune-admin-config.yaml' -Source $yamlPath -Dest $null -Copied $false -Status 'missing' -Message 'dune-admin not set up yet (no config.yaml).'))
        }

        $result.files = $manifest.ToArray()
        $copiedCount = ($result.files | Where-Object { $_.copied }).Count
        $result.message = "Synced $copiedCount file(s) into $dir"
        return $result
    } catch {
        $result.ok = $false
        $result.files = $manifest.ToArray()
        $result.message = "Config-file sync failed: $($_.Exception.Message)"
        return $result
    }
}
