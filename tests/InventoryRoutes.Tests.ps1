BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Register-DstStubs
    $repo = Get-DstRepoRoot
    . (Join-Path $repo 'app\server\HttpServer.ps1')
    Import-DstLib 'Database.ps1'
    Import-DstLib 'ApiContract.ps1'
    Import-DstLib 'RequestPrincipal.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'GameplayWorld.ps1'
    Import-DstLib 'InventoryExplorer.ps1'

    function global:Test-DunePortalAccountModeEnabled { return $false }
    function global:Test-DuneToken { return $true }
    function global:Get-DuneCapabilitiesForPrincipal {
        return @([pscustomobject]@{ id = 'inventory.read' })
    }
    function New-InventoryRouteResponse {
        return [pscustomobject]@{
            StatusCode = 0
            ContentType = ''
            ContentLength64 = 0L
            Headers = @{}
            OutputStream = [IO.MemoryStream]::new()
        }
    }
    function Invoke-InventoryRouteRequest {
        param([string]$Path, [hashtable]$Query)
        $queryString = [Collections.Specialized.NameValueCollection]::new()
        foreach ($entry in $Query.GetEnumerator()) {
            $queryString.Add([string]$entry.Key, [string]$entry.Value)
        }
        $suffix = if ($Query.Count) {
            '?' + (($Query.GetEnumerator() | ForEach-Object {
                "$([Uri]::EscapeDataString([string]$_.Key))=$([Uri]::EscapeDataString([string]$_.Value))"
            }) -join '&')
        } else { '' }
        $request = [pscustomobject]@{
            Url = [uri]("http://127.0.0.1$Path$suffix")
            HttpMethod = 'GET'
            IsWebSocketRequest = $false
            HasEntityBody = $false
            Headers = @{}
            QueryString = $queryString
            RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Loopback }
        }
        $response = New-InventoryRouteResponse
        Invoke-DuneContext -Ctx ([pscustomobject]@{ Request = $request; Response = $response })
        $json = [Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray())
        return @{ response = $response; body = ($json | ConvertFrom-Json) }
    }
}

AfterAll {
    Remove-Item Function:\global:Test-DunePortalAccountModeEnabled -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Test-DuneToken -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Get-DuneCapabilitiesForPrincipal -ErrorAction SilentlyContinue
}

Describe 'Inventory production router integration' {
    BeforeEach {
        $script:DuneRoutes = [Collections.Generic.List[object]]::new()
        $script:DuneWsRoutes = [Collections.Generic.List[object]]::new()
        $script:DuneToken = ''
        $script:DuneApiPoolEnabled = $false
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\Gameplay.ps1')
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\Inventory.ps1')
    }

    Describe 'Inventory PostgreSQL CSV conversion contract' {
        It 'returns zero rows for header-only and explicit zero-row output' {
            foreach ($raw in @("BEGIN`ngroup_key,template_id,total_quantity`nROLLBACK")) {
                $parsed = ConvertFrom-DunePsqlCsv -Output $raw -MaxRows 100
                $parsed.ok | Should -BeTrue
                $parsed.rowCount | Should -Be 0
                @($parsed.rows).Count | Should -Be 0
            }
        }

        It 'fails closed on psql diagnostics instead of parsing them as rows' {
            $parsed = ConvertFrom-DunePsqlCsv `
                -Output "psql: warning: fixture`ngroup_key,template_id`ncopper,Copper" -MaxRows 100
            $parsed.ok | Should -BeFalse
            $parsed.message | Should -Match 'Unexpected psql diagnostic'
            @($parsed.rows).Count | Should -Be 0
        }

        It 'does not confuse a diagnostic-shaped CSV value with transport diagnostics' {
            $parsed = ConvertFrom-DunePsqlCsv `
                -Output "message`nNOTICE: maintenance starts at 8" -MaxRows 100
            $parsed.ok | Should -BeTrue
            $parsed.rowCount | Should -Be 1
            $parsed.rows[0][0] | Should -Be 'NOTICE: maintenance starts at 8'
        }

        It 'preserves data values that resemble a psql row-count footer' {
            $parsed = ConvertFrom-DunePsqlCsv -Output "value`n(1 row)" -MaxRows 100
            $parsed.ok | Should -BeTrue
            $parsed.rowCount | Should -Be 1
            $parsed.rows[0][0] | Should -Be '(1 row)'
        }

        It 'rejects a late merged diagnostic that has fewer fields than the CSV header' {
            $parsed = ConvertFrom-DunePsqlCsv `
                -Output "a,b`n1,2`nWARNING: late warning" -MaxRows 100
            $parsed.ok | Should -BeFalse
            $parsed.message | Should -Match 'fields but the header has'
            @($parsed.rows).Count | Should -Be 0
        }

        It 'keeps psql stderr separate from CSV stdout and fails the SQL result' {
            Mock Invoke-DuneSqlRaw {
                @{ stdout = "a,b`n1,2"; stderr = 'WARNING: late,warning'; exitCode = 0 }
            }
            $result = Invoke-DuneSqlQuery -Ip fixture -Sql 'SELECT 1' -ReadOnly $true -MaxRows 10
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'WARNING'
            $result.stderr | Should -Match 'late,warning'
        }

        It 'preserves empty and multi-row semantics under Windows PowerShell 5.1' -Skip:($env:OS -ne 'Windows_NT') {
            $repo = (Get-DstRepoRoot).Replace("'", "''")
            $command = @"
. '$repo\app\server\lib\Database.ps1'
. '$repo\app\server\lib\Gameplay.ps1'
`$empty = ConvertFrom-DunePsqlCsv -Output "BEGIN``na,b``nROLLBACK" -MaxRows 10
if (-not `$empty.ok -or `$empty.rowCount -ne 0) { throw 'PS5.1 empty CSV semantics failed.' }
`$parsed = ConvertFrom-DunePsqlCsv -Output "a,b``n1,2``n3,4" -MaxRows 10
`$maps = ConvertTo-DuneRowMaps -Result @{ ok=`$true; columns=`$parsed.columns; rows=`$parsed.rows }
if (`$maps.Count -ne 2 -or [string]`$maps[1]['b'] -ne '4') { throw 'PS5.1 row-map semantics failed.' }
"@
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
            $LASTEXITCODE | Should -Be 0
        }
    }

    It 'dispatches a grouped item click through the canonical v1 occurrence route' {
        $grouped = Invoke-InventoryRouteRequest -Path '/api/v1/inventory/items' -Query @{
            grouped = '1'; demo = '1'; types = 'player,storage'; sort = 'name-asc'
        }
        $grouped.response.StatusCode | Should -Be 200 -Because ([string]$grouped.body.error)
        $group = @($grouped.body.data.groups | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.templateId)
        })[0]
        $group | Should -Not -BeNullOrEmpty
        @($grouped.body.data.groups | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.templateId) -or
            [string]::IsNullOrWhiteSpace([string]$_.displayName)
        }).Count | Should -Be 0

        $occurrence = Invoke-InventoryRouteRequest -Path '/api/v1/inventory/items/occurrences' -Query @{
            template_id = [string]$group.templateId
            demo = '1'
            types = 'player,storage'
            sort = 'player-asc'
        }
        $occurrence.response.StatusCode | Should -Be 200 -Because ([string]$occurrence.body.error)
        $occurrence.body.data.templateId | Should -Be $group.templateId
        @($occurrence.body.data.items).Count | Should -BeGreaterThan 0
        @($occurrence.body.data.items | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.templateId)
        }).Count | Should -Be 0
    }

    It 'keeps the template-path occurrence route compatible with existing clients' {
        $result = Invoke-InventoryRouteRequest -Path '/api/v1/inventory/items/Spice_Melange/occurrences' -Query @{
            demo = '1'; types = 'player,storage'
        }
        $result.response.StatusCode | Should -Be 200 -Because ([string]$result.body.error)
        $result.body.data.templateId | Should -Be 'Spice_Melange'
    }

    It 'ships the inventory route and read model through the recursive server package source' {
        $repo = Get-DstRepoRoot
        Test-Path (Join-Path $repo 'app\server\routes\Inventory.ps1') | Should -BeTrue
        Test-Path (Join-Path $repo 'app\server\lib\InventoryExplorer.ps1') | Should -BeTrue
        $installer = Get-Content (Join-Path $repo 'app\installer\DuneServer.iss') -Raw
        $installer | Should -Match 'Source: "\.\.\\server\\\*"; DestDir: "\{app\}\\server"; Flags: ignoreversion recursesubdirs'
    }
}
