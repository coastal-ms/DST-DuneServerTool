BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\ChatCommands.ps1'
}

Describe 'Chat command route registration' {
    It 'registers settings and teleport mutation routes at file scope' {
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path; handler = $Handler }
            }
            . $script:RouteFile
        })

        @($routes | ForEach-Object { "$($_.method) $($_.path)" } | Sort-Object) |
            Should -Be @(
                'DELETE /api/gameplay/chat-commands/teleports'
                'DELETE /api/gameplay/chat-commands/teleports/capture'
                'GET /api/gameplay/chat-commands'
                'POST /api/gameplay/chat-commands/teleports'
                'POST /api/gameplay/chat-commands/teleports/capture'
                'PUT /api/gameplay/chat-commands'
            )
    }

    It 'passes the requested bookmark name into direct save' {
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path; handler = $Handler }
            }
            . $script:RouteFile
        })
        $post = $routes | Where-Object {
            $_.method -eq 'POST' -and $_.path -eq '/api/gameplay/chat-commands/teleports'
        } | Select-Object -First 1

        $script:CapturedBookmarkName = ''
        function Get-DuneDbContext { @{ ok = $true; ip = 'vm' } }
        function Invoke-DuneChatTeleportFileLock {
            param([scriptblock]$Script)
            & $Script
        }
        function Save-DuneChatTeleportFromPawn {
            param($Ip, [string]$Name, $PawnId)
            $script:CapturedBookmarkName = $Name
            @{ ok = $true; status = 200; teleports = @() }
        }
        function Write-DuneJson { param($Response, $Body) }
        function Write-DuneError { param($Response, $Status, $Message); throw $Message }

        & $post.handler $null $null $null @{ name = 'CHome'; pawn_id = 42 }
        $script:CapturedBookmarkName | Should -Be 'CHome'
    }

    It 'passes the requested name into an armed live capture' {
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path; handler = $Handler }
            }
            . $script:RouteFile
        })
        $post = $routes | Where-Object {
            $_.method -eq 'POST' -and $_.path -eq '/api/gameplay/chat-commands/teleports/capture'
        } | Select-Object -First 1

        $script:CapturedBookmarkName = ''
        function Get-DuneDbContext { @{ ok = $true; ip = 'vm' } }
        function Read-DuneChatCommandsState {
            @{ enabled = $true; commands = @{ tp = @{ enabled = $true } } }
        }
        function Invoke-DuneChatTeleportFileLock {
            param([scriptblock]$Script)
            & $Script
        }
        function Set-DuneChatTeleportCaptureForPawn {
            param($Ip, [string]$Name, $PawnId)
            $script:CapturedBookmarkName = $Name
            @{ ok = $true; status = 200; pending = @{ name = $Name; token = 'ABC123' } }
        }
        function Write-DuneJson { param($Response, $Body) }
        function Write-DuneError { param($Response, $Status, $Message); throw $Message }

        & $post.handler $null $null $null @{ name = 'Hagga South'; pawn_id = 42 }
        $script:CapturedBookmarkName | Should -Be 'Hagga South'
    }
}
