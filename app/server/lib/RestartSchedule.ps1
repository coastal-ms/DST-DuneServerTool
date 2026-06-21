# RestartSchedule.ps1
# DST-driven scheduled battlegroup restarts.
#
# Unlike BackupSchedule.ps1 (which installs a VM-side crontab entry that fires
# even when this tool is closed), the restart scheduler runs *inside* the DST
# server process: a dedicated background runspace wakes every ~30s and, once a
# day at the configured local time, optionally sends an in-game broadcast a
# configurable number of minutes ahead, then issues `battlegroup restart` over
# SSH. Because it lives in this process it ONLY works while DST is open and
# running - the UI states this plainly.
#
# State (schedule + last-run stamps + last Funcom update check) lives in a JSON
# file under %LOCALAPPDATA%\DuneServer so it survives restarts of the tool but
# is host-local. Times are interpreted in the DST host's LOCAL timezone.
#
# Depends on (all loaded by the lib dot-source loop / lazy loaders):
#   Invoke-V6Ssh, Get-DuneVmStatus            (Db-Postgres.ps1 / VM status)
#   Get-DuneBackupContext, Invoke-DuneBackupShell (BackupSchedule.ps1)
#   Send-V6GenericBroadcast                    (Broadcast.ps1)
#   Read-DuneConfig                            (Config.ps1)
#   Write-DuneLog                              (DuneLog.ps1)

$script:DuneRestartSchedulerStarted = $false
$script:DuneRestartSchedulerRunspace = $null
$script:DuneRestartSchedulerPowerShell = $null
$script:DuneFuncomCheckRunspace = $null
$script:DuneFuncomCheckPowerShell = $null

# Steam app id for the Dune: Awakening dedicated server. Discovered at runtime
# from the install's appmanifest file; this is only the fallback.
$script:DuneServerSteamAppIdFallback = '4754530'

# VM-side marker dropped during the restart window so a scheduled VM backup cron
# (see BackupSchedule.ps1, which wraps `battlegroup backup` in a freshness check
# against this file) skips itself rather than running concurrently with a
# battlegroup restart. The backup guard uses `find -mmin -30`, so the marker
# only needs its mtime refreshed shortly before / during the restart.
$script:DuneRestartMarkerPath = '/tmp/dst-restart-active'

function Get-DuneRestartStatePath {
    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'restart-schedule.json')
}

function Get-DuneRestartScheduleDefault {
    return [ordered]@{
        enabled              = $false
        time                 = '04:00'
        broadcastLeadMinutes = 10
        lastBroadcastDate    = ''
        lastRestartDate      = ''
        lastMarkerDate       = ''
        updateAvailable      = $false
        installedBuild       = ''
        latestBuild          = ''
        updateCheckedAt      = ''
        lastResult           = ''
    }
}

# Read the schedule state, merging persisted values over the defaults so a
# partial/older file still yields every expected key.
function Get-DuneRestartSchedule {
    $state = Get-DuneRestartScheduleDefault
    $path = Get-DuneRestartStatePath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($k in @($state.Keys)) {
                    if ($obj.PSObject.Properties[$k]) { $state[$k] = $obj.$k }
                }
            }
        } catch {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "restart schedule read failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    # Normalize types.
    $state.enabled              = [bool]$state.enabled
    $state.updateAvailable      = [bool]$state.updateAvailable
    try { $state.broadcastLeadMinutes = [int]$state.broadcastLeadMinutes } catch { $state.broadcastLeadMinutes = 10 }
    return $state
}

function Save-DuneRestartSchedule {
    param([Parameter(Mandatory)] $State)
    $path = Get-DuneRestartStatePath
    $json = ([pscustomobject]$State) | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -Force
}

# Validate + persist user-facing fields (enable/time/lead). Leaves the run
# stamps and update-check fields untouched. Returns the full updated state.
function Set-DuneRestartSchedule {
    param(
        [bool]$Enabled,
        [string]$Time,
        [int]$BroadcastLeadMinutes
    )
    if ($Time -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') {
        return @{ ok = $false; status = 400; message = "Invalid time '$Time'. Use 24-hour HH:mm (e.g. 04:00)." }
    }
    if ($BroadcastLeadMinutes -lt 0)  { $BroadcastLeadMinutes = 0 }
    if ($BroadcastLeadMinutes -gt 60) { $BroadcastLeadMinutes = 60 }

    $state = Get-DuneRestartSchedule
    $state.enabled              = $Enabled
    $state.time                 = $Time
    $state.broadcastLeadMinutes = $BroadcastLeadMinutes
    Save-DuneRestartSchedule -State $state
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "restart schedule saved: enabled=$Enabled time=$Time lead=$BroadcastLeadMinutes"
    }
    return @{ ok = $true; schedule = $state }
}

# Spell out a small whole number (0..60). Used so the broadcast body reads
# "in ten minutes" rather than "in 10 minutes".
function ConvertTo-DuneNumberWords {
    param([int]$N)
    if ($N -lt 0)  { return [string]$N }
    if ($N -gt 60) { return [string]$N }
    $ones = @('zero','one','two','three','four','five','six','seven','eight','nine','ten',
              'eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen',
              'eighteen','nineteen')
    $tens = @{ 20='twenty'; 30='thirty'; 40='forty'; 50='fifty'; 60='sixty' }
    if ($N -lt 20) { return $ones[$N] }
    $t = [math]::Floor($N / 10) * 10
    $r = $N % 10
    if ($r -eq 0) { return $tens[$t] }
    return ($tens[$t] + '-' + $ones[$r])
}

# Non-destructive Funcom server-update check: compare the installed build id
# (from the local appmanifest) against the latest public build id reported by
# steamcmd's app_info_print. Read-only; takes ~20-30s because steamcmd self-
# updates. Pass -Persist to fold the result into the schedule state file.
function Get-DuneFuncomServerUpdateStatus {
    param([switch]$Persist)

    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        return @{ ok = $false; status = $ctx.status; message = $ctx.message; available = $false }
    }
    $appIdFallback = $script:DuneServerSteamAppIdFallback

    # The installed build id is read instantly from the local appmanifest. For
    # the LATEST public build we hit the lightweight SteamCMD info API
    # (api.steamcmd.net) which returns JSON in ~1s - far quicker than spinning
    # up the local steamcmd (+app_info_update can take 20-30s). steamcmd is kept
    # only as a fallback if the API is unreachable.
    $script = @'
set -eu
DLDIR=/home/dune/.dune/download/steamapps
MANIFEST=$(ls "$DLDIR"/appmanifest_*.acf 2>/dev/null | head -1 || true)
APPID="__APPID__"
INSTALLED=""
if [ -n "$MANIFEST" ]; then
  base=$(basename "$MANIFEST")
  aid=$(echo "$base" | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$aid" ]; then APPID="$aid"; fi
  INSTALLED=$(grep -E '"buildid"' "$MANIFEST" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || true)
fi
LATEST=""
SRC=""
# Fast path: public SteamCMD info API (no local steamcmd spin-up).
JSON=$(curl -fsSL --max-time 8 "https://api.steamcmd.net/v1/info/$APPID" 2>/dev/null || true)
if [ -n "$JSON" ]; then
  LATEST=$(printf '%s' "$JSON" | tr -d ' \n' \
    | sed -n 's/.*"branches":{"public":{\([^}]*\)}.*/\1/p' \
    | grep -oE '"buildid":"[0-9]+"' | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$LATEST" ]; then SRC="api"; fi
fi
# Fallback: local steamcmd (slower, but works if the API is unreachable).
if [ -z "$LATEST" ]; then
  STEAMCMD=$(command -v steamcmd 2>/dev/null || true)
  if [ -z "$STEAMCMD" ]; then STEAMCMD=/home/dune/.local/share/Steam/steamcmd/steamcmd.sh; fi
  if [ -x "$STEAMCMD" ] || command -v "$STEAMCMD" >/dev/null 2>&1; then
    LATEST=$("$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$APPID" +quit 2>/dev/null \
      | awk '/"branches"/{inb=1} inb && /"public"/{inp=1} inp && /"buildid"/{gsub(/[^0-9]/,"");print;exit}' || true)
    if [ -n "$LATEST" ]; then SRC="steamcmd"; fi
  fi
fi
echo "APPID=$APPID"
echo "INSTALLED=$INSTALLED"
echo "LATEST=$LATEST"
echo "SRC=$SRC"
'@
    $script = $script -replace '__APPID__', $appIdFallback

    $checkedAt = (Get-Date).ToString('o')
    try {
        $r = Invoke-DuneBackupShell -Ip $ctx.ip -Script $script -TimeoutSec 60
    } catch {
        return @{ ok = $false; status = 502; message = "Update check failed: $($_.Exception.Message)"; available = $false; checkedAt = $checkedAt }
    }
    $out = if ($r) { [string]$r.out } else { '' }
    $installed = ''
    $latest = ''
    $source = ''
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^INSTALLED=(.*)$') { $installed = $Matches[1].Trim() }
        elseif ($line -match '^LATEST=(.*)$') { $latest = $Matches[1].Trim() }
        elseif ($line -match '^SRC=(.*)$') { $source = $Matches[1].Trim() }
    }

    $available = $false
    $ok = $true
    $message = ''
    if (($installed -match '^\d+$') -and ($latest -match '^\d+$')) {
        $available = ([int64]$latest -gt [int64]$installed)
        $message = if ($available) { "Funcom server update available (installed $installed, latest $latest)." }
                   else            { "Server is up to date (build $installed)." }
    } else {
        $ok = $false
        $message = 'Could not determine build ids from the VM (update API/steamcmd or manifest unavailable).'
    }

    $result = @{
        ok             = $ok
        available      = $available
        installedBuild = $installed
        latestBuild    = $latest
        checkedAt      = $checkedAt
        source         = $source
        message        = $message
    }

    if ($Persist) {
        try {
            $state = Get-DuneRestartSchedule
            $state.updateAvailable = $available
            $state.installedBuild  = $installed
            $state.latestBuild     = $latest
            $state.updateCheckedAt = $checkedAt
            Save-DuneRestartSchedule -State $state
        } catch {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "restart schedule update-check persist failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    return $result
}

# Touch the VM-side backup-guard marker so an overlapping scheduled backup skips
# itself. Best-effort; returns $true on success.
function Set-DuneRestartGuardMarker {
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) { return $false }
    try {
        [void](Invoke-DuneBackupShell -Ip $ctx.ip -Script "touch $script:DuneRestartMarkerPath" -TimeoutSec 20)
        return $true
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "restart guard marker touch failed: $($_.Exception.Message)" 'WARN'
        }
        return $false
    }
}

# Issue the actual battlegroup restart over SSH (no console window). Touches the
# backup-guard marker in the same call so a backup cron firing at the same
# moment skips itself. Returns @{ ok; message; rc }.
function Invoke-DuneScheduledRestart {
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        return @{ ok = $false; status = $ctx.status; message = $ctx.message }
    }
    try {
        $r = Invoke-DuneBackupShell -Ip $ctx.ip -Script "touch $script:DuneRestartMarkerPath 2>/dev/null; /home/dune/.dune/bin/battlegroup restart" -TimeoutSec 180
    } catch {
        return @{ ok = $false; status = 502; message = "Restart command failed: $($_.Exception.Message)" }
    }
    $rc = if ($r) { [int]$r.rc } else { -1 }
    $ok = ($rc -eq 0)
    return @{
        ok      = $ok
        rc      = $rc
        message = if ($ok) { 'Scheduled restart issued.' } else { "Restart command exited $rc." }
        out     = if ($r) { [string]$r.out } else { '' }
    }
}

# One scheduler iteration. Safe to call every ~30s. Sends the pre-restart
# broadcast and fires the restart at most once per local day, each within a
# bounded window so a late DST launch doesn't trigger a stale restart hours
# after the scheduled time.
function Invoke-DuneRestartScheduleTick {
    $state = Get-DuneRestartSchedule
    if (-not $state.enabled) { return }

    if ($state.time -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') { return }
    $hh = [int]($state.time.Substring(0,2))
    $mm = [int]($state.time.Substring(3,2))

    $now   = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $restartAt  = Get-Date -Hour $hh -Minute $mm -Second 0
    $lead = [int]$state.broadcastLeadMinutes
    $broadcastAt = $restartAt.AddMinutes(-$lead)
    $restartWindowEnd = $restartAt.AddMinutes(30)

    # --- Backup-overlap guard marker (once/day) ---
    # Drop the VM-side marker a couple of minutes ahead of the restart (and keep
    # it valid through the restart window) so a scheduled backup cron that would
    # otherwise fire at the same time skips itself instead of running
    # concurrently with the restart. Setting it slightly early beats the
    # same-minute race where the backup cron fires before the restart tick does.
    if ($state.lastMarkerDate -ne $today) {
        $guardStart = $restartAt.AddMinutes(-2)
        if ($now -ge $guardStart -and $now -le $restartWindowEnd) {
            if (Set-DuneRestartGuardMarker) {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    Write-DuneLog 'restart guard marker set (overlapping backups will skip)'
                }
                $state = Get-DuneRestartSchedule
                $state.lastMarkerDate = $today
                Save-DuneRestartSchedule -State $state
            }
        }
    }

    # --- Pre-restart broadcast (once/day) ---
    $state = Get-DuneRestartSchedule
    if ($lead -gt 0 -and $state.lastBroadcastDate -ne $today) {
        if ($now -ge $broadcastAt -and $now -lt $restartAt) {
            $word = ConvertTo-DuneNumberWords $lead
            $unit = if ($lead -eq 1) { 'minute' } else { 'minutes' }
            $body = "The game server will be restarting in $word $unit for our scheduled daily BG maintenance."
            try {
                $b = Send-V6GenericBroadcast -Title 'Game Server Restart' -Body $body -DurationSec 10
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    $bm = if ($b -and $b.ok) { 'sent' } else { "failed: $($b.message)" }
                    Write-DuneLog "scheduled restart broadcast $bm"
                }
            } catch {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    Write-DuneLog "scheduled restart broadcast error: $($_.Exception.Message)" 'WARN'
                }
            }
            $state = Get-DuneRestartSchedule
            $state.lastBroadcastDate = $today
            Save-DuneRestartSchedule -State $state
        } elseif ($now -ge $restartAt) {
            # Missed the lead window (DST launched late). Mark done so we don't
            # fire a stale notice; the restart window below still applies.
            $state.lastBroadcastDate = $today
            Save-DuneRestartSchedule -State $state
        }
    }

    # --- Restart (once/day, only within [restartAt, +30m]) ---
    $state = Get-DuneRestartSchedule
    if ($state.lastRestartDate -ne $today) {
        if ($now -ge $restartAt -and $now -le $restartWindowEnd) {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "scheduled restart firing (time=$($state.time))"
            }
            # Kick off the Funcom server-update check up-front, on its own
            # runspace, so it runs *concurrently* with the restart instead of
            # adding latency after it. It persists the dashboard badge flag when
            # it finishes. Falls back to an inline check if the async runspace
            # can't be started (e.g. server dir unknown).
            $serverDir = Get-Variable -Name DuneSchedulerServerDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            $asyncCheck = $false
            if ($serverDir) {
                try { $asyncCheck = Start-DuneFuncomUpdateCheckAsync -ServerDir $serverDir } catch { $asyncCheck = $false }
            }

            $r = Invoke-DuneScheduledRestart
            $state = Get-DuneRestartSchedule
            $state.lastRestartDate = $today
            $state.lastResult = if ($r.ok) { "ok @ $today $($state.time)" } else { "error: $($r.message)" }
            Save-DuneRestartSchedule -State $state
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "scheduled restart result: $($state.lastResult)"
            }
            if (-not $asyncCheck) {
                try { [void](Get-DuneFuncomServerUpdateStatus -Persist) } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        Write-DuneLog "post-restart update check error: $($_.Exception.Message)" 'WARN'
                    }
                }
            }
        } elseif ($now -gt $restartWindowEnd) {
            # Missed the restart window entirely; skip today so we don't restart
            # at an unexpected hour.
            $state.lastRestartDate = $today
            Save-DuneRestartSchedule -State $state
        }
    }
}

# Build an InitialSessionState that loads the same server libs as the API pool
# so every helper the scheduler tick (or the async update checker) needs is in
# scope. Shared by Start-DuneRestartScheduler and Start-DuneFuncomUpdateCheckAsync.
function New-DuneSchedulerInitialSessionState {
    param([Parameter(Mandatory)][string]$ServerDir)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $duneLog = Join-Path $ServerDir 'lib\DuneLog.ps1'
    if (Test-Path -LiteralPath $duneLog) { [void]$iss.StartupScripts.Add($duneLog) }
    $bootstrap = Join-Path $ServerDir 'lib\Bootstrap.ps1'
    if (Test-Path -LiteralPath $bootstrap) { [void]$iss.StartupScripts.Add($bootstrap) }
    $libDir = Join-Path $ServerDir 'lib'
    if (Test-Path -LiteralPath $libDir) {
        foreach ($f in (Get-ChildItem -Path $libDir -Filter '*.ps1' | Sort-Object Name)) {
            if ($f.Name -ieq 'DuneLog.ps1')   { continue }
            if ($f.Name -ieq 'Bootstrap.ps1') { continue }
            [void]$iss.StartupScripts.Add($f.FullName)
        }
    }

    # Propagate the active log file into the runspace so Write-DuneLog actually
    # writes there. The runspace dot-sources DuneLog.ps1 but never runs
    # Initialize-DuneLog, so without this its $script:DuneLogPath stays $null and
    # every scheduler/broadcast/restart line is silently dropped. The runspace
    # scripts call Set-DuneLogPath (header-less, no roll) with this value.
    $logPath = $script:DuneLogPath
    if (-not $logPath) { $logPath = Join-Path $env:LOCALAPPDATA 'DuneServer\dune-server.log' }
    if ($logPath) {
        [void]$iss.Variables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                'DuneSchedulerLogPath', $logPath, 'Active Dune log file for runspace logging'))
    }

    return $iss
}

# Fire the Funcom server-update check on a short-lived background runspace and
# return immediately, so a (slow) check never holds up the restart. The checker
# persists the dashboard badge flag itself. At most one prior checker runspace
# is kept around and is disposed on the next call. Returns $true if started.
function Start-DuneFuncomUpdateCheckAsync {
    param([string]$ServerDir)
    if ([string]::IsNullOrWhiteSpace($ServerDir) -or -not (Test-Path -LiteralPath $ServerDir)) {
        return $false
    }
    # Dispose any previous one-shot checker before starting a new one.
    try { if ($script:DuneFuncomCheckPowerShell) { $script:DuneFuncomCheckPowerShell.Dispose() } } catch {}
    try { if ($script:DuneFuncomCheckRunspace)   { $script:DuneFuncomCheckRunspace.Dispose() } } catch {}
    $script:DuneFuncomCheckPowerShell = $null
    $script:DuneFuncomCheckRunspace   = $null
    try {
        $iss = New-DuneSchedulerInitialSessionState -ServerDir $ServerDir
        $rs = [runspacefactory]::CreateRunspace($iss)
        $rs.Name = 'DuneFuncomUpdateCheck'
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            if ($DuneSchedulerLogPath -and (Get-Command Set-DuneLogPath -ErrorAction SilentlyContinue)) {
                try { Set-DuneLogPath -Path $DuneSchedulerLogPath } catch {}
            }
            try { [void](Get-DuneFuncomServerUpdateStatus -Persist) } catch {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    try { Write-DuneLog "async update check error: $($_.Exception.Message)" 'WARN' } catch {}
                }
            }
        })
        [void]$ps.BeginInvoke()
        $script:DuneFuncomCheckRunspace   = $rs
        $script:DuneFuncomCheckPowerShell = $ps
        return $true
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "async update check failed to start: $($_.Exception.Message)" 'WARN'
        }
        return $false
    }
}

# Launch the background scheduler runspace. Idempotent.
function Start-DuneRestartScheduler {
    param([Parameter(Mandatory)][string]$ServerDir)
    if ($script:DuneRestartSchedulerStarted) { return }
    try {
        $iss = New-DuneSchedulerInitialSessionState -ServerDir $ServerDir

        $rs = [runspacefactory]::CreateRunspace($iss)
        $rs.Name = 'DuneRestartScheduler'
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        # Make the server dir available inside the scheduler runspace so the tick
        # can spin up the parallel update-check runspace.
        try { $rs.SessionStateProxy.SetVariable('DuneSchedulerServerDir', $ServerDir) } catch {}

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            if ($DuneSchedulerLogPath -and (Get-Command Set-DuneLogPath -ErrorAction SilentlyContinue)) {
                try { Set-DuneLogPath -Path $DuneSchedulerLogPath } catch {}
            }
            while ($true) {
                try { Invoke-DuneRestartScheduleTick } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "restart scheduler tick error: $($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                Start-Sleep -Seconds 30
            }
        })
        [void]$ps.BeginInvoke()

        $script:DuneRestartSchedulerRunspace = $rs
        $script:DuneRestartSchedulerPowerShell = $ps
        $script:DuneRestartSchedulerStarted = $true
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog 'restart scheduler started (30s tick)'
        }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "restart scheduler failed to start: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Stop-DuneRestartScheduler {
    try { if ($script:DuneFuncomCheckPowerShell) { $script:DuneFuncomCheckPowerShell.Dispose() } } catch {}
    try { if ($script:DuneFuncomCheckRunspace) { $script:DuneFuncomCheckRunspace.Dispose() } } catch {}
    try { if ($script:DuneRestartSchedulerPowerShell) { $script:DuneRestartSchedulerPowerShell.Stop(); $script:DuneRestartSchedulerPowerShell.Dispose() } } catch {}
    try { if ($script:DuneRestartSchedulerRunspace) { $script:DuneRestartSchedulerRunspace.Close(); $script:DuneRestartSchedulerRunspace.Dispose() } } catch {}
    $script:DuneFuncomCheckPowerShell = $null
    $script:DuneFuncomCheckRunspace = $null
    $script:DuneRestartSchedulerPowerShell = $null
    $script:DuneRestartSchedulerRunspace = $null
    $script:DuneRestartSchedulerStarted = $false
}
