BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\ChatCommands.ps1'
}

Describe 'Chat command route registration' {
    It 'registers settings and teleport mutation routes at file scope' {
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path }
            }
            . $script:RouteFile
        })

        @($routes | ForEach-Object { "$($_.method) $($_.path)" } | Sort-Object) |
            Should -Be @(
                'DELETE /api/gameplay/chat-commands/teleports'
                'GET /api/gameplay/chat-commands'
                'POST /api/gameplay/chat-commands/teleports'
                'PUT /api/gameplay/chat-commands'
            )
    }
}
