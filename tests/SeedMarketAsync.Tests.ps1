# Seed market async launcher contract.
#
# The launcher writes a `seed_progress` block into the bot state file and
# spins a runspace. Tests here cover the synchronous half — the state-file
# gate that prevents a second seed from launching while one is in flight,
# and the structure of the progress object the UI consumes. The actual
# runspace work is exercised by SeedMarket.Tests.ps1 + manual install tests.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayBot.ps1'

    # Redirect the state file to a per-run temp path so we never touch the
    # user's real DuneServer\gameplay-bot-state.json.
    $script:StateDir  = Join-Path $env:TEMP ("dune-bot-state-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    $script:StatePath = Join-Path $script:StateDir 'gameplay-bot-state.json'
    function Get-DuneBotStatePath { $script:StatePath }
}

AfterAll {
    if ($script:StateDir -and (Test-Path -LiteralPath $script:StateDir)) {
        Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Start-DuneBotSeedAsync — state-file gate' -Tag 'MarketBot' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    }

    It 'refuses to launch when seed_progress.running is true' {
        # Pre-stamp an in-flight progress block.
        $st = Read-DuneBotState
        $st.seed_progress = @{
            phase   = 'writing'
            running = $true
            started = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-DuneBotState -State $st

        $r = Start-DuneBotSeedAsync -ServerDir 'C:\does-not-matter'
        $r.ok      | Should -Be $false
        $r.running | Should -Be $true
        $r.error   | Should -Match 'already in progress'
    }

    It 'rejects an invalid ServerDir cleanly (no runspace leak)' {
        $r = Start-DuneBotSeedAsync -ServerDir 'Z:\definitely\not\a\real\path-12345'
        $r.ok    | Should -Be $false
        $r.error | Should -Match 'server dir not found'
        # And it must NOT have stamped running=true since it bailed before that.
        $st = Read-DuneBotState
        if ($st.seed_progress) {
            [bool]$st.seed_progress.running | Should -Be $false
        }
    }

    It 'allows a launch when seed_progress.running is false (finished prior run)' {
        $st = Read-DuneBotState
        $st.seed_progress = @{
            phase    = 'done'
            running  = $false
            finished = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-DuneBotState -State $st

        # We can't actually spawn the runspace cleanly in-test (it would
        # dot-source the real server libs), so we just verify the GATE
        # passes. The function will then try to spin a runspace; on success
        # it returns ok=$true, on bootstrap fail it returns ok=$false with
        # a NON-"already in progress" error. Either way the test asserts
        # that we got PAST the gate (i.e. not the "already in progress"
        # rejection).
        $r = Start-DuneBotSeedAsync -ServerDir $script:StateDir
        ($r.error -match 'already in progress') | Should -Be $false
    }
}

Describe 'Read-DuneBotState — seed_progress field' -Tag 'MarketBot' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    }

    It 'defaults seed_progress to $null when no state file exists' {
        $st = Read-DuneBotState
        $st.Contains('seed_progress') | Should -Be $true
        $st.seed_progress | Should -BeNullOrEmpty
    }

    It 'round-trips a seed_progress hashtable through save/read' {
        $st = Read-DuneBotState
        $st.seed_progress = @{
            phase        = 'writing'
            running      = $true
            chunks_done  = 3
            chunks_total = 7
            inserted     = 612
        }
        Save-DuneBotState -State $st

        $st2 = Read-DuneBotState
        $st2.seed_progress | Should -Not -BeNullOrEmpty
        [string]$st2.seed_progress.phase  | Should -Be 'writing'
        [bool]$st2.seed_progress.running  | Should -Be $true
        [int]$st2.seed_progress.chunks_done  | Should -Be 3
        [int]$st2.seed_progress.chunks_total | Should -Be 7
        [int]$st2.seed_progress.inserted     | Should -Be 612
    }
}

Describe 'Clear-DuneBotError' -Tag 'MarketBot' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    }

    It 'zeros last_error and error_count' {
        $st = Read-DuneBotState
        $st.last_error  = 'chunk 1 failed: ssh timed out after 300s'
        $st.error_count = 7
        Save-DuneBotState -State $st

        $r = Clear-DuneBotError
        $r.ok | Should -Be $true

        $after = Read-DuneBotState
        [string]$after.last_error  | Should -Be ''
        [int]$after.error_count    | Should -Be 0
    }

    It 'is idempotent on an already-clean state' {
        $r1 = Clear-DuneBotError
        $r2 = Clear-DuneBotError
        $r1.ok | Should -Be $true
        $r2.ok | Should -Be $true
    }
}

Describe 'Start-DuneBotSeedAsync — fresh launch clears stale errors' -Tag 'MarketBot' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    }

    It 'wipes last_error / error_count when stamping seed_progress.starting' {
        $st = Read-DuneBotState
        $st.last_error  = 'old chunk failure'
        $st.error_count = 3
        Save-DuneBotState -State $st

        # Pass a VALID ServerDir so the synchronous stamp happens. The spawned
        # runspace will subsequently fail because there's no lib subdir, but
        # that's irrelevant — we only care that the synchronous error-clear
        # part of the function ran before returning. The runspace runs in
        # another thread and only touches seed_progress (never last_error).
        [void](Start-DuneBotSeedAsync -ServerDir $script:StateDir)

        $after = Read-DuneBotState
        [string]$after.last_error | Should -Be ''
        [int]$after.error_count   | Should -Be 0
    }
}
