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
            $commands[$k] = @{
                enabled         = [bool]$state.commands[$k].enabled
                cooldownSeconds = [int]$state.commands[$k].cooldownSeconds
            }
        }

        Write-DuneJson -Response $res -Body @{
            ok         = $true
            enabled    = [bool]$state.enabled
            replyTitle = [string]$state.replyTitle
            channels   = @($state.channels)
            commands   = $commands
            packages   = $packages
            ready      = [bool]$ready.ready
            readyMessage = [string]$ready.message
            lastSeenAt = [string]$state.lastSeenAt
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Chat command settings load failed: $($_.Exception.Message)"
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
        if ($body.ContainsKey('channels') -and $null -ne $body['channels']) {
            $allowed = @('Proximity', 'Map', 'Faction', 'Guild', 'Party')
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
            ready        = [bool]$ready.ready
            readyMessage = [string]$ready.message
            queue        = $queue
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Chat command settings save failed: $($_.Exception.Message)"
    }
}
