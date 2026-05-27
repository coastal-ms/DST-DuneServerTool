# /api/shutdown — gracefully stop the local Dune Server portal process.
#
# Used by the "Shutdown" button in the web UI status bar. Sends the response
# (Write-DuneJson flushes + closes the response stream synchronously), then
# stops the HTTP listener. The main loop in HttpServer.ps1 checks
# $listener.IsListening on each iteration and breaks out when it sees false;
# the script then exits, killing the EXE process.

Register-DuneRoute -Method POST -Path '/api/shutdown' -Handler {
    param($req, $res, $routeParams, $body)

    Write-DuneJson -Response $res -Body @{
        ok       = $true
        shutdown = $true
        message  = 'Dune Server portal is shutting down. You can close this tab.'
    }

    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "Shutdown requested via /api/shutdown from $($req.RemoteEndPoint)"
    }

    # Stop the listener now that the response has been flushed + closed.
    # The main loop will see IsListening=false on the next iteration and
    # break out, after which the script (= EXE) exits.
    if ($script:DuneListener) {
        try { $script:DuneListener.Stop() } catch { }
    }
}
