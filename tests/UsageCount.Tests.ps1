BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'UsageCount.ps1'
    Import-DstLib 'Config.ps1'
}

Describe 'Optional anonymous installation presence' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $caseRoot)
        $script:configPath = Join-Path $caseRoot 'dune-server.config'
        $script:dataRoot = Join-Path $caseRoot 'usage-count'
        Mock Send-DuneUsageRequest {}
    }
    It 'defaults to enabled and persists an explicit opt-out through other config saves' {
        Test-DuneUsageCountEnabled $configPath | Should -BeTrue
        Set-Content $configPath 'AnonymousUsageEnabled=false'
        $script:DuneConfigFile = $configPath
        Save-DuneConfig @{ DbPort = '15432' } | Out-Null
        Test-DuneUsageCountEnabled $configPath | Should -BeFalse
    }
    It 'preserves the completed installer choice receipt through config saves' {
        Set-Content $configPath "AnonymousUsageEnabled=false`nUsageCountChoiceVersion=1"
        $script:DuneConfigFile = $configPath
        Save-DuneConfig @{ DbPort = '15432' } | Out-Null
        $saved = Get-Content $configPath -Raw
        $saved | Should -Match '(?m)^UsageCountChoiceVersion=1\s*$'
        Test-DuneUsageCountEnabled $configPath | Should -BeFalse
    }
    It 'does not create an identity or send anything when disabled from the start' {
        Set-Content $configPath 'AnonymousUsageEnabled=false'
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 100
        Test-Path $dataRoot | Should -BeFalse
        Should -Invoke Send-DuneUsageRequest -Times 0
    }
    It 'sends only a random ID, edition and sanitized app version with a generated token' {
        Set-Content $configPath "ServerName=Private`nFlsToken=never-send`nAnonymousUsageEnabled=true"
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition docker -Version 1.0.7 -Now 100
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Payload.Count -eq 3 -and $Payload.edition -eq 'docker' -and
            $Payload.version -eq '1.0.7' -and $Payload.id -match '^[a-f0-9-]{36}$' -and $Secret -match '^[a-f0-9]{64}$'
        }
        $status = Get-Content (Join-Path $dataRoot 'status.json') -Raw
        $status | Should -Not -Match 'never-send|Private|secret|[a-f0-9]{64}'
    }
    It 'reuses the installation identity across app versions and limits repeat requests' {
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 100
        $identity = Get-Content (Join-Path $dataRoot 'identity.json') -Raw
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.10 -Now 101
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.10 -Now 22000
        (Get-Content (Join-Path $dataRoot 'identity.json') -Raw) | Should -Be $identity
        Should -Invoke Send-DuneUsageRequest -Times 2 -Exactly
    }
    It 'withdraws once on opt-out and resumes with the same identity on opt-in' {
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition docker -Version 1.0.7 -Now 100
        $identity = Read-DuneUsageJson (Join-Path $dataRoot 'identity.json')
        Set-Content $configPath 'AnonymousUsageEnabled=false'
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition docker -Version 1.0.7 -Now 101
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition docker -Version 1.0.7 -Now 102
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Payload.Count -eq 1 -and $Payload.id -eq $identity.id
        }
        Set-Content $configPath 'AnonymousUsageEnabled=true'
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition docker -Version 1.0.7 -Now 103
        (Read-DuneUsageJson (Join-Path $dataRoot 'identity.json')).id | Should -Be $identity.id
        Should -Invoke Send-DuneUsageRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }
    It 'contains service errors, hides response details and backs off' {
        Mock Send-DuneUsageRequest { throw 'Secret response token=do-not-retain' }
        { Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 100 } | Should -Not -Throw
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 101
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly
        (Get-Content (Join-Path $dataRoot 'status.json') -Raw) | Should -Not -Match 'do-not-retain|token='
    }
    It 'does not transmit an arbitrary development path as the version' {
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 'C:/private/source' -Now 100
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly -ParameterFilter { $Payload.version -eq 'unknown' }
    }
    It 'retains four-part Windows release versions' {
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9.1 -Now 100
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly -ParameterFilter { $Payload.version -eq '16.7.9.1' }
    }
    It 'supports a forced refresh before the six-hour deadline without overriding opt-out' {
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 100
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 101 -Force
        Should -Invoke Send-DuneUsageRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Set-Content $configPath 'AnonymousUsageEnabled=false'
        Invoke-DuneUsageCountTick -ConfigPath $configPath -DataRoot $dataRoot -Edition windows -Version 16.7.9 -Now 102 -Force
        Should -Invoke Send-DuneUsageRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Send-DuneUsageRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }
    It 'shuts down while waiting for HTTP readiness without sending a report' {
        $ready = [Threading.ManualResetEventSlim]::new($false)
        $script:DuneConfigFile = $configPath
        $script:DuneToolVersion = '16.7.9'
        Start-DuneUsageCountReporter -ServerDir (Join-Path (Get-DstRepoRoot) 'app/server') -HttpReady $ready
        $script:DuneUsageCountWorker | Should -Not -BeNullOrEmpty
        Stop-DuneUsageCountReporter
        $script:DuneUsageCountWorker | Should -BeNullOrEmpty
        $ready.Dispose()
        Should -Invoke Send-DuneUsageRequest -Times 0
    }
    AfterEach { $script:DuneConfigFile = $null }
}
