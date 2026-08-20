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

    It 'is a no-op on empty input' {
        Invoke-DstRedaction -Text '' | Should -Be ''
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
