# -----------------------------------------------------------------------------
# ChatCommands routes — settings for in-game !commands.
#
# GET  /api/gameplay/chat-commands   -> current settings + the kit names to pick
#                                       from, so the UI never invents a package
# PUT  /api/gameplay/chat-commands   -> save settings
#
# Turning the feature ON declares the intercept queue; turning it OFF removes
# it, so a disabled DST is not quietly accumulating a copy of every message
# players type. See lib/ChatCommands.ps1 for why the queue is bounded.
# -----------------------------------------------------------------------------

Register-DuneRoute -Method GET -Path '/api/gameplay/chat-commands' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $state = Read-DuneChatCommandsState
        $ready = Test-DuneChatCommandsReady -State $state

        # Kits come straight from the existing package store - the same list the
        # Players page uses - so the two can never disagree about what exists.
        $packages = @()
        try { $packages = @(Read-DuneItemPackages | ForEach-Object { "$($_.name)" }) } catch {}

        $commands = @{}
        foreach ($k in @($state.commands.Keys)) {
            $entry = @{
                enabled         = [bool]$state.commands[$k].enabled
                cooldownSeconds = [int]$state.commands[$k].cooldownSeconds
            }
            if ($state.commands[$k].maxQty) { $entry['maxQty'] = [int]$state.commands[$k].maxQty }
            $commands[$k] = $entry
        }

        Write-DuneJson -Response $res -Body @{
            ok         = $true
            enabled    = [bool]$state.enabled
            replyTitle = [string]$state.replyTitle
            channels   = @($state.channels)
            commands   = $commands
            packages   = $packages
            teleports  = @(Read-DuneChatTeleports)
            pollSeconds = [int](Get-DuneChatCommandPollSeconds -State $state)
            pollChoices = @($script:DuneChatPollChoices)
            ready      = [bool]$ready.ready
            readyMessage = [string]$ready.message
            lastSeenAt = [string]$state.lastSeenAt
        }

    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Chat command settings load failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/chat-commands/teleports' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not ($body -is [hashtable])) {
            Write-DuneError -Response $res -Status 400 -Message 'Body must be a JSON object.'
            return
        }
        # Keep this name distinct from Invoke-WithDuneLock's own $Name parameter.
        # PowerShell scriptblocks use dynamic scope, so reusing $name here caused
        # every bookmark to be saved as the lock name instead of the admin's name.
        $bookmarkName = [string]$body['name']
        $pawnId = 0L
        if (-not [int64]::TryParse([string]$body['pawn_id'], [ref]$pawnId)) {
            Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'
            return
        }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) {
            Write-DuneError -Response $res -Status 503 -Message $ctx.message
            return
        }
        $result = Invoke-WithDuneLock -Name 'chat-teleport-bookmarks' -Script {
            Save-DuneChatTeleportFromPawn -Ip $ctx.ip -Name $bookmarkName -PawnId $pawnId
        }
        if (-not $result.ok) {
            Write-DuneError -Response $res -Status ([int]$result.status) -Message $result.error
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Teleport bookmark save failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method DELETE -Path '/api/gameplay/chat-commands/teleports' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not ($body -is [hashtable])) {
            Write-DuneError -Response $res -Status 400 -Message 'Body must be a JSON object.'
            return
        }
        $bookmarkName = [string]$body['name']
        $result = Invoke-WithDuneLock -Name 'chat-teleport-bookmarks' -Script {
            Remove-DuneChatTeleport -Name $bookmarkName
        }
        if (-not $result.ok) {
            Write-DuneError -Response $res -Status ([int]$result.status) -Message $result.error
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Teleport bookmark delete failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameplay/chat-commands' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not ($body -is [hashtable])) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must be a JSON object.'
        return
    }
    try {
        $state = Read-DuneChatCommandsState
        $wasEnabled = [bool]$state.enabled

        if ($body.ContainsKey('enabled')) {
            if (-not ($body['enabled'] -is [bool])) {
                Write-DuneError -Response $res -Status 400 -Message 'enabled must be a JSON boolean.'
                return
            }
            $state.enabled = [bool]$body['enabled']
        }
        if ($body.ContainsKey('replyTitle')) {
            $t = "$($body['replyTitle'])".Trim()
            if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
            $state.replyTitle = if ($t) { $t } else { 'Server' }
        }
        if ($body.ContainsKey('pollSeconds')) {
            # Restricted to the offered choices. This sets a permanent CPU load on
            # the game server, so an arbitrary number from a payload is not
            # something to honour blindly.
            $p = 0
            if ([int]::TryParse("$($body['pollSeconds'])", [ref]$p) -and
                ($script:DuneChatPollChoices -contains $p)) {
                $state.pollSeconds = $p
            } else {
                Write-DuneError -Response $res -Status 400 -Message ("pollSeconds must be one of: " + (($script:DuneChatPollChoices) -join ', '))
                return
            }
        }
        if ($body.ContainsKey('channels') -and $null -ne $body['channels']) {            $allowed = @('Proximity', 'Map', 'Faction', 'Guild', 'Party')
            $picked = @(@($body['channels']) | ForEach-Object { "$_" } | Where-Object { $allowed -contains $_ })
            $state.channels = $picked
        }
        if ($body.ContainsKey('commands') -and $body['commands'] -is [hashtable]) {
            foreach ($k in @($body['commands'].Keys)) {
                $name = "$k".ToLowerInvariant()
                # Only ever touch commands DST actually implements - a payload
                # cannot invent a verb that no executor handles.
                if (-not $state.commands.ContainsKey($name)) { continue }
                $incoming = $body['commands'][$k]
                if ($incoming -isnot [hashtable]) { continue }
                if ($incoming.ContainsKey('enabled')) {
                    $state.commands[$name].enabled = [bool]$incoming['enabled']
                }
                if ($incoming.ContainsKey('cooldownSeconds')) {
                    $n = 0
                    if ([int]::TryParse("$($incoming['cooldownSeconds'])", [ref]$n) -and $n -ge 0) {
                        if ($n -gt 2592000) { $n = 2592000 }   # 30 days is plenty
                        $state.commands[$name].cooldownSeconds = $n
                    }
                }
                # Only !item carries a quantity cap, and it is the one command that
                # can produce anything in the game - so the ceiling is enforced here
                # rather than trusted from the payload.
                if ($incoming.ContainsKey('maxQty') -and $name -eq 'item') {
                    $q = 0
                    if ([int]::TryParse("$($incoming['maxQty'])", [ref]$q) -and $q -ge 1) {
                        if ($q -gt 100000) { $q = 100000 }
                        $state.commands[$name].maxQty = $q
                    }
                }
            }
        }

        if (-not (Save-DuneChatCommandsState -State $state)) {
            Write-DuneError -Response $res -Status 500 -Message 'Could not save chat command settings.'
            return
        }

        # Follow the switch through to the broker. Best-effort on purpose: the
        # settings are saved either way, and the scheduler tick re-declares the
        # queue on its next pass if this did not land.
        $queue = @{ ok = $false; skipped = $true }
        if ($wasEnabled -ne $state.enabled) {
            try {
                $ctx = Get-DuneDbContext
                if ($ctx.ok) {
                    $queue = if ($state.enabled) {
                        Initialize-DuneChatCommandQueue -Ip $ctx.ip
                    } else {
                        Remove-DuneChatCommandQueue -Ip $ctx.ip
                    }
                }
            } catch {}
        }

        $ready = Test-DuneChatCommandsReady -State $state
        Write-DuneJson -Response $res -Body @{
            ok           = $true
            enabled      = [bool]$state.enabled
            replyTitle   = [string]$state.replyTitle
            channels     = @($state.channels)
            pollSeconds  = [int](Get-DuneChatCommandPollSeconds -State $state)
            ready        = [bool]$ready.ready
            readyMessage = [string]$ready.message
            queue        = $queue
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Chat command settings save failed: $($_.Exception.Message)"
    }
}
