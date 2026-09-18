BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path $PSScriptRoot '..\app\server\lib\MapSpinUp.ps1'
    . $lib
    foreach ($name in @(
        '_Get-DuneSpinUpTargetCount',
        '_Get-DuneSpinUpLabel',
        '_Parse-DuneDirectorIni',
        '_Test-DuneSpinUpControllableSection',
        '_Set-DuneIniMinServers',
        '_Set-DuneIniPartySharing'
    )) {
        Set-Item -Path "function:global:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
}

Describe 'Map SpinUp partition-aware floors' {
    It 'uses every configured Deep Desert partition' {
        $bg = @'
{"spec":{"database":{"template":{"spec":{"deployment":{"spec":{"worldPartitions":[
  {"map":"DeepDesert_1","partitions":[{"id":8},{"id":31},{"id":31}]}
]}}}}}}}
'@ | ConvertFrom-Json
        (_Get-DuneSpinUpTargetCount -Map 'DeepDesert_1' -Bg $bg) | Should -Be 2
    }

    It 'keeps non-Deep-Desert maps at one' {
        (_Get-DuneSpinUpTargetCount -Map 'SH_Arrakeen' -Bg ([pscustomobject]@{})) | Should -Be 1
    }

    It 'writes MinServers above one' {
        $ini = "[ DeepDesert_1 ]`nNumExtraServers = 0`nMinServers=1`n"
        $out = _Set-DuneIniMinServers -Ini $ini -Map 'DeepDesert_1' -Value 2
        $out | Should -Match 'MinServers=2'
    }

    It 'inserts a missing MinServers line above one' {
        $ini = "[ DeepDesert_1 ]`nNumExtraServers = 0`n"
        $out = _Set-DuneIniMinServers -Ini $ini -Map 'DeepDesert_1' -Value 2
        $out | Should -Match 'MinServers=2'
    }

    It 'recognizes every verified Retail area without NumExtraServers' {
        $maps = @(
            'CB_Story_DestroyedZanovar'
            'CB_Story_OrbitalMonitor'
            'CB_Arrakis_Story_Paranoid_PrayerRoom'
            'CB_Arrakis_Story_Glutton_DiningRoom'
            'CB_Arrakis_Generic_Sietch_Room'
        )
        $ini = ($maps | ForEach-Object { "[ $_ ]`nPlayerHardCap=1`n" }) -join "`n"
        $sections = @(_Parse-DuneDirectorIni -Ini $ini)

        @($sections.Name) | Should -Be $maps
        foreach ($section in $sections) {
            $section.IsMap | Should -BeFalse
            (_Test-DuneSpinUpControllableSection -Section $section) | Should -BeTrue
        }
    }

    Describe 'Map SpinUp route boolean validation' {
        BeforeAll {
            $script:MapSpinUpRouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\MapSpinUp.ps1'
            $script:MapSpinUpRoutes = @(& {
                function Register-DuneRoute {
                    param($Method, $Path, $Handler)
                    [pscustomobject]@{ method = $Method; path = $Path; handler = $Handler }
                }
                . $script:MapSpinUpRouteFile
                Set-Item -Path function:global:Get-DuneMapSpinUpJsonBoolean `
                    -Value (Get-Item function:Get-DuneMapSpinUpJsonBoolean).ScriptBlock
            })
        }

        It 'rejects omitted and non-boolean party-sharing values before taking the lock' -TestCases @(
            @{ body = @{} }
            @{ body = @{ shared = 'false' } }
            @{ body = [pscustomobject]@{ shared = 0 } }
        ) {
            param($body)
            $route = $script:MapSpinUpRoutes |
                Where-Object path -eq '/api/map-spinup/{map}/party-sharing' |
                Select-Object -First 1
            $script:routeStatus = 0
            $script:routeMessage = ''
            $script:lockCalls = 0
            function Write-DuneError {
                param($Response, $Status, $Message)
                $script:routeStatus = $Status
                $script:routeMessage = $Message
            }
            function Invoke-WithDuneLock {
                param($Name, $Script)
                $script:lockCalls++
                & $Script
            }

            & $route.handler $null $null @{ map = 'CB_Story_DestroyedZanovar' } $body

            $script:routeStatus | Should -Be 400
            $script:routeMessage | Should -Be 'shared must be a JSON boolean.'
            $script:lockCalls | Should -Be 0
        }

        It 'accepts JSON false for party sharing without coercing it' {
            $route = $script:MapSpinUpRoutes |
                Where-Object path -eq '/api/map-spinup/{map}/party-sharing' |
                Select-Object -First 1
            $script:capturedShared = $null
            function Invoke-WithDuneLock { param($Name, $Script); & $Script }
            function Set-DuneSpinUpMapPartySharing {
                param($Map, [bool]$Shared)
                $script:capturedShared = $Shared
                @{ ok = $true }
            }
            function Write-DuneJson {}
            function Write-DuneError {}

            & $route.handler $null $null @{ map = 'CB_Story_DestroyedZanovar' } @{ shared = $false }

            $script:capturedShared | Should -BeFalse
        }

        It 'applies the same strict JSON boolean validation to the sibling enabled route' {
            $route = $script:MapSpinUpRoutes |
                Where-Object path -eq '/api/map-spinup/{map}' |
                Select-Object -First 1
            $script:routeStatus = 0
            $script:lockCalls = 0
            function Write-DuneError { param($Response, $Status, $Message); $script:routeStatus = $Status }
            function Invoke-WithDuneLock { param($Name, $Script); $script:lockCalls++ }

            & $route.handler $null $null @{ map = 'DeepDesert_1' } @{ enabled = 'false' }

            $script:routeStatus | Should -Be 400
            $script:lockCalls | Should -Be 0
        }
    }

    It 'recognizes the Retail Zanovar party-isolation setting' {
        $ini = "[ CB_Story_DestroyedZanovar ]`nMaxParties=1`n"
        $section = @(_Parse-DuneDirectorIni -Ini $ini)[0]
        $section.Name | Should -Be 'CB_Story_DestroyedZanovar'
        $section.HasMaxParties | Should -BeTrue
        $section.MaxParties | Should -Be 1
        (_Test-DuneSpinUpControllableSection -Section $section) | Should -BeTrue
    }

    It 'uses the official friendly labels for the new Retail areas' {
        $labels = [ordered]@{
            'CB_Story_DestroyedZanovar'              = 'Zanovar'
            'CB_Story_OrbitalMonitor'                = 'Arrakeen Spaceport'
            'CB_Arrakis_Story_Paranoid_PrayerRoom'   = 'Place of Contemplation'
            'CB_Arrakis_Story_Glutton_DiningRoom'    = "The Glutton's Dining Room"
            'CB_Arrakis_Generic_Sietch_Room'         = 'Sietch Talab'
        }
        foreach ($map in $labels.Keys) {
            (_Get-DuneSpinUpLabel -Map $map) | Should -Be $labels[$map]
        }
    }

    It 'does not treat an unknown config-only section as a controllable map' {
        $section = @(_Parse-DuneDirectorIni -Ini "[ FutureConfig ]`nMaxParties=1`n")[0]
        (_Test-DuneSpinUpControllableSection -Section $section) | Should -BeFalse
    }

    It 'removes Zanovar party isolation when shared multiplayer is enabled' {
        $ini = "[ CB_Story_DestroyedZanovar ]`nMaxParties=1`n"
        $out = _Set-DuneIniPartySharing -Ini $ini -Map 'CB_Story_DestroyedZanovar' -Shared $true
        $out | Should -Not -Match 'MaxParties'
    }

    It 'restores one-party isolation without changing the next map' {
        $ini = "[ CB_Story_DestroyedZanovar ]`nMinServers=1`n`n[ DeepDesert_1 ]`nNumExtraServers=0`n"
        $out = _Set-DuneIniPartySharing -Ini $ini -Map 'CB_Story_DestroyedZanovar' -Shared $false
        $out | Should -Match '(?ms)^\[ CB_Story_DestroyedZanovar \]\r?\nMaxParties=1\r?\nMinServers=1'
        $out | Should -Match '(?ms)^\[ DeepDesert_1 \]\r?\nNumExtraServers=0'
    }
}
