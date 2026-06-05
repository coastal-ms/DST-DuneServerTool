<#
.SYNOPSIS
    DST Friend Helper bridge daemon. Runs on Neil's PC.

.DESCRIPTION
    Long-lived HTTP listener bound to a stable port (default 47900). Re-reads
    %LOCALAPPDATA%\DuneServer\last-url.txt on every request to discover the
    current DST loopback port + DuneToken (DST rewrites this file on every
    launch). All non-special paths are reverse-proxied to the current DST
    process on 127.0.0.1.

    Trust boundary: this listener binds to all interfaces, but the companion
    Windows Firewall rule (see Install-Bridge.ps1) restricts inbound traffic
    to the Tailscale interface only. Tailscale ACLs gate which devices on
    the tailnet can reach this port. The DuneToken returned by /_dst/token
    is defense-in-depth.

.PARAMETER Port
    TCP port to listen on. Default 47900.

.PARAMETER LastUrlPath
    Path to DST's last-url.txt. Default %LOCALAPPDATA%\DuneServer\last-url.txt.

.PARAMETER LogPath
    Optional log file path. When set, each request is appended.

.NOTES
    PowerShell 7+ (uses [System.Net.Http.HttpClient] async patterns
    synchronously via .GetAwaiter().GetResult()).
#>

[CmdletBinding()]
param(
    [int]$Port = 47900,
    [string]$LastUrlPath = (Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'),
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Hop-by-hop headers that must not be forwarded (RFC 7230 §6.1) plus a few
# that HttpClient / HttpListener manage themselves.
$script:HopByHop = @(
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade',
    'host', 'content-length'
)

# Shared HttpClient — keep-alive + connection pooling to localhost.
$script:HttpClient = [System.Net.Http.HttpClient]::new()
$script:HttpClient.Timeout = [TimeSpan]::FromSeconds(60)

function Write-BridgeLog {
    param([string]$Message)
    $line = "{0} {1}" -f ([DateTime]::UtcNow.ToString('o')), $Message
    Write-Host $line
    if ($LogPath) {
        try {
            $dir = Split-Path -Parent $LogPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
        } catch {
            # Swallow log errors — never let logging take the daemon down.
        }
    }
}

function Get-CurrentDst {
    <#
        Re-read last-url.txt and parse out the current DST loopback URL +
        token. Cheap (single file read), so safe to call per request.
    #>
    if (-not (Test-Path -LiteralPath $LastUrlPath)) {
        throw "last-url.txt not found at $LastUrlPath — is DST running?"
    }
    $raw = (Get-Content -LiteralPath $LastUrlPath -Raw).Trim()
    if (-not $raw) {
        throw "last-url.txt is empty"
    }
    # Expected: http://127.0.0.1:<port>/?t=<token>
    $match = [regex]::Match($raw, '^https?://127\.0\.0\.1:(?<port>\d+)/?\?t=(?<token>[A-Za-z0-9]+)\s*$')
    if (-not $match.Success) {
        throw "last-url.txt does not match expected format: '$raw'"
    }
    return [pscustomobject]@{
        DstPort = [int]$match.Groups['port'].Value
        Token   = $match.Groups['token'].Value
        BaseUrl = "http://127.0.0.1:$($match.Groups['port'].Value)"
    }
}

function Send-JsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        $Body
    )
    $json = $Body | ConvertTo-Json -Compress -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.LongLength
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Invoke-Proxy {
    param(
        [System.Net.HttpListenerContext]$Context,
        [pscustomobject]$Dst
    )
    $req = $Context.Request
    $res = $Context.Response

    # Build the target URI: same path + query, but pointing at loopback DST.
    $targetUri = [Uri]::new("$($Dst.BaseUrl)$($req.Url.PathAndQuery)")
    $httpReq = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($req.HttpMethod),
        $targetUri
    )

    # Copy body (POST/PUT/PATCH). Buffer to memory — DST API payloads are
    # tiny, and HttpListener's InputStream is non-seekable.
    $methodHasBody = @('POST', 'PUT', 'PATCH', 'DELETE') -contains $req.HttpMethod.ToUpperInvariant()
    if ($methodHasBody -and $req.HasEntityBody) {
        $ms = [System.IO.MemoryStream]::new()
        $req.InputStream.CopyTo($ms)
        $ms.Position = 0
        $content = [System.Net.Http.StreamContent]::new($ms)
        if ($req.ContentType) {
            $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($req.ContentType)
        }
        $httpReq.Content = $content
    }

    # Copy headers (skipping hop-by-hop + host/content-length).
    foreach ($name in $req.Headers.AllKeys) {
        if ($script:HopByHop -contains $name.ToLowerInvariant()) { continue }
        $values = $req.Headers.GetValues($name)
        # Try request headers first, fall back to content headers.
        if (-not $httpReq.Headers.TryAddWithoutValidation($name, $values)) {
            if ($httpReq.Content) {
                [void]$httpReq.Content.Headers.TryAddWithoutValidation($name, $values)
            }
        }
    }

    # Send and stream the response back.
    $httpRes = $script:HttpClient.SendAsync(
        $httpReq,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()

    try {
        $res.StatusCode = [int]$httpRes.StatusCode

        foreach ($h in $httpRes.Headers) {
            if ($script:HopByHop -contains $h.Key.ToLowerInvariant()) { continue }
            try { $res.Headers[$h.Key] = ($h.Value -join ', ') } catch { }
        }
        if ($httpRes.Content) {
            foreach ($h in $httpRes.Content.Headers) {
                if ($script:HopByHop -contains $h.Key.ToLowerInvariant()) { continue }
                if ($h.Key -ieq 'Content-Type') {
                    $res.ContentType = ($h.Value -join ', ')
                    continue
                }
                try { $res.Headers[$h.Key] = ($h.Value -join ', ') } catch { }
            }

            $stream = $httpRes.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try { $stream.CopyTo($res.OutputStream) } finally { $stream.Dispose() }
        }
    } finally {
        $httpRes.Dispose()
        try { $res.OutputStream.Close() } catch { }
    }
}

function Invoke-Request {
    param([System.Net.HttpListenerContext]$Context)
    $req = $Context.Request
    $res = $Context.Response
    $path = $req.Url.AbsolutePath
    $client = $req.RemoteEndPoint

    try {
        if ($path -eq '/_dst/token') {
            $dst = Get-CurrentDst
            Send-JsonResponse -Response $res -StatusCode 200 -Body @{
                url   = $dst.BaseUrl
                token = $dst.Token
            }
            Write-BridgeLog "200 $($req.HttpMethod) $path from $client (token-handout)"
            return
        }

        if ($path -eq '/_dst/health') {
            try {
                $null = Get-CurrentDst
                Send-JsonResponse -Response $res -StatusCode 200 -Body @{ ok = $true }
            } catch {
                Send-JsonResponse -Response $res -StatusCode 503 -Body @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }

        # Everything else: reverse-proxy to current DST.
        $dst = Get-CurrentDst
        Invoke-Proxy -Context $Context -Dst $dst
        Write-BridgeLog "$($res.StatusCode) $($req.HttpMethod) $path from $client"
    } catch {
        $msg = $_.Exception.Message
        Write-BridgeLog "ERR $($req.HttpMethod) $path from $client : $msg"
        try {
            Send-JsonResponse -Response $res -StatusCode 502 -Body @{
                ok    = $false
                error = $msg
            }
        } catch {
            try { $res.OutputStream.Close() } catch { }
        }
    }
}

function Start-Bridge {
    $listener = [System.Net.HttpListener]::new()
    # Bind to all interfaces; the firewall rule scopes inbound to Tailscale.
    $prefix = "http://+:$Port/"
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    } catch [System.Net.HttpListenerException] {
        throw "Failed to bind $prefix — needs admin OR a URL ACL: `n  netsh http add urlacl url=$prefix user=$env:USERNAME`n($($_.Exception.Message))"
    }

    Write-BridgeLog "DST Helper Bridge listening on $prefix"
    Write-BridgeLog "Watching $LastUrlPath"

    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            # Inline (synchronous) handling. Friend helper = single user;
            # concurrency isn't worth runspace overhead here.
            Invoke-Request -Context $ctx
        }
    } finally {
        try { $listener.Stop(); $listener.Close() } catch { }
        try { $script:HttpClient.Dispose() } catch { }
        Write-BridgeLog "Bridge stopped."
    }
}

Start-Bridge
