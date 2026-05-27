# Shared mutation guard — refuses to touch live DB state while players are
# connected. Pulled out of Characters.ps1 so any future route can reuse it.
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
