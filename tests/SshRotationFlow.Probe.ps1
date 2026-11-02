param([string]$RepoRoot, [switch]$Legacy)
$ErrorActionPreference = 'Stop'
if ($Legacy) { $PSNativeCommandArgumentPassing = 'Legacy' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dst rotation ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
$originalLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $scratch
try {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'dune-server.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Get-DuneSshPrivateKeyFiles','Resolve-FreshSshKey','Complete-DuneSshKeyRotation')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function New-FixtureKey([string]$Name) {
        $path = Join-Path $scratch $Name
        $empty = if ($PSVersionTable.PSVersion -ge [version]'7.3' -and $PSNativeCommandArgumentPassing -ne 'Legacy') { '' } else { '""' }
        & ssh-keygen -t ed25519 -f $path -N $empty -q
        if ($LASTEXITCODE -ne 0) { throw 'Fixture key generation failed' }
        return $path
    }
    function Assert-Flow($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
    $script:allowLogin = $true
    $script:allowAuthorization = $true
    $script:loginCalls = 0
    function ssh {
        if ($args -contains 'echo dst-rotation-ok') {
            $script:loginCalls++
            Assert-Flow ($args -contains 'BatchMode=yes' -and $args -contains 'IdentitiesOnly=yes' -and $args -contains 'IdentityAgent=none') 'Login must be noninteractive and use the selected identity'
            $script:probedKey = $args[([array]::IndexOf($args, '-i')) + 1]
            $global:LASTEXITCODE = if ($script:allowLogin) { 0 } else { 255 }
            if ($script:allowLogin) { 'dst-rotation-ok' } else { 'Permission denied (publickey)' }
        } else {
            $remote = [string]$args[-1]
            Assert-Flow ($remote -match 'echo ([A-Za-z0-9+/=]+) \| base64 -d') 'Authorization must safely encode the public key'
            $publicText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
            Assert-Flow ($publicText.EndsWith([string][char]10) -and -not $publicText.EndsWith("`r`n")) 'Linux public-key line must end in LF'
            $global:LASTEXITCODE = if ($script:allowAuthorization) { 0 } else { 255 }
        }
    }
    $oldKey = New-FixtureKey 'old key'
    $folder = Join-Path $scratch 'DuneAwakeningServer/sshKey'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $newKey = New-FixtureKey 'DuneAwakeningServer/sshKey/newkey-generated'
    (Get-Item -LiteralPath ($newKey + '.pub')).LastWriteTime = (Get-Date).AddMinutes(10)
    $script:configPath = Join-Path $scratch 'dune-server.config'
    $original = "# preserve this comment`r`nSteamPath=C:\Steam`r`nSshKey=$folder`r`nCustomSetting=0`r`n"
    [IO.File]::WriteAllText($script:configPath, $original)
    $before = @{ $oldKey = (Get-FileHash -LiteralPath $oldKey).Hash }
    $selected = Complete-DuneSshKeyRotation -Paths @($folder, $oldKey) -Before $before -Ip '192.0.2.1' -User 'dune' -ConfigPath $script:configPath
    Assert-Flow ($selected -eq $newKey -and $script:probedKey -eq $newKey) 'Folder selection did not resolve and verify its private-key file'
    Assert-Flow ([IO.File]::ReadAllText($script:configPath) -eq $original.Replace("SshKey=$folder", "SshKey=$newKey")) 'Rotation changed unrelated configuration'
    Assert-Flow (@(Get-ChildItem -LiteralPath $scratch -Filter '*.bak').Count -eq 1) 'Original configuration backup missing'
    Assert-Flow (@(Get-DuneSshPrivateKeyFiles -Paths @($folder, $newKey + '.pub')).Count -eq 1) 'Public key was selected as a private key'
    $savedHash = (Get-FileHash -LiteralPath $script:configPath).Hash
    $script:allowLogin = $false
    try { Complete-DuneSshKeyRotation -Paths @($newKey) -Before @{} -Ip '192.0.2.1' -User 'dune' -ConfigPath $script:configPath; throw 'Failed login accepted' }
    catch { if ($_.Exception.Message -notmatch 'did not pass login verification') { throw } }
    Assert-Flow ((Get-FileHash -LiteralPath $script:configPath).Hash -eq $savedHash) 'Failed login changed saved selection'
    $script:allowLogin = $true
    $calls = $script:loginCalls
    try { Complete-DuneSshKeyRotation -Paths @($oldKey) -Before $before -Ip '192.0.2.1' -User 'dune' -ConfigPath $script:configPath; throw 'Unchanged old key accepted as a new rotation' }
    catch { if ($_.Exception.Message -notmatch 'did not pass login verification') { throw } }
    Assert-Flow ($script:loginCalls -eq $calls -and (Get-FileHash -LiteralPath $script:configPath).Hash -eq $savedHash) 'Cancelled/unchanged rotation touched selection or authenticated with old key'

    # Execute the actual console branch with a fixture Funcom return value.
    $branch = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$cmdName -eq "rotate-ssh-key"' }, $true)
    $rotationScript = [scriptblock]::Create($branch.Extent.Text)
    $bgSetupPath = Join-Path $scratch 'vendor'
    New-Item -ItemType Directory -Path $bgSetupPath | Out-Null
    Set-Content -LiteralPath (Join-Path $bgSetupPath 'vm-utilities.ps1') -Value '# fixture'
    function Invoke-DuneFuncomKeyUpdate {
        param($VmUtilitiesPath,$Ip)
        if ($script:createConsoleKey) { New-FixtureKey 'DuneAwakeningServer/sshKey/newkey-console' | Out-Null }
        return $script:returnedPath
    }
    $consoleKey = Join-Path $folder 'newkey-console'
    $script:createConsoleKey = $true
    $script:returnedPath = $folder
    $cmdName = 'rotate-ssh-key'; $ip = '192.0.2.1'; $sshUser = 'dune'
    $configFile = $script:configPath; $sshKey = $oldKey; $cfg = @{ SshKey=$oldKey }
    $SshRotationResultPath = Join-Path $scratch 'console result.json'
    foreach ($attempt in @(1)) { . $rotationScript }
    $completion = Get-Content -LiteralPath $SshRotationResultPath -Raw | ConvertFrom-Json
    Assert-Flow ($completion.ok -and $completion.keyPath -eq $consoleKey -and $cfg.SshKey -eq $consoleKey) 'Console did not save and report the verified generated file'
    $consoleHash = (Get-FileHash -LiteralPath $configFile).Hash
    $script:createConsoleKey = $false
    $script:returnedPath = $consoleKey
    foreach ($attempt in @(1)) { . $rotationScript }
    $completion = Get-Content -LiteralPath $SshRotationResultPath -Raw | ConvertFrom-Json
    Assert-Flow (-not $completion.ok -and (Get-FileHash -LiteralPath $configFile).Hash -eq $consoleHash) 'Console reported an unchanged old key as a successful rotation'
    Remove-Item -LiteralPath (Join-Path $bgSetupPath 'vm-utilities.ps1')
    $script:allowAuthorization = $false
    $oldHash = (Get-FileHash -LiteralPath $consoleKey).Hash
    foreach ($attempt in @(1)) { . $rotationScript }
    $completion = Get-Content -LiteralPath $SshRotationResultPath -Raw | ConvertFrom-Json
    Assert-Flow (-not $completion.ok -and (Get-FileHash -LiteralPath $consoleKey).Hash -eq $oldHash -and (Get-FileHash -LiteralPath $configFile).Hash -eq $consoleHash) 'Fallback authorization failure replaced the old key or selection'
    $script:allowAuthorization = $true
    foreach ($attempt in @(1)) { . $rotationScript }
    $completion = Get-Content -LiteralPath $SshRotationResultPath -Raw | ConvertFrom-Json
    Assert-Flow ($completion.ok -and (Test-Path -LiteralPath $completion.keyPath -PathType Leaf) -and $completion.keyPath -ne $consoleKey -and $script:probedKey -eq $completion.keyPath -and $cfg.SshKey -eq $completion.keyPath) 'Fallback did not select and verify the replacement private-key file'

    # Exercise Settings completion handling, never launching a process or SSH.
    $script:handlers = @{}
    function Register-DuneRoute { param($Method,$Path,$Handler) $script:handlers[$Path]=$Handler }
    function Get-DuneCommandByName { param($Name) @{ Name=$Name } }
    function Get-DuneCurrentState { @{} }
    function Get-DuneCommandAvailability { param($Command,$State) @{available=$true} }
    function Get-DuneConfigPath { $script:configPath }
    function Read-DuneConfig { @{SshKey=$script:selectedPath} }
    function Get-DuneVmStatus { @{running=$true;ip='192.0.2.1'} }
    function Write-DuneJson { param($Response,$Body) $script:result=$Body }
    function Write-DuneError { param($Response,$Status,$Message) $script:result=@{ok=$false;message=$Message} }
    function Get-Process { param($Id) $script:processChecks++; return $null }
    function Invoke-DuneCommandExternal {
        param($Name,$SshRotationResultPath)
        $script:lastResultPath = $SshRotationResultPath
        if ($script:routeCase -ne 'closed') {
            $value = @{ok=($script:routeCase -ne 'failed');keyPath=$script:returnedPath;message='Fixture authorization failed'}
            [IO.File]::WriteAllText($SshRotationResultPath,($value | ConvertTo-Json -Compress))
        }
        return @{pid=987654;ok=$true}
    }
    function Invoke-DuneSshHidden {
        param($Ip,$KeyPath,$TimeoutSec,$SshOptions,$RemoteCommand)
        $script:apiProbes++
        Assert-Flow ($KeyPath -eq $consoleKey -and $SshOptions -contains 'BatchMode=yes' -and $SshOptions -contains 'IdentitiesOnly=yes' -and $SshOptions -contains 'IdentityAgent=none') 'Settings verified the wrong identity'
        return @{Exit=$(if($script:routeCase -eq 'login-failed'){255}else{0});Stdout=$(if($script:routeCase -eq 'marker-missing'){@('unexpected')}else{@('dst-rotation-ok','')})}
    }
    . (Join-Path $RepoRoot 'app/server/routes/Config.ps1')
    foreach ($case in @('success','closed','failed','folder','mismatch','login-failed','marker-missing')) {
        $script:routeCase=$case; $script:apiProbes=0; $script:processChecks=0
        $script:selectedPath=$consoleKey; $script:returnedPath=$consoleKey
        if ($case -eq 'folder') { $script:selectedPath=$folder; $script:returnedPath=$folder }
        if ($case -eq 'mismatch') { $script:selectedPath=$oldKey }
        & $script:handlers['/api/config/rotate-ssh-key'] $null $null $null @{}
        if ($case -eq 'success') {
            Assert-Flow ($script:result.ok -and $script:result.rotated -and $script:result.keyPath -eq $consoleKey -and $script:apiProbes -eq 1 -and $script:processChecks -eq 0) 'Settings did not verify login before success while console remains open'
        } else { Assert-Flow (-not $script:result.ok) "Settings falsely reported success: $case" }
        if ($case -in @('closed','failed','folder','mismatch')) { Assert-Flow ($script:apiProbes -eq 0) "Invalid completion reached SSH: $case" }
        Assert-Flow (-not (Test-Path -LiteralPath $script:lastResultPath)) 'Terminal result file was not cleaned up'
    }
    'SSH rotation flow verification passed'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $scratchFull = [IO.Path]::GetFullPath($scratch)
    if (-not $scratchFull.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $scratchFull -Recurse -Force
}
