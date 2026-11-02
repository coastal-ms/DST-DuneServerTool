param([string]$RepoRoot, [switch]$Legacy)
$ErrorActionPreference = 'Stop'
if ($Legacy) { $PSNativeCommandArgumentPassing = 'Legacy' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dst ssh keys ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    . (Join-Path $RepoRoot 'app/server/lib/Status.ps1')
    # Exercise the actual DST wrappers against Funcom's legacy keygen syntax.
    # The fixture uses real ssh-keygen, but no SSH connection or user key.
    $vendorDirectory = Join-Path $scratch 'Funcom scripts'
    New-Item -ItemType Directory -Path $vendorDirectory | Out-Null
    $vendorUtilities = Join-Path $vendorDirectory 'vm-utilities.ps1'
    @'
function Update-SshKey {
    param([string]$Ip)
    & ssh-keygen -t ed25519 -f $env:DST_TEST_FUNCOM_KEY -N '""' -q
    if ($LASTEXITCODE -ne 0) { throw 'Funcom fixture generation failed' }
}
'@ | Set-Content -LiteralPath $vendorUtilities -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $vendorDirectory 'initial-setup.ps1') -Value "Update-SshKey -Ip '192.0.2.1'"
    $entryPath = Join-Path $RepoRoot 'dune-server.ps1'
    $entryAst = [Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$null)
    $wrapper = $entryAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DuneFuncomKeyUpdate' }, $true)
    . ([scriptblock]::Create($wrapper.Extent.Text))
    $originalMode = $PSNativeCommandArgumentPassing
    $vendorHash = (Get-FileHash -LiteralPath $vendorUtilities).Hash
    $env:DST_TEST_FUNCOM_KEY = Join-Path $scratch 'rotated key'
    Invoke-DuneFuncomKeyUpdate -VmUtilitiesPath $vendorUtilities -Ip '192.0.2.1'
    if ((Test-DuneSshKeyEncrypted $env:DST_TEST_FUNCOM_KEY) -ne $false) { throw 'Funcom rotation created encrypted key' }
    if ($PSNativeCommandArgumentPassing -ne $originalMode) { throw 'Rotation changed caller argument mode' }
    if ((Get-FileHash -LiteralPath $vendorUtilities).Hash -ne $vendorHash) { throw 'Funcom source changed' }
    $childAssignment = $entryAst.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$childScript' }, $true)
    $bgEsc = $vendorDirectory.Replace("'", "''")
    . ([scriptblock]::Create($childAssignment.Extent.Text))
    $env:DST_TEST_FUNCOM_KEY = Join-Path $scratch 'initial setup key'
    & (Get-Process -Id $PID).Path -NoProfile -Command $childScript
    if ($LASTEXITCODE -ne 0 -or (Test-DuneSshKeyEncrypted $env:DST_TEST_FUNCOM_KEY) -ne $false) { throw 'Funcom setup created encrypted key' }
    if ($PSNativeCommandArgumentPassing -ne $originalMode) { throw 'Setup changed caller argument mode' }
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
    # A directory must never reach keygen, SSH, or config persistence.
    $script:testKey = Join-Path $scratch 'key folder'
    New-Item -ItemType Directory -Path $script:testKey | Out-Null
    function ssh-keygen { throw 'Directory reached ssh-keygen' }
    function Invoke-DuneSshHidden { throw 'Directory reached SSH' }
    function Invoke-WithDuneLock { throw 'Directory reached config persistence' }
    function Get-DuneConfigPath { Join-Path $scratch 'missing.config' }
    try {
        if ($null -ne (Test-DuneSshKeyEncrypted $script:testKey)) { throw 'Directory classified as encrypted' }
        $reason = Get-DuneSshFailureReason -KeyPath $script:testKey -Stderr 'Permission denied (publickey): incorrect passphrase' -ExitCode 255
        if ($reason -notmatch 'folder' -or $reason -match 'passphrase') { throw 'Misleading directory failure reason' }
        $snapshot = Get-DuneBattlegroupSnapshotFresh -VmStatus @{ exists=$true; running=$true; ip='192.0.2.1' }
        if ($snapshot.available -or $snapshot.reason -notmatch 'folder') { throw 'Directory status probe failed' }
        & $script:handlers['/api/config'] $null $null $null @{ values=@{ SshKey=$script:testKey } }
        if ($script:result.ok -or $script:result.message -notmatch 'folder') { throw 'Directory config save accepted' }
        & $script:handlers['/api/config/strip-ssh-passphrase'] $null $null $null @{ passphrase='test' }
        if ($script:result.ok -or $script:result.message -notmatch 'folder') { throw 'Directory removal accepted' }
        . (Join-Path $RepoRoot 'app/server/lib/Setup.ps1')
        $preflight = Get-DuneSetupPreflight
        $keyCheck = $preflight.checks | Where-Object { $_.key -eq 'sshkey' }
        if ($keyCheck.ok -or $keyCheck.detail -notmatch 'folder') { throw 'Directory preflight failed' }
        if ((Get-DuneSetupConfigSummary).sshKeyExists) { throw 'Directory marked as an existing key file' }
    } finally {
        Remove-Item Function:ssh-keygen, Function:Invoke-DuneSshHidden, Function:Invoke-WithDuneLock, Function:Get-DuneConfigPath
    }
    $script:testKey = Join-Path $scratch 'invalid-key'
    Set-Content -LiteralPath $script:testKey -Value 'not an SSH key'
    $before = (Get-FileHash $script:testKey).Hash
    & $script:handlers['/api/config/strip-ssh-passphrase'] $null $null $null @{ passphrase='test' }
    if ($script:result.ok -or $script:result.message -match 'That passphrase is incorrect' -or $script:result.message -notmatch 'Could not remove') { throw 'Key load error mislabeled as a passphrase error' }
    if ((Get-FileHash $script:testKey).Hash -ne $before) { throw 'Invalid key was changed' }
    # Create fixtures through .NET's argument list in a separate modern runtime.
    # No production/Legacy passphrase escaping participates in fixture creation.
    $fixtureScript = Join-Path $scratch 'fixture.ps1'
    @'
$ErrorActionPreference = 'Stop'
function Invoke-FixtureKeygen([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new('ssh-keygen')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.StandardOutput.ReadToEnd()
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw $errorText }
}
Invoke-FixtureKeygen @('-t', 'ed25519', '-f', $env:DST_TEST_KEY, '-N', $env:DST_TEST_PASSPHRASE, '-q')
# Independently prove the original literal passphrase unlocks the fixture.
Invoke-FixtureKeygen @('-y', '-P', $env:DST_TEST_PASSPHRASE, '-f', $env:DST_TEST_KEY)
'@ | Set-Content -LiteralPath $fixtureScript -Encoding UTF8
    foreach ($passphrase in @('test passphrase', '""', 'test "quoted" phrase')) {
        $script:testKey = Join-Path $scratch ([guid]::NewGuid().ToString())
        $env:DST_TEST_KEY = $script:testKey
        $env:DST_TEST_PASSPHRASE = $passphrase
        & pwsh.exe -NoProfile -File $fixtureScript
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
    Remove-Item Env:DST_TEST_KEY, Env:DST_TEST_PASSPHRASE, Env:DST_TEST_FUNCOM_KEY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
