# BackupSchedule.ps1
# Manage a configurable battlegroup-backup cron entry on the Dune VM.
#
# Source of truth is a single block in the VM's root crontab, delimited by:
#   # DST-BACKUP BEGIN
#   # DST-BACKUP-PRESET: <name>
#   # DST-BACKUP-KEEP-LAST: <count>
#   <preset cron line(s)>
#   <keep-last cron line, if count > 0>
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

# Default retention for the auto-prune. The user-configurable value lives in
# the BackupSchedule and is rendered into the cron command at Save time so the
# tick honors whatever was last saved. Used when no override is supplied.
$script:DuneBackupPodPruneKeepLastDefault = 10
$script:DuneBackupPodPruneKeepDaysDefault = 0

# Build the cron-embedded pod-prune snippet for a given keepLast value.
# Auto-prune the `*-dump-YYYYMMDD-HHMMSS-pod` objects Funcom's backup job
# leaves behind on every run. Keeps the most recent N pods; deletes older
# ones. Runs right after every backup invocation so accumulation can't
# outpace the cron cadence (issue #363). One-line BusyBox-safe pipeline so
# the whole backup command stays a single crontab entry:
#   - kubectl jsonpath -> "ns|name|phase" per pod
#   - awk filter to Succeeded dump-* pods
#   - sort by name (timestamp embedded, newest first), keep first N, delete rest
# keepDays is intentionally NOT folded into the cron snippet — keeping the
# crontab one-line + BusyBox-safe rules out the age math here. The cron tick
# uses count-only; the manual Prune button on the Database card honors both
# thresholds via Remove-DuneBackupDumpPods (PowerShell-side filtering).
function New-DuneBackupPodPruneSnippet {
    param([int]$KeepLast = 10)
    if ($KeepLast -lt 0)   { $KeepLast = 0 }
    if ($KeepLast -gt 100) { $KeepLast = 100 }
    $skip = $KeepLast + 1
    return "sudo kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.phase}{`"\n`"}{end}' 2>/dev/null | awk -F'|' '`$3==`"Succeeded`" && `$2 ~ /-dump-[0-9]{8}-[0-9]{6}-pod`$/' | sort -t'|' -k2 -r | tail -n +$skip | while IFS='|' read ns nm phase; do echo `"`$(date) dst: prune dump pod `$ns/`$nm`" >> /var/log/dune-backup.log; sudo kubectl delete pod -n `"`$ns`" `"`$nm`" --ignore-not-found >> /var/log/dune-backup.log 2>&1; done"
}

# Build the full backup cron command for a given keepLast value.
# The scheduled backup is wrapped in a guard that skips it when a DST-driven
# battlegroup restart is in progress: RestartSchedule.ps1 touches
# /tmp/dst-restart-active just before (and during) the restart, and `find -mmin
# -30` here treats a marker touched within the last 30 minutes as "active". The
# guard fails safe - any error in the check falls through to running the backup
# normally - and contains no literal '%' so it is crontab-safe.
#
# After a successful backup we also run the dump-pod pruner — same cadence as
# backups, so the pod count stays bounded automatically (issue #363). The
# pruner is skipped during the restart window too: a kubectl-delete storm
# while k3s is restarting would just compete for the API server.
function New-DuneBackupCmd {
    param([int]$KeepLastPods = 10)
    $snippet = New-DuneBackupPodPruneSnippet -KeepLast $KeepLastPods
    return "if find /tmp/dst-restart-active -mmin -30 2>/dev/null | grep -q .; then echo `"`$(date) dst: backup skipped - BG restart window active`" >> /var/log/dune-backup.log; else /home/dune/.dune/bin/battlegroup backup >> /var/log/dune-backup.log 2>&1; $snippet; fi"
}
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
# Build the rendered crontab block from a preset + keepLast. Returns either
# a string (the block, including trailing newline) or $null for 'Off'.
# -----------------------------------------------------------------------------
function New-DuneBackupBlock {
    param(
        [Parameter(Mandatory)][string]$Preset,
        [int]$KeepLast = 0,
        [Nullable[int]]$KeepLastPods = $null,
        [Nullable[int]]$KeepDaysPods = $null
    )
    if (-not $script:DuneBackupPresets.ContainsKey($Preset)) {
        throw "Unknown preset: $Preset"
    }
    if ($Preset -eq 'Off') { return $null }
    if ($null -eq $KeepLastPods -or $KeepLastPods -lt 0) { $KeepLastPods = $script:DuneBackupPodPruneKeepLastDefault }
    if ($KeepLastPods -gt 100) { $KeepLastPods = 100 }
    if ($null -eq $KeepDaysPods -or $KeepDaysPods -lt 0) { $KeepDaysPods = $script:DuneBackupPodPruneKeepDaysDefault }
    if ($KeepDaysPods -gt 365) { $KeepDaysPods = 365 }

    $cmd = New-DuneBackupCmd -KeepLastPods $KeepLastPods

    $lines = @()
    $lines += $script:DuneBackupBeginMarker
    $lines += "# DST-BACKUP-PRESET: $Preset"
    $lines += "# DST-BACKUP-KEEP-LAST: $KeepLast"
    $lines += "# DST-BACKUP-KEEP-LAST-PODS: $KeepLastPods"
    $lines += "# DST-BACKUP-KEEP-DAYS-PODS: $KeepDaysPods"
    foreach ($cronExpr in $script:DuneBackupPresets[$Preset].crons) {
        $lines += "$cronExpr $cmd"
    }
    if ($KeepLast -gt 0) {
        # Narrow the retention pattern to filenames that match Funcom's own
        # battlegroup-dump naming (<bg>-YYYYMMDD-HHMMSS.backup[.yaml]) so we
        # never delete a manually-named snapshot like 'pre-patch-X.backup'.
        $namePat = '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].backup*'
        $find = "ls -t $script:DuneBackupDumpDir/$namePat 2>/dev/null | tail -n +$($KeepLast + 1) | xargs -r rm"
        $lines += "15 5 * * * $find"
    }
    $lines += $script:DuneBackupEndMarker
    return (($lines -join "`n") + "`n")
}

# -----------------------------------------------------------------------------
# Parse a crontab string into managed-block + leftover lines.
# Returns @{ block = <hashtable or $null>; outsideText = string; hasUnmanagedBackupLines = bool }.
# Block hashtable has: preset, keepLast, raw, looksTampered.
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
        $keepLast = 0
        $keepLastPods = $script:DuneBackupPodPruneKeepLastDefault
        $keepDaysPods = $script:DuneBackupPodPruneKeepDaysDefault
        foreach ($bl in $blockLines) {
            if ($bl -match '^# DST-BACKUP-PRESET:\s*(\S+)') { $preset = $Matches[1] }
            elseif ($bl -match '^# DST-BACKUP-KEEP-LAST-PODS:\s*(\d+)') { $keepLastPods = [int]$Matches[1] }
            elseif ($bl -match '^# DST-BACKUP-KEEP-DAYS-PODS:\s*(\d+)') { $keepDaysPods = [int]$Matches[1] }
            elseif ($bl -match '^# DST-BACKUP-(?:KEEP-LAST|RETENTION):\s*(\d+)') { $keepLast = [int]$Matches[1] }
        }
        if (-not $preset) { $preset = 'Custom' }
        $blockInfo = @{
            preset       = $preset
            keepLast     = $keepLast
            keepLastPods = $keepLastPods
            keepDaysPods = $keepDaysPods
            raw          = ($blockLines -join "`n")
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
    $keepLast = 0
    $keepLastPods = $script:DuneBackupPodPruneKeepLastDefault
    $keepDaysPods = $script:DuneBackupPodPruneKeepDaysDefault
    $looksTampered = $false
    $inferredFromUnmanaged = $false
    if ($parsed.block) {
        $preset       = $parsed.block.preset
        $keepLast     = $parsed.block.keepLast
        $keepLastPods = $parsed.block.keepLastPods
        $keepDaysPods = $parsed.block.keepDaysPods
        $enabled      = ($preset -ne 'Off')
        # If the rendered block doesn't match the stored knobs any more, the
        # operator likely edited it by hand. Surface that to the UI.
        $expected = (New-DuneBackupBlock -Preset $preset -KeepLast $keepLast -KeepLastPods $keepLastPods -KeepDaysPods $keepDaysPods)
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
        keepLast                  = $keepLast
        keepLastPods              = $keepLastPods
        keepDaysPods              = $keepDaysPods
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
        [int]$KeepLast = 0,
        [Nullable[int]]$KeepLastPods = $null,
        [Nullable[int]]$KeepDaysPods = $null
    )
    if (-not $script:DuneBackupPresets.ContainsKey($Preset)) {
        return @{ ok=$false; status=400; message="Unknown preset: $Preset" }
    }
    if ($KeepLast -lt 0 -or $KeepLast -gt 1000) {
        return @{ ok=$false; status=400; message="keepLast must be 0..1000 (got $KeepLast)." }
    }
    if ($null -ne $KeepLastPods -and ($KeepLastPods -lt 0 -or $KeepLastPods -gt 100)) {
        return @{ ok=$false; status=400; message="keepLastPods must be 0..100 (got $KeepLastPods)." }
    }
    if ($null -ne $KeepDaysPods -and ($KeepDaysPods -lt 0 -or $KeepDaysPods -gt 365)) {
        return @{ ok=$false; status=400; message="keepDaysPods must be 0..365 (got $KeepDaysPods)." }
    }

    $newBlock = New-DuneBackupBlock -Preset $Preset -KeepLast $KeepLast -KeepLastPods $KeepLastPods -KeepDaysPods $KeepDaysPods
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
        if ($parsed.block.preset -ne $Preset -or $parsed.block.keepLast -ne $KeepLast) {
            return @{ ok=$false; status=502; message="Verification mismatch: got preset=$($parsed.block.preset), keepLast=$($parsed.block.keepLast)." }
        }
        $expectedKeepLastPods = if ($null -ne $KeepLastPods) { [int]$KeepLastPods } else { $script:DuneBackupPodPruneKeepLastDefault }
        $expectedKeepDaysPods = if ($null -ne $KeepDaysPods) { [int]$KeepDaysPods } else { $script:DuneBackupPodPruneKeepDaysDefault }
        if ($parsed.block.keepLastPods -ne $expectedKeepLastPods -or $parsed.block.keepDaysPods -ne $expectedKeepDaysPods) {
            return @{ ok=$false; status=502; message="Verification mismatch: got keepLastPods=$($parsed.block.keepLastPods), keepDaysPods=$($parsed.block.keepDaysPods)." }
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

# -----------------------------------------------------------------------------
# Public: list `*-dump-YYYYMMDD-HHMMSS-pod` pods left behind by Funcom's database-
# backup jobs. They finish Succeeded but are never garbage-collected, so they
# pile up over time (issue #363). Returned newest-first by the timestamp baked
# into the pod name (kubectl creationTimestamp would work too, but the embedded
# timestamp is naturally sortable as a string and survives clock drift).
# -----------------------------------------------------------------------------
$script:DuneBackupDumpPodNameRegex = '^[a-z0-9.-]+-dump-[0-9]{8}-[0-9]{6}-pod$'

function Get-DuneBackupDumpPods {
    param([Parameter(Mandatory)][string]$Ip)
    # Stream namespace|name|startTime|phase|ownerKind|ownerName|controller via
    # jsonpath. Avoids needing jq on the VM. We filter by phase + name regex
    # here so callers always get a canonical list (Completed/Succeeded dump-*
    # pods only).
    #
    # Owner reference info is included because "pod survives a force-delete"
    # means an owner controller is re-creating it with the same name — we
    # need to surface WHICH owner so the user can decide whether to delete
    # that instead. Only the first ownerReference is captured (Kubernetes
    # allows multiple but a controller-owner is typically singular).
    #
    # NOTE: in Kubernetes the actual `.status.phase` value for a finished pod
    # is "Succeeded" — what kubectl displays as "Completed" in the STATUS
    # column is a container reason, not the pod phase. We keep the
    # ==="Completed" check defensively in case Funcom's CRD ever sets it.
    $jp = '{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.startTime}|{.status.phase}|{.metadata.ownerReferences[0].kind}|{.metadata.ownerReferences[0].name}|{.metadata.ownerReferences[0].controller}{"\n"}{end}'
    $cmd = "sudo kubectl get pods --all-namespaces -o jsonpath='$jp' 2>/dev/null"
    $raw = $null
    try {
        $raw = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 25
    } catch {
        throw "kubectl get pods failed: $($_.Exception.Message)"
    }
    $rows = if ($raw) { (($raw -join "`n") -replace "`r",'') -split "`n" } else { @() }
    $nowUtc = [datetime]::UtcNow
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        if (-not $r) { continue }
        $parts = $r -split '\|', 7
        if ($parts.Count -lt 4) { continue }
        $ns    = $parts[0]
        $name  = $parts[1]
        $start = $parts[2]
        $phase = $parts[3]
        $ownerKind = if ($parts.Count -gt 4) { [string]$parts[4] } else { '' }
        $ownerName = if ($parts.Count -gt 5) { [string]$parts[5] } else { '' }
        $ownerCtrl = if ($parts.Count -gt 6) { [string]$parts[6] } else { '' }
        if ($name -notmatch $script:DuneBackupDumpPodNameRegex) { continue }
        if ($phase -ne 'Succeeded' -and $phase -ne 'Completed') { continue }

        # Parse the timestamp baked into the name (authoritative — survives
        # status.startTime being cleared on terminal pods) and compute age.
        $nameTs = Get-DuneBackupDumpPodTimestamp -Name $name
        $ageMin = if ($nameTs) { [int]($nowUtc - $nameTs).TotalMinutes } else { $null }

        $out.Add([pscustomobject]@{
            namespace          = $ns
            name               = $name
            startTime          = $start
            phase              = $phase
            nameTimestamp      = if ($nameTs) { $nameTs.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
            ageMinutes         = $ageMin
            ownerKind          = $ownerKind
            ownerName          = $ownerName
            ownerIsController  = ($ownerCtrl -eq 'true')
        }) | Out-Null
    }
    # Sort by the embedded YYYYMMDD-HHMMSS in the name (newest first). Falls
    # back to name lexically — which for our regex is equivalent because the
    # suffix is fixed-width.
    return @($out | Sort-Object name -Descending)
}

# -----------------------------------------------------------------------------
# Parse the YYYYMMDD-HHMMSS that's baked into every Funcom dump-pod name. Used
# as the authoritative age signal — the pod name is the only timestamp that
# survives even when k8s status.startTime is missing/cleared (which happens
# on some terminal pods). Returns $null if the regex doesn't match.
# -----------------------------------------------------------------------------
function Get-DuneBackupDumpPodTimestamp {
    param([string]$Name)
    if (-not $Name) { return $null }
    if ($Name -notmatch '-dump-([0-9]{8})-([0-9]{6})-pod$') { return $null }
    $date = $Matches[1]; $time = $Matches[2]
    try {
        return [datetime]::ParseExact("$date$time", 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch {
        return $null
    }
}

# -----------------------------------------------------------------------------
# Public: prune Succeeded/Completed dump-* pods. Two independent thresholds:
#   -KeepLast N   : keep at most the N most-recent pods (0 = no count cap)
#   -KeepDays D   : also delete anything older than D days (0 = no age cap)
# A pod survives only if it passes BOTH filters — exceeding either threshold
# makes it a prune candidate. 0 on a threshold disables that axis (matches
# the keep-forever convention used by the file-retention setting above).
#
# Returns @{ ok; deleted; kept; remaining; output }. Never touches the live
# DB StatefulSet, util/mon/pghero, file-browser pods, or any pod whose name
# doesn't match the canonical dump-* shape — the name regex check is
# authoritative and re-checked before each kubectl delete.
# -----------------------------------------------------------------------------
function Remove-DuneBackupDumpPods {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$KeepLast = 5,
        [int]$KeepDays = 0
    )
    if ($KeepLast -lt 0)   { $KeepLast = 0 }
    if ($KeepLast -gt 100) { $KeepLast = 100 }
    if ($KeepDays -lt 0)   { $KeepDays = 0 }
    if ($KeepDays -gt 365) { $KeepDays = 365 }

    $pods = Get-DuneBackupDumpPods -Ip $Ip
    $total = @($pods).Count

    # Age-filter cutoff. If KeepDays=0 we don't compute a cutoff; nothing is
    # age-eligible for prune.
    $ageCutoff = if ($KeepDays -gt 0) { [datetime]::UtcNow.AddDays(-$KeepDays) } else { $null }

    # Walk the list (already sorted newest-first by name) and mark each pod
    # as kept or to-delete based on both filters.
    $kept     = New-Object System.Collections.Generic.List[object]
    $toDelete = New-Object System.Collections.Generic.List[object]
    $idx = 0
    foreach ($p in $pods) {
        $idx++
        $exceededCount = ($KeepLast -gt 0 -and $idx -gt $KeepLast)
        $exceededAge = $false
        if ($ageCutoff) {
            $ts = Get-DuneBackupDumpPodTimestamp -Name $p.name
            if ($ts -and $ts -lt $ageCutoff) { $exceededAge = $true }
        }
        if ($exceededCount -or $exceededAge) {
            $toDelete.Add($p) | Out-Null
        } else {
            $kept.Add($p) | Out-Null
        }
    }

    if ($toDelete.Count -eq 0) {
        $why = if ($KeepLast -eq 0 -and $KeepDays -eq 0) { 'no limits set' }
               elseif ($KeepLast -gt 0 -and $KeepDays -gt 0) { "keep last $KeepLast, max age $KeepDays day(s)" }
               elseif ($KeepLast -gt 0) { "keep last $KeepLast" }
               else { "max age $KeepDays day(s)" }
        return @{
            ok        = $true
            deleted   = @()
            kept      = @($kept)
            remaining = @($kept)
            message   = "Found $total dump pod(s); nothing to prune ($why)."
            output    = ''
        }
    }

    # Re-validate every namespace/name we're about to interpolate. Defence in
    # depth — the jsonpath output should already be clean, but a stale CRD or
    # webhook could in principle return surprises and we're about to embed
    # these values into a shell command.
    #
    # Each delete prints a status marker so we can tell which actually ran
    # (and which kubectl rejected, which was a no-op due to --ignore-not-found,
    # etc.). Markers are easy to parse without changing the existing rc model.
    $cmds = New-Object System.Collections.Generic.List[string]
    foreach ($p in $toDelete) {
        $ns = [string]$p.namespace
        $nm = [string]$p.name
        if ($ns -notmatch '^[a-z0-9][a-z0-9.-]{0,253}$') { continue }
        if ($nm -notmatch $script:DuneBackupDumpPodNameRegex) { continue }
        $cmds.Add("out=`$(sudo kubectl delete pod -n '${ns}' '${nm}' --ignore-not-found 2>&1); rc=`$?; echo __DST_POD_DEL__:`${rc}:${ns}/${nm}:`${out}") | Out-Null
    }
    if ($cmds.Count -eq 0) {
        return @{
            ok        = $true
            deleted   = @()
            kept      = @($pods)
            remaining = @($pods)
            message   = "Found $total dump pod(s); $($kept.Count) retained, $($toDelete.Count) skipped after name validation."
            output    = ''
        }
    }
    # First pass: graceful delete. Then settle briefly inside the same SSH
    # session so the API server has propagated the deletes to etcd. Then re-
    # read to find any that survived (owner-controller recreated, RBAC denied,
    # stuck-terminating, etc.) and force-delete those.
    $shellScript = ($cmds -join "`n") + "`nsleep 1`n"
    $r = Invoke-DuneBackupShell -Ip $Ip -Script $shellScript -TimeoutSec 90
    if ($r.rc -lt 0) {
        return @{ ok=$false; status=502; message='SSH to VM failed (no exit code).' }
    }
    $firstPassOutput = $r.out

    # Refresh from authoritative source. Retry once if the API hasn't indexed
    # the deletes yet (count didn't drop at all).
    $remaining = Get-DuneBackupDumpPods -Ip $Ip
    if (@($remaining).Count -ge $total) {
        Start-Sleep -Milliseconds 1500
        $remaining = Get-DuneBackupDumpPods -Ip $Ip
    }

    # If pods we tried to delete are STILL in the remaining list, the first
    # pass failed for those (owner-recreated / stuck terminating / RBAC). Try
    # a force delete (--force --grace-period=0) which bypasses graceful drain
    # and finalizers — the only thing that won't bypass is a still-running
    # controller that re-creates the pod with the same name, which is rare.
    $remainingNames = @{}
    foreach ($p in $remaining) { $remainingNames[$p.name] = $true }
    $survivors = New-Object System.Collections.Generic.List[object]
    foreach ($p in $toDelete) {
        if ($remainingNames.ContainsKey($p.name)) { $survivors.Add($p) | Out-Null }
    }
    $forceOutput = ''
    if ($survivors.Count -gt 0) {
        $forceCmds = New-Object System.Collections.Generic.List[string]
        foreach ($p in $survivors) {
            $ns = [string]$p.namespace
            $nm = [string]$p.name
            if ($ns -notmatch '^[a-z0-9][a-z0-9.-]{0,253}$') { continue }
            if ($nm -notmatch $script:DuneBackupDumpPodNameRegex) { continue }
            $forceCmds.Add("out=`$(sudo kubectl delete pod -n '${ns}' '${nm}' --ignore-not-found --force --grace-period=0 2>&1); rc=`$?; echo __DST_POD_FORCE__:`${rc}:${ns}/${nm}:`${out}") | Out-Null
        }
        if ($forceCmds.Count -gt 0) {
            $forceScript = ($forceCmds -join "`n") + "`nsleep 1`n"
            $rf = Invoke-DuneBackupShell -Ip $Ip -Script $forceScript -TimeoutSec 90
            if ($rf.rc -ge 0) {
                $forceOutput = $rf.out
                $remaining = Get-DuneBackupDumpPods -Ip $Ip
            }
        }
    }

    # Compare intent vs reality: which intended deletes actually disappeared.
    $remainingNames = @{}
    foreach ($p in $remaining) { $remainingNames[$p.name] = $true }
    $actuallyDeleted = New-Object System.Collections.Generic.List[object]
    $stillPresent    = New-Object System.Collections.Generic.List[object]
    foreach ($p in $toDelete) {
        if ($remainingNames.ContainsKey($p.name)) { $stillPresent.Add($p) | Out-Null }
        else                                      { $actuallyDeleted.Add($p) | Out-Null }
    }

    $msg = "Deleted $($actuallyDeleted.Count) of $($toDelete.Count) dump pod(s); $($kept.Count) kept."
    if ($stillPresent.Count -gt 0) {
        $names = ($stillPresent | ForEach-Object { $_.name }) -join ', '
        $msg += " $($stillPresent.Count) survived both delete passes (likely owner-recreated or RBAC-denied): $names. Check kubectl describe."
    }
    return @{
        ok              = $true
        deleted         = @($actuallyDeleted)
        attempted       = @($toDelete)
        kept            = @($kept)
        remaining       = @($remaining)
        survivors       = @($stillPresent)
        message         = $msg
        output          = ($firstPassOutput + "`n" + $forceOutput).Trim()
    }
}
