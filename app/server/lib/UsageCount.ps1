# Optional installation presence only. No game, server, account or host data.
function Test-DuneUsageWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function ConvertFrom-DuneUsageJson {
    param([string]$Json)
    $value = $Json | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw 'Invalid count data.' }
    $result = @{}
    foreach ($property in $value.PSObject.Properties) { $result[$property.Name] = $property.Value }
    return $result
}

function New-DuneUsageSecret {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Test-DuneUsageCountEnabled {
    param([Parameter(Mandatory)][string]$ConfigPath)
    try {
        $value = ''
        if (Test-Path -LiteralPath $ConfigPath) {
            foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
                if ($line -match '^\s*AnonymousUsageEnabled\s*=\s*(.*?)\s*$') { $value = $Matches[1] }
            }
        }
        if ([string]::IsNullOrWhiteSpace($value)) { return $true }
        return $value -match '^(?i:true|1|yes|on)$'
    } catch { return $false }
}

function Write-DuneUsagePrivateJson {
    param([string]$Path, [hashtable]$Value)
    $directory = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    if (-not (Test-DuneUsageWindows)) { [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]448) }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        # Set permissions before writing the generated reporting credential.
        [IO.File]::WriteAllText($temp, '')
        if (Test-DuneUsageWindows) {
            $acl = Get-Acl -LiteralPath $temp
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
                    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
            }
            Set-Acl -LiteralPath $temp -AclObject $acl
        } else { [IO.File]::SetUnixFileMode($temp, [IO.UnixFileMode]384) }
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 4 -Compress))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Read-DuneUsageJson {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return @{} }
    return (ConvertFrom-DuneUsageJson ([IO.File]::ReadAllText($Path)))
}

function Get-DuneUsageCountLockName {
    param([string]$DataRoot, [string]$Kind)
    $path = [IO.Path]::GetFullPath($DataRoot)
    if (Test-DuneUsageWindows) { $path = $path.ToLowerInvariant() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))).Replace('-', '') }
    finally { $sha.Dispose() }
    return 'DSTUsage-' + $Kind + '-' + $hash
}

function Send-DuneUsageRequest {
    param([ValidateSet('POST','DELETE')][string]$Method, [hashtable]$Payload,
          [string]$Secret, [Threading.CancellationToken]$CancellationToken)
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $cancel = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),
        'https://duneservertool.com/api/usage.php')
    $response = $null
    try {
        $cancel.CancelAfter(5000)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Secret)
        $request.Content = [Net.Http.StringContent]::new(($Payload | ConvertTo-Json -Compress),
            [Text.Encoding]::UTF8, 'application/json')
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancel.Token).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw 'Count service unavailable.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = [byte[]]::new(4097)
        $length = 0
        while ($length -lt $buffer.Length) {
            $readTask = $stream.ReadAsync($buffer, $length, $buffer.Length - $length, $cancel.Token)
            if (-not $readTask.Wait(5000, $cancel.Token)) { throw 'Count service response timed out.' }
            $read = $readTask.GetAwaiter().GetResult()
            if ($read -eq 0) { break }; $length += $read
        }
        if ($length -gt 4096) { throw 'Invalid count service response.' }
        $receipt = ConvertFrom-DuneUsageJson ([Text.Encoding]::UTF8.GetString($buffer, 0, $length))
        if ($receipt['accepted'] -isnot [bool] -or $receipt['accepted'] -ne $true) { throw 'Count service did not accept the report.' }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose(); $cancel.Dispose(); $client.Dispose(); $handler.Dispose()
    }
}

function Invoke-DuneUsageCountTick {
    param([string]$ConfigPath, [string]$DataRoot,
          [ValidateSet('windows','docker')][string]$Edition, [string]$Version,
          [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(),
          [switch]$Force,
          [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    # Manual and scheduled reports share the same identity/file transaction.
    $mutex = [Threading.Mutex]::new($false, (Get-DuneUsageCountLockName $DataRoot 'tick'))
    $owned = $false
    try {
    try { $owned = $mutex.WaitOne(6000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { return }
    $enabled = Test-DuneUsageCountEnabled -ConfigPath $ConfigPath
    $identityPath = Join-Path $DataRoot 'identity.json'
    $statusPath = Join-Path $DataRoot 'status.json'
    try {
        $status = Read-DuneUsageJson $statusPath
        if (-not $enabled -and -not [IO.File]::Exists($identityPath)) { return }
        if (-not $Force -and $status['enabled'] -eq $enabled -and [long]$status['nextAttemptAt'] -gt $Now) { return }
        if (-not $enabled -and $status['withdrawn'] -eq $true) { return }
        if ([IO.File]::Exists($identityPath)) { $identity = Read-DuneUsageJson $identityPath }
        else {
            $identity = @{ id = [guid]::NewGuid().ToString(); secret = New-DuneUsageSecret }
            Write-DuneUsagePrivateJson $identityPath $identity
        }
        if ($identity['id'] -notmatch '^[a-f0-9-]{36}$' -or $identity['secret'] -notmatch '^[a-f0-9]{64}$') {
            throw 'Invalid local count identity.'
        }
        $payload = @{ id = $identity['id'] }
        if ($enabled) {
            $payload['edition'] = $Edition
            $payload['version'] = if ($Version.Length -le 80 -and $Version -match '^\d+\.\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?$') { $Version } else { 'unknown' }
        }
        $method = if ($enabled) { 'POST' } else { 'DELETE' }
        Send-DuneUsageRequest -Method $method -Payload $payload -Secret $identity['secret'] -CancellationToken $CancellationToken
        Write-DuneUsagePrivateJson $statusPath @{ enabled = $enabled; withdrawn = (-not $enabled);
            lastSuccessAt = $Now; nextAttemptAt = ($Now + 21600); error = $null }
    } catch {
        # Never retain HTTP responses or exception text (may contain request data).
        if (-not $CancellationToken.IsCancellationRequested) {
            try { Write-DuneUsagePrivateJson $statusPath @{ enabled = $enabled; withdrawn = $false;
                nextAttemptAt = ($Now + 21600); error = 'Count service unavailable; DST operation is unaffected.' } } catch {}
        }
    }
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Start-DuneUsageCountReporter {
    param([string]$ServerDir, [Threading.ManualResetEventSlim]$HttpReady)
    if ($script:DuneUsageCountWorker) { return }
    $edition = if ($env:DST_HOSTING_BACKEND -eq 'docker') { 'docker' } else { 'windows' }
    $configPath = Get-DuneConfigPath
    $dataRoot = Join-Path (Split-Path -Parent $configPath) 'usage-count'
    $cancellation = [Threading.CancellationTokenSource]::new()
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript({
            param($Library, $ConfigPath, $DataRoot, $Edition, $Version, $Ready, $Token)
            . $Library
            $mutex = [Threading.Mutex]::new($false, (Get-DuneUsageCountLockName $DataRoot 'reporter'))
            $owned = $false
            try {
                try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
                if (-not $owned) { return }
                if ($Ready) { $Ready.Wait($Token) }
                # Give the host time to read/change the default before first report.
                if ($Token.WaitHandle.WaitOne(30000 + (Get-Random -Minimum 0 -Maximum 30001))) { return }
                while (-not $Token.IsCancellationRequested) {
                    Invoke-DuneUsageCountTick -ConfigPath $ConfigPath -DataRoot $DataRoot -Edition $Edition -Version $Version -CancellationToken $Token
                    if ($Token.WaitHandle.WaitOne(5000)) { break }
                }
            } catch {} finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
        }).AddArgument((Join-Path $ServerDir 'lib/UsageCount.ps1')).AddArgument($configPath).
            AddArgument($dataRoot).AddArgument($edition).AddArgument([string]$script:DuneToolVersion).
            AddArgument($HttpReady).AddArgument($cancellation.Token)
        $handle = $ps.BeginInvoke()
        $script:DuneUsageCountWorker = @{ PowerShell = $ps; Handle = $handle; Cancellation = $cancellation }
    } catch { $ps.Dispose(); $cancellation.Dispose() }
}

function Stop-DuneUsageCountReporter {
    $worker = $script:DuneUsageCountWorker
    if (-not $worker) { return }
    $worker.Cancellation.Cancel()
    if (-not $worker.Handle.AsyncWaitHandle.WaitOne(6000)) { [void]$worker.PowerShell.BeginStop($null, $null) }
    if ($worker.Handle.AsyncWaitHandle.WaitOne(1000)) {
        try { $null = $worker.PowerShell.EndInvoke($worker.Handle) } catch {}
        $worker.PowerShell.Dispose(); $worker.Cancellation.Dispose()
    }
    $script:DuneUsageCountWorker = $null
}
