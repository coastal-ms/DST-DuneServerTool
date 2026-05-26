# Dune Server — HTTP server (PowerShell HttpListener)
#
# Serves the built React SPA from <DistRoot> and dispatches /api/* and /ws/*
# to route handlers registered via Register-DuneRoute.
#
# Localhost-only. Per-launch GUID token required on every /api/* and /ws/* call.

$script:DuneRoutes      = [System.Collections.Generic.List[object]]::new()
$script:DuneWsRoutes    = [System.Collections.Generic.List[object]]::new()
$script:DuneToken       = [string]::Empty
$script:DuneListener    = $null
$script:DunePrefixUrl   = $null
$script:DuneDistRoot    = $null

# ---------- MIME ---------------------------------------------------------------

$script:DuneMimeMap = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.mjs'  = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.map'  = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.ico'  = 'image/x-icon'
    '.webp' = 'image/webp'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
    '.ttf'  = 'font/ttf'
    '.txt'  = 'text/plain; charset=utf-8'
}

function Get-DuneMimeType {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:DuneMimeMap.ContainsKey($ext)) { return $script:DuneMimeMap[$ext] }
    return 'application/octet-stream'
}

# ---------- Routing ------------------------------------------------------------

function Register-DuneRoute {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE','PATCH')] [string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Handler
    )
    $pattern = '^' + ([regex]::Escape($Path) -replace '\\\{([^/}]+)}', '(?<$1>[^/]+)') + '$'
    $script:DuneRoutes.Add([pscustomobject]@{
        Method  = $Method
        Path    = $Path
        Regex   = [regex]$pattern
        Handler = $Handler
    }) | Out-Null
}

function Register-DuneWebSocket {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Handler
    )
    $pattern = '^' + ([regex]::Escape($Path) -replace '\\\{([^/}]+)}', '(?<$1>[^/]+)') + '$'
    $script:DuneWsRoutes.Add([pscustomobject]@{
        Path    = $Path
        Regex   = [regex]$pattern
        Handler = $Handler
    }) | Out-Null
}

# ---------- Responses ----------------------------------------------------------

function Write-DuneJson {
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] $Body,
        [int]$Status = 200
    )
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.Headers['Cache-Control'] = 'no-store'
    $json  = if ($null -eq $Body) { 'null' } else { $Body | ConvertTo-Json -Depth 12 -Compress }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Write-DuneError {
    param($Response, [int]$Status, [string]$Message)
    Write-DuneJson -Response $Response -Status $Status -Body @{ error = $Message }
}

function Write-DuneFile {
    param($Response, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-DuneError -Response $Response -Status 404 -Message 'Not found'
        return
    }
    $Response.StatusCode  = 200
    $Response.ContentType = Get-DuneMimeType $Path

    # Cache hashed assets aggressively, anything else not at all.
    if ($Path -match '\\assets\\.+\-[A-Za-z0-9_-]{6,}\.(?:js|css|woff2?|png|jpg|svg)$') {
        $Response.Headers['Cache-Control'] = 'public, max-age=31536000, immutable'
    } else {
        $Response.Headers['Cache-Control'] = 'no-cache'
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $Response.ContentLength64 = $stream.Length
        $stream.CopyTo($Response.OutputStream)
    } finally {
        $stream.Dispose()
        $Response.OutputStream.Close()
    }
}

# ---------- Static SPA serving -------------------------------------------------

function Resolve-DuneStaticPath {
    param([string]$UrlPath)
    if ([string]::IsNullOrEmpty($UrlPath) -or $UrlPath -eq '/') {
        return (Join-Path $script:DuneDistRoot 'index.html')
    }
    $rel = $UrlPath.TrimStart('/')
    if ($rel.Contains('..')) { return $null }
    $full = Join-Path $script:DuneDistRoot $rel
    $normalized = [System.IO.Path]::GetFullPath($full)
    $rootNorm   = [System.IO.Path]::GetFullPath($script:DuneDistRoot)
    if (-not $normalized.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $normalized
}

# ---------- Token --------------------------------------------------------------

function Test-DuneToken {
    param($Request)
    if ([string]::IsNullOrEmpty($script:DuneToken)) { return $true }  # dev-mode escape hatch
    $hdr = $Request.Headers['X-Dune-Token']
    if (-not $hdr) { $hdr = $Request.QueryString['t'] }
    return ($hdr -eq $script:DuneToken)
}

# ---------- Main loop ----------------------------------------------------------

function Start-DuneHttpServer {
    param(
        [Parameter(Mandatory)][string]$DistRoot,
        [int]$PreferredPort = 47823,
        [string]$Token = ''
    )

    $script:DuneDistRoot = (Resolve-Path -LiteralPath $DistRoot).Path
    $script:DuneToken    = $Token

    # Find a free port starting at $PreferredPort.
    $port = $PreferredPort
    $listener = $null
    while ($port -lt ($PreferredPort + 50)) {
        try {
            $l = [System.Net.HttpListener]::new()
            $prefix = "http://127.0.0.1:$port/"
            $l.Prefixes.Add($prefix)
            $l.Start()
            $listener = $l
            $script:DunePrefixUrl = $prefix
            break
        } catch {
            try { $l.Close() } catch {}
            $port++
        }
    }
    if (-not $listener) {
        throw "Could not bind HTTP listener in range $PreferredPort..$($PreferredPort + 49)"
    }
    $script:DuneListener = $listener
    Write-Host "[dune-http] Listening on $script:DunePrefixUrl" -ForegroundColor Cyan

    try {
        while ($listener.IsListening) {
            $ctxTask = $listener.GetContextAsync()
            $ctx = $ctxTask.GetAwaiter().GetResult()
            try {
                Invoke-DuneContext -Ctx $ctx
            } catch {
                try {
                    $ctx.Response.StatusCode = 500
                    $msg = "Server error: $($_.Exception.Message)"
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.OutputStream.Close()
                } catch {}
                Write-Host "[dune-http] $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
}

function Stop-DuneHttpServer {
    if ($script:DuneListener) {
        try { $script:DuneListener.Stop() } catch {}
        try { $script:DuneListener.Close() } catch {}
        $script:DuneListener = $null
    }
}

function Get-DuneServerUrl {
    if (-not $script:DunePrefixUrl) { return $null }
    if ([string]::IsNullOrEmpty($script:DuneToken)) { return $script:DunePrefixUrl }
    return ("{0}?t={1}" -f $script:DunePrefixUrl, [Uri]::EscapeDataString($script:DuneToken))
}

function Invoke-DuneContext {
    param($Ctx)
    $req = $Ctx.Request
    $res = $Ctx.Response
    $rawPath = $req.Url.AbsolutePath
    $method  = $req.HttpMethod

    # WebSocket upgrades
    if ($req.IsWebSocketRequest) {
        if (-not (Test-DuneToken -Request $req)) {
            $res.StatusCode = 401
            $res.OutputStream.Close()
            return
        }
        foreach ($r in $script:DuneWsRoutes) {
            $m = $r.Regex.Match($rawPath)
            if ($m.Success) {
                $routeParams = @{}
                foreach ($g in $r.Regex.GetGroupNames()) {
                    if ($g -notmatch '^\d+$') { $routeParams[$g] = $m.Groups[$g].Value }
                }
                $wsTask = $Ctx.AcceptWebSocketAsync($null)
                $wsCtx  = $wsTask.GetAwaiter().GetResult()
                & $r.Handler $wsCtx.WebSocket $routeParams $req
                return
            }
        }
        $res.StatusCode = 404
        $res.OutputStream.Close()
        return
    }

    # API routes
    if ($rawPath.StartsWith('/api/')) {
        if (-not (Test-DuneToken -Request $req)) {
            Write-DuneError -Response $res -Status 401 -Message 'Invalid or missing token'
            return
        }
        foreach ($r in $script:DuneRoutes) {
            if ($r.Method -ne $method) { continue }
            $m = $r.Regex.Match($rawPath)
            if ($m.Success) {
                $routeParams = @{}
                foreach ($g in $r.Regex.GetGroupNames()) {
                    if ($g -notmatch '^\d+$') { $routeParams[$g] = $m.Groups[$g].Value }
                }
                $body = $null
                if ($req.HasEntityBody) {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if ($body -and $req.ContentType -like 'application/json*') {
                        try { $body = $body | ConvertFrom-Json -AsHashtable } catch { }
                    }
                }
                & $r.Handler $req $res $routeParams $body
                return
            }
        }
        Write-DuneError -Response $res -Status 404 -Message "No route for $method $rawPath"
        return
    }

    # Static SPA serving (GET only)
    if ($method -ne 'GET' -and $method -ne 'HEAD') {
        Write-DuneError -Response $res -Status 405 -Message 'Method not allowed'
        return
    }

    $filePath = Resolve-DuneStaticPath -UrlPath $rawPath
    if ($filePath -and (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-DuneFile -Response $res -Path $filePath
        return
    }

    # SPA fallback — serve index.html for client-side routes
    $indexPath = Join-Path $script:DuneDistRoot 'index.html'
    if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        Write-DuneFile -Response $res -Path $indexPath
        return
    }

    Write-DuneError -Response $res -Status 404 -Message 'Static asset not found'
}
