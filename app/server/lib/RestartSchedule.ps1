# RestartSchedule.ps1
# DST-managed VM-side scheduled battlegroup maintenance.
#
# The actual restart/update runs from root's VM crontab and therefore works when
# DST is closed. DST's background runspace still provides advance broadcasts,
# Discord notifications, status checks, and startup reconciliation of the VM
# script/crontab.
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
$script:DuneDiscordLastBgState = $null
$script:DuneDiscordLastUpdateAvailable = $null
# Server-state notification trackers (Online when Hagga/Survival_1 is Ready;
# Offline only after the server has been down for a debounce window so a normal
# restart doesn't post a false "offline"). Reset per up/down cycle.
$script:DuneDiscordLastHaggaReady = $null   # $true/$false once observed; $null before first tick
$script:DuneDiscordOfflineSince = $null     # UTC time the server went not-ready (after being ready)
$script:DuneDiscordOfflineSent = $false     # offline notice already sent for this down-period
$script:DuneDiscordRestartingSent = $false  # restarting notice already sent for this down-period
$script:DuneDiscordOfflineDebounceSecs = 75 # how long not-ready before "offline" fires (~1 min+)

# Steam app id for the Dune: Awakening dedicated server. Discovered at runtime
# from the install's appmanifest file; this is only the fallback.
$script:DuneServerSteamAppIdFallback = '4754530'

# VM-side marker dropped during the restart window so a scheduled VM backup cron
# (see BackupSchedule.ps1, which wraps `battlegroup backup` in a freshness check
# against this file) skips itself rather than running concurrently with a
# battlegroup restart. The backup guard uses `find -mmin -30`, so the marker
# only needs its mtime refreshed shortly before / during the restart.
$script:DuneRestartMarkerPath = '/tmp/dst-restart-active'
$script:DuneRestartCronBeginMarker = '# DST-DAILY-MAINTENANCE BEGIN'
$script:DuneRestartCronEndMarker = '# DST-DAILY-MAINTENANCE END'
$script:DuneRestartVmScriptPath = '/usr/local/bin/dst-daily-maintenance.sh'
$script:DuneRestartVmLogPath = '/var/log/dst-daily-maintenance.log'
$script:DuneRestartVmResultPath = '/var/lib/dune-server/daily-maintenance-result'
$script:DuneRestartVmResultLastPoll = [datetime]::MinValue
$script:DuneRestartVmResultPollSeconds = 300

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
        applyFuncomUpdates    = $false
        discordEnabled       = $false
        discordNotifyOnline  = $false
        discordNotifyOffline = $false
        discordNotifyRestarting = $false
        discordNotifyUpdate  = $false
        discordWebhookUrl    = ''
        discordMentionId     = ''
        lastBroadcastDate    = ''
        lastDiscordNoticeDate = ''
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
    $state.applyFuncomUpdates    = [bool]$state.applyFuncomUpdates
    $state.updateAvailable      = [bool]$state.updateAvailable
    $state.discordEnabled       = [bool]$state.discordEnabled
    $state.discordNotifyOnline  = [bool]$state.discordNotifyOnline
    $state.discordNotifyOffline = [bool]$state.discordNotifyOffline
    $state.discordNotifyRestarting = [bool]$state.discordNotifyRestarting
    $state.discordNotifyUpdate  = [bool]$state.discordNotifyUpdate
    $state.discordWebhookUrl    = [string]$state.discordWebhookUrl
    $state.discordMentionId     = [string]$state.discordMentionId
    try { $state.broadcastLeadMinutes = [int]$state.broadcastLeadMinutes } catch { $state.broadcastLeadMinutes = 10 }
    return $state
}

function Save-DuneRestartSchedule {
    param([Parameter(Mandatory)] $State)
    $path = Get-DuneRestartStatePath
    $json = ([pscustomobject]$State) | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -Force
}

# Returns $true when the string looks like a Discord incoming-webhook URL.
# Used both at save time (reject anything else so a bot token or arbitrary host
# can't be stored / SSRF'd) and before sending. Empty is treated as "not set".
function Test-DuneDiscordWebhookUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ($Url -match '^https://(?:(?:canary|ptb)\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+$')
}

# Normalize a user-entered "mention on alert" value. Accepts an empty string
# (no ping), the keywords 'everyone'/'here', a raw role id (17-20 digit
# snowflake), or a pasted role mention like <@&123...>. Returns the cleaned
# value to store, or $null when the input is not a valid mention target.
function Resolve-DuneDiscordMentionInput {
    param([string]$Mention)
    if ([string]::IsNullOrWhiteSpace($Mention)) { return '' }
    $m = $Mention.Trim()
    if ($m -match '^@?(everyone|here)$') { return $Matches[1].ToLowerInvariant() }
    if ($m -match '^<@&(\d{17,20})>$')   { return $Matches[1] }
    if ($m -match '^\d{17,20}$')         { return $m }
    return $null
}

# Turn a stored mention value into the Discord payload bits (content prefix +
# allowed_mentions) so a ping actually fires. Empty -> no ping at all.
function Get-DuneDiscordMentionPayload {
    param([string]$Mention)
    $m = if ($null -eq $Mention) { '' } else { $Mention.Trim() }
    if ($m -eq 'everyone') { return @{ content = '@everyone'; allowed = @{ parse = @('everyone') } } }
    if ($m -eq 'here')     { return @{ content = '@here';     allowed = @{ parse = @('everyone') } } }
    if ($m -match '^\d{17,20}$') { return @{ content = "<@&$m>"; allowed = @{ parse = @(); roles = @($m) } } }
    return @{ content = ''; allowed = @{ parse = @() } }
}

# Validate + persist user-facing fields (enable/time/lead + Discord notify).
# Leaves the run stamps and update-check fields untouched. Returns the full
# updated state. A $null DiscordWebhookUrl means "leave the stored URL as-is"
# so the secret never has to round-trip back through the browser.
function Set-DuneRestartSchedule {
    param(
        [bool]$Enabled,
        [string]$Time,
        [int]$BroadcastLeadMinutes,
        [bool]$ApplyFuncomUpdates,
        [bool]$DiscordEnabled,
        [bool]$DiscordNotifyOnline,
        [bool]$DiscordNotifyOffline,
        [bool]$DiscordNotifyRestarting,
        [bool]$DiscordNotifyUpdate,
        # [object] (not [string]) so a genuine $null survives parameter binding
        # and means "leave the stored value unchanged". A [string] param coerces
        # $null to '', which would wrongly read as "clear it".
        [object]$DiscordWebhookUrl,
        [object]$DiscordMentionId
    )
    if ($Time -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') {
        return @{ ok = $false; status = 400; message = "Invalid time '$Time'. Use 24-hour HH:mm (e.g. 04:00)." }
    }
    if ($BroadcastLeadMinutes -lt 0)  { $BroadcastLeadMinutes = 0 }
    if ($BroadcastLeadMinutes -gt 60) { $BroadcastLeadMinutes = 60 }

    $state = Get-DuneRestartSchedule

    # Resolve the effective webhook URL: a non-$null value replaces it (empty
    # string clears it); $null keeps the previously-stored URL.
    $effectiveUrl = if ($null -ne $DiscordWebhookUrl) { ([string]$DiscordWebhookUrl).Trim() } else { [string]$state.discordWebhookUrl }
    if ($effectiveUrl -and -not (Test-DuneDiscordWebhookUrl $effectiveUrl)) {
        return @{ ok = $false; status = 400; message = 'Invalid Discord webhook URL. Expected https://discord.com/api/webhooks/<id>/<token>.' }
    }
    if (($DiscordEnabled -or $DiscordNotifyOnline -or $DiscordNotifyOffline -or $DiscordNotifyRestarting -or $DiscordNotifyUpdate) -and -not $effectiveUrl) {
        return @{ ok = $false; status = 400; message = 'Enable Discord notifications requires a webhook URL.' }
    }

    # $null mention means "leave as-is"; anything else is validated then stored.
    $effectiveMention = if ($null -ne $DiscordMentionId) {
        $resolved = Resolve-DuneDiscordMentionInput ([string]$DiscordMentionId)
        if ($null -eq $resolved) {
            return @{ ok = $false; status = 400; message = 'Invalid mention. Use a role ID (Discord > right-click role > Copy Role ID), or the keyword everyone or here.' }
        }
        $resolved
    } else { [string]$state.discordMentionId }

    $state.enabled              = $Enabled
    $state.time                 = $Time
    $state.broadcastLeadMinutes = $BroadcastLeadMinutes
    $state.applyFuncomUpdates    = $ApplyFuncomUpdates
    $state.discordEnabled       = $DiscordEnabled
    $state.discordNotifyOnline  = $DiscordNotifyOnline
    $state.discordNotifyOffline = $DiscordNotifyOffline
    $state.discordNotifyRestarting = $DiscordNotifyRestarting
    $state.discordNotifyUpdate  = $DiscordNotifyUpdate
    $state.discordWebhookUrl    = $effectiveUrl
    $state.discordMentionId     = $effectiveMention
    Save-DuneRestartSchedule -State $state
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "restart schedule saved: enabled=$Enabled time=$Time lead=$BroadcastLeadMinutes applyFuncomUpdates=$ApplyFuncomUpdates discord=$DiscordEnabled discordUrlSet=$([bool]$effectiveUrl) discordMention=$([bool]$effectiveMention)"
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

# Mask a Discord webhook URL for log output: keep the host + id, drop the token.
function Get-DuneRedactedWebhookUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '<none>' }
    return ([regex]::Replace($Url, '(/api/webhooks/\d+/)[A-Za-z0-9_-]+', '${1}<redacted>'))
}

# Post the "restart imminent" embed to a Discord incoming webhook. Pure outbound
# HTTPS from the DST host - no inbound/NAT requirement. Best-effort and fully
# self-contained: it NEVER throws (the caller runs inside the scheduler tick),
# retries briefly on 429/5xx, and only ever logs a redacted URL. Returns
# @{ ok; status; message }.
function Send-DuneDiscordWebhook {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$ServerName,
        [int]$MinutesToRestart,
        [datetime]$RestartAt,
        [string]$Reason,
        [string]$MentionId
    )
    if (-not (Test-DuneDiscordWebhookUrl $Url)) {
        return @{ ok = $false; status = 400; message = 'Invalid Discord webhook URL.' }
    }

    $name = if ([string]::IsNullOrWhiteSpace($ServerName)) { 'Dune server' } else { $ServerName }
    $minText = if ($MinutesToRestart -eq 1) { '1 minute' } else { "$MinutesToRestart minutes" }
    $whenLocal = $RestartAt.ToString('HH:mm')
    # Discord renders <t:unix:t> in each viewer's own timezone.
    $unix = [int][double]::Parse((Get-Date $RestartAt -UFormat %s))
    $reasonText = if ([string]::IsNullOrWhiteSpace($Reason)) { 'Scheduled daily BG maintenance' } else { $Reason }
    $warn = [System.Char]::ConvertFromUtf32(0x26A0)  # warning sign - kept as a codepoint so this .ps1 stays ASCII

    $embed = [ordered]@{
        title       = "$warn $name restarting in $minText"
        description = "Scheduled battlegroup maintenance restart. The server will go down shortly and should be back up soon after."
        color       = 16763904
        fields      = @(
            [ordered]@{ name = 'Server';         value = $name;                       inline = $true }
            [ordered]@{ name = 'Restarts in';    value = $minText;                    inline = $true }
            [ordered]@{ name = 'Scheduled time'; value = "$whenLocal local (<t:$unix:t>)"; inline = $true }
            [ordered]@{ name = 'Reason';          value = $reasonText;                 inline = $false }
        )
        footer      = [ordered]@{ text = 'Posted by Dune Server Tool' }
    }
    $payload = [ordered]@{
        username = 'DST Server'
        embeds   = @($embed)
    }
    # Optional role/@everyone/@here ping. Empty mention => no ping (parse: []).
    $mp = Get-DuneDiscordMentionPayload $MentionId
    if ($mp.content) { $payload.content = $mp.content }
    $payload.allowed_mentions = $mp.allowed
    $json = $payload | ConvertTo-Json -Depth 6

    $attempts = 0
    $maxAttempts = 3
    while ($true) {
        $attempts++
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $code = [int]$resp.StatusCode
            return @{ ok = $true; status = $code; message = "Discord notice sent (HTTP $code)." }
        } catch {
            $code = 0
            $retryAfter = 0
            $exResp = $_.Exception.Response
            if ($exResp) {
                try { $code = [int]$exResp.StatusCode } catch {}
                try {
                    $ra = $exResp.Headers['Retry-After']
                    if ($ra) { [double]$raD = 0; if ([double]::TryParse($ra, [ref]$raD)) { $retryAfter = $raD } }
                } catch {}
            }
            $transient = ($code -eq 429 -or ($code -ge 500 -and $code -le 599) -or $code -eq 0)
            if ($transient -and $attempts -lt $maxAttempts) {
                $delay = if ($retryAfter -gt 0) { [math]::Min($retryAfter, 10) } else { [math]::Min(2 * $attempts, 6) }
                Start-Sleep -Seconds $delay
                continue
            }
            return @{ ok = $false; status = $code; message = "Discord notice failed (HTTP $code): $($_.Exception.Message)" }
        }
    }
}

# Build the Discord embed for a single server-state notice. Shared by the live
# state monitor and the "send test message" route so a test looks EXACTLY like
# the real notification for that event. State is one of online/offline/
# restarting/update. -Test only swaps the footer so a test post is labelled as
# such. Titles use codepoints (ConvertFromUtf32) so this .ps1 stays ASCII.
function New-DuneDiscordStateEmbed {
    param(
        [Parameter(Mandatory)][ValidateSet('online','offline','restarting','update')][string]$State,
        [string]$ServerName,
        [string]$InstalledBuild,
        [string]$LatestBuild,
        [switch]$Test
    )
    $name  = if ([string]::IsNullOrWhiteSpace($ServerName)) { 'Dune server' } else { $ServerName }
    $check = [System.Char]::ConvertFromUtf32(0x2705)
    $stop  = [System.Char]::ConvertFromUtf32(0x1F6D1)
    $warn  = [System.Char]::ConvertFromUtf32(0x26A0)
    $pkg   = [System.Char]::ConvertFromUtf32(0x1F4E6)
    switch ($State) {
        'online' {
            $embed = [ordered]@{ title = "$check $name is online"; description = 'The game server is up and reachable.'; color = 5763719 }
        }
        'offline' {
            $embed = [ordered]@{ title = "$stop $name is offline"; description = 'The game server has gone down.'; color = 15548997 }
        }
        'restarting' {
            $embed = [ordered]@{ title = "$warn $name is restarting"; description = 'The game server is restarting and should be back shortly.'; color = 16763904 }
        }
        'update' {
            $inst = if ($InstalledBuild) { $InstalledBuild } else { 'Unknown' }
            $late = if ($LatestBuild) { $LatestBuild } else { 'Unknown' }
            $embed = [ordered]@{
                title       = "$pkg Update available for $name"
                description = 'A new game server update has been detected. Schedule a restart or update it manually.'
                color       = 3447003
                fields      = @(
                    [ordered]@{ name = 'Installed Build'; value = $inst; inline = $true },
                    [ordered]@{ name = 'Latest Build';    value = $late; inline = $true }
                )
            }
        }
    }
    $embed.timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $embed.footer    = [ordered]@{ text = if ($Test) { 'Test notification - Dune Server Tool' } else { 'Posted by Dune Server Tool' } }
    return $embed
}

# Post a prebuilt embed to a Discord incoming webhook with the same best-effort
# retry/redaction contract as Send-DuneDiscordWebhook. Never throws. Returns
# @{ ok; status; message }. Used by the state monitor and the test route.
function Send-DuneDiscordEmbed {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)]$Embed,
        [string]$MentionId
    )
    if (-not (Test-DuneDiscordWebhookUrl $Url)) {
        return @{ ok = $false; status = 400; message = 'Invalid Discord webhook URL.' }
    }
    $payload = [ordered]@{ username = 'DST Server'; embeds = @($Embed) }
    $mp = Get-DuneDiscordMentionPayload $MentionId
    if ($mp.content) { $payload.content = $mp.content }
    $payload.allowed_mentions = $mp.allowed
    $json = $payload | ConvertTo-Json -Depth 6

    $attempts = 0
    $maxAttempts = 3
    while ($true) {
        $attempts++
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $code = [int]$resp.StatusCode
            return @{ ok = $true; status = $code; message = "Sent (HTTP $code)." }
        } catch {
            $code = 0
            $retryAfter = 0
            $exResp = $_.Exception.Response
            if ($exResp) {
                try { $code = [int]$exResp.StatusCode } catch {}
                try {
                    $ra = $exResp.Headers['Retry-After']
                    if ($ra) { [double]$raD = 0; if ([double]::TryParse($ra, [ref]$raD)) { $retryAfter = $raD } }
                } catch {}
            }
            $transient = ($code -eq 429 -or ($code -ge 500 -and $code -le 599) -or $code -eq 0)
            if ($transient -and $attempts -lt $maxAttempts) {
                $delay = if ($retryAfter -gt 0) { [math]::Min($retryAfter, 10) } else { [math]::Min(2 * $attempts, 6) }
                Start-Sleep -Seconds $delay
                continue
            }
            return @{ ok = $false; status = $code; message = "Discord notice failed (HTTP $code): $($_.Exception.Message)" }
        }
    }
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

function New-DuneVmDailyMaintenanceScript {
    param([bool]$ApplyFuncomUpdates)
    $apply = if ($ApplyFuncomUpdates) { '1' } else { '0' }
    $appId = $script:DuneServerSteamAppIdFallback
    $body = @"
#!/bin/bash
set -u
APPLY_UPDATES=$apply
APPID=$appId
LOCK=/tmp/dst-daily-maintenance.lock
LOG=$script:DuneRestartVmLogPath
RESULT=$script:DuneRestartVmResultPath
mkdir -p /var/lib/dune-server
if ! mkdir "`$LOCK" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "`$LOCK" 2>/dev/null || true' EXIT INT TERM
exec >>"`$LOG" 2>&1
echo "=== `$(date -u +%Y-%m-%dT%H:%M:%SZ) scheduled maintenance ==="
MANIFEST=`$(ls /home/dune/.dune/download/steamapps/appmanifest_*.acf 2>/dev/null | head -1 || true)
INSTALLED=""
if [ -n "`$MANIFEST" ]; then
  INSTALLED=`$(grep -E '"buildid"' "`$MANIFEST" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || true)
fi
LATEST=""
JSON=`$(wget -qO- -T 8 "https://api.steamcmd.net/v1/info/`$APPID" 2>/dev/null || true)
if [ -n "`$JSON" ]; then
  LATEST=`$(printf '%s' "`$JSON" | tr -d ' \n' | grep -oE '"public":\{"buildid":"[0-9]+"' | head -1 | grep -oE '[0-9]+' || true)
fi
ACTION=restart
if [ "`$APPLY_UPDATES" = "1" ] && [ -n "`$INSTALLED" ] && [ -n "`$LATEST" ] && [ "`$LATEST" -gt "`$INSTALLED" ]; then
  ACTION=update
fi
touch $script:DuneRestartMarkerPath 2>/dev/null || true
if [ "`$ACTION" = "update" ]; then
  ORPHAN_WORKDIR=0
  [ -d /home/dune/.dune/download/steamapps/downloading/`$APPID ] && ORPHAN_WORKDIR=1
  [ -d /home/dune/.dune/download/steamapps/temp ] && ORPHAN_WORKDIR=1
  if [ "`$ORPHAN_WORKDIR" = "1" ]; then
    echo '[dst] Cleaning SteamCMD orphan workdir before scheduled update...'
    rm -rf /home/dune/.dune/download/steamapps/downloading/`$APPID /home/dune/.dune/download/steamapps/temp
  fi
  /home/dune/.dune/bin/battlegroup update
  RC=`$?
else
  /home/dune/.dune/bin/battlegroup restart
  RC=`$?
fi
printf '%s|%s|%s|%s|%s\n' "`$(date -u +%Y-%m-%dT%H:%M:%SZ)" "`$ACTION" "`$RC" "`$INSTALLED" "`$LATEST" > "`$RESULT"
exit "`$RC"
"@
    return (($body -replace "`r",'').TrimEnd("`n") + "`n")
}

function ConvertTo-DuneVmCronTime {
    param([string]$Time, [string]$VmOffset)
    if ($Time -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') { throw "Invalid schedule time '$Time'." }
    if ($VmOffset -notmatch '^([+-])(\d{2})(\d{2})$') { throw "Invalid VM timezone offset '$VmOffset'." }
    $sign = if ($Matches[1] -eq '-') { -1 } else { 1 }
    $offsetMinutes = $sign * (([int]$Matches[2] * 60) + [int]$Matches[3])
    $local = [datetime]::Today.AddHours([int]$Time.Substring(0,2)).AddMinutes([int]$Time.Substring(3,2))
    $utc = $local.ToUniversalTime()
    $vm = $utc.AddMinutes($offsetMinutes)
    return @{ hour = $vm.Hour; minute = $vm.Minute; offset = $VmOffset }
}

function Sync-DuneRestartScheduleAutomation {
    $state = Get-DuneRestartSchedule
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) { return @{ ok = $false; message = $ctx.message } }
    try {
        $offsetResult = Invoke-DuneBackupShell -Ip $ctx.ip -Script 'date +%z' -TimeoutSec 15
        if ($offsetResult.rc -ne 0) { return @{ ok = $false; message = 'Could not read VM timezone offset.' } }
        $cronTime = ConvertTo-DuneVmCronTime -Time $state.time -VmOffset ([string]$offsetResult.out).Trim()
        $vmScript = New-DuneVmDailyMaintenanceScript -ApplyFuncomUpdates ([bool]$state.applyFuncomUpdates)
        $scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($vmScript))
        $cronLine = "$($cronTime.minute) $($cronTime.hour) * * * $script:DuneRestartVmScriptPath"
        $enabled = if ($state.enabled) { '1' } else { '0' }
        $install = @"
set -eu
printf '%s' '$scriptB64' | base64 -d > $script:DuneRestartVmScriptPath
chmod 755 $script:DuneRestartVmScriptPath
/bin/bash -n $script:DuneRestartVmScriptPath
OLD=`$(crontab -l 2>/dev/null || true)
printf '%s\n' "`$OLD" | awk '
  `$0 == "$script:DuneRestartCronBeginMarker" { skip=1; next }
  `$0 == "$script:DuneRestartCronEndMarker" { skip=0; next }
  !skip { print }
' > /tmp/dst-crontab-clean
if [ "$enabled" = "1" ]; then
  {
    cat /tmp/dst-crontab-clean
    echo "$script:DuneRestartCronBeginMarker"
    echo "$cronLine"
    echo "$script:DuneRestartCronEndMarker"
  } > /tmp/dst-crontab-new
else
  cp /tmp/dst-crontab-clean /tmp/dst-crontab-new
fi
crontab /tmp/dst-crontab-new
rm -f /tmp/dst-crontab-clean /tmp/dst-crontab-new
if [ -x /sbin/rc-update ]; then /sbin/rc-update add crond default >/dev/null 2>&1 || true; fi
if [ -x /sbin/rc-service ]; then /sbin/rc-service crond start >/dev/null 2>&1 || true; fi
crontab -l 2>/dev/null || true
"@
        $r = Invoke-DuneBackupShell -Ip $ctx.ip -Script $install -TimeoutSec 30
        if ($r.rc -ne 0) { return @{ ok = $false; message = "VM cron install exited $($r.rc)." } }
        $hasBlock = ([string]$r.out -match [regex]::Escape($script:DuneRestartCronBeginMarker))
        if ($state.enabled -and -not $hasBlock) { return @{ ok = $false; message = 'VM cron verification failed.' } }
        if (-not $state.enabled -and $hasBlock) { return @{ ok = $false; message = 'VM cron remained after disabling schedule.' } }
        return @{ ok = $true; message = if ($state.enabled) { "VM cron ensured at $cronLine (VM offset $($cronTime.offset))." } else { 'VM cron disabled.' } }
    } catch {
        return @{ ok = $false; message = "VM cron reconciliation failed: $($_.Exception.Message)" }
    }
}

function Sync-DuneVmDailyMaintenanceResult {
    param([switch]$Force)
    if (-not $Force -and
        (([datetime]::UtcNow - $script:DuneRestartVmResultLastPoll).TotalSeconds -lt $script:DuneRestartVmResultPollSeconds)) {
        return @{ ok = $true; changed = $false; skipped = $true; message = 'VM result poll not due.' }
    }
    $script:DuneRestartVmResultLastPoll = [datetime]::UtcNow
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) { return @{ ok = $false; message = $ctx.message } }
    try {
        $script = @"
if [ -f $script:DuneRestartVmResultPath ]; then
  cat $script:DuneRestartVmResultPath
fi
"@
        $r = Invoke-DuneBackupShell -Ip $ctx.ip -Script $script -TimeoutSec 15
        if ($r.rc -ne 0) { return @{ ok = $false; message = "VM result read exited $($r.rc)." } }
        $line = ([string]$r.out).Trim()
        if (-not $line) { return @{ ok = $true; changed = $false; message = 'No VM maintenance result yet.' } }
        $parts = @($line -split '\|', 5)
        if ($parts.Count -ne 5) { return @{ ok = $false; message = 'VM maintenance result was malformed.' } }
        $stamp, $action, $rcText, $installed, $latest = $parts
        $rc = -1
        if ($rcText -match '^-?\d+$') { $rc = [int]$rcText }
        $state = Get-DuneRestartSchedule
        $resultText = if ($rc -eq 0) { "$action ok @ $stamp" } else { "$action error (rc=$rc) @ $stamp" }
        $changed = ($state.lastResult -ne $resultText)
        $state.lastResult = $resultText
        $state.installedBuild = $installed
        $state.latestBuild = $latest
        $state.updateAvailable = (($installed -match '^\d+$') -and ($latest -match '^\d+$') -and ([int64]$latest -gt [int64]$installed) -and $action -ne 'update')
        $state.updateCheckedAt = $stamp
        Save-DuneRestartSchedule -State $state
        return @{ ok = $true; changed = $changed; action = $action; rc = $rc; message = $resultText }
    } catch {
        return @{ ok = $false; message = "VM result reconciliation failed: $($_.Exception.Message)" }
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

            # --- Outbound Discord "restart imminent" notice (once/day) ---
            # Rides the same lead window as the in-game broadcast but keeps its
            # own dedupe stamp + enable flag so the two channels are independent.
            # A Discord failure must never throw out of the tick.
            $state = Get-DuneRestartSchedule
            if ($state.discordEnabled -and $state.discordWebhookUrl -and $state.lastDiscordNoticeDate -ne $today) {
                try {
                    $serverName = ''
                    if (Get-Command Get-DuneServerName -ErrorAction SilentlyContinue) {
                        try { $serverName = Get-DuneServerName -CachedOnly } catch { $serverName = '' }
                    }
                    $reason = if ($state.updateAvailable) { 'Scheduled daily BG maintenance (Funcom server update available)' } else { 'Scheduled daily BG maintenance' }
                    $d = Send-DuneDiscordWebhook -Url $state.discordWebhookUrl -ServerName $serverName `
                        -MinutesToRestart $lead -RestartAt $restartAt -Reason $reason -MentionId $state.discordMentionId
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        $dm = if ($d -and $d.ok) { "sent (HTTP $($d.status))" } else { "failed: $($d.message)" }
                        Write-DuneLog "scheduled restart discord notice $dm [$(Get-DuneRedactedWebhookUrl $state.discordWebhookUrl)]"
                    }
                    $state = Get-DuneRestartSchedule
                    $state.lastDiscordNoticeDate = $today
                    Save-DuneRestartSchedule -State $state
                } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        Write-DuneLog "scheduled restart discord notice error: $($_.Exception.Message)" 'WARN'
                    }
                }
            }

            $state = Get-DuneRestartSchedule
            $state.lastBroadcastDate = $today
            Save-DuneRestartSchedule -State $state
        } elseif ($now -ge $restartAt) {
            # Missed the lead window (DST launched late). Mark done so we don't
            # fire a stale notice; the restart window below still applies.
            $state.lastBroadcastDate = $today
            $state.lastDiscordNoticeDate = $today
            Save-DuneRestartSchedule -State $state
        }
    }

    # --- VM cron observation (once/day) ---
    # The VM owns the actual restart/update even while DST is closed. When DST is
    # open, keep the dashboard update badge fresh and mark that today's cron
    # window was observed; never issue a second host-side restart.
    $state = Get-DuneRestartSchedule
    if ($state.lastRestartDate -ne $today) {
        if ($now -ge $restartAt -and $now -le $restartWindowEnd) {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "VM cron maintenance window reached (host time=$($state.time))"
            }
            $serverDir = Get-Variable -Name DuneSchedulerServerDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if ($serverDir) {
                try { [void](Start-DuneFuncomUpdateCheckAsync -ServerDir $serverDir) } catch {}
            }
            $state = Get-DuneRestartSchedule
            $state.lastRestartDate = $today
            $state.lastResult = "VM cron maintenance scheduled @ $today $($state.time)"
            Save-DuneRestartSchedule -State $state
        } elseif ($now -gt $restartWindowEnd) {
            # The VM cron already owned the maintenance window while DST was
            # closed; only mark the host-side notification/check window complete.
            $state.lastRestartDate = $today
            Save-DuneRestartSchedule -State $state
        }
    }
}

# True when the persistent Hagga Basin overworld (Survival_1) is Ready - i.e.
# players can actually join. Read from the battlegroup snapshot's parsed
# gameServers (map/phase/ready). Falls back to the coarse running state when the
# status output has no parseable game-server rows.
function Test-DuneGameServerReady {
    param($Gs)
    if (-not $Gs) { return $false }
    $ready = "$($Gs.ready)".Trim()
    $phase = "$($Gs.phase)".Trim()
    if ($ready -match '^(\d+)\s*/\s*(\d+)$') {
        $n = [int]$Matches[1]; $m = [int]$Matches[2]
        return ($m -ge 1 -and $n -ge $m)
    }
    if ($ready -match '(?i)^true$')      { return $true }
    if ($phase -match '(?i)\bReady\b')   { return $true }
    return $false
}

function Test-DuneHaggaReady {
    param($Snapshot)
    if (-not $Snapshot) { return $false }
    $servers = @()
    if ($Snapshot.gameServers) { $servers = @($Snapshot.gameServers) }
    if ($servers.Count -gt 0) {
        # Prefer the Survival_1 / Hagga row when the status names it.
        $hagga = @($servers | Where-Object { "$($_.map)" -match '(?i)survival|hagga' })
        if ($hagga.Count -gt 0) {
            foreach ($h in $hagga) { if (Test-DuneGameServerReady $h) { return $true } }
            return $false
        }
        # Status didn't name the survival map - treat any Ready game server as online.
        foreach ($s in $servers) { if (Test-DuneGameServerReady $s) { return $true } }
        return $false
    }
    # No parseable game-server rows - fall back to the coarse battlegroup state.
    return ("$($Snapshot.state)" -eq 'running')
}

# Track state changes for Discord notifications (Online, Offline, Restarting, Update Available).
#
# NOTE: this only observes state while DST is running. It fires:
#   - Online      when Hagga Basin (Survival_1) becomes Ready (joinable),
#   - Restarting  once, when the server drops out of Ready into a transitional state,
#   - Offline     once, after the server has been not-Ready for the debounce window,
#   - Update      when the scheduled-restart update check detects a new Funcom build.
# Changes made directly on the VM (battlegroup.bat) while DST is closed are not seen.
function Invoke-DuneDiscordStateMonitorTick {
    $state = Get-DuneRestartSchedule
    if (-not $state.discordWebhookUrl) { return }
    if (-not $state.discordNotifyOnline -and -not $state.discordNotifyOffline -and -not $state.discordNotifyRestarting -and -not $state.discordNotifyUpdate) { return }

    $serverName = ''
    if (Get-Command Get-DuneServerName -ErrorAction SilentlyContinue) {
        try { $serverName = Get-DuneServerName -CachedOnly } catch { $serverName = '' }
    }
    $name = if ([string]::IsNullOrWhiteSpace($serverName)) { 'Dune server' } else { $serverName }

    $vm = Get-DuneVmStatus
    $bgState = 'unknown'
    $haggaReady = $false
    if ($vm.running) {
        if (Get-Command Get-DuneBattlegroupSnapshot -ErrorAction SilentlyContinue) {
            try {
                $bg = Get-DuneBattlegroupSnapshot
                if ($bg) {
                    if ($bg.state) { $bgState = $bg.state }
                    $haggaReady = Test-DuneHaggaReady -Snapshot $bg
                }
            } catch {}
        }
    }

    $lastHagga = $script:DuneDiscordLastHaggaReady

    $fireState = $null
    if ($haggaReady) {
        # Up and joinable. Fire Online only on an observed not-ready -> ready
        # transition (so opening DST against an already-up server is silent).
        if ($lastHagga -eq $false -and $state.discordNotifyOnline) { $fireState = 'online' }
        $script:DuneDiscordOfflineSince   = $null
        $script:DuneDiscordOfflineSent    = $false
        $script:DuneDiscordRestartingSent = $false
    } else {
        # Not joinable. Only start tracking a down-period once we've actually
        # seen the server Ready this session (a ready -> not-ready transition),
        # so a server that's intentionally down when DST opens stays silent.
        if ($lastHagga -eq $true) {
            $script:DuneDiscordOfflineSince   = [datetime]::UtcNow
            $script:DuneDiscordOfflineSent    = $false
            $script:DuneDiscordRestartingSent = $false
        }

        if ($script:DuneDiscordOfflineSince) {
            # Restarting: announce once as soon as a real down-period begins
            # (covers DST commands, scheduled restarts, and the bat path while
            # DST is open).
            if ($state.discordNotifyRestarting -and -not $script:DuneDiscordRestartingSent) {
                $fireState = 'restarting'
                $script:DuneDiscordRestartingSent = $true
            }
            # Offline: only after the down-period exceeds the debounce, so a normal
            # restart that comes back quickly never posts a false offline.
            elseif ($state.discordNotifyOffline -and -not $script:DuneDiscordOfflineSent) {
                $downSecs = ([datetime]::UtcNow - $script:DuneDiscordOfflineSince).TotalSeconds
                if ($downSecs -ge $script:DuneDiscordOfflineDebounceSecs) {
                    $fireState = 'offline'
                    $script:DuneDiscordOfflineSent = $true
                }
            }
        }
    }
    $script:DuneDiscordLastHaggaReady = $haggaReady

    if ($fireState) {
        $embed = New-DuneDiscordStateEmbed -State $fireState -ServerName $name
        $r = Send-DuneDiscordEmbed -Url $state.discordWebhookUrl -Embed $embed -MentionId $state.discordMentionId
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            if ($r.ok) {
                Write-DuneLog "discord state monitor fired '$fireState' [$(Get-DuneRedactedWebhookUrl $state.discordWebhookUrl)]"
            } else {
                Write-DuneLog "discord state monitor error: $($r.message)" 'WARN'
            }
        }
    }

    $lastUpdate = $script:DuneDiscordLastUpdateAvailable
    $curUpdate = $state.updateAvailable
    $script:DuneDiscordLastUpdateAvailable = $curUpdate

    if ($lastUpdate -ne $null -and $curUpdate -and -not $lastUpdate -and $state.discordNotifyUpdate) {
        $serverName = ''
        if (Get-Command Get-DuneServerName -ErrorAction SilentlyContinue) {
            try { $serverName = Get-DuneServerName -CachedOnly } catch { $serverName = '' }
        }
        $name = if ([string]::IsNullOrWhiteSpace($serverName)) { 'Dune server' } else { $serverName }

        $embed = New-DuneDiscordStateEmbed -State 'update' -ServerName $name -InstalledBuild $state.installedBuild -LatestBuild $state.latestBuild
        $r = Send-DuneDiscordEmbed -Url $state.discordWebhookUrl -Embed $embed -MentionId $state.discordMentionId
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            if ($r.ok) {
                Write-DuneLog "discord state monitor fired 'update available' [$(Get-DuneRedactedWebhookUrl $state.discordWebhookUrl)]"
            } else {
                Write-DuneLog "discord state monitor error (update): $($r.message)" 'WARN'
            }
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
            # Reinstall/repair the VM-owned daily maintenance script + root cron
            # on every DST startup. Normal Funcom battlegroup updates leave host
            # cron intact; this restores it after VM replacement or reset.
            try {
                $restartSync = Sync-DuneRestartScheduleAutomation
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    if ($restartSync.ok) { Write-DuneLog $restartSync.message }
                    else { Write-DuneLog "VM daily maintenance reconciliation unconfirmed: $($restartSync.message)" 'WARN' }
                }
            } catch {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    try { Write-DuneLog "VM daily maintenance reconciliation error: $($_.Exception.Message)" 'WARN' } catch {}
                }
            }
            try {
                $resultSync = Sync-DuneVmDailyMaintenanceResult -Force
                if ($resultSync.changed -and (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
                    Write-DuneLog "VM daily maintenance result: $($resultSync.message)"
                }
            } catch {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    try { Write-DuneLog "VM daily maintenance result reconciliation error: $($_.Exception.Message)" 'WARN' } catch {}
                }
            }
            # One-time on scheduler start: ensure the autonomous partition
            # self-heal (VM boot hook + */15 cron) is installed/refreshed, so a
            # stuck on-demand/warm map pin self-heals even with DST closed (e.g.
            # after a host crash + VM reboot). VM-gated + best-effort inside the
            # function; must never block the scheduler loop.
            try {
                if (Get-Command Sync-DunePartitionAutomation -ErrorAction SilentlyContinue) {
                    $cpSync = Sync-DunePartitionAutomation
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        if ($cpSync.ok) { Write-DuneLog 'partition self-heal automation ensured on VM' }
                        else { Write-DuneLog "partition self-heal automation install unconfirmed: $($cpSync.message)" 'WARN' }
                    }
                }
            } catch {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    try { Write-DuneLog "partition self-heal automation install error: $($_.Exception.Message)" 'WARN' } catch {}
                }
            }
            # Funcom's director ReplicaSet can leave terminal Evicted/Unknown pod
            # objects after VM power cycles. This SSH maintenance is unrelated to
            # serving the UI, so keep it on this background runspace and off the
            # listener's cold-start path.
            try {
                if (Get-Command Remove-DuneTerminalDirectorPods -ErrorAction SilentlyContinue) {
                    $directorPrune = Remove-DuneTerminalDirectorPods
                    if ($directorPrune.ok -and $directorPrune.count -gt 0 -and
                        (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
                        Write-DuneLog "pod maintenance: $($directorPrune.message)"
                    }
                }
            } catch {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    try { Write-DuneLog "pod maintenance: terminal director cleanup failed: $($_.Exception.Message)" 'WARN' } catch {}
                }
            }
            while ($true) {
                try { Invoke-DuneRestartScheduleTick } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "restart scheduler tick error: $($_.Exception.Message)" 'WARN' } catch {}
                    }
                    try { [void](Sync-DuneVmDailyMaintenanceResult) } catch {
                        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                            try { Write-DuneLog "VM daily maintenance result tick error: $($_.Exception.Message)" 'WARN' } catch {}
                        }
                    }
                }
                try { Invoke-DuneDiscordStateMonitorTick } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "discord state monitor tick error: $($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                # Self-heals the db-dbdepl-util bare-pod wedge (see
                # lib/DbUtilAutoheal.ps1). Silent no-op unless the util pod
                # terminated non-zero with the DB deployment stuck on Pending.
                # Runs unconditionally so it catches wedges from any trigger:
                # user-issued `battlegroup start`/`restart`, our scheduled
                # restart, FLS token rotation, the Public IP Apply
                # refresh-status-pods step, or a Funcom self-host update.
                try { [void](Invoke-DuneDbUtilAutohealTick) } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "db-util autoheal tick error (outer): $($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                # v12.18.13: local backup mirror auto-copy. The restart
                # scheduler loop sleeps 30s per iteration; this tick internally
                # gates to every 20th call (~10 minutes) which is plenty for
                # hourly backups. Runs whether or not the Database page is open
                # in the webui, so a scheduled backup landing at 00:00 gets
                # copied within ~10 min without the user touching DST. Silent
                # no-op unless the user has turned the mirror on (Database →
                # Local Backup Mirror card).
                try { Invoke-DuneBackupMirrorSchedulerTick } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "backup mirror tick error (outer): $($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                # Deep Desert base-backup guard (see lib/BaseBackupGuard.ps1).
                # Silent no-op unless the user opted in; internally rate-limited
                # to one DB round-trip every 10 minutes. Its job is to notice
                # when a Funcom migration has replaced the wipe function and
                # dropped our 'BaseBackup' exclusion, and put it back before the
                # next season end deletes someone's stored base.
                try { [void](Invoke-DuneBaseBackupGuardTick) } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "base backup guard tick error (outer): $($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                # Welcome back packages (see lib/WelcomeBack.ps1). Silent no-op
                # unless the admin turned it on AND chose a package. Internally
                # throttled to one DB pass every 5 minutes - it watches for a
                # login having happened, which does not need half-minute
                # resolution and is measured against the previous login rather
                # than against "now", so arriving late changes nothing.
                try { [void](Invoke-DuneWelcomeBackTick) } catch {
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "welcome back tick error (outer): $($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                # In-game !commands (see lib/ChatCommands.ps1). Silent no-op
                # unless the admin has enabled the feature.
                #
                # LATENCY: chat has to feel like chat. A player who types !water
                # and waits half a minute assumes it did not work, so this does
                # NOT ride the 30s cadence with everything else. The loop's sleep
                # IS this loop: it wakes every 3s to drain chat, and one full pass
                # still takes 30s, so every heavy tick above keeps its old
                # cadence.
                #
                # COST - measured, not assumed (2026-08-04, 8-core VM):
                #   idle VM                9.14% busy
                #   with 3s polling       15.41% busy
                # ~= half a core, sustained, for as long as the feature is on. It
                # is paid per CALL and not per message, because `rabbitmqctl eval`
                # starts a hidden Erlang node every time (~1.5 core-seconds each),
                # so the poll interval is the whole cost: 3s ~ 0.50 core, 5s ~
                # 0.30, 10s ~ 0.15, 30s ~ 0.05. That trade belongs to the admin,
                # so the interval is a setting rather than a constant - see
                # Get-DuneChatCommandPollSeconds.
                #
                # The right long-term fix is a persistent AMQP consumer, which
                # would be instant AND near-free. It is harder than it looks: the
                # broker speaks amqp/ssl only and delegates auth to Funcom's HTTP
                # shim (verified on a live server), so it needs TLS plus
                # shim-accepted credentials plus reconnect handling. Worth doing
                # if these commands become something servers rely on.
                #
                # The tick returns immediately when the feature is off, so a
                # server not using it pays nothing.
                $chatPoll = 3
                try { $chatPoll = [int](Get-DuneChatCommandPollSeconds) } catch { $chatPoll = 3 }
                if ($chatPoll -lt 1) { $chatPoll = 1 }
                # One outer pass stays ~30s so every heavy tick above keeps the
                # cadence it was written for, regardless of the chat setting.
                $chatElapsed = 0
                while ($chatElapsed -lt 30) {
                    $slice = [Math]::Min($chatPoll, 30 - $chatElapsed)
                    Start-Sleep -Seconds $slice
                    $chatElapsed += $slice
                    try { [void](Invoke-DuneChatCommandTick) } catch {
                        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                            try { Write-DuneLog "chat command tick error (outer): $($_.Exception.Message)" 'WARN' } catch {}
                        }
                    }
                }
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
