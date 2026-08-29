# Tests the pure helpers in the diagnostics-bundle route: the duplicate-section
# detector that headlines each INI snapshot, and the redaction pass that runs on
# every file before it lands in a ZIP the user attaches to a public issue.
# No SSH / IO — the live INI pull is exercised only on a real VM.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstRoute 'Diagnostics.ps1'
}

Describe 'Get-DstIniDuplicateHeaders' -Tag 'Pure' {
    It 'flags a section name that appears twice' {
        $raw = @"
[/Script/DuneSandbox.BuildingSettings]
m_BuildingBlueprintMaxExtensions=5
[/Script/DuneSandbox.InventorySystemSettings]
PlayerInventoryStartingVolumeCapacity=195
[/Script/DuneSandbox.BuildingSettings]
m_BaseBackupMaxExtensions=3
"@
        $dupes = Get-DstIniDuplicateHeaders -Raw $raw
        $dupes | Should -Contain '/Script/DuneSandbox.BuildingSettings x2'
        $dupes.Count | Should -Be 1
    }

    It 'returns nothing when every header is unique' {
        $raw = "[A]`nk=1`n[B]`nk=2`n"
        @(Get-DstIniDuplicateHeaders -Raw $raw).Count | Should -Be 0
    }

    It 'returns nothing for empty / null input' {
        @(Get-DstIniDuplicateHeaders -Raw '').Count   | Should -Be 0
        @(Get-DstIniDuplicateHeaders -Raw $null).Count | Should -Be 0
    }

    It 'ignores key=value lines and indented brackets in values' {
        $raw = "[Only]`nname=[not a header]`nlist=(1,2)`n"
        @(Get-DstIniDuplicateHeaders -Raw $raw).Count | Should -Be 0
    }
}

Describe 'Invoke-DstRedaction' -Tag 'Pure' {
    It 'redacts IPv4 addresses but leaves loopback alone' {
        $out = Invoke-DstRedaction -Text 'connect 203.0.113.7 then 127.0.0.1'
        $out | Should -Match '<ip>'
        $out | Should -Match '127\.0\.0\.1'
        $out | Should -Not -Match '203\.0\.113\.7'
    }

    It 'collapses any Windows user-profile path to <user>' {
        $out = Invoke-DstRedaction -Text 'C:\Users\Alice\.ssh\dune'
        $out | Should -Be 'C:\Users\<user>\.ssh\dune'
    }

    It 'redacts the explicit Windows user when supplied' {
        $out = Invoke-DstRedaction -Text 'hello Bob world' -WindowsUser 'Bob'
        $out | Should -Be 'hello <user> world'
    }

    It 'redacts PowerShell transcript user and machine identity headers' {
        $raw = "Username: DOMAIN\Alice`nRunAs User: DOMAIN\Alice`nMachine: DESKTOP-SECRET (Windows)"
        $out = Invoke-DstRedaction -Text $raw -WindowsUser 'Alice'
        $out | Should -Match 'Username: <redacted>'
        $out | Should -Match 'RunAs User: <redacted>'
        $out | Should -Match 'Machine: <redacted>'
        $out | Should -Not -Match 'DOMAIN|DESKTOP-SECRET|Alice'
    }

    It 'redacts game login passwords from server-state JSON' {
        $raw = '{"serverId":"abc","loginPassword":"server-secret","displayName":"Test"}'
        $out = Invoke-DstRedaction -Text $raw

        $out | Should -Be '{"serverId":"abc","loginPassword":"<redacted>","displayName":"Test"}'
        $out | Should -Not -Match 'server-secret'
    }

    It 'is a no-op on empty input' {
        Invoke-DstRedaction -Text '' | Should -Be ''
    }
}

Describe 'Read-DstLogText' -Tag 'Pure' {
    It 'preserves a complete WebView2-sized log larger than the old 200 KB limit' {
        $path = Join-Path $TestDrive 'webview2-debug.log'
        $start = '[shell] startup failure'
        $end = '[console.error] latest failure'
        $padding = 'x' * 225000
        [IO.File]::WriteAllText($path, "$start`n$padding`n$end", [Text.UTF8Encoding]::new($false))

        $content = Read-DstLogText -Path $path

        $content | Should -Match ([regex]::Escape($start))
        $content | Should -Match ([regex]::Escape($end))
        ([Text.Encoding]::UTF8.GetByteCount($content)) | Should -BeGreaterThan 204800
    }

    It 'retains bounded tail reads for other diagnostic logs' {
        $path = Join-Path $TestDrive 'cli.log'
        [IO.File]::WriteAllText($path, ('a' * 1024) + 'END', [Text.UTF8Encoding]::new($false))

        $content = Read-DstLogTail -Path $path -MaxBytes 128

        $content | Should -Be (('a' * 125) + 'END')
    }
}

Describe 'ConvertTo-DstWorldRestartDiagnosticState' -Tag 'Pure' {
    It 'exports operational state without player identities or paths' {
        $state = [pscustomobject]@{
            phase='error'; running=$false; operation='restart'
            started='2026-08-20T00:00:00Z'; finished='2026-08-20T00:10:00Z'
            rollbackAvailable=$true; recoveryRequired=$true
            researchRecoveryRequired=$true; researchRecoveryRunning=$false
            automaticRollback=$false; error='Character Coastal failed at C:\secret'
            backupPath='/private/world.backup'
            researchSnapshot=[pscustomobject]@{
                characters=@([pscustomobject]@{ characterName='Coastal'; funcomId='Coastal#1'; accountId=42 })
            }
            steps=@([pscustomobject]@{ id='verify'; status='failed'; detail='Verification failed.' })
        }

        $json = ConvertTo-DstWorldRestartDiagnosticState -State $state |
            ConvertTo-Json -Depth 6

        $json | Should -Match '"phase": "error"'
        $json | Should -Match '"hasError": true'
        $json | Should -Match '"id": "verify"'
        $json | Should -Not -Match 'Verification failed|Coastal|funcomId|accountId|backupPath|world\.backup|C:\\secret'
    }
}

Describe 'Diagnostics route registration' -Tag 'Pure' {
    It 'collects only updater text evidence through the redaction path' {
        $routeFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\Diagnostics.ps1'
        $source = Get-Content -LiteralPath $routeFile -Raw
        $source | Should -Match 'update-result-\[A-Za-z0-9\._-\]'
        $source | Should -Match 'Invoke-DstRedaction -Text \$tail'
        $source | Should -Not -Match "Get-ChildItem.+DuneServerSetup.+included"
    }

    It 'includes the complete bounded WebView2 debug log' {
        $routeFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\Diagnostics.ps1'
        $source = Get-Content -LiteralPath $routeFile -Raw

        $source | Should -Match 'Read-DstLogText -Path \$wv2'
        $source | Should -Match 'webview2-debug\.log \(complete, sanitized'
        $source | Should -Not -Match 'webview2-debug\.log was truncated'
    }

    It 'registers failed database operation cleanup at script scope' {
        $routeFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\Diagnostics.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $routeFile,
            [ref]$tokens,
            [ref]$errors
        )
        $errors | Should -BeNullOrEmpty

        $route = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Register-DuneRoute' -and
                $node.Extent.Text -match '/api/diagnostics/cleanup-failed-database-operations'
        }, $true))
        $route.Count | Should -Be 1

        $ancestor = $route[0].Parent
        while ($ancestor -and $ancestor -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
            $ancestor = $ancestor.Parent
        }
        $ancestor.Parent | Should -BeNullOrEmpty
    }
}
