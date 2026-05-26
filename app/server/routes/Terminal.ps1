# Terminal — WebSocket bridge from xterm.js to a persistent PowerShell runspace
#
# Each WS connection owns one PowerShell Runspace. Commands sent from the
# client execute in that runspace, so cwd / variables / loaded modules
# persist across commands. Output streams (Output / Error / Warning /
# Information / Verbose) are polled and forwarded as they arrive.
#
# This is an *exec model*, not a true PTY. Full TUI apps (vim, htop) won't
# work — but kubectl, ssh -i key dune@vm '<cmd>', Get-VM, Get-Process,
# Invoke-RestMethod, etc. all behave correctly.
#
# Protocol (all frames UTF-8 JSON):
#
#   Client -> Server:
#     { "type": "init",   "cols": 100 }                  (first frame only)
#     { "type": "exec",   "cmd": "Get-Process" }
#     { "type": "cancel" }                               (Ctrl+C)
#     { "type": "resize", "cols": 120 }                  (re-format on resize)
#
#   Server -> Client:
#     { "type": "ready",  "cwd": "C:\\..." }             (after init)
#     { "type": "output", "stream": "stdout|stderr|info|warn|verbose",
#                         "data": "<text>" }
#     { "type": "done",   "cwd": "...", "durationMs": N, "hadErrors": bool }
#     { "type": "error",  "message": "<text>" }
#
# Runs in a runspace from $script:DuneWsPool — no PS functions from
# lib/*.ps1 are visible. Pure .NET / built-in cmdlets.

Register-DuneWebSocket -Path '/ws/terminal' -Handler {
    param($ws, $routeParams)

    $CT  = [System.Threading.CancellationToken]::None
    $ENC = [System.Text.Encoding]::UTF8

    function _Send([hashtable]$obj) {
        try {
            $json  = $obj | ConvertTo-Json -Compress -Depth 5
            $bytes = $ENC.GetBytes($json)
            $seg   = [System.ArraySegment[byte]]::new($bytes)
            $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $CT).GetAwaiter().GetResult()
            return $true
        } catch { return $false }
    }

    function _RecvFrame([byte[]]$buf) {
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            $r = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $CT).GetAwaiter().GetResult()
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
            if ($r.Count -gt 0) { [void]$sb.Append($ENC.GetString($buf, 0, $r.Count)) }
            if ($r.EndOfMessage) { break }
        }
        return $sb.ToString()
    }

    # ---- 1. init -----------------------------------------------------------------
    $buf = [byte[]]::new(16384)
    $cols = 100
    try {
        $first = _RecvFrame $buf
        if ($first) {
            $init = $first | ConvertFrom-Json -ErrorAction Stop
            if ($init.type -eq 'init' -and $init.cols) {
                $cols = [Math]::Max(40, [Math]::Min(400, [int]$init.cols))
            }
        }
    } catch {
        [void](_Send @{ type='error'; message="init parse failed: $($_.Exception.Message)" })
        return
    }

    # ---- 2. spawn runspace -------------------------------------------------------
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    $rs = [runspacefactory]::CreateRunspace($iss)
    try { $rs.Open() } catch {
        [void](_Send @{ type='error'; message="Failed to open runspace: $($_.Exception.Message)" })
        return
    }

    # Start in user profile dir (matches what a fresh terminal would show).
    try { $rs.SessionStateProxy.Path.SetLocation([Environment]::GetFolderPath('UserProfile')) | Out-Null } catch {}
    $cwd = try { $rs.SessionStateProxy.Path.CurrentLocation.Path } catch { 'C:\' }
    [void](_Send @{ type='ready'; cwd=$cwd; cols=$cols })

    # ---- 3. main loop ------------------------------------------------------------
    $currentPs   = $null
    $currentAsync = $null
    $closing = $false

    try {
        while (-not $closing -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $frame = _RecvFrame $buf
            if ($null -eq $frame) { break }

            try {
                $msg = $frame | ConvertFrom-Json -ErrorAction Stop
            } catch {
                [void](_Send @{ type='error'; message="bad frame: $($_.Exception.Message)" })
                continue
            }

            switch ($msg.type) {

                'exec' {
                    if ($currentPs) {
                        [void](_Send @{ type='error'; message='A command is already running.' })
                        continue
                    }
                    $cmdText = [string]$msg.cmd
                    if ([string]::IsNullOrWhiteSpace($cmdText)) {
                        [void](_Send @{ type='done'; cwd=$cwd; durationMs=0; hadErrors=$false })
                        continue
                    }

                    # Wrap the user's command so non-string objects flow through
                    # the formatter and arrive as readable text lines.
                    $wrapped = @"
& {
$cmdText
} 2>&1 | & {
  process {
    if (`$_ -is [System.Management.Automation.ErrorRecord]) { `$_ } else { `$_ | Out-String -Stream -Width $cols }
  }
}
"@

                    $currentPs = [powershell]::Create()
                    $currentPs.Runspace = $rs
                    [void]$currentPs.AddScript($wrapped)

                    $outCol = [System.Management.Automation.PSDataCollection[psobject]]::new()

                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $currentAsync = $currentPs.BeginInvoke(
                            [System.Management.Automation.PSDataCollection[psobject]]::new(),
                            $outCol)
                    } catch {
                        [void](_Send @{ type='error'; message="BeginInvoke failed: $($_.Exception.Message)" })
                        try { $currentPs.Dispose() } catch {}
                        $currentPs = $null
                        continue
                    }

                    # ---- poll loop: drain streams, accept cancel, until done
                    $idxOut = 0; $idxErr = 0; $idxWarn = 0; $idxInfo = 0; $idxVerb = 0
                    $hadErrors = $false

                    $drain = {
                        # output (formatted strings + raw ErrorRecords)
                        while ($idxOut -lt $outCol.Count) {
                            $rec = $outCol[$idxOut]; $idxOut++
                            if ($rec -is [System.Management.Automation.ErrorRecord]) {
                                $hadErrors = $true
                                [void](_Send @{ type='output'; stream='stderr'; data = ($rec | Out-String) })
                            } elseif ($rec -ne $null) {
                                [void](_Send @{ type='output'; stream='stdout'; data = "$rec`r`n" })
                            }
                        }
                        # error stream (anything that escaped 2>&1)
                        $errStream = $currentPs.Streams.Error
                        while ($idxErr -lt $errStream.Count) {
                            $rec = $errStream[$idxErr]; $idxErr++
                            $hadErrors = $true
                            [void](_Send @{ type='output'; stream='stderr'; data = ($rec | Out-String) })
                        }
                        # warning
                        $warnStream = $currentPs.Streams.Warning
                        while ($idxWarn -lt $warnStream.Count) {
                            $rec = $warnStream[$idxWarn]; $idxWarn++
                            [void](_Send @{ type='output'; stream='warn'; data = "WARNING: $($rec.Message)`r`n" })
                        }
                        # information (Write-Host / Write-Information)
                        $infoStream = $currentPs.Streams.Information
                        while ($idxInfo -lt $infoStream.Count) {
                            $rec = $infoStream[$idxInfo]; $idxInfo++
                            [void](_Send @{ type='output'; stream='info'; data = "$($rec.MessageData)`r`n" })
                        }
                        # verbose
                        $verbStream = $currentPs.Streams.Verbose
                        while ($idxVerb -lt $verbStream.Count) {
                            $rec = $verbStream[$idxVerb]; $idxVerb++
                            [void](_Send @{ type='output'; stream='verbose'; data = "VERBOSE: $($rec.Message)`r`n" })
                        }
                    }

                    # While the command runs, do interleaved drain + non-blocking WS receive.
                    # WS receive: kick off a Task and check IsCompleted each tick.
                    $recvTask = $null
                    try { $recvTask = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $CT) } catch {}

                    while (-not $currentAsync.IsCompleted) {
                        & $drain

                        # peek WS for cancel
                        if ($recvTask -and $recvTask.IsCompleted) {
                            try {
                                $rr = $recvTask.GetAwaiter().GetResult()
                                if ($rr.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                                    $closing = $true
                                    try { $currentPs.Stop() } catch {}
                                    break
                                }
                                if ($rr.Count -gt 0 -and $rr.EndOfMessage) {
                                    $pf = $ENC.GetString($buf, 0, $rr.Count)
                                    try {
                                        $po = $pf | ConvertFrom-Json -ErrorAction Stop
                                        if ($po.type -eq 'cancel') {
                                            try { $currentPs.Stop() } catch {}
                                        } elseif ($po.type -eq 'resize' -and $po.cols) {
                                            $cols = [Math]::Max(40, [Math]::Min(400, [int]$po.cols))
                                        }
                                    } catch {}
                                }
                            } catch { }
                            try { $recvTask = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $CT) } catch { $recvTask = $null }
                        }

                        Start-Sleep -Milliseconds 30
                    }

                    # final drain
                    & $drain
                    try { $currentPs.EndInvoke($currentAsync) } catch { $hadErrors = $true }
                    $sw.Stop()
                    try { $cwd = $rs.SessionStateProxy.Path.CurrentLocation.Path } catch {}
                    [void](_Send @{ type='done'; cwd=$cwd; durationMs=[int]$sw.ElapsedMilliseconds; hadErrors=$hadErrors })

                    try { $currentPs.Dispose() } catch {}
                    $currentPs = $null
                    $currentAsync = $null

                    # If client closed during command, stop loop.
                    if ($closing) { break }
                }

                'cancel' {
                    # No command running — just ack
                }

                'resize' {
                    if ($msg.cols) { $cols = [Math]::Max(40, [Math]::Min(400, [int]$msg.cols)) }
                }

                default { }
            }
        }
    } finally {
        try { if ($currentPs) { $currentPs.Stop(); $currentPs.Dispose() } } catch {}
        try { $rs.Close() } catch {}
        try { $rs.Dispose() } catch {}
    }
}
