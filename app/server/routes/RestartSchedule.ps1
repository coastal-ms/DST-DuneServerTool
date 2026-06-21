# RestartSchedule.ps1 - Routes for the Scheduled Restarts card (Server Health).
#
# GET  /api/restart-schedule               - current schedule + last update-check state
# PUT  /api/restart-schedule               - save settings, body { enabled, time, broadcastLeadMinutes }
# POST /api/restart-schedule/check-update  - run a Funcom server-update check now (VM-gated, slow)
#
# The schedule lives host-side (JSON in %LOCALAPPDATA%\DuneServer) and the
# scheduler only runs while DST is open, so GET/PUT work even when the VM is
# stopped - only the live update check needs the VM.

Register-DuneRoute -Method GET -Path '/api/restart-schedule' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $state = Get-DuneRestartSchedule
        Write-DuneJson -Response $res -Body @{
            enabled              = [bool]$state.enabled
            time                 = [string]$state.time
            broadcastLeadMinutes = [int]$state.broadcastLeadMinutes
            discordEnabled       = [bool]$state.discordEnabled
            discordWebhookSet    = [bool]([string]$state.discordWebhookUrl)
            discordMentionId     = [string]$state.discordMentionId
            lastRestartDate      = [string]$state.lastRestartDate
            lastResult           = [string]$state.lastResult
            updateAvailable      = [bool]$state.updateAvailable
            installedBuild       = [string]$state.installedBuild
            latestBuild          = [string]$state.latestBuild
            updateCheckedAt      = [string]$state.updateCheckedAt
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/restart-schedule' -Handler {
    param($req, $res, $routeParams, $body)
    $enabled = $false
    $time = $null
    $lead = 10
    $discordEnabled = $false
    # $null webhook means "leave the stored URL unchanged" so the secret never
    # has to round-trip through the browser. Only a present key updates it.
    $discordWebhookUrl = $null
    $discordMentionId = $null
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('enabled'))              { $enabled = [bool]$body.enabled }
        if ($body.ContainsKey('time'))                 { $time = [string]$body.time }
        if ($body.ContainsKey('broadcastLeadMinutes')) { try { $lead = [int]$body.broadcastLeadMinutes } catch { $lead = -1 } }
        if ($body.ContainsKey('discordEnabled'))       { $discordEnabled = [bool]$body.discordEnabled }
        if ($body.ContainsKey('discordWebhookUrl'))    { $discordWebhookUrl = [string]$body.discordWebhookUrl }
        if ($body.ContainsKey('discordMentionId'))     { $discordMentionId = [string]$body.discordMentionId }
    } elseif ($body) {
        if ($null -ne $body.enabled)              { $enabled = [bool]$body.enabled }
        if ($body.time)                           { $time = [string]$body.time }
        if ($null -ne $body.broadcastLeadMinutes) { try { $lead = [int]$body.broadcastLeadMinutes } catch { $lead = -1 } }
        if ($null -ne $body.discordEnabled)       { $discordEnabled = [bool]$body.discordEnabled }
        if ($body.PSObject.Properties['discordWebhookUrl']) { $discordWebhookUrl = [string]$body.discordWebhookUrl }
        if ($body.PSObject.Properties['discordMentionId'])  { $discordMentionId = [string]$body.discordMentionId }
    }
    if (-not $time) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include "time" (HH:mm).'
        return
    }
    try {
        $r = Set-DuneRestartSchedule -Enabled $enabled -Time $time -BroadcastLeadMinutes $lead `
            -DiscordEnabled $discordEnabled -DiscordWebhookUrl $discordWebhookUrl -DiscordMentionId $discordMentionId
        if (-not $r.ok) {
            Write-DuneError -Response $res -Status ([int]$r.status) -Message $r.message
            return
        }
        $state = $r.schedule
        Write-DuneJson -Response $res -Body @{
            enabled              = [bool]$state.enabled
            time                 = [string]$state.time
            broadcastLeadMinutes = [int]$state.broadcastLeadMinutes
            discordEnabled       = [bool]$state.discordEnabled
            discordWebhookSet    = [bool]([string]$state.discordWebhookUrl)
            discordMentionId     = [string]$state.discordMentionId
            lastRestartDate      = [string]$state.lastRestartDate
            lastResult           = [string]$state.lastResult
            updateAvailable      = [bool]$state.updateAvailable
            installedBuild       = [string]$state.installedBuild
            latestBuild          = [string]$state.latestBuild
            updateCheckedAt      = [string]$state.updateCheckedAt
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Schedule save failed: $($_.Exception.Message)"
    }
}

# Send a one-off test embed to the saved (or supplied) Discord webhook so the
# user can verify the integration without waiting for a scheduled restart.
Register-DuneRoute -Method POST -Path '/api/restart-schedule/test-discord' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $state = Get-DuneRestartSchedule
        $url = [string]$state.discordWebhookUrl
        if ($body -is [hashtable] -and $body.ContainsKey('discordWebhookUrl') -and [string]$body.discordWebhookUrl) {
            $url = [string]$body.discordWebhookUrl
        } elseif ($body -and $body.PSObject.Properties['discordWebhookUrl'] -and [string]$body.discordWebhookUrl) {
            $url = [string]$body.discordWebhookUrl
        }
        if (-not (Test-DuneDiscordWebhookUrl $url)) {
            Write-DuneError -Response $res -Status 400 -Message 'No valid Discord webhook URL saved. Save a webhook URL first.'
            return
        }
        $serverName = ''
        if (Get-Command Get-DuneServerName -ErrorAction SilentlyContinue) {
            try { $serverName = Get-DuneServerName -CachedOnly } catch { $serverName = '' }
        }
        $lead = [int]$state.broadcastLeadMinutes
        if ($lead -le 0) { $lead = 10 }
        $r = Send-DuneDiscordWebhook -Url $url -ServerName $serverName -MinutesToRestart $lead `
            -RestartAt ((Get-Date).AddMinutes($lead)) -Reason 'Test notification from Dune Server Tool' -MentionId $state.discordMentionId
        if (-not $r.ok) {
            Write-DuneError -Response $res -Status 502 -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body @{ ok = $true; message = 'Test message sent to Discord.' }
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Test message failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/restart-schedule/check-update' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DuneFuncomServerUpdateStatus -Persist
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status ([int]$r.status) -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Update check failed: $($_.Exception.Message)"
    }
}
