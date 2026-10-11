BeforeAll {
    $script:Launcher = Join-Path $PSScriptRoot '../app/server/lib/LaunchSoloMods.ps1'
    $script:OriginalLocalApp = $env:LOCALAPPDATA
}
Describe 'Desktop mod shortcut launch' {
BeforeEach {
    $env:LOCALAPPDATA = $TestDrive
    New-Item -ItemType Directory -Path "$TestDrive/DuneServer" -Force | Out-Null
    Set-Content "$TestDrive/DuneServer/last-url.txt" 'http://127.0.0.1:47823/?t=fresh-test-token'
    Mock Start-Process {}
    Mock Start-Sleep {}
    Mock Add-Type {}
}
AfterEach { $env:LOCALAPPDATA = $script:OriginalLocalApp }
    It 'uses the current local token and requests a modded launch' {
        Mock Invoke-RestMethod {
            if ($Method -eq 'Post') { return @{ok=$true} }
            return @{gameRunning=$false;runtimeReady=$true;mods=@()}
        }
        & $script:Launcher
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq 'http://127.0.0.1:47823/api/solo/mods/launch' -and
            $Headers['X-Dune-Token'] -eq 'fresh-test-token' -and $Body -eq '{"withMods":true}'
        }
        Should -Invoke Start-Process -Times 0
    }
    It 'opens DST once when its local API is unavailable, then launches after readiness' {
        $script:Attempts = 0
        Mock Test-Path { return $true }
        Mock Invoke-RestMethod {
            if ($Method -eq 'Post') { return @{ok=$true} }
            $script:Attempts++
            if ($script:Attempts -eq 1) { throw 'Not running' }
            return @{gameRunning=$false;runtimeReady=$true;mods=@()}
        }
        & $script:Launcher
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -like '*DuneServer.exe' -and $WindowStyle -eq 'Hidden' }
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Method -eq 'Post' }
    }
    It 'checks connectivity without starting DST or the game' {
        Mock Invoke-RestMethod { return @{gameRunning=$false;runtimeReady=$true;mods=@(@{enabled=$true})} }
        $result = & $script:Launcher -CheckOnly
        $result.Connected | Should -BeTrue
        $result.EnabledMods | Should -Be 1
        Should -Invoke Start-Process -Times 0
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'Post' }
    }
}
