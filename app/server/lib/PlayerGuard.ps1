# Shared mutation guard — refuses to touch live DB state while players are
# connected. Lives in its own file so any future route can reuse it.
#
# Background: on 2025-05-27 a player's crafting recipes were wiped from 482 to
# 29 entries. Root cause was a Funcom game-side partial-load race triggered by
# pod-state instability — an actor loaded with an empty m_PersistentName, then
# the game auto-saved that empty state back over the real character. The tool
# didn't cause it, but writing to actors.properties while the player is in the
# middle of logging in or out can race the same way and corrupt their data.
#
# Bypass with ?force=1|true|yes once the operator confirms in the UI.
# Returns $true to proceed, $false if a 409 was written and the handler should
# return immediately. Fails open on DB errors so a transient psql/SSH failure
# doesn't lock all editing.

function Test-DunePlayerGuard {
    param($Req, $Res, [string]$Ip)

    try {
        $f = $null
        try { $f = $Req.QueryString['force'] } catch {}
        if ($f -and ($f -eq '1' -or $f -eq 'true' -or $f -eq 'yes')) { return $true }
    } catch {}

    $players = @()
    try { $players = @(Get-V6OnlinePlayers -Ip $Ip) } catch { return $true }
    if ($players.Count -eq 0) { return $true }

    $names = @($players | ForEach-Object {
        if ($_.name -and "$($_.name)".Trim()) { "$($_.name)" } else { "id=$($_.id)" }
    })
    $body = @{
        ok            = $false
        conflict      = 'players_online'
        playersOnline = $players.Count
        playerNames   = $names
        players       = @($players | ForEach-Object {
            @{
                id     = "$($_.id)"
                name   = "$($_.name)"
                status = "$($_.status)"
            }
        })
        message       = "$($players.Count) player(s) currently connected — saving while they're online can corrupt their characters."
    }
    Write-DuneJson -Response $Res -Status 409 -Body $body
    return $false
}

function Test-DuneDisruptiveActionGuard {
    param(
        $Req,
        $Res,
        [string]$Ip,
        [Parameter(Mandatory)][string]$Action
    )

    $force = $false
    try {
        $value = $Req.QueryString['force']
        $force = ($value -in @('1','true','yes'))
    } catch {}
    if ($force) { return $true }

    if ([string]::IsNullOrWhiteSpace($Ip)) {
        try {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) { $Ip = [string]$ctx.ip }
        } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($Ip)) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "player safety verification failed before ${Action}: context_unavailable (no VM/database address)" 'WARN'
        }
        Write-DuneJson -Response $Res -Status 409 -Body @{
            ok                  = $false
            conflict            = 'player_status_unknown'
            verificationFailure = 'context_unavailable'
            playersOnline       = $null
            playerNames         = @()
            players             = @()
            message             = "DST could not verify whether players are online before $Action. The running VM or database address is unavailable."
        }
        return $false
    }

    try {
        $players = @(Get-V6OnlinePlayersStrict -Ip $Ip)
    } catch {
        $failure = 'server_error'
        if ($_.Exception.Data -and $_.Exception.Data.Contains('DunePlayerVerificationFailure')) {
            $failure = [string]$_.Exception.Data['DunePlayerVerificationFailure']
        }
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "player safety verification failed before ${Action}: $failure ($($_.Exception.Message))" 'WARN'
        }
        Write-DuneJson -Response $Res -Status 409 -Body @{
            ok                  = $false
            conflict            = 'player_status_unknown'
            verificationFailure = $failure
            playersOnline       = $null
            playerNames         = @()
            players             = @()
            message             = "DST could not verify whether players are online before $Action. $($_.Exception.Message)"
        }
        return $false
    }
    if ($players.Count -eq 0) { return $true }

    $names = @($players | ForEach-Object {
        if ($_.name -and "$($_.name)".Trim()) { "$($_.name)" } else { "id=$($_.id)" }
    })
    Write-DuneJson -Response $Res -Status 409 -Body @{
        ok            = $false
        conflict      = 'players_online'
        playersOnline = $players.Count
        playerNames   = $names
        players       = @($players | ForEach-Object {
            @{
                id     = "$($_.id)"
                name   = "$($_.name)"
                status = "$($_.status)"
            }
        })
        message       = "$($players.Count) player(s) currently connected. $Action will disconnect them."
    }
    return $false
}
