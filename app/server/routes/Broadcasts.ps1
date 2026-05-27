# Broadcasts API — generic + shutdown ServiceBroadcasts via mq-game.

Register-DuneRoute -Method POST -Path '/api/broadcasts/generic' -Handler {
    param($req, $res, $routeParams, $body)
    if ($null -eq $body) {
        Write-DuneError -Response $res -Status 400 -Message 'Body required'
        return
    }
    $title       = $null
    $bodyText    = $null
    $durationSec = 30
    if ($body -is [System.Collections.IDictionary]) {
        if ($body.Contains('title'))       { $title       = [string]$body['title'] }
        if ($body.Contains('body'))        { $bodyText    = [string]$body['body'] }
        if ($body.Contains('durationSec')) { $durationSec = [int]$body['durationSec'] }
    } else {
        if ($body.PSObject.Properties['title'])       { $title       = [string]$body.title }
        if ($body.PSObject.Properties['body'])        { $bodyText    = [string]$body.body }
        if ($body.PSObject.Properties['durationSec']) { $durationSec = [int]$body.durationSec }
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        Write-DuneError -Response $res -Status 400 -Message 'title is required'
        return
    }
    if ($null -eq $bodyText) { $bodyText = '' }
    try {
        $r = Send-V6GenericBroadcast -Title $title -Body $bodyText -DurationSec $durationSec
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/broadcasts/shutdown' -Handler {
    param($req, $res, $routeParams, $body)
    if ($null -eq $body) {
        Write-DuneError -Response $res -Status 400 -Message 'Body required'
        return
    }
    $shutdownType = 'Restart'
    $delayMinutes = 10
    $frequency    = 0
    $duration     = 0
    $cancel       = $false
    if ($body -is [System.Collections.IDictionary]) {
        if ($body.Contains('shutdownType')) { $shutdownType = [string]$body['shutdownType'] }
        if ($body.Contains('delayMinutes')) { $delayMinutes = [int]$body['delayMinutes'] }
        if ($body.Contains('frequency'))    { $frequency    = [int]$body['frequency'] }
        if ($body.Contains('duration'))     { $duration     = [int]$body['duration'] }
        if ($body.Contains('cancel'))       { $cancel       = [bool]$body['cancel'] }
    } else {
        if ($body.PSObject.Properties['shutdownType']) { $shutdownType = [string]$body.shutdownType }
        if ($body.PSObject.Properties['delayMinutes']) { $delayMinutes = [int]$body.delayMinutes }
        if ($body.PSObject.Properties['frequency'])    { $frequency    = [int]$body.frequency }
        if ($body.PSObject.Properties['duration'])     { $duration     = [int]$body.duration }
        if ($body.PSObject.Properties['cancel'])       { $cancel       = [bool]$body.cancel }
    }
    try {
        $r = Send-V6ShutdownBroadcast -ShutdownType $shutdownType -DelayMinutes $delayMinutes -Frequency $frequency -Duration $duration -Cancel $cancel
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}