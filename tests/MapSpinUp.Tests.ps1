BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path $PSScriptRoot '..\app\server\lib\MapSpinUp.ps1'
    . $lib
    foreach ($name in @('_Get-DuneSpinUpTargetCount','_Set-DuneIniMinServers')) {
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
}
