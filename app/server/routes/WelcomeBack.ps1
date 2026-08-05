# WelcomeBack routes - settings for the returning-player package.
#
# GET  /api/gameplay/welcome-back  -> settings, the packages to pick from, and
#                                     what has recently been handed out
# PUT  /api/gameplay/welcome-back  -> save settings
#
# See lib/WelcomeBack.ps1 for why the trigger is a login-transition poll and why
# enabling this cannot mass-grant to an existing player base.

Register-DuneRoute -Method GET -Path '/api/gameplay/welcome-back' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $state = Read-DuneWelcomeBackState
        $ready = Test-DuneWelcomeBackReady -State $state

        # Offer the same package store the Players page uses, so the picker can
        # never point at something that does not exist.
        $packages = @()
        try {
            $packages = @(Read-DuneItemPackages | ForEach-Object {
                @{ id = "$($_.id)"; name = "$($_.name)"; itemCount = @($_.items).Count }
            })
        } catch {}

        Write-DuneJson -Response $res -Body @{
            ok           = $true
            enabled      = [bool]$state.enabled
            packageId    = [string]$state.packageId
            daysAway     = [int]$state.daysAway
            announce     = [bool]$state.announce
            packages     = $packages
            recent       = @($state.recent)
            tracked      = @($state.players.Keys).Count
            lastRunAt    = [string]$state.lastRunAt
            lastError    = [string]$state.lastError
            ready        = [bool]$ready.ready
            readyMessage = [string]$ready.message
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Welcome back settings load failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameplay/welcome-back' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not ($body -is [hashtable])) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must be a JSON object.'
        return
    }
    try {
        $state = Read-DuneWelcomeBackState
        $wasEnabled = [bool]$state.enabled

        if ($body.ContainsKey('enabled')) {
            if (-not ($body['enabled'] -is [bool])) {
                Write-DuneError -Response $res -Status 400 -Message 'enabled must be a JSON boolean.'
                return
            }
            $state.enabled = [bool]$body['enabled']
        }
        if ($body.ContainsKey('announce')) {
            $state.announce = [bool]$body['announce']
        }
        if ($body.ContainsKey('packageId')) {
            $id = "$($body['packageId'])".Trim()
            # Only accept a package that actually exists, so the feature can never
            # be left pointing at a deleted one and silently doing nothing.
            if ($id -and -not (Get-DuneWelcomeBackPackage -PackageId $id)) {
                Write-DuneError -Response $res -Status 400 -Message 'That package does not exist.'
                return
            }
            $state.packageId = $id
        }
        if ($body.ContainsKey('daysAway')) {
            $state = Set-DuneWelcomeBackDaysAway -State $state -Value $body['daysAway']
        }

        if (-not (Save-DuneWelcomeBackState -State $state)) {
            Write-DuneError -Response $res -Status 500 -Message 'Could not save welcome back settings.'
            return
        }

        # Turning it ON runs one pass immediately, which seeds the ledger with
        # everyone's current login. That is the pass that makes "enable" safe:
        # without it the first scheduled tick would still only seed, but the
        # admin would have no signal that anything happened.
        $seeded = 0
        if (-not $wasEnabled -and $state.enabled) {
            try {
                $r = Invoke-DuneWelcomeBackTick -Force
                if ($null -ne $r.seeded) { $seeded = [int]$r.seeded }
            } catch {}
            $state = Read-DuneWelcomeBackState
        }

        $ready = Test-DuneWelcomeBackReady -State $state
        Write-DuneJson -Response $res -Body @{
            ok           = $true
            enabled      = [bool]$state.enabled
            packageId    = [string]$state.packageId
            daysAway     = [int]$state.daysAway
            announce     = [bool]$state.announce
            tracked      = @($state.players.Keys).Count
            seeded       = $seeded
            ready        = [bool]$ready.ready
            readyMessage = [string]$ready.message
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Welcome back settings save failed: $($_.Exception.Message)"
    }
}
