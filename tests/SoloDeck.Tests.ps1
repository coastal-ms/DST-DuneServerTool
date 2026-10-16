BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloDeck.ps1'
}

Describe 'Read-only Steam Deck connection' {
    BeforeEach {
        $script:deckRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:deckRoot | Out-Null
        Mock Get-DuneSoloDeckConnectionRoot { $script:deckRoot }
    }
    It 'does not connect or fall back to local saves when unpaired' {
        Mock Invoke-DuneSoloDeckReader { throw 'must not run' }
        $result = Get-DuneSoloDeckStatus
        $result.paired | Should -BeFalse
        $result.connected | Should -BeFalse
        $result.report | Should -BeNullOrEmpty
        Should -Invoke Invoke-DuneSoloDeckReader -Times 0
    }
    It 'drops the report on a lost connection instead of returning stale local data' {
        '{}' | Set-Content (Join-Path $script:deckRoot 'connection.json')
        Mock Invoke-DuneSoloDeckReader { throw 'Deck offline' }
        $result = Get-DuneSoloDeckStatus
        $result.paired | Should -BeTrue
        $result.connected | Should -BeFalse
        $result.report | Should -BeNullOrEmpty
        $result.error | Should -Be 'Deck offline'
    }
    It 'accepts only the stock SteamOS read-only report' {
        '{}' | Set-Content (Join-Path $script:deckRoot 'connection.json')
        Mock Invoke-DuneSoloDeckReader { [pscustomobject]@{ protocol=1;mode='read-only';os=@{ID='steamos';VARIANT_ID='steamdeck'} } }
        (Get-DuneSoloDeckStatus).connected | Should -BeTrue
        Mock Invoke-DuneSoloDeckReader { [pscustomobject]@{ protocol=1;mode='write';os=@{ID='steamos';VARIANT_ID='steamdeck'} } }
        (Get-DuneSoloDeckStatus).connected | Should -BeFalse
    }
    It 'rejects target argument injection before starting SSH' {
        { Invoke-DuneSoloDeckReader -Root $script:deckRoot -Connection @{host='-oProxyCommand=bad';user='deck'} } | Should -Throw '*invalid*'
        { Invoke-DuneSoloDeckReader -Root $script:deckRoot -Connection @{host='192.0.2.1';user='deck -o bad'} } | Should -Throw '*invalid*'
        { Invoke-DuneSoloDeckReader -Root $script:deckRoot -Connection @{host='192.0.2.1';user='deck';pcAddress='-oProxyCommand=bad'} } | Should -Throw '*invalid*'
        { Invoke-DuneSoloDeckReader -Root $script:deckRoot -Connection @{host='192.0.2.1';user='deck';port='22 -oProxyCommand=bad'} } | Should -Throw '*invalid*'
    }
    It 'sends a BOM-free UTF-8 transfer request through the installed Windows runtime' -Skip:($env:OS -ne 'Windows_NT') {
        $probe = Join-Path $PSScriptRoot 'production\SoloDeck.PS51.ps1'
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -RepoRoot (Get-DstRepoRoot) -FixtureRoot $script:deckRoot
        $LASTEXITCODE | Should -Be 0
        ($raw | ConvertFrom-Json).ok | Should -BeTrue
        # Exercise the same real child process under the current PS7 host too.
        $currentRaw = & $probe -RepoRoot (Get-DstRepoRoot) -FixtureRoot $script:deckRoot -UseExistingProbe
        ($currentRaw | ConvertFrom-Json).ok | Should -BeTrue
    }
    It 'keeps status and both settings transfer routes host-local' {
        $routes = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); @{method=$Method;path=$Path;localOnly=[bool]$LocalOnly} }
            . (Join-Path (Get-DstRepoRoot) 'app/server/routes/SoloDeck.ps1')
        }
        @($routes).Count | Should -Be 7
        @($routes | Where-Object { -not $_.localOnly }).Count | Should -Be 0
        @($routes | Where-Object method -eq 'GET').Count | Should -Be 2
        @($routes | Where-Object method -eq 'POST').Count | Should -Be 5
    }
    It 'previews one-way differences while preserving Deck-only values and game-controlled fields' {
        $source = @(
            @{file='Engine.ini';section='ConsoleVariables';key='Vehicle.MaxVehiclesPerPlayer';value='20'},
            @{file='ServerCustomSettings.ini';section='native';key='DifficultyLevel';value='Custom'},
            @{file='ServerCustomSettings.ini';section='native';key='bAllowSandworms';value='True'}
        )
        $files = @(
            @{file='Engine.ini';duplicates=@();values=@(@{section='ConsoleVariables';key='DeckOnly';value='1'})},
            @{file='ServerCustomSettings.ini';duplicates=@();values=@(@{section='native';key='DifficultyLevel';value='Normal'},@{section='native';key='bAllowSandworms';value='False'})}
        )
        $result = Compare-DuneSoloDeckSettings -SourceEntries $source -DeckFiles $files
        $result.differenceCount | Should -Be 4
        $result.writesEnabled | Should -BeFalse
        ($result.differences | Where-Object key -eq 'DeckOnly').action | Should -Be 'Keep Deck value'
        ($result.differences | Where-Object key -eq 'DifficultyLevel').action | Should -Be 'Game controlled'
        ($result.differences | Where-Object key -eq 'bAllowSandworms').action | Should -Be 'Would copy to Deck'
        ($result.differences | Where-Object key -eq 'bAllowSandworms').warning | Should -Match 'bases built on sand'
    }
    It 'does not produce an overwrite preview from duplicate Deck keys' {
        { Compare-DuneSoloDeckSettings -DeckFiles @(@{file='Game.ini';duplicates=@(@{key='duplicate'});values=@()}) } | Should -Throw '*Duplicate*'
    }
}

Describe 'Deck settings transfer preparation' {
    BeforeEach {
        $script:transferRoot = Join-Path $TestDrive 'deck-pair'
        New-Item -ItemType Directory -Path $script:transferRoot -Force | Out-Null
        '{"host":"192.0.2.1","user":"deck"}' | Set-Content (Join-Path $script:transferRoot 'connection.json')
        Mock Get-DuneSoloDeckConnectionRoot { $script:transferRoot }
        function global:Assert-DuneSoloGameClosed {}
        $script:transferState = @{ connected=$true;report=@{game_processes=@();errors=@();settings_write_capabilities=@('managed-ini-v1');saves=@(@{path='/fixture/game.db';sha256='unchanged'});settings_candidates=@(@{files=@(@{file='Engine.ini';sha256='original'})})};comparison=@{available=$true;differences=@(@{file='Engine.ini';section='ConsoleVariables';key='Dune.DisableShieldOnShooting';pcValue='1';deckValue='0';action='Would copy to Deck'})} }
        Mock Get-DuneSoloDeckStatus { $script:transferState }
        Mock Invoke-DuneSoloDeckReader { [pscustomobject]@{applied=$false;files=@()} }
    }
    It 'prepares only explicit settings with server-generated identity and original hashes' {
        $result=Invoke-DuneSoloDeckSettingsPreview
        $result.token | Should -Match '^[0-9a-f]{64}$'
        $saved=Get-Content (Join-Path $script:transferRoot 'settings-preview.json') -Raw | ConvertFrom-Json
        $saved.request.files[0].expected_sha256 | Should -Be 'original'
        $saved.request.files[0].values[0].key | Should -Be 'Dune.DisableShieldOnShooting'
        Should -Invoke Invoke-DuneSoloDeckReader -Times 1 -ParameterFilter { $Command -eq 'dst-settings-v1' -and $Request.action -eq 'preview-settings' }
    }
    It 'groups multiple INI files and orders dictionary settings consistently' {
        $script:transferState.report.settings_candidates[0].files += @{file='Game.ini';sha256='game-original'}
        $script:transferState.comparison.differences += @(
            @{file='Engine.ini';section='ConsoleVariables';key='Alpha';pcValue='2';action='Would copy to Deck'},
            @{file='Game.ini';section='Inventory';key='Size';pcValue='100';action='Would copy to Deck'}
        )
        $plan = New-DuneSoloDeckSettingsPlan $script:transferState
        @($plan.request.files).Count | Should -Be 2
        $plan.request.files[0].file | Should -Be 'Engine.ini'
        $plan.request.files[0].values[0].key | Should -Be 'Alpha'
        $plan.request.files[1].file | Should -Be 'Game.ini'
        $plan.request.files[1].expected_sha256 | Should -Be 'game-original'
    }
    It 'rejects missing final or Cloud approval before dispatching' {
        {Invoke-DuneSoloDeckSettingsApply -Token 'unused' -Confirmed $true -CloudConfirmed $false} | Should -Throw '*Confirm*'
        {Invoke-DuneSoloDeckSettingsApply -Token 'unused' -Confirmed 'true' -CloudConfirmed $true} | Should -Throw '*Confirm*'
        Should -Invoke Invoke-DuneSoloDeckReader -Times 0
    }
    It 'rejects changed PC settings, pairing and expired approvals without writes' {
        $preview=Invoke-DuneSoloDeckSettingsPreview
        $script:transferState.comparison.differences[0].pcValue='2'
        {Invoke-DuneSoloDeckSettingsApply -Token $preview.token -Confirmed $true -CloudConfirmed $true} | Should -Throw '*changed*'
        $script:transferState.comparison.differences[0].pcValue='1'
        '{"different":true}' | Set-Content (Join-Path $script:transferRoot 'connection.json')
        {Invoke-DuneSoloDeckSettingsApply -Token $preview.token -Confirmed $true -CloudConfirmed $true} | Should -Throw '*pairing changed*'
        Should -Invoke Invoke-DuneSoloDeckReader -Times 0 -ParameterFilter { $Request.action -eq 'apply-settings' }
    }
    It 'blocks a running game or a helper without transfer capability' {
        $script:transferState.report.game_processes=@(@{pid=1})
        {Invoke-DuneSoloDeckSettingsPreview} | Should -Throw '*Close Dune*'
        $script:transferState.report.game_processes=@()
        $script:transferState.report.settings_write_capabilities=@()
        {Invoke-DuneSoloDeckSettingsPreview} | Should -Throw '*Update*'
        Should -Invoke Invoke-DuneSoloDeckReader -Times 0
    }
    It 'consumes approval once, verifies the returned settings and preserves the save fingerprint' {
        $preview=Invoke-DuneSoloDeckSettingsPreview
        Mock Invoke-DuneSoloDeckReader {
            if ($Request.action -eq 'apply-settings') {
                $script:transferState.comparison.differences=@()
                return [pscustomobject]@{applied=$true;backup='/fixture/backup'}
            }
            return [pscustomobject]@{applied=$false}
        }
        $result=Invoke-DuneSoloDeckSettingsApply -Token $preview.token -Confirmed $true -CloudConfirmed $true
        $result.applied | Should -BeTrue
        $result.saveUnchanged | Should -BeTrue
        $result.remainingDifferences | Should -Be 0
        {Invoke-DuneSoloDeckSettingsApply -Token $preview.token -Confirmed $true -CloudConfirmed $true} | Should -Throw '*fresh settings preview*'
        Should -Invoke Invoke-DuneSoloDeckReader -Times 1 -ParameterFilter { $Request.action -eq 'apply-settings' }
    }
}
