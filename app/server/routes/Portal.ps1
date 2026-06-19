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
# Recovery flow (issue #280): the app window does NOT close on hand-off. The
# freshly-opened browser POSTs /api/portal/checkin once it loads; the app
# window polls /api/portal/checkin-status and only closes itself after the
# browser confirms it reached the server. If the browser is blocked from
# 127.0.0.1 (AV/VPN/proxy) it never checks in, so the user keeps a working app
# window + a Copy URL fallback instead of a dead "page unavailable" tab.
# /api/portal/reattach undoes the detach when the user gives up.
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

    # Reset any stale browser check-in so the app window's poll only reacts to
    # the browser we're about to open (issue #280 recovery flow). The window
    # stays open until that fresh browser tab checks in (or the user gives up
    # and uses the Copy URL fallback).
    if (Get-Command Clear-DunePortalBrowserCheckin -ErrorAction SilentlyContinue) {
        Clear-DunePortalBrowserCheckin
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
        message  = 'Opening portal in your default browser. The app window stays open until the browser connects.'
    }
}

# POST /api/portal/checkin — the freshly-opened external browser tab calls this
# on load to prove it reached the local server. The app window polls
# /api/portal/checkin-status and closes itself once this fires (issue #280).
Register-DuneRoute -Method POST -Path '/api/portal/checkin' -Inline -Handler {
    param($req, $res, $routeParams, $body)
    if (Get-Command Set-DunePortalBrowserCheckin -ErrorAction SilentlyContinue) {
        Set-DunePortalBrowserCheckin
    }
    Write-DuneJson -Response $res -Body @{ ok = $true; checkedIn = $true }
}

# GET /api/portal/checkin-status — polled by the app window after it hands the
# portal off to the browser. Returns checkedIn=true once the browser has loaded.
Register-DuneRoute -Method GET -Path '/api/portal/checkin-status' -Inline -Handler {
    param($req, $res, $routeParams, $body)
    $checkedIn = $false
    if (Get-Command Test-DunePortalBrowserCheckin -ErrorAction SilentlyContinue) {
        $checkedIn = [bool](Test-DunePortalBrowserCheckin)
    }
    Write-DuneJson -Response $res -Body @{ ok = $true; checkedIn = $checkedIn }
}

# POST /api/portal/reattach — the user cancelled the browser hand-off (the
# browser couldn't reach the server). Clear the detach flag so closing the app
# window tears the server down normally again, and drop any check-in marker.
Register-DuneRoute -Method POST -Path '/api/portal/reattach' -Inline -Handler {
    param($req, $res, $routeParams, $body)
    if (Get-Command Clear-DuneAppDetached -ErrorAction SilentlyContinue) {
        Clear-DuneAppDetached
    } else {
        $script:DuneAppDetached = $false
    }
    if (Get-Command Clear-DunePortalBrowserCheckin -ErrorAction SilentlyContinue) {
        Clear-DunePortalBrowserCheckin
    }
    Write-DuneJson -Response $res -Body @{ ok = $true; detached = $false }
}
