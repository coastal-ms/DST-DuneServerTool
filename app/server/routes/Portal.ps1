# /api/portal/open-in-browser — hand the portal off to the user's default browser.
#
# Called by the sidebar "Web Portal" button when the user is running inside the
# native DuneShell.exe app window. We:
#
#   1. Set $script:DuneAppDetached so the app-window watcher in ConsoleHost.ps1
#      skips its usual "shell exited -> stop listener" teardown. The HTTP server
#      stays up so the browser tab the user is about to open works without a
#      restart and without rotating the token.
#
#   2. Return the live portal URL (with the current launch token). The CLIENT
#      then hands that URL to the WebView2 host (chrome.webview.postMessage)
#      so DuneShell.exe (which runs NON-elevated) opens it via Process.Start
#      with UseShellExecute=true. That's important: if the elevated server
#      did Start-Process here, the browser would inherit our elevated token
#      and Chrome/Edge would block the launch ("can't run elevated").
#
# Next launch of DuneServer.exe detects no surviving DuneShell.exe and treats
# it as a kill+restart request (see DuneServer.ps1 second-instance branch).

Register-DuneRoute -Method POST -Path '/api/portal/open-in-browser' -Inline -Handler {
    param($req, $res, $routeParams, $body)

    if (Get-Command Set-DuneAppDetached -ErrorAction SilentlyContinue) {
        Set-DuneAppDetached
    } else {
        $script:DuneAppDetached = $true
    }

    $url = $null
    if (Get-Command Get-DuneServerUrl -ErrorAction SilentlyContinue) {
        try { $url = Get-DuneServerUrl } catch { $url = $null }
    }
    if (-not $url) {
        # Fallback: rebuild from the stored pieces. Shouldn't fire — Get-DuneServerUrl
        # always works once the listener is bound — but keeps the endpoint honest
        # if anyone ever calls it before the prefix is set.
        if ($script:DunePrefixUrl) {
            $url = if ($script:DuneToken) {
                "{0}?t={1}" -f $script:DunePrefixUrl, [Uri]::EscapeDataString($script:DuneToken)
            } else { $script:DunePrefixUrl }
        }
    }

    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "Portal detach requested via /api/portal/open-in-browser; server will keep running until next launch"
    }

    Write-DuneJson -Response $res -Body @{
        ok       = $true
        detached = $true
        url      = $url
        message  = 'App window will close; portal opens in default browser. Server stays running.'
    }
}
