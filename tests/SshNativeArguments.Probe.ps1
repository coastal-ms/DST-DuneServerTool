param([string]$RepoRoot, [switch]$Legacy)
$ErrorActionPreference = 'Stop'
if ($Legacy) { $PSNativeCommandArgumentPassing = 'Legacy' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dst ssh keys ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    . (Join-Path $RepoRoot 'app/server/lib/Status.ps1')
    foreach ($relative in @('dune-server.ps1', 'app/server/lib/HyperVLanInstall.ps1')) {
        $source = Get-Content (Join-Path $RepoRoot $relative) -Raw
        $match = [regex]::Match($source, '(?m)^\s*\$emptyPassphrase = .*\r?\n\s*& ssh-keygen -t ed25519[^\r\n]+')
        if (-not $match.Success) { throw 'Generation block missing' }
        $keyPath = Join-Path $scratch ([guid]::NewGuid().ToString())
        $key = $keyPath
        & ([scriptblock]::Create($match.Value))
        if ($LASTEXITCODE -ne 0 -or (Test-DuneSshKeyEncrypted $keyPath) -ne $false) { throw "Encrypted generated key: $relative" }
    }
    $script:handlers = @{}
    function Register-DuneRoute { param($Method, $Path, $Handler) $script:handlers[$Path] = $Handler }
    function Read-DuneConfig { @{ SshKey = $script:testKey } }
    function Write-DuneJson { param($Response, $Body) $script:result = $Body }
    function Write-DuneError { param($Response, $Status, $Message) $script:result = @{ ok = $false; message = $Message } }
    . (Join-Path $RepoRoot 'app/server/routes/Config.ps1')
    foreach ($passphrase in @('test passphrase', '""', 'test "quoted" phrase')) {
        $script:testKey = Join-Path $scratch ([guid]::NewGuid().ToString())
        $oldArgument = if ($PSVersionTable.PSVersion -ge [version]'7.3' -and $PSNativeCommandArgumentPassing -ne 'Legacy') { $passphrase } else { $passphrase.Replace('"', '\"') }
        & ssh-keygen -t ed25519 -f $script:testKey -N $oldArgument -q
        if ($LASTEXITCODE -ne 0 -or (Test-DuneSshKeyEncrypted $script:testKey) -ne $true) { throw 'Encrypted test fixture failed' }
        $before = (Get-FileHash $script:testKey).Hash
        & $script:handlers['/api/config/strip-ssh-passphrase'] $null $null $null @{ passphrase = 'wrong' }
        if ($script:result.ok -or (Get-FileHash $script:testKey).Hash -ne $before) { throw 'Wrong passphrase changed key' }
        $public = Get-Content ($script:testKey + '.pub') -Raw
        & $script:handlers['/api/config/strip-ssh-passphrase'] $null $null $null @{ passphrase = $passphrase }
        if (-not $script:result.ok -or (Test-DuneSshKeyEncrypted $script:testKey) -ne $false) { throw ('Removal failed: ' + $script:result.message) }
        if ((Get-Content ($script:testKey + '.pub') -Raw) -ne $public) { throw 'Public key changed' }
        & $script:handlers['/api/config/strip-ssh-passphrase'] $null $null $null @{}
        if (-not $script:result.ok -or $script:result.stripped) { throw 'Idempotent removal failed' }
    }
    'SSH native argument verification passed: ' + $PSVersionTable.PSVersion + '; Legacy=' + $Legacy
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
