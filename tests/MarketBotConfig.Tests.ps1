BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'GameplayBot.ps1'
}

Describe 'Market Bot config persistence' -Tag 'MarketBot' {
    BeforeEach {
        Mock Get-DuneBotConfigPath { Join-Path $TestDrive 'gameplay-bot.json' }
    }

    It 'keeps Stackables Only enabled after saving and reopening the config' {
        $saved = Save-DuneBotConfig -Incoming @{ stackables_only = $true }
        $saved['stackables_only'] | Should -BeTrue

        $onDisk = Get-Content -LiteralPath (Get-DuneBotConfigPath) -Raw | ConvertFrom-Json
        $onDisk.sane_defaults_revision | Should -Be 3
        $onDisk.stackables_only | Should -BeTrue

        $reloaded = Read-DuneBotConfig
        $reloaded['stackables_only'] | Should -BeTrue
    }
}
