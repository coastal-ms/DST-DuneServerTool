BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path $PSScriptRoot '..\app\server\lib\MapSpinUp.ps1'
    . $lib
    foreach ($name in @(
        '_Get-DuneSpinUpTargetCount',
        '_Get-DuneSpinUpLabel',
        '_Parse-DuneDirectorIni',
        '_Test-DuneSpinUpControllableSection',
        '_Test-DuneSpinUpKnownMap',
        '_Test-DuneSpinUpKnownRetailMap',
        '_New-DuneSpinUpMissingSectionResult',
        '_New-DuneSpinUpNotStartedResult',
        '_Set-DuneIniMinServers',
        '_Set-DuneIniPartySharing',
        'Set-DuneSpinUpMap',
        'Get-DuneSpinUpMaps'
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

Describe 'A director.ini section missing entirely is detected and routed to support' {
    # Regression coverage for the 2026-09-20 Tri case: a battlegroup's embedded
    # director.ini was missing the whole [ DeepDesert_1 ] section, so Deep
    # Desert just vanished from Lifecycle with no diagnostic pointing at the
    # cause. Detection must distinguish "known map, section entirely gone"
    # from "not a map DST manages at all", and the resulting message must
    # never tell the end user to hand-edit director.ini/YAML themselves.

    BeforeAll {
        function New-DuneTestBg {
            param([Parameter(Mandatory)][string]$Ini)
            [pscustomobject]@{
                spec = [pscustomobject]@{
                    utilities = [pscustomobject]@{
                        director = [pscustomobject]@{
                            spec = [pscustomobject]@{
                                configFiles = [pscustomobject]@{
                                    files = [pscustomobject]@{ 'director.ini' = $Ini }
                                }
                            }
                        }
                    }
                }
            }
        }
        Set-Item -Path 'function:global:New-DuneTestBg' -Value (Get-Item 'function:New-DuneTestBg').ScriptBlock
    }

    It 'recognizes native-MinServers maps as sections DST expects to exist' {
        foreach ($map in @('DeepDesert_1', 'SH_Arrakeen', 'SH_HarkoVillage')) {
            (_Test-DuneSpinUpKnownMap -Map $map) | Should -BeTrue -Because "$map is a native-MinServers map"
        }
        (_Test-DuneSpinUpKnownMap -Map 'NotARealMap') | Should -BeFalse
    }

    It 'does NOT flag Retail maps as a real error when absent - regression for a real false positive' {
        # Caught during v15.1.7 release-candidate testing (2026-09-20): a live
        # self-hosted battlegroup had all five DuneSpinUpRetailMaps sections
        # absent from director.ini while every one of them was fully alive
        # and working via the battlegroup director's own live admin page
        # (real queue-fail routing, instance throttling, per-map caps - none
        # of it sourced from director.ini). Flagging these in the same
        # error tier as a native-map gap would have told a healthy
        # self-hoster their server was broken, when it wasn't - these are
        # cataloged as their own low-severity "not started yet" tier instead
        # (see _Test-DuneSpinUpKnownRetailMap).
        foreach ($map in @(
            'CB_Story_DestroyedZanovar', 'CB_Story_OrbitalMonitor',
            'CB_Arrakis_Story_Paranoid_PrayerRoom', 'CB_Arrakis_Story_Glutton_DiningRoom',
            'CB_Arrakis_Generic_Sietch_Room'
        )) {
            (_Test-DuneSpinUpKnownMap -Map $map) | Should -BeFalse -Because "$map is a Retail map, not the native-error tier"
            (_Test-DuneSpinUpKnownRetailMap -Map $map) | Should -BeTrue -Because "$map is a cataloged Retail map"
        }

        $ini = "[ SH_Arrakeen ]`nNumExtraServers = 0`nMinServers=1`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }
        $r = Get-DuneSpinUpMaps
        @($r.missingSections.map) | Should -Not -Contain 'CB_Story_DestroyedZanovar'
        @($r.missingSections.map) | Should -Not -Contain 'CB_Arrakis_Generic_Sietch_Room'
        @($r.notStartedSections.map) | Should -Contain 'CB_Story_DestroyedZanovar'
        @($r.notStartedSections.map) | Should -Contain 'CB_Arrakis_Generic_Sietch_Room'
    }

    It 'gives Retail "not started" maps a calm, non-game-breaking message distinct from the error tier' {
        $r = _New-DuneSpinUpNotStartedResult -Map 'CB_Story_DestroyedZanovar'

        $r.ok | Should -BeFalse
        $r.notStarted | Should -BeTrue
        $r.ContainsKey('missingSection') | Should -BeFalse
        $r.map | Should -Be 'CB_Story_DestroyedZanovar'
        $r.message | Should -Match 'Zanovar'
        $r.message | Should -Match "hasn't been started yet"
        $r.message | Should -Match 'normal'
        $r.message | Should -Match 'DST Discord'

        # Same guardrails as the error tier: no self-serve edit instruction,
        # and never claims this is a config gap or something to restore.
        $r.message | Should -Not -Match '(?i)Edit Director'
        $r.message | Should -Not -Match '(?i)DST Commands'
        $r.message | Should -Not -Match 'NumExtraServers\s*='
        $r.message | Should -Not -Match 'MinServers\s*='
    }

    It 'declining to enable an un-started Retail map still returns the calm notStarted result' {
        $ini = "[ SH_Arrakeen ]`nNumExtraServers = 0`nMinServers=1`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }

        $r = Set-DuneSpinUpMap -Map 'CB_Story_DestroyedZanovar' -Enabled $false

        $r.ok | Should -BeFalse
        $r.status | Should -Be 404
        $r.notStarted | Should -BeTrue
        $r.ContainsKey('missingSection') | Should -BeFalse
        $r.map | Should -Be 'CB_Story_DestroyedZanovar'
    }

    It 'enabling an un-started Retail map creates the section from scratch and patches it directly' {
        # Regression coverage for the 2026-09-20 finding: Coastal manually
        # added a brand-new [ CB_Story_DestroyedZanovar ] section with just
        # MinServers=1 via a raw CRD edit, and it came online immediately -
        # no battlegroup restart. Set-DuneSpinUpMap should do the same patch
        # itself on first enable instead of only reporting "not started yet".
        $ini = "[ SH_Arrakeen ]`nNumExtraServers = 0`nMinServers=1`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }
        $script:capturedCmd = $null
        function Invoke-V6Ssh { param($Ip, $Cmd, $TimeoutSec) $script:capturedCmd = $Cmd; 'battlegroup.dst.example patched' }

        $r = Set-DuneSpinUpMap -Map 'CB_Story_DestroyedZanovar' -Enabled $true

        $r.ok | Should -BeTrue
        $r.map | Should -Be 'CB_Story_DestroyedZanovar'
        $r.enabled | Should -BeTrue
        $r.minServers | Should -Be 1
        $r.firstStart | Should -BeTrue
        $r.ContainsKey('notStarted') | Should -BeFalse
        $r.ContainsKey('missingSection') | Should -BeFalse

        # Decode the base64 JSON patch payload embedded in the SSH command to
        # confirm the actual director.ini content sent is a clean new section.
        $script:capturedCmd -match 'echo (\S+) \|' | Should -BeTrue
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
        $decoded | Should -Match '\[ CB_Story_DestroyedZanovar \]'
        $decoded | Should -Match 'MinServers=1'
    }

    It 'names the map, the missing section, and director.ini without directing a self-serve edit' {
        $r = _New-DuneSpinUpMissingSectionResult -Map 'DeepDesert_1'

        $r.ok | Should -BeFalse
        $r.missingSection | Should -BeTrue
        $r.map | Should -Be 'DeepDesert_1'
        $r.message | Should -Match 'Deep Desert'
        $r.message | Should -Match '\[ DeepDesert_1 \]'
        $r.message | Should -Match 'director\.ini'
        $r.message | Should -Match 'DST Discord'

        # Never a self-serve manual-edit instruction, and never frames this
        # as DST's fault or a specific channel/promise to restore it.
        $r.message | Should -Not -Match '(?i)Edit Director'
        $r.message | Should -Not -Match '(?i)DST Commands'
        $r.message | Should -Not -Match 'NumExtraServers\s*='
        $r.message | Should -Not -Match 'MinServers\s*='
        $r.message | Should -Not -Match '(?i)config gap'
        $r.message | Should -Not -Match '(?i)restore the section'
    }

    It 'flags the toggle as a missing-section config gap, not a generic unknown-map error' {
        $ini = "[ SH_Arrakeen ]`nNumExtraServers = 0`nMinServers=1`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }

        $r = Set-DuneSpinUpMap -Map 'DeepDesert_1' -Enabled $true

        $r.ok | Should -BeFalse
        $r.status | Should -Be 404
        $r.missingSection | Should -BeTrue
        $r.map | Should -Be 'DeepDesert_1'
        $r.message | Should -Match 'director\.ini'
        $r.message | Should -Not -Match '(?i)Edit Director'
    }

    It 'keeps the plain unknown-map error for a name DST does not catalog at all' {
        $ini = "[ SH_Arrakeen ]`nNumExtraServers = 0`nMinServers=1`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }

        $r = Set-DuneSpinUpMap -Map 'NotARealMap' -Enabled $true

        $r.ok | Should -BeFalse
        $r.status | Should -Be 404
        $r.ContainsKey('missingSection') | Should -BeFalse
        $r.message | Should -Be "Map 'NotARealMap' is not a controllable map section in director.ini."
    }

    It 'still treats an existing section needing a value change as a normal toggle, not a missing section' {
        $ini = "[ DeepDesert_1 ]`nNumExtraServers = 0`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }
        function Invoke-V6Ssh { param($Ip, $Cmd, $TimeoutSec) 'battlegroup.dst.example patched' }

        $r = Set-DuneSpinUpMap -Map 'DeepDesert_1' -Enabled $true

        $r.ContainsKey('missingSection') | Should -BeFalse
        $r.status | Should -Not -Be 404
    }

    It 'lists missing native sections separately from present maps in Get-DuneSpinUpMaps' {
        $ini = "[ SH_Arrakeen ]`nNumExtraServers = 0`nMinServers=1`n"
        function Get-DuneMapsContext { @{ ok = $true; vm = @{ ip = '10.0.0.1' } } }
        function Get-V6Battlegroup { param($Ip) @{ Ns = 'ns1'; Name = 'bg1'; Bg = (New-DuneTestBg -Ini $ini) } }

        $r = Get-DuneSpinUpMaps

        $r.ok | Should -BeTrue
        @($r.maps.map) | Should -Contain 'SH_Arrakeen'
        @($r.maps.map) | Should -Not -Contain 'DeepDesert_1'
        @($r.missingSections.map) | Should -Contain 'DeepDesert_1'
        $deepDesert = $r.missingSections | Where-Object { $_.map -eq 'DeepDesert_1' } | Select-Object -First 1
        $deepDesert.message | Should -Match 'director\.ini'
        $deepDesert.message | Should -Not -Match '(?i)Edit Director'
    }
}
