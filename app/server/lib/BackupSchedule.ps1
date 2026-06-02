# BackupSchedule.ps1
# Manage a configurable battlegroup-backup cron entry on the Dune VM.
#
# Source of truth is a single block in the VM's root crontab, delimited by:
#   # DST-BACKUP BEGIN
#   # DST-BACKUP-PRESET: <name>
#   # DST-BACKUP-RETENTION: <days>
#   <preset cron line(s)>
#   <retention cron line, if days > 0>
#   # DST-BACKUP END
#
# Markers are ASCII-only on purpose — they have to round-trip through
# PowerShell → SSH → BusyBox crontab without encoding surprises.
#
# All edits go through one SSH command that takes a VM-side mkdir lock, so
# two concurrent Save Schedule calls (or a console operator running
# `sudo crontab -e`) can't lose each other's edits in the middle of our
# read-modify-write. The lock is per-VM and only held for the duration of
# the SSH command — never for the lifetime of a request.
#
# Loaded by app/DuneServer.ps1's lib-dot-sourcing. Depends on Invoke-V6Ssh
# from app/lib/Db-Postgres.ps1 (loaded lazily here if it's not already in
# scope, mirroring Broadcast.ps1).

$script:DuneDbPostgresPathForBackup = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\Db-Postgres.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\Db-Postgres.ps1')
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneDbPostgresPathForBackup = $full; break }
}
if ($script:DuneDbPostgresPathForBackup -and -not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
    . $script:DuneDbPostgresPathForBackup
}

# -----------------------------------------------------------------------------
# Preset definitions. Cron expressions assume the VM's local timezone, which
# defaults to UTC on Alpine — Get-DuneBackupSchedule returns the detected
# timezone separately so the UI can label accurately rather than assume.
# -----------------------------------------------------------------------------
$script:DuneBackupPresets = @{
    'Off'             = @{ label='Disabled';                       crons=@() }
    'Hourly'          = @{ label='Every hour (on the hour)';       crons=@('0 * * * *') }
    'Every6Hours'     = @{ label='Every 6 hours';                  crons=@('0 */6 * * *') }
    'DailyUtc04'      = @{ label='Daily at 04:00';                 crons=@('0 4 * * *') }
    'TwiceDailyUtc'   = @{ label='Twice daily (04:00 and 16:00)';  crons=@('0 4 * * *','0 16 * * *') }
    'WeeklyMonUtc04'  = @{ label='Weekly, Monday 04:00';           crons=@('0 4 * * 1') }
}

$script:DuneBackupCmd = '/home/dune/.dune/bin/battlegroup backup >> /var/log/dune-backup.log 2>&1'
$script:DuneBackupBeginMarker = '# DST-BACKUP BEGIN'
$script:DuneBackupEndMarker   = '# DST-BACKUP END'
$script:DuneBackupDumpDir     = '/funcom/artifacts/database-dumps'

function Get-DuneBackupPresetNames {
    return @($script:DuneBackupPresets.Keys | Sort-Object)
}

# Map a set of cron expressions back to a preset id, or $null if no match.
# Comparison is order-insensitive on the expressions themselves but exact on
# the time fields — anything unusual stays "Custom".
function Get-DuneBackupPresetForCronExprs {
    param([string[]]$Exprs)
    if (-not $Exprs -or $Exprs.Count -eq 0) { return $null }
    $sorted = ($Exprs | Sort-Object) -join '|'
    foreach ($name in $script:DuneBackupPresets.Keys) {
        $candidate = $script:DuneBackupPresets[$name].crons
        if (-not $candidate -or $candidate.Count -eq 0) { continue }
        if (($candidate | Sort-Object) -join '|' -eq $sorted) { return $name }
    }
    return $null
}

# Extract the 5-field cron expression from a crontab line that runs our
# backup command. Returns $null if the line doesn't look like a managed
# backup invocation (i.e. doesn't reference the battlegroup-backup binary).
function Get-DuneBackupCronExprFromLine {
    param([string]$Line)
    if (-not $Line) { return $null }
    if ($Line -notmatch 'battlegroup\s+backup') { return $null }
    $trimmed = $Line.Trim()
    if ($trimmed.StartsWith('#')) { return $null }
    # First 5 whitespace-separated fields = the cron schedule. BusyBox cron
    # doesn't support @yearly/@daily/@hourly shortcuts in /etc/crontabs, so
    # we only worry about the standard 5-field form.
    $parts = $trimmed -split '\s+', 6
    if ($parts.Count -lt 6) { return $null }
    return ($parts[0..4] -join ' ')
}

function Get-DuneBackupContext {
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='SSH helper unavailable (Db-Postgres.ps1 not loaded).' }
    }
    if (-not (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='VM status helper unavailable.' }
    }
    $vm = Get-DuneVmStatus
    if (-not $vm)         { return @{ ok=$false; status=503; message='VM status unavailable.' } }
    if (-not $vm.exists)  { return @{ ok=$false; status=503; message='VM does not exist on this host.' } }
    if (-not $vm.running) { return @{ ok=$false; status=503; message='VM is not running. Start the battlegroup first.' } }
    if (-not $vm.ip)      { return @{ ok=$false; status=503; message='VM has no IP yet - wait for it to finish booting.' } }
    return @{ ok=$true; ip=$vm.ip; vm=$vm }
}

# -----------------------------------------------------------------------------
# Run a shell script on the VM and return @{ rc; out } even when the underlying
# Invoke-V6Ssh helper swallows stderr. We base64-encode the script (so embedded
# newlines/quotes survive), append an explicit RC marker line, then peel that
# marker back off the output. Returns rc=-1 if the marker is missing (e.g. SSH
# failed before our wrapper ran).
# -----------------------------------------------------------------------------
function Invoke-DuneBackupShell {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Script,
        [int]$TimeoutSec = 30
    )
    # Run the caller's script in a subshell so its exit code is observable
    # even if the script uses `exit N` (the parent shell still gets to print
    # the __DST_RC sentinel). `sudo bash 2>&1` merges remote stderr into
    # stdout so Invoke-V6Ssh's local-stderr redirect doesn't eat it.
    $clean = $Script -replace "`r",''
    $wrapped = "( $clean`n)`n__dst_rc=`$?`nprintf '\n__DST_RC:%s\n' `"`$__dst_rc`""
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wrapped))
    $cmd = "echo $b64 | base64 -d | sudo bash 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec $TimeoutSec
    $joined = if ($null -eq $out) { '' } else { ($out -join "`n") }
    $rc = -1
    $body = $joined
    $m = [regex]::Match($joined, '(?ms)\r?\n?__DST_RC:(\d+)\r?\n?\s*$')
    if ($m.Success) {
        $rc = [int]$m.Groups[1].Value
        $body = $joined.Substring(0, $m.Index)
    }
    return @{ rc = $rc; out = $body }
}

# -----------------------------------------------------------------------------
# Build the rendered crontab block from a preset + retention. Returns either
# a string (the block, including trailing newline) or $null for 'Off'.
# -----------------------------------------------------------------------------
function New-DuneBackupBlock {
    param(
        [Parameter(Mandatory)][string]$Preset,
        [int]$RetentionDays = 0
    )
    if (-not $script:DuneBackupPresets.ContainsKey($Preset)) {
        throw "Unknown preset: $Preset"
    }
    if ($Preset -eq 'Off') { return $null }

    $lines = @()
    $lines += $script:DuneBackupBeginMarker
    $lines += "# DST-BACKUP-PRESET: $Preset"
    $lines += "# DST-BACKUP-RETENTION: $RetentionDays"
    foreach ($cronExpr in $script:DuneBackupPresets[$Preset].crons) {
        $lines += "$cronExpr $script:DuneBackupCmd"
    }
    if ($RetentionDays -gt 0) {
        # Narrow the retention pattern to filenames that match Funcom's own
        # battlegroup-dump naming (<bg>-YYYYMMDD-HHMMSS.backup[.yaml]) so we
        # never delete a manually-named snapshot like 'pre-patch-X.backup'.
        $namePat = '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].backup'
        $find = "find $script:DuneBackupDumpDir -type f \( -name '$namePat' -o -name '$namePat.yaml' \) -mtime +$RetentionDays -delete"
        $lines += "15 5 * * * $find"
    }
    $lines += $script:DuneBackupEndMarker
    return (($lines -join "`n") + "`n")
}

# -----------------------------------------------------------------------------
# Parse a crontab string into managed-block + leftover lines.
# Returns @{ block = <hashtable or $null>; outsideText = string; hasUnmanagedBackupLines = bool }.
# Block hashtable has: preset, retentionDays, raw, looksTampered.
# -----------------------------------------------------------------------------
function ConvertFrom-DuneBackupCrontab {
    param([string]$CrontabText)
    if ($null -eq $CrontabText) { $CrontabText = '' }
    $lines = ($CrontabText -replace "`r",'') -split "`n"
    $outside = New-Object System.Collections.Generic.List[string]
    $blockLines = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($ln in $lines) {
        if (-not $inBlock -and $ln -eq $script:DuneBackupBeginMarker) {
            $inBlock = $true
            continue
        }
        if ($inBlock -and $ln -eq $script:DuneBackupEndMarker) {
            $inBlock = $false
            continue
        }
        if ($inBlock) {
            $blockLines.Add($ln) | Out-Null
        } else {
            $outside.Add($ln) | Out-Null
        }
    }
    $blockInfo = $null
    if ($blockLines.Count -gt 0 -or $CrontabText -match [regex]::Escape($script:DuneBackupBeginMarker)) {
        $preset = $null
        $retention = 0
        foreach ($bl in $blockLines) {
            if ($bl -match '^# DST-BACKUP-PRESET:\s*(\S+)') { $preset = $Matches[1] }
            elseif ($bl -match '^# DST-BACKUP-RETENTION:\s*(\d+)') { $retention = [int]$Matches[1] }
        }
        if (-not $preset) { $preset = 'Custom' }
        $blockInfo = @{
            preset        = $preset
            retentionDays = $retention
            raw           = ($blockLines -join "`n")
        }
    }

    # Detect user-managed cron lines outside our block that still call the
    # backup command — surfaces as a warning in the UI. Also collect their
    # cron expressions so the caller can try to reverse-map to a preset
    # (the most common case is the hardcoded `0 4 * * *` line that early
    # adopters installed by hand before this card existed).
    $unmanagedExprs = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $outside) {
        $expr = Get-DuneBackupCronExprFromLine -Line $ln
        if ($expr) { $unmanagedExprs.Add($expr) | Out-Null }
    }
    $unmanaged = ($unmanagedExprs.Count -gt 0)

    return @{
        block                    = $blockInfo
        outsideText              = ($outside -join "`n").TrimEnd("`n")
        hasUnmanagedBackupLines  = $unmanaged
        unmanagedBackupCronExprs = @($unmanagedExprs)
    }
}

# -----------------------------------------------------------------------------
# Public: read the current schedule from the VM.
# -----------------------------------------------------------------------------
function Get-DuneBackupSchedule {
    param([Parameter(Mandatory)][string]$Ip)
    # crond status + timezone probe + crontab fetch in a single SSH round-trip.
    $script = @'
echo "__DST_SECTION:TZ"
date +%Z
echo "__DST_SECTION:DATE"
date -u +%Y-%m-%dT%H:%M:%SZ
echo "__DST_SECTION:CROND"
if command -v rc-service >/dev/null 2>&1; then
  rc-service crond status 2>&1 || true
elif command -v service >/dev/null 2>&1; then
  service crond status 2>&1 || service cron status 2>&1 || true
else
  ps -A 2>/dev/null | grep -E "[c]rond?" | head -1 || true
fi
echo "__DST_SECTION:CRONTAB"
sudo crontab -l 2>&1 || true
'@
    $r = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 20
    if ($r.rc -lt 0) { throw "SSH to VM failed (no exit code returned)." }

    $sections = @{}
    $current = $null
    foreach ($ln in ($r.out -split "`n")) {
        if ($ln -match '^__DST_SECTION:(\w+)') { $current = $Matches[1]; $sections[$current] = New-Object System.Collections.Generic.List[string]; continue }
        if ($current) { $sections[$current].Add($ln) | Out-Null }
    }
    $tz       = if ($sections.ContainsKey('TZ'))       { ($sections['TZ']       -join '').Trim() } else { 'UTC' }
    $vmNowUtc = if ($sections.ContainsKey('DATE'))     { ($sections['DATE']     -join '').Trim() } else { '' }
    $crondTxt = if ($sections.ContainsKey('CROND'))    { ($sections['CROND']    -join "`n") } else { '' }
    $cronText = if ($sections.ContainsKey('CRONTAB'))  { ($sections['CRONTAB']  -join "`n") } else { '' }

    # `crontab -l` returns 1 + "no crontab for ..." on stderr when none exists;
    # we already merged stderr->stdout above, so just normalize that case.
    if ($cronText -match '^no crontab for') { $cronText = '' }

    $crondRunning = ($crondTxt -match 'status:\s*started' -or $crondTxt -match 'is running' -or $crondTxt -match '\bcrond?\b')

    $parsed = ConvertFrom-DuneBackupCrontab -CrontabText $cronText

    $enabled = $false
    $preset = 'Off'
    $retention = 0
    $looksTampered = $false
    $inferredFromUnmanaged = $false
    if ($parsed.block) {
        $preset    = $parsed.block.preset
        $retention = $parsed.block.retentionDays
        $enabled   = ($preset -ne 'Off')
        # If the rendered block doesn't match the stored preset+retention any
        # more, the operator likely edited it by hand. Surface that to the UI.
        $expected = (New-DuneBackupBlock -Preset $preset -RetentionDays $retention)
        if ($expected) {
            $expectedInner = ($expected.TrimEnd("`n") -split "`n" | Select-Object -Skip 1 | Select-Object -SkipLast 1) -join "`n"
            if ($expectedInner -ne $parsed.block.raw) { $looksTampered = $true }
        }
    } elseif ($parsed.hasUnmanagedBackupLines) {
        # No managed block, but a hand-installed `battlegroup backup` cron
        # exists outside the block (e.g. the legacy `0 4 * * *` line from
        # the miniature-disco docs). If the schedule matches a known preset
        # exactly, infer it so the UI shows the right preselected option and
        # the user just clicks Save to migrate it into our managed block.
        $inferred = Get-DuneBackupPresetForCronExprs -Exprs $parsed.unmanagedBackupCronExprs
        if ($inferred) {
            $preset    = $inferred
            $enabled   = $true
            $inferredFromUnmanaged = $true
        }
    }

    return @{
        enabled                   = $enabled
        preset                    = $preset
        retentionDays             = $retention
        vmTimezone                = $tz
        vmNowUtc                  = $vmNowUtc
        crondRunning              = [bool]$crondRunning
        crondStatusRaw            = $crondTxt.Trim()
        hasUnmanagedBackupLines   = $parsed.hasUnmanagedBackupLines
        managedBlockLooksTampered = $looksTampered
        inferredFromUnmanaged     = $inferredFromUnmanaged
        presets                   = @(Get-DuneBackupPresetNames | ForEach-Object {
            @{ id=$_; label=$script:DuneBackupPresets[$_].label }
        })
    }
}

# -----------------------------------------------------------------------------
# Public: write the schedule. Locks per-VM and verifies by reading the
# crontab back after the write.
# -----------------------------------------------------------------------------
function Set-DuneBackupSchedule {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Preset,
        [int]$RetentionDays = 0
    )
    if (-not $script:DuneBackupPresets.ContainsKey($Preset)) {
        return @{ ok=$false; status=400; message="Unknown preset: $Preset" }
    }
    if ($RetentionDays -lt 0 -or $RetentionDays -gt 3650) {
        return @{ ok=$false; status=400; message="retentionDays must be 0..3650 (got $RetentionDays)." }
    }

    $newBlock = New-DuneBackupBlock -Preset $Preset -RetentionDays $RetentionDays
    $newBlockB64 = if ($newBlock) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newBlock)) } else { '' }

    # Whole RMW (read existing crontab, strip our block, append new block,
    # install via `crontab -`) happens inside a VM-side mkdir lock so two
    # concurrent saves serialize cleanly. We also ensure the backup log file
    # exists with a sane owner/perms before installing, otherwise the first
    # scheduled run's `>> /var/log/dune-backup.log` would create it owned
    # by root only.
    $script = @"
set +e
LOCK=/tmp/dst-backup-schedule.lock
if ! sudo mkdir "`$LOCK" 2>/dev/null; then
  echo "__DST_LOCK_HELD"
  exit 75
fi
trap 'sudo rmdir "`$LOCK" 2>/dev/null' EXIT

sudo touch /var/log/dune-backup.log 2>/dev/null || true
sudo chmod 0644 /var/log/dune-backup.log 2>/dev/null || true

existing=`$(sudo crontab -l 2>/dev/null || true)
# Drop any prior managed block (inclusive of markers) AND any stray cron
# line that calls `battlegroup backup` outside the block — otherwise an
# old hand-installed line (e.g. the legacy `0 4 * * *` from the docs)
# would coexist with our new managed block and run a second time.
# awk is BusyBox-safe.
stripped=`$(printf '%s\n' "`$existing" | awk '
  /^# DST-BACKUP BEGIN`$/ { in_block=1; next }
  /^# DST-BACKUP END`$/   { in_block=0; next }
  in_block                { next }
  /^[[:space:]]*#/        { print; next }
  /battlegroup[[:space:]]+backup/ { next }
  { print }
')

newblock=''
if [ -n "$newBlockB64" ]; then
  newblock=`$(echo "$newBlockB64" | base64 -d)
fi

# Compose final crontab: stripped content + blank separator + new block.
final=`$(printf '%s' "`$stripped" | sed -e :a -e '/^\n*`$/{`$d;N;ba' -e '}')
if [ -n "`$newblock" ]; then
  if [ -n "`$final" ]; then
    final="`$final
`$newblock"
  else
    final="`$newblock"
  fi
fi

printf '%s' "`$final" | sudo crontab -
inst_rc=`$?
echo "__DST_SECTION:INSTALL_RC"
echo "`$inst_rc"
echo "__DST_SECTION:VERIFY"
sudo crontab -l 2>&1 || true
"@

    $r = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 25
    if ($r.rc -lt 0) {
        return @{ ok=$false; status=502; message='SSH to VM failed (no exit code returned).' }
    }
    if ($r.out -match '__DST_LOCK_HELD') {
        return @{ ok=$false; status=409; message='Another schedule save is in progress. Try again in a moment.' }
    }
    if ($r.rc -ne 0) {
        return @{ ok=$false; status=502; message="Schedule install failed (rc=$($r.rc)): $($r.out.Trim())" }
    }

    # Parse install_rc + verification to confirm the new block landed.
    $installRc = -1
    $verifyText = ''
    $sect = $null
    foreach ($ln in ($r.out -split "`n")) {
        if ($ln -match '^__DST_SECTION:(\w+)') { $sect = $Matches[1]; continue }
        if ($sect -eq 'INSTALL_RC') { if ($ln.Trim()) { $installRc = [int]$ln.Trim() } }
        elseif ($sect -eq 'VERIFY') { $verifyText += $ln + "`n" }
    }
    if ($installRc -ne 0) {
        return @{ ok=$false; status=502; message="crontab install returned rc=$installRc. Output: $($r.out.Trim())" }
    }
    $parsed = ConvertFrom-DuneBackupCrontab -CrontabText $verifyText
    if ($Preset -eq 'Off') {
        if ($parsed.block) {
            return @{ ok=$false; status=502; message='Crontab still contains a DST-BACKUP block after Off save.' }
        }
    } else {
        if (-not $parsed.block) {
            return @{ ok=$false; status=502; message='Crontab does not contain a DST-BACKUP block after save.' }
        }
        if ($parsed.block.preset -ne $Preset -or $parsed.block.retentionDays -ne $RetentionDays) {
            return @{ ok=$false; status=502; message="Verification mismatch: got preset=$($parsed.block.preset), retention=$($parsed.block.retentionDays)." }
        }
    }

    return @{ ok=$true }
}

# -----------------------------------------------------------------------------
# Public: list recent backup files + tail the backup log.
# -----------------------------------------------------------------------------
function Get-DuneBackupHistory {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Recent = 10,
        [int]$LogLines = 50
    )
    if ($Recent -lt 1)   { $Recent = 1 }
    if ($Recent -gt 100) { $Recent = 100 }
    if ($LogLines -lt 1)    { $LogLines = 1 }
    if ($LogLines -gt 500)  { $LogLines = 500 }

    $script = @"
echo '__DST_SECTION:FILES'
sudo find $script:DuneBackupDumpDir -maxdepth 3 -type f -name '*.backup' 2>/dev/null \
  | head -200 \
  | xargs -r -I{} sudo stat -c '%Y|%s|%n' '{}' 2>/dev/null \
  | sort -rn \
  | head -$Recent
echo '__DST_SECTION:LOG'
sudo tail -$LogLines /var/log/dune-backup.log 2>/dev/null || true
echo '__DST_SECTION:DISK'
sudo du -sh $script:DuneBackupDumpDir 2>/dev/null | awk '{print `$1}' || true
"@

    $r = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 30
    if ($r.rc -lt 0) { throw 'SSH to VM failed (no exit code returned).' }

    $sections = @{}
    $current = $null
    foreach ($ln in ($r.out -split "`n")) {
        if ($ln -match '^__DST_SECTION:(\w+)') { $current = $Matches[1]; $sections[$current] = New-Object System.Collections.Generic.List[string]; continue }
        if ($current) { $sections[$current].Add($ln) | Out-Null }
    }

    $files = @()
    if ($sections.ContainsKey('FILES')) {
        foreach ($row in $sections['FILES']) {
            if (-not $row) { continue }
            $parts = $row -split '\|', 3
            if ($parts.Count -ne 3) { continue }
            $epoch = 0
            $size = 0
            try { $epoch = [long]$parts[0] } catch { continue }
            try { $size  = [long]$parts[1] } catch { $size = 0 }
            $path = $parts[2]
            $files += @{
                path       = $path
                sizeBytes  = $size
                mtimeEpoch = $epoch
                mtimeIso   = (([datetimeoffset]::FromUnixTimeSeconds($epoch)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))
            }
        }
    }
    $logTail = if ($sections.ContainsKey('LOG'))  { ($sections['LOG']  -join "`n").TrimEnd("`n") } else { '' }
    $diskUse = if ($sections.ContainsKey('DISK')) { ($sections['DISK'] -join '').Trim() } else { '' }

    return @{
        recent        = $files
        logTail       = $logTail
        dumpDirPath   = $script:DuneBackupDumpDir
        dumpDirSize   = $diskUse
        logPath       = '/var/log/dune-backup.log'
    }
}
