BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:Repo = Get-DstRepoRoot
}

Describe 'Unsupported self-hosted Claim Rewards grants' {
    It 'does not expose Grant Reward in the player actions UI' {
        $sections = Get-Content (
            Join-Path $script:Repo 'webui\src\pages\gameplay\players\sections.tsx'
        ) -Raw

        $sections | Should -Not -Match 'Grant Reward \(popup\)'
        $sections | Should -Not -Match 'grantLive'
    }

    It 'keeps the legacy route fail-closed without a reward-table write' {
        $route = Get-Content (
            Join-Path $script:Repo 'app\server\routes\PlayersRmq.ps1'
        ) -Raw
        $handler = [regex]::Match(
            $route,
            "(?ms)Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-live'.*?^}"
        ).Value

        $handler | Should -Match 'Status 409'
        $handler | Should -Match 'require Funcom FLS grants'
        $handler | Should -Not -Match 'landsraad_house_rewards'
        $handler | Should -Not -Match 'Invoke-DunePlayerWriteRoute'
    }

    It 'removes the obsolete database mutation helper' {
        $library = Get-Content (
            Join-Path $script:Repo 'app\server\lib\PlayersRmq.ps1'
        ) -Raw

        $library | Should -Not -Match 'Invoke-DunePlayerGrantLive'
        $library | Should -Not -Match "house_name = 'AdminGrant'"
    }
}
