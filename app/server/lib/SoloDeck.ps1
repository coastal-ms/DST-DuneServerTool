function Compare-DuneSoloDeckSettings {
    param([object[]]$SourceEntries = @(), [object[]]$DeckFiles = @())
    $source = @{}
    $deck = @{}
    foreach ($entry in $SourceEntries) {
        $id = [string]$entry.file + "`n" + [string]$entry.section + "`n" + [string]$entry.key
        if ($source.ContainsKey($id)) { throw 'Duplicate PC settings need review before comparison.' }
        $source[$id] = $entry
    }
    foreach ($file in $DeckFiles) {
        if (@($file.duplicates).Count) { throw 'Duplicate Deck settings need review before comparison.' }
        foreach ($entry in @($file.values)) {
            $id = [string]$file.file + "`n" + [string]$entry.section + "`n" + [string]$entry.key
            if ($deck.ContainsKey($id)) { throw 'Duplicate Deck settings need review before comparison.' }
            $deck[$id] = @{file=[string]$file.file;section=[string]$entry.section;key=[string]$entry.key;value=[string]$entry.value}
        }
    }
    $rows = @(foreach ($id in @(@($source.Keys) + @($deck.Keys) | Sort-Object -Unique)) {
        $pcValue = if ($source.ContainsKey($id)) { [string]$source[$id].value } else { $null }
        $deckValue = if ($deck.ContainsKey($id)) { [string]$deck[$id].value } else { $null }
        if ($pcValue -ceq $deckValue) { continue }
        $entry = if ($source.ContainsKey($id)) { $source[$id] } else { $deck[$id] }
        $readOnly = $entry.file -eq 'ServerCustomSettings.ini' -and $entry.key -in @('DifficultyLevel','PVPMode')
        $action = if ($readOnly) { 'Game controlled' } elseif ($null -eq $pcValue) { 'Keep Deck value' } else { 'Would copy to Deck' }
        @{
            file=[string]$entry.file;section=[string]$entry.section;key=[string]$entry.key
            pcValue=$pcValue;deckValue=$deckValue;action=$action
            warning=$(if ($entry.key -in @('bAllowSandworms','SandwormConsequences')) { 'Changing worm settings can affect bases built on sand. Review before syncing.' } else { '' })
        }
    })
    return @{ available=$true;error='';differences=$rows;differenceCount=$rows.Count;writesEnabled=$false }
}

function Get-DuneSoloDeckComparison {
    param([Parameter(Mandatory)]$Report)
    try {
        if (-not (Get-Command Get-DuneSoloProfile -ErrorAction SilentlyContinue)) { throw 'Local Solo profile is not available in this host.' }
        $profile = Get-DuneSoloProfile
        if (-not $profile.dbPath) { throw 'Connect a local Steam or Xbox Solo profile to compare settings.' }
        $candidates = @($Report.settings_candidates)
        if ($candidates.Count -ne 1) { throw 'Choose exactly one Deck settings folder before comparison.' }
        $source = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in @((Read-DuneSoloSettings -NativeValues).entries)) {
            # The local reader synthesizes inventory size from Game.ini; do not
            # invent a second override in ServerCustomSettings.ini.
            if ($entry.present -and $entry.key -ne 'PlayerInventoryStartingSize') { $source.Add(@{file='ServerCustomSettings.ini';section=$script:DuneSoloSection;key=$entry.key;value=$entry.value}) }
        }
        foreach ($entry in @((Read-DuneSoloConsoleSettings).entries)) {
            if ($entry.present) { $source.Add(@{file='Engine.ini';section='ConsoleVariables';key=$entry.key;value=$entry.value}) }
        }
        $gamePath = Join-Path (Split-Path -Parent ([string]$profile.settingsPath)) 'Game.ini'
        if (Test-Path -LiteralPath $gamePath -PathType Leaf) {
            $section = ''
            foreach ($line in [IO.File]::ReadAllLines($gamePath)) {
                if ($line -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1];continue }
                if ($line -match '^\s*([^;#][^=]*?)\s*=(.*)$') {
                    $key = $Matches[1].Trim(); $value = $Matches[2].Trim()
                    if (($section -eq '/Script/DuneSandbox.BuildingSettings' -and $key -in @('m_MaxNumLandclaimSegments','m_BuildableBuildAndFillHoldTimes')) -or
                        ($section -eq '/Script/DuneSandbox.InventorySystemSettings' -and $key -eq 'PlayerInventoryStartingSize')) {
                        $source.Add(@{file='Game.ini';section=$section;key=$key;value=$value})
                    }
                }
            }
        }
        return Compare-DuneSoloDeckSettings -SourceEntries $source.ToArray() -DeckFiles @($candidates[0].files)
    } catch { return @{available=$false;error=$_.Exception.Message;differences=@();differenceCount=0;writesEnabled=$false} }
}

function Get-DuneSoloDeckConnectionRoot {
    Join-Path (Join-Path $env:APPDATA 'DuneServer') 'SteamDeck'
}

function Get-DuneSoloDeckResourceRoot {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\resources\steam-deck'))
}

function Start-DuneSoloDeckBridge {
    param([switch]$RenewPairing)
    $root = Get-DuneSoloDeckConnectionRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($item in @((Get-Item -LiteralPath $root -Force)) + @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Deck pairing storage cannot contain linked files.' }
    }
    # The same owner-only directory holds the SSH key and pairing certificate.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $root -AclObject $acl
    $statusPath = Join-Path $root 'bridge-status.json'
    if (Test-Path -LiteralPath $statusPath) {
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        $savedProcess = Get-CimInstance Win32_Process -Filter ('ProcessId = '+[int]$status.pid) -ErrorAction SilentlyContinue
        if ($status.ok -and $savedProcess -and $savedProcess.CommandLine.Contains('PairingBridge.ps1') -and $savedProcess.CommandLine.Contains($root)) {
            if (-not $RenewPairing) { return $status }
            [IO.File]::WriteAllText((Join-Path $root ('bridge-stop-'+[int]$status.pid)), '')
            $until = [DateTime]::UtcNow.AddSeconds(12)
            while ((Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
            if (Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue) { Stop-Process -Id ([int]$status.pid) -ErrorAction Stop }
        }
        if ($status.firewallName -match '^DSTDeck-[0-9a-f]{32}$' -and (Get-Command Remove-NetFirewallRule -ErrorAction SilentlyContinue)) {
            Remove-NetFirewallRule -Name $status.firewallName -ErrorAction SilentlyContinue
        }
    }
    $key = Join-Path $root 'ssh_key'
    if (-not (Test-Path -LiteralPath $key)) {
        $keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
        $keyProcess = Start-Process -FilePath $keygen -ArgumentList @('-q','-t','ed25519','-N','""','-f',('"'+$key+'"')) -WindowStyle Hidden -Wait -PassThru
        if ($keyProcess.ExitCode -ne 0) { throw 'Could not create the Deck connection key. Check Windows OpenSSH.' }
    }
    if (-not (Test-Path -LiteralPath ($key + '.pub'))) {
        $keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
        $public = & $keygen -y -f $key
        if ($LASTEXITCODE -ne 0 -or $public -notmatch '^ssh-ed25519 ') { throw 'Could not read the Deck connection public key.' }
        [IO.File]::WriteAllText(($key+'.pub'), [string]$public, (New-Object Text.UTF8Encoding($false)))
    }
    $resource = Get-DuneSoloDeckResourceRoot
    $bridge = Join-Path $resource 'PairingBridge.ps1'
    $companion = Join-Path $resource 'DST-Deck-Companion.sh'
    if (-not (Test-Path -LiteralPath $bridge) -or -not (Test-Path -LiteralPath $companion)) { throw 'The Deck companion is missing. Repair or reinstall DST.' }
    if (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath -Force }
    $pwsh = if ($script:PwshExe -and (Test-Path -LiteralPath $script:PwshExe -PathType Leaf)) { [string]$script:PwshExe } else { (Get-Command pwsh.exe -ErrorAction Stop).Source }
    $process = Start-Process -FilePath $pwsh -ArgumentList ('-NoProfile -File "'+$bridge+'" -Root "'+$root+'" -ParentId '+$PID+' -CompanionPath "'+$companion+'"') -WindowStyle Hidden -PassThru
    $until = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $until -and -not (Test-Path -LiteralPath $statusPath)) {
        if ($process.HasExited) { throw 'The Deck pairing service could not start.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $statusPath)) { throw 'Deck pairing did not start in time.' }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if (-not $status.ok) { throw [string]$status.error }
    return $status
}

function Get-DuneSoloDeckPairingInfo {
    $status = Start-DuneSoloDeckBridge -RenewPairing
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred'
    } | ForEach-Object { $_.IPAddress + ':' + $status.port })
    return @{ok=$true;addresses=$addresses;code=$status.code;certificateFingerprint=$status.certificateFingerprint;expires=$status.pairExpires}
}

function Invoke-DuneSoloDeckReader {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Connection,
        [ValidateSet('','dst-settings-v1','dst-mods-v1')][string]$Command = '', $Request = $null)
    $address = $null
    if (-not [Net.IPAddress]::TryParse([string]$Connection.host, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        [string]$Connection.user -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw 'The saved Steam Deck connection is invalid. Pair the companion again.'
    }
    $bindArgument = ''
    $sshPort = 22
    if ($null -ne $Connection.port -and (-not [int]::TryParse([string]$Connection.port,[ref]$sshPort) -or $sshPort -lt 1 -or $sshPort -gt 65535)) {
        throw 'The saved Steam Deck connection is invalid. Pair the companion again.'
    }
    if ($Connection.pcAddress) {
        $bindAddress = $null
        if (-not [Net.IPAddress]::TryParse([string]$Connection.pcAddress,[ref]$bindAddress) -or $bindAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw 'The saved Steam Deck connection is invalid. Pair the companion again.'
        }
        # Keep the PC source address that the Deck authorized during pairing,
        # including machines with Ethernet, Wi-Fi and virtual adapters.
        $bindArgument = ' -b ' + $bindAddress.ToString()
    }
    foreach ($name in @('ssh_key', 'known_hosts')) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Steam Deck pairing files are missing.' }
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Steam Deck pairing files cannot be symbolic links.'
        }
    }
    $ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) { throw 'The Windows OpenSSH client is unavailable.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ssh
    $start.WorkingDirectory = $Root
    # The saved target is validated above; relative pairing paths avoid quoting or shell expansion.
    $start.Arguments = '-T -p ' + $sshPort + ' -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=known_hosts -o ConnectTimeout=4 -i ssh_key' + $bindArgument + ' ' + [string]$Connection.user + '@' + $address.ToString()
    $payload = ''
    if ($Command) {
        $payload = ConvertTo-Json -InputObject $Request -Depth 15 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($payload) -gt 262144) { throw 'Deck transfer request is too large.' }
        $start.Arguments += ' ' + $Command
        $start.RedirectStandardInput = $true
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if ($Command -and $start.PSObject.Properties['StandardInputEncoding']) {
            $start.StandardInputEncoding = New-Object Text.UTF8Encoding($false)
            [void]$process.Start()
        } elseif ($Command) {
            # .NET Framework creates and flushes its stdin writer during Start,
            # using Console.InputEncoding. A UTF-8 console with a BOM would
            # prepend that BOM before our first byte. Serialize only this short
            # initialization and restore the host encoding before any I/O wait.
            [Threading.Monitor]::Enter([Console])
            $previousInputEncoding = [Console]::InputEncoding
            try {
                [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
                [void]$process.Start()
            } finally {
                try { [Console]::InputEncoding = $previousInputEncoding }
                finally { [Threading.Monitor]::Exit([Console]) }
            }
        } else {
            [void]$process.Start()
        }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if ($Command) {
            # The installed host uses .NET Framework, whose ProcessStartInfo
            # has no StandardInputEncoding. Write UTF-8 bytes directly so both
            # Windows PowerShell 5.1 and PS7 send the same BOM-free request.
            $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $write = $process.StandardInput.BaseStream.WriteAsync($payloadBytes, 0, $payloadBytes.Length)
            if (-not $write.Wait(10000)) { $process.Kill(); throw 'The Deck stopped accepting the transfer. Refresh its status before retrying.' }
            [void]$write.GetAwaiter().GetResult()
            # Closing the unused StreamWriter can append its encoding preamble
            # on .NET Framework. Close the byte stream directly to send EOF.
            $process.StandardInput.BaseStream.Close()
        }
        if (-not $process.WaitForExit($(if ($Command) { 30000 } else { 10000 }))) {
            $process.Kill()
            throw 'Steam Deck is unavailable. It may be off or asleep. Turn it on, keep it awake on the same network as this PC, then choose Refresh Deck. If it still cannot connect, open the companion and pair again.'
        }
        $text = $output.GetAwaiter().GetResult()
        if ($text.Length -gt 1048576) { throw 'Steam Deck discovery response is too large.' }
        if (-not $text.Trim()) { throw 'Steam Deck is unavailable. It may be off or asleep. Turn it on, keep it awake on the same network as this PC, then choose Refresh Deck. If it still cannot connect, open the companion and pair again.' }
        $result = $text | ConvertFrom-Json
        if ($result.ok -eq $false) { throw [string]$result.error }
        if ($process.ExitCode -ne 0) { throw 'Steam Deck is unavailable. It may be off or asleep. Turn it on, keep it awake on the same network as this PC, then choose Refresh Deck. If it still cannot connect, open the companion and pair again.' }
        return $result
    } finally { $process.Dispose() }
}

function Get-DuneSoloDeckStatus {
    $root = Get-DuneSoloDeckConnectionRoot
    $path = Join-Path $root 'connection.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ ok = $true; paired = $false; connected = $false; readOnly = $true; error = ''; report = $null }
    }
    try {
        $connection = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $report = Invoke-DuneSoloDeckReader -Root $root -Connection $connection
        if ([int]$report.protocol -ne 1 -or $report.mode -ne 'read-only' -or
            $report.os.ID -ne 'steamos' -or $report.os.VARIANT_ID -ne 'steamdeck') {
            throw 'The paired device did not return a supported SteamOS discovery report.'
        }
        $readOnly = 'managed-ini-v1' -notin @($report.settings_write_capabilities) -and 'mods-sync-v1' -notin @($report.mod_capabilities)
        return @{ ok = $true; paired = $true; connected = $true; readOnly = $readOnly; error = ''; report = $report; comparison = (Get-DuneSoloDeckComparison -Report $report) }
    } catch {
        return @{ ok = $true; paired = $true; connected = $false; readOnly = $true; error = $_.Exception.Message; report = $null }
    }
}

function New-DuneSoloDeckSettingsPlan {
    param([Parameter(Mandatory)]$State)
    if (-not $State.connected -or -not $State.comparison.available) { throw 'Connect the Deck and a local Solo profile before syncing.' }
    $report = $State.report
    if (@($report.game_processes).Count -or @($report.settings_candidates).Count -ne 1 -or @($report.errors).Count) { throw 'Close Dune on the Deck and resolve discovery errors before syncing.' }
    if ('managed-ini-v1' -notin @($report.settings_write_capabilities)) { throw 'Update and run the Deck Companion before syncing settings.' }
    $rows = @($State.comparison.differences | Where-Object action -eq 'Would copy to Deck')
    # PS5.1 Group/Sort-Object property names do not resolve hashtable keys.
    $files = @(foreach ($group in @($rows | Group-Object { $_.file } | Sort-Object Name)) {
        $target = @($report.settings_candidates[0].files | Where-Object file -eq $group.Name)
        if ($target.Count -ne 1) { throw 'Deck settings target changed; refresh the preview.' }
        [ordered]@{file=$group.Name;expected_sha256=$target[0].sha256;values=@($group.Group | Sort-Object { $_.section },{ $_.key } | ForEach-Object {
            [ordered]@{section=[string]$_.section;key=[string]$_.key;value=[string]$_.pcValue}
        })}
    })
    return @{request=[ordered]@{action='preview-settings';files=$files};rows=$rows}
}

function Get-DuneSoloDeckSaveFingerprints {
    param($Report)
    return ConvertTo-Json -InputObject @($Report.saves | Sort-Object { $_.path } | ForEach-Object {
        [ordered]@{path=[string]$_.path;sha256=[string]$_.sha256}
    }) -Compress
}

function Invoke-DuneSoloDeckSettingsPreview {
    Assert-DuneSoloGameClosed
    $state = Get-DuneSoloDeckStatus
    $plan = New-DuneSoloDeckSettingsPlan -State $state
    if (-not $plan.rows.Count) { return @{ok=$true;complete=$true;rows=@()} }
    $root = Get-DuneSoloDeckConnectionRoot
    $connectionPath = Join-Path $root 'connection.json'
    $connection = Get-Content -LiteralPath $connectionPath -Raw | ConvertFrom-Json
    $preview = Invoke-DuneSoloDeckReader -Root $root -Connection $connection -Command 'dst-settings-v1' -Request $plan.request
    if ($preview.PSObject.Properties.Name -notcontains 'applied' -or $preview.applied -ne $false) { throw 'The Deck helper did not confirm a settings-only preview.' }
    $token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    $record = [ordered]@{token=$token;expires=[DateTime]::UtcNow.AddMinutes(10).ToString('o');request=$plan.request
        connectionHash=(Get-FileHash -LiteralPath $connectionPath -Algorithm SHA256).Hash
        saveFingerprints=(Get-DuneSoloDeckSaveFingerprints $state.report)}
    [IO.File]::WriteAllText((Join-Path $root 'settings-preview.json'), ($record | ConvertTo-Json -Depth 15 -Compress), (New-Object Text.UTF8Encoding($false)))
    return @{ok=$true;token=$token;rows=$plan.rows;preview=$preview}
}

function Invoke-DuneSoloDeckSettingsApply {
    param([string]$Token, $Confirmed, $CloudConfirmed)
    if ($Confirmed -isnot [bool] -or -not $Confirmed -or $CloudConfirmed -isnot [bool] -or -not $CloudConfirmed) { throw 'Confirm the settings preview and completed Steam Cloud preparation.' }
    Assert-DuneSoloGameClosed
    $root = Get-DuneSoloDeckConnectionRoot
    $pending = Join-Path $root 'settings-preview.json'
    if (-not (Test-Path -LiteralPath $pending -PathType Leaf)) { throw 'Prepare a fresh settings preview.' }
    $record = Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json
    $connectionPath = Join-Path $root 'connection.json'
    if ($Token -cne [string]$record.token -or [DateTime]::Parse($record.expires).ToUniversalTime() -lt [DateTime]::UtcNow -or
        (Get-FileHash -LiteralPath $connectionPath -Algorithm SHA256).Hash -cne [string]$record.connectionHash) { throw 'The preview expired or pairing changed. Prepare a fresh preview.' }
    $state = Get-DuneSoloDeckStatus
    $plan = New-DuneSoloDeckSettingsPlan -State $state
    $currentJson = ConvertTo-Json -InputObject $plan.request -Depth 15 -Compress
    $expectedJson = ConvertTo-Json -InputObject $record.request -Depth 15 -Compress
    if ($currentJson -cne $expectedJson -or (Get-DuneSoloDeckSaveFingerprints $state.report) -cne [string]$record.saveFingerprints) { throw 'PC settings or the Deck save changed. Prepare a fresh preview.' }
    $request = [ordered]@{action='apply-settings';files=$plan.request.files;confirmed=$true;cloud_confirmed=$true}
    # Consume once before dispatch. A lost reply must never cause an automatic retry.
    Remove-Item -LiteralPath $pending -Force
    $connection = Get-Content -LiteralPath $connectionPath -Raw | ConvertFrom-Json
    $result = Invoke-DuneSoloDeckReader -Root $root -Connection $connection -Command 'dst-settings-v1' -Request $request
    if ($result.PSObject.Properties.Name -notcontains 'applied') { throw 'Deck transfer did not return a settings result. Refresh before retrying.' }
    $after = Get-DuneSoloDeckStatus
    if (-not $after.connected) { throw 'Transfer returned, but the Deck readback is unavailable. Reconnect and refresh before launching.' }
    $saveUnchanged = (Get-DuneSoloDeckSaveFingerprints $after.report) -ceq [string]$record.saveFingerprints
    $remaining = @((New-DuneSoloDeckSettingsPlan $after).rows).Count
    return @{ok=$true;applied=[bool]$result.applied;backup=[string]$result.backup;saveUnchanged=$saveUnchanged;remainingDifferences=$remaining}
}
