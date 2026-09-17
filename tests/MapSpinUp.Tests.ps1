BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path $PSScriptRoot '..\app\server\lib\MapSpinUp.ps1'
    . $lib
    foreach ($name in @(
        '_Get-DuneSpinUpTargetCount',
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

    It 'recognizes the Retail Zanovar party-isolation setting' {
        $ini = "[ CB_Story_DestroyedZanovar ]`nMaxParties=1`n"
        $section = @(_Parse-DuneDirectorIni -Ini $ini)[0]
        $section.Name | Should -Be 'CB_Story_DestroyedZanovar'
        $section.HasMaxParties | Should -BeTrue
        $section.MaxParties | Should -Be 1
        (_Test-DuneSpinUpControllableSection -Section $section) | Should -BeTrue
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
