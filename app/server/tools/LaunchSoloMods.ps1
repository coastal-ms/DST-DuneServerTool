param([switch]$CheckOnly)
if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
try {
    $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
    $status = $null
    $started = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        try {
            $portal = [uri](Get-Content -LiteralPath $urlFile -Raw -ErrorAction Stop).Trim()
            if ($portal.Scheme -ne 'http' -or $portal.Host -ne '127.0.0.1') { throw 'Invalid local address.' }
            $match = [regex]::Match($portal.Query, '(?:^\?|&)t=([^&]+)')
            if (-not $match.Success) { throw 'Missing launch token.' }
            $headers = @{'X-Dune-Token' = [uri]::UnescapeDataString($match.Groups[1].Value)}
            $base = $portal.GetLeftPart('Authority')
            $status = Invoke-RestMethod -Uri ($base + '/api/solo/mods') -Headers $headers -TimeoutSec 3
        } catch {
            if ($CheckOnly) { throw 'Dune Server Tool is not available.' }
            if (-not $started) {
                $exe = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\DuneServer.exe'))
                if (-not (Test-Path -LiteralPath $exe)) { throw 'Reinstall Dune Server Tool or open it before using this shortcut.' }
                Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden
                $started = $true
            }
            Start-Sleep -Milliseconds 500
        }
    } while (-not $status -and [DateTime]::UtcNow -lt $deadline)
    if (-not $status) { throw 'Dune Server Tool did not become ready. Open DST and try again.' }
    if ($CheckOnly) {
        [pscustomobject]@{Connected=$true;RuntimeReady=[bool]$status.runtimeReady;EnabledMods=@($status.mods | Where-Object enabled).Count;GameRunning=[bool]$status.gameRunning}
        return
    }
    if ($status.gameRunning) { throw 'Dune is already running. Close the game before launching with mods.' }
    $null = Invoke-RestMethod -Uri ($base + '/api/solo/mods/launch') -Method Post -Headers $headers -ContentType 'application/json' -Body '{"withMods":true}' -TimeoutSec 30
} catch {
    if ($CheckOnly) { throw }
    $message = $_.Exception.Message
    if ($_.ErrorDetails.Message) {
        try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json; if ($detail.error) {$message=[string]$detail.error} elseif ($detail.message) {$message=[string]$detail.message} } catch {}
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Dune — Launch with mods', 'OK', 'Error')
    exit 1
}

