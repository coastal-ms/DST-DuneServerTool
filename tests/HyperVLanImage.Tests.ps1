BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'HyperVLanImage.ps1'
    Import-DstLib 'HyperVLanInstall.ps1'
    # Isolate the transport boundary without opening a live PSSession. The real
    # remote verification script still runs against fixture files below.
    function global:Invoke-Command { param($Session, $ArgumentList, $ScriptBlock, $ComputerName, $Credential, $ErrorAction) }
    $script:token = 'e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"HostId":"test-host"}')).TrimEnd('=').Replace('+','-').Replace('/','_') + '.signature'
    function New-TestImage($library, $state = 4) {
        $root = Join-Path $library 'steamapps\common\Self Hosted Server'
        New-Item -ItemType Directory -Path "$root\Virtual Machines", "$root\Virtual Hard Disks", "$root\battlegroup-management\bootstrap" -Force | Out-Null
        Set-Content "$library\steamapps\appmanifest_4754530.acf" ('"StateFlags" "' + $state + '" "installdir" "Self Hosted Server"')
        Set-Content "$root\Virtual Machines\test.vmcx" 'configuration'
        Set-Content "$root\Virtual Hard Disks\test.vhdx" 'disk'
        Set-Content "$root\battlegroup-management\bootstrap\setup" 'setup'
        return $root
    }
}

AfterAll {
    Remove-Item function:global:Invoke-Command -ErrorAction SilentlyContinue
}

Describe 'Local Steam image selection' {
    It 'finds a completed tool in a secondary library with spaces' {
        $library = Join-Path $TestDrive 'Secondary Steam Library'
        $root = New-TestImage $library
        Find-DuneLanImage @((Join-Path $TestDrive 'empty'), $library) | Should -Be $root
    }
    It 'rejects an incomplete Steam download even when VM files exist' {
        $library = Join-Path $TestDrive 'partial'
        New-TestImage $library 1026 | Out-Null
        Find-DuneLanImage @($library) | Should -BeNullOrEmpty
    }
    It 'rejects an image without its guest bootstrap' {
        $library = Join-Path $TestDrive 'missing-bootstrap'
        $root = New-TestImage $library
        Remove-Item "$root\battlegroup-management\bootstrap\setup"
        Find-DuneLanImage @($library) | Should -BeNullOrEmpty
    }
    It 'reuses a completed image without launching Steam' {
        $library = Join-Path $TestDrive 'reuse'
        $root = New-TestImage $library
        Mock Get-DuneLanSteamLibraries { @($library) }
        Mock Start-Process { throw 'Must not launch Steam' }
        Wait-DuneLanLocalImage | Should -Be $root
        Should -Invoke Start-Process -Times 0
    }
    It 'opens local Steam and fails explicitly when its download remains incomplete' {
        Mock Get-DuneLanSteamLibraries { @($TestDrive) }
        Mock Start-Process {}
        Mock Start-Sleep {}
        { Wait-DuneLanLocalImage -TimeoutSeconds 0 } | Should -Throw '*Finish its install in Steam*'
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'steam://install/4754530' }
    }
}

Describe 'World setup validation before import' {
    It 'accepts a safe world name, selected region and account token' {
        { Assert-DuneLanWorldInputs 'Test World' 3 $token } | Should -Not -Throw
    }
    It 'rejects names that would alter the generated YAML or sed replacement' {
        { Assert-DuneLanWorldInputs "World'&" 3 $token } | Should -Throw '*world name*'
    }
    It 'rejects a token without HostId without exposing its contents' {
        { Assert-DuneLanWorldInputs 'World' 3 'e30.e30.secret' } | Should -Throw '*valid HostId*'
    }
    It 'rejects an invalid region' {
        { Assert-DuneLanWorldInputs 'World' 0 $token } | Should -Throw '*region*'
    }
    It 'does not import or bootstrap if image verification fails' {
        Mock Read-DuneConfig { @{ LastAppliedPublicIp=''; LastKnownVmIp='' } }
        Mock Resolve-DuneHyperVLanCredential { @{ ok=$true; credential=[pscredential]::new('test', (ConvertTo-SecureString 'test' -AsPlainText -Force)) } }
        Mock New-PSSession { $null }
        Mock Save-DuneHyperVLanInstallState { $script:lastState=$State }
        Mock Wait-DuneLanLocalImage { 'local-image' }
        Mock Copy-DuneLanImage { throw 'VM image transfer verification failed.' }
        Mock Invoke-Command { throw 'Import must not run' }
        Mock Initialize-DuneLanGuest { throw 'Bootstrap must not run' }
        Invoke-DuneHyperVLanInstall -HostIp '192.0.2.1' -DestDrive 'D:' -MemoryGB 20 -SwitchName 'test' -WorldName 'World' -Region 3 -ServerToken $token
        $lastState.phase | Should -Be 'error'
        $lastState.error | Should -Match 'verification failed'
        ($lastState | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($token))
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke Initialize-DuneLanGuest -Times 0
    }
}

Describe 'Verified transfer of VM files only' {
    BeforeAll {
        function Copy-Item { param($LiteralPath, $Destination, $ToSession, $ErrorAction) }
    }
    BeforeEach {
        $script:image = New-TestImage (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path "$image\.logs" | Out-Null
        Set-Content "$image\.logs\private.log" 'must never transfer'
        $script:remoteRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Invoke-Command {
            if ($ArgumentList.Count -eq 1) { & $ScriptBlock $remoteRoot }
            else { & $ScriptBlock $remoteRoot $ArgumentList[1] }
        }
        Mock Copy-Item {
            $relative = $Destination.Substring($Destination.IndexOf('Virtual '))
            [IO.File]::Copy($LiteralPath, (Join-Path $remoteRoot $relative))
        }
    }
    It 'copies and verifies actual file contents without including logs' {
        $r = Copy-DuneLanImage -Session $null -ImageRoot $image -DestDrive 'D:'
        $r.ok | Should -BeTrue
        Should -Invoke Copy-Item -Times 2
        Test-Path "$remoteRoot\.logs" | Should -BeFalse
    }
    It 'rejects a corrupted transferred disk before import' {
        Mock Copy-Item {
            $relative = $Destination.Substring($Destination.IndexOf('Virtual '))
            [IO.File]::Copy($LiteralPath, (Join-Path $remoteRoot $relative))
            if ($relative.EndsWith('.vhdx')) { Set-Content (Join-Path $remoteRoot $relative) 'corrupt' }
        }
        { Copy-DuneLanImage -Session $null -ImageRoot $image -DestDrive 'D:' } | Should -Throw '*verification failed*'
    }
}

Describe 'Move only the recorded old VM client route' {
    BeforeEach {
        Mock Get-DunePublicIpHostRouteEnabled { $true }
        Mock Find-NetRoute { @{ InterfaceIndex=9 } }
        Mock New-NetRoute {}
        Mock Remove-NetRoute {}
    }
    It 'creates the replacement before removing the old VM route' {
        Mock Get-NetRoute { @{ NextHop='192.0.2.10'; InterfaceIndex=9; RouteMetric=1 } }
        Update-DuneLanClientRoute '198.51.100.1' '192.0.2.10' '192.0.2.11'
        Should -Invoke New-NetRoute -Times 1 -ParameterFilter { $NextHop -eq '192.0.2.11' }
        Should -Invoke Remove-NetRoute -Times 1 -ParameterFilter { $NextHop -eq '192.0.2.10' }
    }
    It 'preserves routes pointing to unrelated gateways' {
        Mock Get-NetRoute { @{ NextHop='192.0.2.99'; InterfaceIndex=9; RouteMetric=1 } }
        Update-DuneLanClientRoute '198.51.100.1' '192.0.2.10' '192.0.2.11'
        Should -Invoke New-NetRoute -Times 0
        Should -Invoke Remove-NetRoute -Times 0
    }
    It 'preserves the old route when creating its replacement fails' {
        Mock Get-NetRoute { @{ NextHop='192.0.2.10'; InterfaceIndex=9; RouteMetric=1 } }
        Mock New-NetRoute { throw 'Access denied' }
        { Update-DuneLanClientRoute '198.51.100.1' '192.0.2.10' '192.0.2.11' } | Should -Throw '*Access denied*'
        Should -Invoke Remove-NetRoute -Times 0
    }
    It 'does not create routes when the user disabled loopback routing' {
        Mock Get-DunePublicIpHostRouteEnabled { $false }
        Update-DuneLanClientRoute '198.51.100.1' '192.0.2.10' '192.0.2.11'
        Should -Invoke New-NetRoute -Times 0
        Should -Invoke Remove-NetRoute -Times 0
    }
}

Describe 'Transferred VM image staging cleanup' {
    BeforeEach {
        Mock Invoke-Command {
            & $ScriptBlock $ArgumentList
        }
    }
    It 'rejects paths outside a single generated staging directory before deletion' {
        Mock Remove-Item { throw 'Must never delete an unrelated directory.' }
        { Remove-DuneLanImageStage -Session $null -ImageRoot 'C:\DuneAwakeningServer' } | Should -Throw '*Unexpected VM image staging path*'
        Should -Invoke Remove-Item -Times 0
    }
    It 'accepts an absent generated stage without deleting another path' {
        Mock Test-Path { $false }
        Mock Remove-Item {}
        Remove-DuneLanImageStage -Session $null -ImageRoot ('C:\DuneServerStage\' + ('a' * 32))
        Should -Invoke Remove-Item -Times 0
    }
    It 'removes only the verified stage after checking links' {
        Mock Test-Path { $true }
        Mock Get-Item { @{Attributes=[IO.FileAttributes]::Directory} }
        Mock Get-ChildItem { @{Attributes=[IO.FileAttributes]::Archive} }
        Mock Remove-Item {}
        Remove-DuneLanImageStage -Session $null -ImageRoot ('C:\DuneServerStage\' + ('a' * 32))
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -eq ('C:\DuneServerStage\' + ('a' * 32)) -and $Recurse -and $Force }
    }
    It 'preserves a stage containing a filesystem link' {
        Mock Test-Path { $true }
        Mock Get-Item { @{Attributes=[IO.FileAttributes]::Directory} }
        Mock Get-ChildItem { @{Attributes=[IO.FileAttributes]::ReparsePoint} }
        Mock Remove-Item {}
        { Remove-DuneLanImageStage -Session $null -ImageRoot ('C:\DuneServerStage\' + ('a' * 32)) } | Should -Throw '*contains a link*'
        Should -Invoke Remove-Item -Times 0
    }
}
