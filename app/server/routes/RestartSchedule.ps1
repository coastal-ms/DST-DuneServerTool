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
            discordNotifyOnline  = [bool]$state.discordNotifyOnline
            discordNotifyOffline = [bool]$state.discordNotifyOffline
            discordNotifyRestarting = [bool]$state.discordNotifyRestarting
            discordNotifyUpdate  = [bool]$state.discordNotifyUpdate
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
    $discordNotifyOnline = $false
    $discordNotifyOffline = $false
    $discordNotifyRestarting = $false
    $discordNotifyUpdate = $false
    # $null webhook means "leave the stored URL unchanged" so the secret never
    # has to round-trip through the browser. Only a present key updates it.
    $discordWebhookUrl = $null
    $discordMentionId = $null
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('enabled'))              { $enabled = [bool]$body.enabled }
        if ($body.ContainsKey('time'))                 { $time = [string]$body.time }
        if ($body.ContainsKey('broadcastLeadMinutes')) { try { $lead = [int]$body.broadcastLeadMinutes } catch { $lead = -1 } }
        if ($body.ContainsKey('discordEnabled'))       { $discordEnabled = [bool]$body.discordEnabled }
        if ($body.ContainsKey('discordNotifyOnline'))  { $discordNotifyOnline = [bool]$body.discordNotifyOnline }
        if ($body.ContainsKey('discordNotifyOffline')) { $discordNotifyOffline = [bool]$body.discordNotifyOffline }
        if ($body.ContainsKey('discordNotifyRestarting')) { $discordNotifyRestarting = [bool]$body.discordNotifyRestarting }
        if ($body.ContainsKey('discordNotifyUpdate'))  { $discordNotifyUpdate = [bool]$body.discordNotifyUpdate }
        if ($body.ContainsKey('discordWebhookUrl'))    { $discordWebhookUrl = [string]$body.discordWebhookUrl }
        if ($body.ContainsKey('discordMentionId'))     { $discordMentionId = [string]$body.discordMentionId }
    } elseif ($body) {
        if ($null -ne $body.enabled)              { $enabled = [bool]$body.enabled }
        if ($body.time)                           { $time = [string]$body.time }
        if ($null -ne $body.broadcastLeadMinutes) { try { $lead = [int]$body.broadcastLeadMinutes } catch { $lead = -1 } }
        if ($null -ne $body.discordEnabled)       { $discordEnabled = [bool]$body.discordEnabled }
        if ($null -ne $body.discordNotifyOnline)  { $discordNotifyOnline = [bool]$body.discordNotifyOnline }
        if ($null -ne $body.discordNotifyOffline) { $discordNotifyOffline = [bool]$body.discordNotifyOffline }
        if ($null -ne $body.discordNotifyRestarting) { $discordNotifyRestarting = [bool]$body.discordNotifyRestarting }
        if ($null -ne $body.discordNotifyUpdate)  { $discordNotifyUpdate = [bool]$body.discordNotifyUpdate }
        if ($body.PSObject.Properties['discordWebhookUrl']) { $discordWebhookUrl = [string]$body.discordWebhookUrl }
        if ($body.PSObject.Properties['discordMentionId'])  { $discordMentionId = [string]$body.discordMentionId }
    }
    if (-not $time) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include "time" (HH:mm).'
        return
    }
    try {
        $r = Set-DuneRestartSchedule -Enabled $enabled -Time $time -BroadcastLeadMinutes $lead `
            -DiscordEnabled $discordEnabled -DiscordNotifyOnline $discordNotifyOnline -DiscordNotifyOffline $discordNotifyOffline -DiscordNotifyRestarting $discordNotifyRestarting -DiscordNotifyUpdate $discordNotifyUpdate -DiscordWebhookUrl $discordWebhookUrl -DiscordMentionId $discordMentionId
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
            discordNotifyOnline  = [bool]$state.discordNotifyOnline
            discordNotifyOffline = [bool]$state.discordNotifyOffline
            discordNotifyRestarting = [bool]$state.discordNotifyRestarting
            discordNotifyUpdate  = [bool]$state.discordNotifyUpdate
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

# Send sample notifications to the saved (or supplied) Discord webhook so the
# user can verify the integration without waiting for a real event. Sends one
# representative message PER ENABLED notification type (online / offline /
# restarting / update-available), plus the pre-restart broadcast when that
# toggle is on - so the test mirrors exactly what each enabled event will look
# like, instead of always sending the same restart message.
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

        $sent   = New-Object System.Collections.Generic.List[string]
        $failed = New-Object System.Collections.Generic.List[string]

        # One sample per enabled state toggle, using the same embeds the live
        # monitor posts (so the test is representative).
        $stateNotices = @()
        if ($state.discordNotifyOnline)     { $stateNotices += @{ key = 'online';     label = 'online' } }
        if ($state.discordNotifyOffline)    { $stateNotices += @{ key = 'offline';    label = 'offline' } }
        if ($state.discordNotifyRestarting) { $stateNotices += @{ key = 'restarting'; label = 'restarting' } }
        if ($state.discordNotifyUpdate)     { $stateNotices += @{ key = 'update';     label = 'update available' } }

        foreach ($n in $stateNotices) {
            $embed = New-DuneDiscordStateEmbed -State $n.key -ServerName $serverName `
                -InstalledBuild $state.installedBuild -LatestBuild $state.latestBuild -Test
            $r = Send-DuneDiscordEmbed -Url $url -Embed $embed -MentionId $state.discordMentionId
            if ($r.ok) { $sent.Add($n.label) } else { $failed.Add("$($n.label) ($($r.message))") }
            Start-Sleep -Milliseconds 400   # gentle pacing to avoid Discord rate limits
        }

        # The pre-restart maintenance broadcast (master Discord restart toggle),
        # and a fallback so the button still demonstrates something when nothing
        # specific is enabled.
        $sendRestart = [bool]$state.discordEnabled -or ($stateNotices.Count -eq 0)
        if ($sendRestart) {
            $lead = [int]$state.broadcastLeadMinutes
            if ($lead -le 0) { $lead = 10 }
            $r = Send-DuneDiscordWebhook -Url $url -ServerName $serverName -MinutesToRestart $lead `
                -RestartAt ((Get-Date).AddMinutes($lead)) -Reason 'Test notification from Dune Server Tool' -MentionId $state.discordMentionId
            if ($r.ok) { $sent.Add('scheduled restart') } else { $failed.Add("scheduled restart ($($r.message))") }
        }

        if ($sent.Count -eq 0) {
            $msg = if ($failed.Count -gt 0) { "Test failed: $($failed -join '; ')" } else { 'No notifications are enabled to test.' }
            Write-DuneError -Response $res -Status 502 -Message $msg
            return
        }
        $summary = "Sent $($sent.Count) test notification$(if ($sent.Count -ne 1) { 's' }): $($sent -join ', ')."
        if ($failed.Count -gt 0) { $summary += " Failed: $($failed -join '; ')." }
        Write-DuneJson -Response $res -Body @{ ok = $true; message = $summary }
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

