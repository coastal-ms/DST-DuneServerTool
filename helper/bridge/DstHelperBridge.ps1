<#
.SYNOPSIS
    DST Friend Helper bridge daemon. Runs on the host's PC.

.DESCRIPTION
    Long-lived HTTP listener bound to a stable port (default 47900). Re-reads
    %LOCALAPPDATA%\DuneServer\last-url.txt on every request to discover the
    current DST loopback port + DuneToken (DST rewrites this file on every
    launch). All non-special paths are reverse-proxied to the current DST
    process on 127.0.0.1.

    Trust boundary: this listener binds to LOOPBACK (127.0.0.1) only. Remote
    devices reach it exclusively through a Cloudflare quick tunnel — cloudflared
    runs on this same PC and connects OUT to Cloudflare, then forwards inbound
    requests to 127.0.0.1 locally. Nothing is exposed on the LAN or the public
    internet, so no firewall rule or URL ACL is needed. The DuneToken returned by
    /_dst/token is defense-in-depth.

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
    [string]$LogPath,
    # Override the listener URL prefix. Defaults to loopback (127.0.0.1), which
    # needs no admin / URL ACL and is reached remotely only via the local
    # cloudflared quick tunnel. Set to 'http://+:<port>/' only for legacy setups
    # that front the bridge with their own firewall-scoped exposure.
    [string]$Prefix
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

function Start-WsPumpAsync {
    <#
        Spawn a background PowerShell runspace that pumps WebSocket frames
        one-way (Src -> Dst). Returns @{ PS = ..., Handle = ... } so the
        caller can wait for completion and dispose.
    #>
    param(
        [System.Net.WebSockets.WebSocket]$Src,
        [System.Net.WebSockets.WebSocket]$Dst,
        [System.Threading.CancellationToken]$CT
    )
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript({
        param($s, $d, $ct)
        $buf = [byte[]]::new(16384)
        try {
            while (-not $ct.IsCancellationRequested -and
                   $s.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $seg = [System.ArraySegment[byte]]::new($buf)
                $r = $s.ReceiveAsync($seg, $ct).GetAwaiter().GetResult()
                if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    if ($d.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                        try {
                            [void]$d.CloseOutputAsync(
                                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                                '', [System.Threading.CancellationToken]::None
                            ).GetAwaiter().GetResult()
                        } catch { }
                    }
                    return
                }
                $out = [System.ArraySegment[byte]]::new($buf, 0, $r.Count)
                [void]$d.SendAsync($out, $r.MessageType, $r.EndOfMessage, $ct).GetAwaiter().GetResult()
            }
        } catch {
            # Connection dropped / cancelled. Let the partner pump notice
            # through its own cancellation token; nothing to log per-frame.
        }
    }).AddArgument($Src).AddArgument($Dst).AddArgument($CT) | Out-Null
    return @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Invoke-WsProxy {
    <#
        Bidirectional WebSocket reverse proxy. The friend's browser opens a
        WS to the bridge (e.g. /ws/terminal?t=token); we accept it, open a
        matching WS to DST on loopback, and bridge frames in both directions
        until either side closes.

        Trade-off: this call blocks the main HttpListener loop for the
        lifetime of the WS session. The friend helper is single-user and
        the DST WebUI only opens one WS at a time (from the Terminal page),
        so this is acceptable for the scaffold scope. Periodic REST polls
        from other tabs will queue behind the WS — close the Terminal page
        to free the loop.
    #>
    param(
        [System.Net.HttpListenerContext]$Context,
        [pscustomobject]$Dst
    )
    $req = $Context.Request
    $serverWs = $null
    $client = $null
    $cts = [System.Threading.CancellationTokenSource]::new()
    $j1 = $null
    $j2 = $null

    try {
        # Accept the inbound upgrade (subprotocol negotiation deferred to DST —
        # pass through whatever the client requested, if anything).
        $subprotocol = [NullString]::Value
        $requested = $req.Headers['Sec-WebSocket-Protocol']
        if ($requested) {
            # Use the first offered subprotocol; AcceptWebSocketAsync requires
            # us to pick one specifically rather than echoing the list.
            $subprotocol = ($requested -split ',')[0].Trim()
        }
        $wsCtx = $Context.AcceptWebSocketAsync($subprotocol).GetAwaiter().GetResult()
        $serverWs = $wsCtx.WebSocket

        # Connect to DST on loopback. Same path + query (e.g. ?t=token).
        $client = [System.Net.WebSockets.ClientWebSocket]::new()
        if ($subprotocol -and $subprotocol -ne [NullString]::Value) {
            $client.Options.AddSubProtocol($subprotocol)
        }
        $targetUri = [Uri]::new("ws://127.0.0.1:$($Dst.DstPort)$($req.Url.PathAndQuery)")
        [void]$client.ConnectAsync($targetUri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

        # Two pumps in parallel: client->DST and DST->client.
        $j1 = Start-WsPumpAsync -Src $serverWs -Dst $client -CT $cts.Token
        $j2 = Start-WsPumpAsync -Src $client -Dst $serverWs -CT $cts.Token

        [System.Threading.WaitHandle]::WaitAny(@($j1.Handle.AsyncWaitHandle, $j2.Handle.AsyncWaitHandle)) | Out-Null
        $cts.Cancel()
        # WaitAll isn't supported on STA threads (PowerShell default), so
        # wait on each handle individually with a 5s ceiling each.
        foreach ($j in @($j1, $j2)) {
            try { [void]$j.Handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(5)) } catch { }
        }
    } catch {
        Write-BridgeLog "WS proxy error: $($_.Exception.Message)"
    } finally {
        foreach ($j in @($j1, $j2)) {
            if ($null -ne $j) {
                try { [void]$j.PS.EndInvoke($j.Handle) } catch { }
                try { $j.PS.Dispose() } catch { }
            }
        }
        if ($null -ne $serverWs) {
            try {
                if ($serverWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    [void]$serverWs.CloseAsync(
                        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                        '', [System.Threading.CancellationToken]::None
                    ).GetAwaiter().GetResult()
                }
            } catch { }
            try { $serverWs.Dispose() } catch { }
        }
        if ($null -ne $client) {
            try {
                if ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    [void]$client.CloseAsync(
                        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                        '', [System.Threading.CancellationToken]::None
                    ).GetAwaiter().GetResult()
                }
            } catch { }
            try { $client.Dispose() } catch { }
        }
        $cts.Dispose()
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

        if ($req.IsWebSocketRequest) {
            # WebSocket upgrades (currently just /ws/terminal). Handled inline
            # — see Invoke-WsProxy for the trade-off note about main-loop blocking.
            Invoke-WsProxy -Context $Context -Dst $dst
            Write-BridgeLog "WS  $($req.HttpMethod) $path from $client (closed)"
            return
        }

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
    # Bind to loopback by default: cloudflared connects locally, so nothing needs
    # to be exposed on the LAN/public interfaces and no admin/URL ACL is required.
    # The -Prefix override allows legacy all-interfaces binding if ever needed.
    $effectivePrefix = if ($Prefix) { $Prefix } else { "http://127.0.0.1:$Port/" }
    $listener.Prefixes.Add($effectivePrefix)

    try {
        $listener.Start()
    } catch [System.Net.HttpListenerException] {
        throw "Failed to bind $effectivePrefix — needs admin OR a URL ACL: `n  netsh http add urlacl url=$effectivePrefix user=$env:USERNAME`n($($_.Exception.Message))"
    }

    Write-BridgeLog "DST Helper Bridge listening on $effectivePrefix"
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
