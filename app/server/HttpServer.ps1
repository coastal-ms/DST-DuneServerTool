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
$script:DuneWsPool      = $null   # RunspacePool — WS handlers run here so they don't block the main HTTP loop

# --- API handler pool (issue #47): HTTP /api handlers run on a runspace pool so
# a slow handler (SSH/kubectl/backup/install) can't head-of-line-block the
# single-threaded listener and freeze the whole UI. ----------------------------
$script:DuneApiPool      = $null   # RunspacePool for /api handlers
$script:DuneApiGate      = $null   # SemaphoreSlim bounding in-flight handlers (saturation -> 503)
$script:DuneApiInFlight  = $null   # synchronized list of {Ps;Handle;Release} for cleanup
$script:DuneApiLockTable = $null   # shared synchronized name -> SemaphoreSlim registry (named locks)
$script:DuneApiCtx       = $null   # immutable server-context injected into every worker
$script:DuneApiMax       = 16      # max concurrent handlers == pool max == gate count
$script:DuneServerDir    = $null   # server/ dir (for the pool's startup dot-sources)

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
    '.webmanifest' = 'application/manifest+json; charset=utf-8'
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
        [Parameter(Mandatory)][scriptblock]$Handler,
        # Inline routes run ON the listener thread instead of the handler pool.
        # Reserve this for fast handlers that mutate MAIN-runspace lifecycle state
        # (e.g. the listener / app-detach flag) which a worker runspace can't touch.
        [switch]$Inline
    )
    $pattern = '^' + ([regex]::Escape($Path) -replace '\\\{([^/}]+)}', '(?<$1>[^/]+)') + '$'
    $script:DuneRoutes.Add([pscustomobject]@{
        Method  = $Method
        Path    = $Path
        Regex   = [regex]$pattern
        Handler = $Handler
        Inline  = [bool]$Inline
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

# Initialize the WebSocket handler runspace pool. WS sessions can be
# long-lived (terminal, log streams) and would block the single-threaded
# HTTP main loop. Min=1 / Max=8 covers multiple terminals + ambient streams.
function Initialize-DuneWsPool {
    if ($script:DuneWsPool) { return }
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
    $pool.Open()
    $script:DuneWsPool = $pool
}

# Fire-and-forget dispatch of a WebSocket handler scriptblock. The handler
# runs in a runspace from the pool — .NET types loaded into the AppDomain
# (Pty.Net, DuneServer.PtySink, WebSockets) are visible, but PS functions
# from main runspace's lib/*.ps1 are NOT. Pass any state via arguments.
function Invoke-DuneWsHandlerAsync {
    param(
        [Parameter(Mandatory)][scriptblock]$Handler,
        [Parameter(Mandatory)]$WebSocket,
        [Parameter(Mandatory)][hashtable]$RouteParams
    )
    Initialize-DuneWsPool
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:DuneWsPool
    [void]$ps.AddScript({
        param($handlerText, $ws, $routeParams)
        try {
            $h = [scriptblock]::Create($handlerText)
            & $h $ws $routeParams
        } catch {
            Write-Host "[ws-handler] $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            try {
                if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    $ws.CloseAsync(
                        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                        'closing', [System.Threading.CancellationToken]::None
                    ).GetAwaiter().GetResult()
                }
            } catch {}
            try { $ws.Dispose() } catch {}
        }
    }).AddArgument($Handler.ToString()).AddArgument($WebSocket).AddArgument($RouteParams)
    [void]$ps.BeginInvoke()
}

# ---------- Named locks (issue #47) --------------------------------------------
#
# Once handlers run concurrently, two simultaneous read-modify-write mutations of
# the same resource (director.ini, config file, backup cron, on-demand CRD scale,
# installs) can clobber each other. Invoke-WithDuneLock serializes them by name.
#
# The registry MUST be a single object shared across every worker runspace, so it
# is created once in Initialize-DuneApiPool and injected into workers via the
# server context. Get-DuneLock lazily creates a per-name SemaphoreSlim under a
# SyncRoot monitor (synchronized hashtables make single ops atomic, but
# check-then-add is two ops and would otherwise race two locks into existence).

function Get-DuneLock {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:DuneApiLockTable) {
        $script:DuneApiLockTable = [System.Collections.Hashtable]::Synchronized(@{})
    }
    $table = $script:DuneApiLockTable
    [System.Threading.Monitor]::Enter($table.SyncRoot)
    try {
        if (-not $table.ContainsKey($Name)) {
            $table[$Name] = [System.Threading.SemaphoreSlim]::new(1, 1)
        }
        return $table[$Name]
    } finally {
        [System.Threading.Monitor]::Exit($table.SyncRoot)
    }
}

function Invoke-WithDuneLock {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$TimeoutSec = 30
    )
    $sem = Get-DuneLock -Name $Name
    if (-not $sem.Wait($TimeoutSec * 1000)) {
        throw "Resource '$Name' is busy (timed out after ${TimeoutSec}s waiting for the lock)."
    }
    try { & $Script } finally { [void]$sem.Release() }
}

# ---------- API handler runspace pool (issue #47) ------------------------------

# Build the pool whose worker runspaces have every lib function + route handler
# available (same dot-source order as DuneServer.ps1). Each runspace pays the
# dot-source cost once (pooled, reused across requests). All Add-Type calls in
# those files are lazy (inside functions) so dot-sourcing has no AppDomain side
# effects beyond defining functions + harmless route re-registration.
function Initialize-DuneApiPool {
    param([string]$ServerDir = $script:DuneServerDir)
    if ($script:DuneApiPool) { return }
    if (-not $ServerDir -or -not (Test-Path -LiteralPath $ServerDir)) {
        throw "Initialize-DuneApiPool: server dir not found ('$ServerDir')."
    }

    # Shared cross-runspace coordination objects (created ONCE).
    $script:DuneApiGate      = [System.Threading.SemaphoreSlim]::new($script:DuneApiMax, $script:DuneApiMax)
    $script:DuneApiInFlight  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    if (-not $script:DuneApiLockTable) {
        $script:DuneApiLockTable = [System.Collections.Hashtable]::Synchronized(@{})
    }

    # Immutable snapshot of the main-runspace $script: vars that route handlers
    # read but that are set by DuneServer.ps1's bootstrap / Start-DuneHttpServer
    # (i.e. NOT defined by dot-sourcing the lib files). Everything else the
    # handlers use is defined per-runspace by the startup dot-sources.
    $script:DuneApiCtx = @{
        Token         = $script:DuneToken
        PrefixUrl     = $script:DunePrefixUrl
        Listener      = $script:DuneListener
        DistRoot      = $script:DuneDistRoot
        ToolVersion   = $script:DuneToolVersion
        PwshExe       = $script:PwshExe
        MainScript    = $script:MainScript
        AppDir        = $script:AppDir
        LogPath       = $script:DuneLogPath
        IsCompiledExe = $script:DuneIsCompiledExe
        LockTable     = $script:DuneApiLockTable
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $duneLog = Join-Path $ServerDir 'lib\DuneLog.ps1'
    if (Test-Path -LiteralPath $duneLog) { [void]$iss.StartupScripts.Add($duneLog) }
    [void]$iss.StartupScripts.Add((Join-Path $ServerDir 'HttpServer.ps1'))
    $libDir = Join-Path $ServerDir 'lib'
    if (Test-Path -LiteralPath $libDir) {
        foreach ($f in (Get-ChildItem -Path $libDir -Filter '*.ps1' | Sort-Object Name)) {
            if ($f.Name -ieq 'DuneLog.ps1') { continue }
            [void]$iss.StartupScripts.Add($f.FullName)
        }
    }
    $routesDir = Join-Path $ServerDir 'routes'
    if (Test-Path -LiteralPath $routesDir) {
        foreach ($f in (Get-ChildItem -Path $routesDir -Filter '*.ps1' | Sort-Object Name)) {
            [void]$iss.StartupScripts.Add($f.FullName)
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(2, $script:DuneApiMax, $iss, $Host)
    $pool.Open()
    $script:DuneApiPool = $pool
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "API handler pool ready (2..$($script:DuneApiMax) runspaces)"
    }
}

# Reclaim a gate permit exactly once, no matter which thread gets here first
# (worker finally, or the main-loop sweep). Double-release would over-count the
# SemaphoreSlim and throw, so guard with a one-shot flag under a monitor.
function Complete-DuneApiRelease {
    param([Parameter(Mandatory)]$Release)
    try {
        [System.Threading.Monitor]::Enter($Release)
        if (-not $Release.Done) {
            $Release.Done = $true
            if ($Release.Gate) { [void]$Release.Gate.Release() }
        }
    } catch {
    } finally {
        try { [System.Threading.Monitor]::Exit($Release) } catch {}
    }
}

# Fire-and-forget dispatch of one /api handler onto the pool. The listener
# thread has already done the (fast, CPU-only) token check + route match; the
# worker reads/parses the body (off the accept loop, so a slow upload can't stall
# it) and runs the handler. The worker ALWAYS closes the response so a failed or
# throwing handler never leaves the client hanging.
function Invoke-DuneApiHandlerAsync {
    param(
        [Parameter(Mandatory)][scriptblock]$Handler,
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][hashtable]$RouteParams
    )

    # Saturation guard: never queue behind a full pool. If every permit is held
    # (e.g. many hung SSH calls during a VM outage) answer 503 immediately so the
    # UI gets a fast, honest error instead of an unbounded wait.
    if (-not $script:DuneApiGate.Wait(0)) {
        try { Write-DuneError -Response $Response -Status 503 -Message 'Server busy: handler pool saturated. Try again shortly.' } catch {}
        # Remote portal audit (issue #74): saturation on a remote write
        # never reaches the worker's finally block, so log here.
        try {
            if ($RouteParams -and $RouteParams.ContainsKey('remoteEmail') -and $RouteParams.remoteEmail) {
                $m = ''; try { $m = [string]$Request.HttpMethod } catch {}
                if ($m -and $m -ne 'GET' -and $m -ne 'HEAD') {
                    $p = ''; try { $p = [string]$Request.Url.AbsolutePath } catch {}
                    Write-DuneRemoteAudit -Role ([string]$RouteParams.remoteRole) -Email ([string]$RouteParams.remoteEmail) -Method $m -Path $p -Status 503 -Note 'pool-saturated'
                }
            }
        } catch {}
        return
    }

    $release = [pscustomobject]@{ Gate = $script:DuneApiGate; Done = $false }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:DuneApiPool
    [void]$ps.AddScript({
        param($handlerText, $req, $res, $routeParams, $ctx, $release)
        try {
            # Inject main-runspace server context into BOTH scopes. Functions
            # defined by the startup dot-sources read these as $script:X (which,
            # for a dot-sourced top-level scope, resolves to global); we set both
            # to be unambiguous. Done per-invocation AFTER startup scripts ran so
            # HttpServer.ps1's own `$script:DuneToken = ''` init can't clobber it.
            foreach ($pair in @(
                ,@('DuneToken',        $ctx.Token)
                ,@('DunePrefixUrl',    $ctx.PrefixUrl)
                ,@('DuneListener',     $ctx.Listener)
                ,@('DuneDistRoot',     $ctx.DistRoot)
                ,@('DuneToolVersion',  $ctx.ToolVersion)
                ,@('PwshExe',          $ctx.PwshExe)
                ,@('MainScript',       $ctx.MainScript)
                ,@('AppDir',           $ctx.AppDir)
                ,@('DuneLogPath',      $ctx.LogPath)
                ,@('DuneIsCompiledExe',$ctx.IsCompiledExe)
                ,@('DuneApiLockTable', $ctx.LockTable)
            )) {
                Set-Variable -Name $pair[0] -Value $pair[1] -Scope Global -ErrorAction SilentlyContinue
                Set-Variable -Name $pair[0] -Value $pair[1] -Scope Script -ErrorAction SilentlyContinue
            }

            # Read + parse the request body here (off the listener thread).
            $body = $null
            if ($req.HasEntityBody) {
                if ($req.ContentLength64 -gt 26214400) {   # 25 MB hard cap
                    Write-DuneError -Response $res -Status 413 -Message 'Request body too large.'
                    return
                }
                $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($raw -and $req.ContentType -like 'application/json*') {
                    $body = ConvertFrom-DuneRequestJson -Raw $raw
                } else {
                    $body = $raw
                }
            }

            $h = [scriptblock]::Create($handlerText)
            & $h $req $res $routeParams $body
        } catch {
            # Off-thread failure: best-effort 500. If the handler already started
            # the response this throws and is swallowed; the finally still closes.
            try {
                $res.StatusCode = 500
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("Server error: $($_.Exception.Message)")
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {}
            try {
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    Write-DuneLog "api-handler error: $($_.Exception.Message)" 'ERROR'
                }
            } catch {}
        } finally {
            try { $res.OutputStream.Close() } catch {}
            # Remote portal audit log (issue #74): when this worker handled
            # a write (non-GET) /api/remote/* request, append one line with
            # the final status code. Reads are NOT audit-logged. Listener-
            # thread denials (401/403/503) are logged in Invoke-DuneContext
            # directly because the worker never starts for those.
            try {
                if ($routeParams -and $routeParams.ContainsKey('remoteEmail') -and $routeParams.remoteEmail) {
                    $m = ''
                    try { $m = [string]$req.HttpMethod } catch {}
                    if ($m -and $m -ne 'GET' -and $m -ne 'HEAD') {
                        $p = ''
                        try { $p = [string]$req.Url.AbsolutePath } catch {}
                        $sc = 0
                        try { $sc = [int]$res.StatusCode } catch {}
                        if (Get-Command Write-DuneRemoteAudit -ErrorAction SilentlyContinue) {
                            Write-DuneRemoteAudit -Role ([string]$routeParams.remoteRole) -Email ([string]$routeParams.remoteEmail) -Method $m -Path $p -Status $sc
                        }
                    }
                }
            } catch {}
            try { $res.Close() } catch {}
            # Release the gate permit (idempotent with the main-loop sweep).
            try {
                [System.Threading.Monitor]::Enter($release)
                if (-not $release.Done) { $release.Done = $true; if ($release.Gate) { [void]$release.Gate.Release() } }
            } catch {} finally { try { [System.Threading.Monitor]::Exit($release) } catch {} }
        }
    }).AddArgument($Handler.ToString()).AddArgument($Request).AddArgument($Response).AddArgument($RouteParams).AddArgument($script:DuneApiCtx).AddArgument($release)

    try {
        $handle = $ps.BeginInvoke()
        [void]$script:DuneApiInFlight.Add([pscustomobject]@{ Ps = $ps; Handle = $handle; Release = $release })
    } catch {
        # Couldn't even start the pipeline — reclaim the permit and answer now so
        # the client isn't left hanging on a request we never ran.
        Complete-DuneApiRelease -Release $release
        try { $ps.Dispose() } catch {}
        try { Write-DuneError -Response $Response -Status 503 -Message 'Server busy: could not dispatch handler.' } catch {}
    }
}

# Reap finished worker pipelines: EndInvoke + Dispose, and defensively reclaim
# any permit a worker somehow failed to release (e.g. an aborted runspace).
# Called each iteration of the accept loop and during shutdown. Per-entry
# try/catch so one faulted EndInvoke can't abort the whole sweep.
function Clear-DuneApiCompleted {
    if (-not $script:DuneApiInFlight) { return }
    $done = @()
    foreach ($e in @($script:DuneApiInFlight.ToArray())) {
        if ($e.Handle -and $e.Handle.IsCompleted) { $done += $e }
    }
    foreach ($e in $done) {
        try { [void]$e.Ps.EndInvoke($e.Handle) } catch {}
        try { $e.Ps.Dispose() } catch {}
        Complete-DuneApiRelease -Release $e.Release
        try { [void]$script:DuneApiInFlight.Remove($e) } catch {}
    }
}

# ---------- Responses ----------------------------------------------------------

# Parse incoming JSON request body into a [hashtable] that works on both
# Windows PowerShell 5.1 (no -AsHashtable) and PowerShell 7+. Falls back to
# the raw string on parse failure so callers can still inspect it.
function ConvertFrom-DuneRequestJson {
    param([Parameter(Mandatory)][string]$Raw)
    if (-not $Raw -or -not $Raw.Trim()) { return $null }
    # PS 7+: prefer -AsHashtable when available.
    $hasAsHashtable = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('AsHashtable')
    if ($hasAsHashtable) {
        try { return ($Raw | ConvertFrom-Json -AsHashtable) } catch { return $Raw }
    }
    # PS 5.1: parse to PSCustomObject, then convert recursively to [hashtable].
    try {
        $obj = $Raw | ConvertFrom-Json
        return (ConvertTo-DuneHashtable -InputObject $obj)
    } catch {
        return $Raw
    }
}

function ConvertTo-DuneHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($k in $InputObject.Keys) { $out[[string]$k] = ConvertTo-DuneHashtable $InputObject[$k] }
        return $out
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $out[$p.Name] = ConvertTo-DuneHashtable $p.Value }
        return $out
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        return ,@($InputObject | ForEach-Object { ConvertTo-DuneHashtable $_ })
    }
    return $InputObject
}

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
    param(
        $Response,
        [string]$Path,
        # When set, treat the file as the remote-portal index.html and
        # string-replace the <!-- DUNE_REMOTE_BOOTSTRAP --> marker with a
        # tiny <script> tag that exposes the per-launch DuneToken to the
        # remote SPA. Issue #74: this is how the SPA gets the token without
        # the user having to paste it on a phone.
        [switch]$InjectRemoteToken
    )
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

    if ($InjectRemoteToken) {
        # index.html is small (~1 KB); read it as text, do the replacement,
        # then emit UTF-8 bytes. Never cached (we already set no-cache above).
        $html = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $tokenLiteral = if ($script:DuneToken) { ($script:DuneToken -replace '"','\"') } else { '' }
        $script = '<script>window.__duneRemoteToken="' + $tokenLiteral + '";</script>'
        $html = $html -replace '<!--\s*DUNE_REMOTE_BOOTSTRAP\s*-->', $script
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Close()
        return
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
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "HTTP listening on $script:DunePrefixUrl"
    } else {
        Write-Host "[dune-http] Listening on $script:DunePrefixUrl" -ForegroundColor Cyan
    }

    # Persist actual URL (with token) for external tools.
    $actualUrl = if ($Token) { "{0}?t={1}" -f $script:DunePrefixUrl, [Uri]::EscapeDataString($Token) } else { $script:DunePrefixUrl }
    try {
        $stateDir = Join-Path $env:LOCALAPPDATA 'DuneServer'
        if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $stateDir 'last-url.txt') -Value $actualUrl -Encoding UTF8 -Force
    } catch { }

    # Link the app-window + console lifecycle to this listener now that it's
    # bound: closing the app window stops the server, and apply the user's
    # chosen console presentation (minimized vs. system tray). No-op in
    # browser-fallback mode (nothing to watch).
    if (Get-Command Start-DuneConsoleLifecycle -ErrorAction SilentlyContinue) {
        try { Start-DuneConsoleLifecycle -Listener $listener } catch {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Console lifecycle init failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    # Build the /api handler pool now that the listener is bound and all the
    # main-runspace context vars are set. If it fails for any reason, fall back
    # to the legacy inline dispatch so the server still works (just single
    # threaded) rather than not starting at all.
    $script:DuneApiPoolEnabled = $false
    try {
        Initialize-DuneApiPool -ServerDir $script:DuneServerDir
        $script:DuneApiPoolEnabled = $true
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "API handler pool init failed; falling back to inline dispatch: $($_.Exception.Message)" 'WARN'
        }
    }

    try {
        while ($listener.IsListening) {
            # Reap finished worker pipelines from the previous wait.
            try { Clear-DuneApiCompleted } catch {}
            try {
                $ctxTask = $listener.GetContextAsync()
                $ctx = $ctxTask.GetAwaiter().GetResult()
            } catch [System.Net.HttpListenerException] {
                break  # Listener was Stop()ed externally (e.g., tray Quit)
            } catch [System.ObjectDisposedException] {
                break
            } catch {
                if (-not $listener.IsListening) { break }
                throw
            }
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
                if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                    Write-DuneLog "request handler error: $($_.Exception.Message)" 'ERROR'
                } else {
                    Write-Host "[dune-http] $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    } finally {
        # Wait briefly for in-flight handlers to finish, then reap + tear down.
        try {
            $deadline = (Get-Date).AddSeconds(5)
            while ($script:DuneApiInFlight -and $script:DuneApiInFlight.Count -gt 0 -and (Get-Date) -lt $deadline) {
                Clear-DuneApiCompleted
                if ($script:DuneApiInFlight.Count -gt 0) { Start-Sleep -Milliseconds 100 }
            }
        } catch {}
        try { $listener.Stop() } catch { }
        try { $listener.Close() } catch { }
    }
}

function Stop-DuneHttpServer {
    if ($script:DuneListener) {
        try { $script:DuneListener.Stop() } catch {}
        try { $script:DuneListener.Close() } catch {}
        $script:DuneListener = $null
    }
    if ($script:DuneWsPool) {
        try { $script:DuneWsPool.Close() } catch {}
        try { $script:DuneWsPool.Dispose() } catch {}
        $script:DuneWsPool = $null
    }
    if ($script:DuneApiPool) {
        try { Clear-DuneApiCompleted } catch {}
        try { $script:DuneApiPool.Close() } catch {}
        try { $script:DuneApiPool.Dispose() } catch {}
        $script:DuneApiPool = $null
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

    # WebSocket upgrades — dispatched onto a runspace pool so the main loop
    # can keep accepting HTTP requests while the WS session runs.
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
                try {
                    $wsTask = $Ctx.AcceptWebSocketAsync([NullString]::Value)
                    $wsCtx  = $wsTask.GetAwaiter().GetResult()
                } catch {
                    Write-Host "[ws] accept failed: $($_.Exception.Message)" -ForegroundColor Red
                    return
                }
                Invoke-DuneWsHandlerAsync -Handler $r.Handler -WebSocket $wsCtx.WebSocket -RouteParams $routeParams
                return
            }
        }
        $res.StatusCode = 404
        $res.OutputStream.Close()
        return
    }

    # ---------- Remote portal (issue #74) ------------------------------------
    # Two distinct surfaces gated by Cloudflare Access:
    #   /api/remote/*  — JSON API, requires CF Access header + ACL match
    #                    AND DuneToken (defense in depth).
    #   /remote/*      — SPA HTML/assets, requires CF Access header + ACL.
    #                    Token reaches the SPA via index.html injection.
    # All other /api/* and /api/remote-access/* fall through to the
    # standard DuneToken gate below.
    $isRemoteApi = $rawPath.StartsWith('/api/remote/')
    $isRemoteSpa = $rawPath.StartsWith('/remote/') -or $rawPath -eq '/remote'
    if ($isRemoteApi -or $isRemoteSpa) {
        $auth = $null
        try { $auth = Test-DuneRemoteRequest -Request $req } catch {
            $auth = @{ ok = $false; status = 500; message = "Auth middleware error: $($_.Exception.Message)" }
        }
        if (-not $auth.ok) {
            $note = if ($auth.status -eq 401) { 'auth-required' } elseif ($auth.status -eq 403) { 'not-authorized' } else { 'auth-error' }
            $emailHdr = ''
            try { $emailHdr = ($req.Headers['Cf-Access-Authenticated-User-Email']) } catch {}
            try {
                Write-DuneRemoteAudit -Role '-' -Email $emailHdr -Method $method -Path $rawPath -Status $auth.status -Note $note
            } catch {}
            Write-DuneError -Response $res -Status $auth.status -Message $auth.message
            return
        }

        if ($isRemoteApi) {
            # /api/remote/* — also require the per-launch DuneToken (defense
            # in depth — a same-Windows-box attacker forging the CF header
            # still hits this wall because the token only lives in DST's RAM).
            if (-not (Test-DuneToken -Request $req)) {
                try { Write-DuneRemoteAudit -Role $auth.role -Email $auth.email -Method $method -Path $rawPath -Status 401 -Note 'token-missing' } catch {}
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
                    $routeParams['remoteEmail'] = $auth.email
                    $routeParams['remoteRole']  = $auth.role
                    if ($script:DuneApiPoolEnabled -and -not $r.Inline) {
                        Invoke-DuneApiHandlerAsync -Handler $r.Handler -Request $req -Response $res -RouteParams $routeParams
                        return
                    }
                    $body = $null
                    if ($req.HasEntityBody) {
                        $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                        if ($body -and $req.ContentType -like 'application/json*') {
                            $body = ConvertFrom-DuneRequestJson -Raw $body
                        }
                    }
                    & $r.Handler $req $res $routeParams $body
                    # Inline path also gets audit-logged for writes (the
                    # worker path is handled in Invoke-DuneApiHandlerAsync).
                    if ($method -ne 'GET' -and $method -ne 'HEAD') {
                        try { Write-DuneRemoteAudit -Role $auth.role -Email $auth.email -Method $method -Path $rawPath -Status ([int]$res.StatusCode) } catch {}
                    }
                    return
                }
            }
            try { Write-DuneRemoteAudit -Role $auth.role -Email $auth.email -Method $method -Path $rawPath -Status 404 -Note 'no-route' } catch {}
            Write-DuneError -Response $res -Status 404 -Message "No route for $method $rawPath"
            return
        }

        # /remote/* SPA serving (GET/HEAD only). Token injection happens in
        # Write-DuneFile when the served file is index.html.
        if ($method -ne 'GET' -and $method -ne 'HEAD') {
            Write-DuneError -Response $res -Status 405 -Message 'Method not allowed'
            return
        }
        $filePath = Resolve-DuneStaticPath -UrlPath $rawPath
        $serveIndex = $false
        if ($filePath -and (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            $serveIndex = ($filePath -match '\\index\.html$')
            Write-DuneFile -Response $res -Path $filePath -InjectRemoteToken:$serveIndex
            return
        }
        # SPA fallback (client-side router URLs like /remote/maps) — serve
        # the SPA's index.html with the token injection.
        $indexPath = Join-Path $script:DuneDistRoot 'index.html'
        if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
            Write-DuneFile -Response $res -Path $indexPath -InjectRemoteToken
            return
        }
        Write-DuneError -Response $res -Status 404 -Message 'Static asset not found'
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

                # Non-inline routes dispatch to the handler pool so a slow handler
                # can't block the accept loop. The worker reads the body itself.
                if ($script:DuneApiPoolEnabled -and -not $r.Inline) {
                    Invoke-DuneApiHandlerAsync -Handler $r.Handler -Request $req -Response $res -RouteParams $routeParams
                    return
                }

                # Inline path (control routes, or pool-disabled fallback): read +
                # parse the body on the listener thread, then run the handler.
                $body = $null
                if ($req.HasEntityBody) {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if ($body -and $req.ContentType -like 'application/json*') {
                        $body = ConvertFrom-DuneRequestJson -Raw $body
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
