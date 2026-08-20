# WelcomeBack.ps1 - hand a returning player an item package when they come back.
#
# Replaces the three `dw.ReturningPlayer.*` console variables, which were removed
# in 13.4.0 because a Funcom developer confirmed they do nothing on a self-hosted
# server: the reward packs are granted by Funcom's own service, so a self-host has
# nothing to hand out no matter how they are configured. This does the same job
# with parts a self-host actually controls - the admin's own item packages.
#
# ---------------------------------------------------------------------------
# Why the trigger is a poll and not an event
# ---------------------------------------------------------------------------
# There is no login hook to subscribe to. But `dune.player_state.last_login_time`
# is stamped at login (verified on a live server: a session showed login 00:32
# against last activity 01:19), so a login is visible as that column moving
# forward. Polling it on the existing scheduler tick needs no new plumbing.
#
# The absence is measured between a player's PREVIOUS login and the one that just
# happened - not against "now". That single choice is what makes this fire exactly
# once per absence:
#
#     P = the last login DST recorded for them    L = last_login_time right now
#     no P    -> record P = L, grant nothing        (new player, or first run)
#     L > P   -> they just logged in; absence = L - P
#                absence >= DaysAway  ->  give the package
#     always  -> record P = L
#
# Consequences worth keeping:
#   * It cannot re-fire while they stay logged in, because L stops moving.
#   * It cannot fire twice for one absence, because P advances to L immediately.
#   * There is no "already claimed" flag to reset, get stale, or migrate - a
#     second absence is simply a second gap, and qualifies on its own merits.
#   * Enabling the feature cannot mass-grant to a whole player base, because the
#     first pass only seeds P. Someone who has been away a year gets their package
#     on their next login, which is the intent, rather than instantly while they
#     are still offline and unable to see it.
#
# Granting goes through the existing bulk give path, which routes an online player
# to the live RMQ path (instant, no relog). Since the trigger IS the login, the
# player is nearly always online at that moment, so this normally lands in front
# of them while they are standing there.
# ---------------------------------------------------------------------------

function Get-DuneWelcomeBackStatePath {
    $dir = if ($env:APPDATA) { Join-Path $env:APPDATA 'DuneServer' } else { $env:TEMP }
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }
    return (Join-Path $dir 'welcome-back.json')
}

# Off, with no package chosen. Both have to be set deliberately - see
# Test-DuneWelcomeBackReady for why "on with no package" is treated as an error
# rather than quietly doing nothing.
function New-DuneWelcomeBackDefault {
    return @{
        enabled   = $false
        packageId = ''
        daysAway  = 7
        announce  = $false
        # players: accountId -> @{ lastLoginSeen; lastGrantedAt; grants; name }
        players   = @{}
        # newest-first ring of what was handed out, so the admin can see the
        # feature working without going to the game logs
        recent    = @()
        lastRunAt = ''
        lastError = ''
    }
}

$script:DuneWelcomeBackMaxRecent = 25
# 0 is deliberately allowed and means "every login qualifies" - any gap at all is
# >= 0. Useful for testing without waiting a week, and a legitimate setting for a
# server that wants a package on every return. It is still bounded by the login
# transition, so it cannot re-fire while a player stays online, and the first
# pass still only seeds, so it cannot mass-grant on enable.
$script:DuneWelcomeBackMinDays   = 0
$script:DuneWelcomeBackMaxDays   = 365

# Single place that decides whether the feature may run. "Enabled but no package"
# is surfaced rather than swallowed: an admin who flipped it on and expected
# something to happen deserves to be told why nothing did.
function Test-DuneWelcomeBackReady {
    param([hashtable]$State)
    if (-not $State) { return @{ ready = $false; reason = 'no-state' } }
    if (-not $State.enabled) { return @{ ready = $false; reason = 'disabled' } }
    if ([string]::IsNullOrWhiteSpace([string]$State.packageId)) {
        return @{ ready = $false; reason = 'no-package'
                  message = 'Choose the package to give, or nothing will be handed out.' }
    }
    $pkg = Get-DuneWelcomeBackPackage -PackageId $State.packageId
    if (-not $pkg) {
        return @{ ready = $false; reason = 'package-missing'
                  message = 'The chosen package no longer exists. Pick another one.' }
    }
    if (@($pkg.items).Count -eq 0) {
        return @{ ready = $false; reason = 'package-empty'
                  message = "Package '$($pkg.name)' has no items in it." }
    }
    return @{ ready = $true }
}

# Resolve against the shared package store so this and the Players page can never
# disagree about what a package contains.
function Get-DuneWelcomeBackPackage {
    param([string]$PackageId)
    if ([string]::IsNullOrWhiteSpace($PackageId)) { return $null }
    if (-not (Get-Command Read-DuneItemPackages -ErrorAction SilentlyContinue)) { return $null }
    try {
        foreach ($p in @(Read-DuneItemPackages)) {
            if ("$($p.id)" -eq "$PackageId") { return $p }
        }
    } catch {}
    return $null
}

function Read-DuneWelcomeBackState {
    $path = Get-DuneWelcomeBackStatePath
    $def = New-DuneWelcomeBackDefault
    if (-not (Test-Path -LiteralPath $path)) { return $def }
    try {
        $obj = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
        $out = $def
        if ($null -ne $obj.enabled)  { $out.enabled = [bool]$obj.enabled }
        if ($null -ne $obj.announce) { $out.announce = [bool]$obj.announce }
        if ($obj.packageId) { $out.packageId = [string]$obj.packageId }
        if ($null -ne $obj.daysAway) {
            $d = 0
            if ([int]::TryParse("$($obj.daysAway)", [ref]$d)) { $out.daysAway = $d }
        }
        if ($obj.lastRunAt) { $out.lastRunAt = [string]$obj.lastRunAt }
        if ($obj.lastError) { $out.lastError = [string]$obj.lastError }
        if ($obj.players) {
            $ledger = @{}
            foreach ($p in $obj.players.PSObject.Properties) {
                $v = $p.Value
                $grants = 0
                if ($null -ne $v.grants) { [void][int]::TryParse("$($v.grants)", [ref]$grants) }
                $ledger["$($p.Name)"] = @{
                    lastLoginSeen = [string]$v.lastLoginSeen
                    lastGrantedAt = [string]$v.lastGrantedAt
                    grants        = $grants
                    name          = [string]$v.name
                }
            }
            $out.players = $ledger
        }
        if ($obj.recent) {
            $r = New-Object System.Collections.Generic.List[object]
            foreach ($e in @($obj.recent)) {
                $r.Add(@{
                    at       = [string]$e.at
                    name     = [string]$e.name
                    daysAway = [double]$e.daysAway
                    package  = [string]$e.package
                    ok       = [bool]$e.ok
                    message  = [string]$e.message
                })
            }
            $out.recent = @($r.ToArray())
        }
        return $out
    } catch {
        return $def
    }
}

function Save-DuneWelcomeBackState {
    param([hashtable]$State)
    $path = Get-DuneWelcomeBackStatePath
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Set-DuneWelcomeBackDaysAway {
    param([hashtable]$State, $Value)
    $d = 0
    if (-not [int]::TryParse("$Value", [ref]$d)) { return $State }
    if ($d -lt $script:DuneWelcomeBackMinDays) { $d = $script:DuneWelcomeBackMinDays }
    if ($d -gt $script:DuneWelcomeBackMaxDays) { $d = $script:DuneWelcomeBackMaxDays }
    $State.daysAway = $d
    return $State
}

# -----------------------------------------------------------------------------
# The decision, kept pure so it is directly testable without a database. Takes
# the rows as DST already reads them plus the current ledger, and returns what
# ought to happen. Nothing in here talks to the server.
# -----------------------------------------------------------------------------
function Get-DuneWelcomeBackPlan {
    param(
        [object[]]$Players,
        [hashtable]$Ledger,
        [int]$DaysAway = 7
    )
    $grants = New-Object System.Collections.Generic.List[object]
    $seeded = New-Object System.Collections.Generic.List[object]
    $nextLedger = @{}
    if ($Ledger) {
        # Copy each ENTRY, not just the key. Assigning $Ledger[$k] straight across
        # would share the inner hashtable, so advancing lastLoginSeen below would
        # reach back and mutate the caller's ledger - making a second call on the
        # same input silently disagree with the first.
        foreach ($k in @($Ledger.Keys)) {
            $src = $Ledger[$k]
            $nextLedger[$k] = @{
                lastLoginSeen = [string]$src.lastLoginSeen
                lastGrantedAt = [string]$src.lastGrantedAt
                grants        = [int]$src.grants
                name          = [string]$src.name
            }
        }
    }

    foreach ($p in @($Players)) {
        if ($null -eq $p) { continue }
        $key = "$($p.account_id)"
        if ([string]::IsNullOrWhiteSpace($key) -or $key -eq '0') { continue }

        $loginRaw = [string]$p.last_login
        if ([string]::IsNullOrWhiteSpace($loginRaw)) { continue }
        $login = [datetime]::MinValue
        if (-not [datetime]::TryParse($loginRaw, [ref]$login)) { continue }
        $login = $login.ToUniversalTime()

        $entry = $nextLedger[$key]
        if (-not $entry) {
            $entry = @{ lastLoginSeen = ''; lastGrantedAt = ''; grants = 0; name = [string]$p.name }
        }
        $entry.name = [string]$p.name

        $prevRaw = [string]$entry.lastLoginSeen
        $prev = [datetime]::MinValue
        $hasPrev = $prevRaw -and [datetime]::TryParse($prevRaw, [ref]$prev)
        if ($hasPrev) { $prev = $prev.ToUniversalTime() }

        if (-not $hasPrev) {
            # First time we have ever seen this player. Record where they are and
            # grant nothing - we have no idea how long they were away, and
            # guessing would either mass-grant on enable or punish a newcomer.
            $entry.lastLoginSeen = $login.ToString('o')
            $nextLedger[$key] = $entry
            $seeded.Add(@{ account_id = $key; name = [string]$p.name })
            continue
        }

        if ($login -gt $prev) {
            $away = ($login - $prev).TotalDays
            if ($away -ge $DaysAway) {
                $grants.Add(@{
                    account_id = $key
                    name       = [string]$p.name
                    pawn_id    = [int64]$p.pawn_id
                    daysAway   = [math]::Round($away, 2)
                })
            }
            # Advance regardless of whether it qualified, so a short hop can never
            # be re-evaluated and a qualifying one can never pay out twice.
            $entry.lastLoginSeen = $login.ToString('o')
        }
        $nextLedger[$key] = $entry
    }

    return @{
        grants = @($grants.ToArray())
        seeded = @($seeded.ToArray())
        ledger = $nextLedger
    }
}

# -----------------------------------------------------------------------------
# Live side.
# -----------------------------------------------------------------------------

# Everyone who has ever played, with the two facts the plan needs. Deliberately
# not filtered to online players: the login we care about may have happened
# between ticks and them logging straight back out does not make the absence
# untrue - the package still lands via the SQL path and is there when they return.
function Get-DuneWelcomeBackPlayers {
    param([string]$Ip)
    $sql = @'
SELECT COALESCE(ps.account_id::text, '')                                   AS account_id,
       COALESCE(ps.character_name, '')                                     AS name,
       COALESCE(ps.player_pawn_id::text, '0')                              AS pawn_id,
       COALESCE(to_char(ps.last_login_time AT TIME ZONE 'UTC',
                        'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')                 AS last_login
FROM dune.player_state ps
WHERE ps.account_id IS NOT NULL
  AND ps.last_login_time IS NOT NULL
ORDER BY ps.last_login_time DESC;
'@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        $pawn = 0L
        [void][int64]::TryParse("$($row['pawn_id'])", [ref]$pawn)
        $list.Add(@{
            account_id = [string]$row['account_id']
            name       = [string]$row['name']
            pawn_id    = $pawn
            last_login = [string]$row['last_login']
        })
    }
    return @{ ok = $true; players = @($list.ToArray()) }
}

function Invoke-DuneWelcomeBackGrant {
    param(
        [string]$Ip,
        [hashtable]$Grant,
        $Package
    )
    if ([int64]$Grant.pawn_id -le 0) {
        return @{ ok = $false; message = "No character to give to (pawn id missing)." }
    }
    if (-not (Get-Command Invoke-DunePlayerGiveItemsBulk -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; message = 'Give-items helper unavailable.' }
    }
    try {
        $r = Invoke-DunePlayerGiveItemsBulk -Ip $Ip -PawnId ([int64]$Grant.pawn_id) `
             -Items @($Package.items) -AllowOverflow $true
        return @{ ok = [bool]$r.ok; message = [string]$r.message }
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Send-DuneWelcomeBackAnnounce {
    param([hashtable]$Grant, $Package)
    if (-not (Get-Command Send-V6GenericBroadcast -ErrorAction SilentlyContinue)) { return }
    $who = [string]$Grant.name
    if (-not $who) { return }
    try {
        [void](Send-V6GenericBroadcast -Title 'Welcome Back' `
              -Body "$who has been away and received $($Package.name)." -DurationSec 10)
    } catch {}
}

# -----------------------------------------------------------------------------
# Tick. Silent no-op unless the admin turned this on AND picked a package.
# Rides the 30s restart-scheduler loop, but only touches the database every few
# minutes - a login is not urgent enough to justify a query every half minute,
# and the absence maths is unaffected by arriving a little late.
# -----------------------------------------------------------------------------
$script:DuneWelcomeBackLastRun = [datetime]::MinValue
$script:DuneWelcomeBackIntervalMin = 5
$script:DuneNativeWelcomeBackCleanupLastRun = [datetime]::MinValue

function Invoke-DuneNativeWelcomeBackCleanup {
    param([string]$Ip)
    $sql = @'
UPDATE dune.encrypted_player_state
SET last_returning_player_awarded_time = now(),
    last_returning_player_event_time = NULL
WHERE online_status::text = 'Offline'
  AND last_returning_player_event_time IS NOT NULL
RETURNING account_id::text;
'@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 5000 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; cleaned = 0; error = $r.error } }
    return @{ ok = $true; cleaned = [int]$r.rowCount }
}

function Invoke-DuneNativeWelcomeBackCleanupTick {
    param([switch]$Force)
    if (-not $Force) {
        $since = ([datetime]::UtcNow - $script:DuneNativeWelcomeBackCleanupLastRun).TotalMinutes
        if ($since -lt $script:DuneWelcomeBackIntervalMin) {
            return @{ ok = $true; cleaned = 0; message = 'throttled' }
        }
    }
    $script:DuneNativeWelcomeBackCleanupLastRun = [datetime]::UtcNow
    if (-not (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; cleaned = 0; error = 'db context helper unavailable' }
    }
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { return @{ ok = $false; cleaned = 0; error = $ctx.message } }
    return Invoke-DuneNativeWelcomeBackCleanup -Ip $ctx.ip
}

function Invoke-DuneWelcomeBackTick {
    param([switch]$Force)
    try {
        # Funcom's native returning-player service cannot deliver award packs to
        # self-hosted servers. Failed claims leave an event latched and show the
        # empty popup again on every login. Mark only offline pending characters
        # handled; online state remains untouched and the update is idempotent.
        $nativeCleanup = Invoke-DuneNativeWelcomeBackCleanupTick -Force:$Force
        if (-not $nativeCleanup.ok -and (Get-Command Write-DuneLog -ErrorAction SilentlyContinue)) {
            try { Write-DuneLog "native welcome-back cleanup failed: $($nativeCleanup.error)" 'WARN' } catch {}
        }

        $state = Read-DuneWelcomeBackState
        if (-not $state.enabled) {
            return @{ ok = $true; acted = ([int]$nativeCleanup.cleaned -gt 0)
                      cleanedNative = [int]$nativeCleanup.cleaned; message = 'disabled' }
        }

        if (-not $Force) {
            $since = ([datetime]::UtcNow - $script:DuneWelcomeBackLastRun).TotalMinutes
            if ($since -lt $script:DuneWelcomeBackIntervalMin) {
                return @{ ok = $true; acted = $false; message = 'throttled' }
            }
        }
        $script:DuneWelcomeBackLastRun = [datetime]::UtcNow

        $ready = Test-DuneWelcomeBackReady -State $state
        if (-not $ready.ready) {
            # Persist the reason so the card can show it without the admin having
            # to go looking in a log for why nothing is happening.
            if ($state.lastError -ne [string]$ready.message) {
                $state.lastError = [string]$ready.message
                [void](Save-DuneWelcomeBackState -State $state)
            }
            return @{ ok = $false; acted = $false; message = [string]$ready.message }
        }

        if (-not (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue)) {
            return @{ ok = $false; acted = $false; message = 'db context helper unavailable' }
        }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { return @{ ok = $false; acted = $false; message = $ctx.message } }

        $fetch = Get-DuneWelcomeBackPlayers -Ip $ctx.ip
        if (-not $fetch.ok) {
            $state.lastError = "Could not read players: $($fetch.error)"
            [void](Save-DuneWelcomeBackState -State $state)
            return @{ ok = $false; acted = $false; message = $state.lastError }
        }

        $package = Get-DuneWelcomeBackPackage -PackageId $state.packageId
        $plan = Get-DuneWelcomeBackPlan -Players $fetch.players -Ledger $state.players -DaysAway ([int]$state.daysAway)

        $recent = New-Object System.Collections.Generic.List[object]
        $granted = 0
        foreach ($g in @($plan.grants)) {
            $res = Invoke-DuneWelcomeBackGrant -Ip $ctx.ip -Grant $g -Package $package
            $stamp = ([datetime]::UtcNow).ToString('o')
            if ($res.ok) {
                $granted++
                $entry = $plan.ledger["$($g.account_id)"]
                if ($entry) {
                    $entry.lastGrantedAt = $stamp
                    $entry.grants = [int]$entry.grants + 1
                }
                if ($state.announce) { Send-DuneWelcomeBackAnnounce -Grant $g -Package $package }
            } else {
                # A failed give must NOT hold the ledger back - if it did, the same
                # broken grant would be retried on every tick forever. It is
                # recorded in `recent` instead so the admin can see and re-give it.
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    try { Write-DuneLog "welcome back: give failed for $($g.name): $($res.message)" 'WARN' } catch {}
                }
            }
            $recent.Add(@{
                at = $stamp; name = [string]$g.name; daysAway = [double]$g.daysAway
                package = [string]$package.name; ok = [bool]$res.ok; message = [string]$res.message
            })
        }

        $state.players = $plan.ledger
        if ($recent.Count -gt 0) {
            $merged = @($recent.ToArray()) + @($state.recent)
            if ($merged.Count -gt $script:DuneWelcomeBackMaxRecent) {
                $merged = $merged[0..($script:DuneWelcomeBackMaxRecent - 1)]
            }
            $state.recent = @($merged)
        }
        $state.lastRunAt = ([datetime]::UtcNow).ToString('o')
        $state.lastError = ''
        [void](Save-DuneWelcomeBackState -State $state)

        return @{
            ok = $true; acted = ($granted -gt 0)
            granted = $granted; seeded = @($plan.seeded).Count
            message = "Welcome back: $granted granted, $(@($plan.seeded).Count) newly tracked."
        }
    } catch {
        return @{ ok = $false; acted = $false; message = $_.Exception.Message }
    }
}
