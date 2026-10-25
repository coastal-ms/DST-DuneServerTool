BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'PlayerAccess.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    function New-PrivacyResponse {
        [pscustomobject]@{ StatusCode=0;ContentType='';Headers=@{};ContentLength64=0;OutputStream=[IO.MemoryStream]::new() }
    }
}

Describe 'Player response address privacy' {
    It 'redacts IPv4 and IPv6 in nested data and error messages without changing map coordinates' {
        $json = @{ vm=@{ip='192.0.2.19'};publicIp='198.51.100.42';error='SSH to 192.0.2.19:22 failed';ipv6='2001:db8::5';point=@{x=198.51;y=100.42};name='Own player' } | ConvertTo-Json -Depth 5 -Compress
        $safe = Protect-DunePlayerResponseJson $json
        $safe | Should -Not -Match '192\.0\.2\.19|198\.51\.100\.42|2001:db8::5'
        $decoded = $safe | ConvertFrom-Json
        $decoded.point.x | Should -Be 198.51
        $decoded.name | Should -Be 'Own player'
    }
    It 'marks player responses before shared routes or access-denied errors are written' {
        $response = New-PrivacyResponse
        $params = @{ requestPrincipal=@{type='linked-player'};registeredPath='/api/player-portal/status' }
        $request = @{HttpMethod='GET';Url=[uri]'https://portal.example/api/player-portal/status'}
        Test-DunePlayerRequestAccess -Request $request -Response $response -RouteParams $params -Body $null | Should -BeTrue
        Write-DuneJson -Response $response -Body @{publicIp='198.51.100.42';map='HaggaBasin'}
        $json = [Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray())
        $json | Should -Not -Match '198\.51\.100\.42'
        ($json | ConvertFrom-Json).map | Should -Be 'HaggaBasin'
        $response.ContentLength64 | Should -Be ([Text.Encoding]::UTF8.GetByteCount($json))
    }
    It 'does not change a separate administrator response' {
        $response = New-PrivacyResponse
        Write-DuneJson -Response $response -Body @{publicIp='198.51.100.42'}
        [Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()) | Should -Match '198\.51\.100\.42'
    }
    It 'compresses filtered map data and preserves exact JSON without restoring addresses' {
        $rows = @(1..2000 | ForEach-Object { @{name='Map marker';x=12345.67;y=98765.43;ip='192.0.2.19'} })
        $json = Protect-DunePlayerResponseJson (ConvertTo-Json -InputObject @{items=$rows} -Depth 4 -Compress)
        $plain = [Text.Encoding]::UTF8.GetBytes($json)
        $packed = Compress-DunePlayerMapJson -Bytes $plain
        $packed.GetType().FullName | Should -Be 'System.Byte[]'
        $packed.Length | Should -BeLessThan ($plain.Length / 10)
        $stream = [IO.MemoryStream]::new($packed, $false)
        $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
        $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
        try {
            $decoded = $reader.ReadToEnd()
            $decoded | Should -BeExactly $json
            $decoded | Should -Not -Match '192\.0\.2\.19'
            @((ConvertFrom-Json $decoded).items).Count | Should -Be 2000
        } finally { $reader.Dispose(); $gzip.Dispose(); $stream.Dispose() }
    }
}
