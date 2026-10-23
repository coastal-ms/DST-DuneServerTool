# Guest setup transport keeps shell quoting intact across Windows OpenSSH.
function Get-DuneHyperVLanResumeTarget {
    param($Session, [string]$VmId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($VmId, [ref]$parsed)) { throw 'The previous VM identity is missing. No existing VM will be changed.' }
    return Invoke-Command -Session $Session -ArgumentList $VmId -ScriptBlock {
        param($id)
        $vm = Get-VM -Id ([guid]$id) -ErrorAction Stop
        if ($vm.Name -ne 'dune-awakening') { throw 'The recorded VM is no longer the Dune VM.' }
        if ($vm.State -ne 'Running') { Start-VM -VM $vm -ErrorAction Stop | Out-Null }
        for ($attempt=0; $attempt -lt 30; $attempt++) {
            $ip = (Get-VMNetworkAdapter -VM $vm).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' } | Select-Object -First 1
            if ($ip) { return @{ ip=[string]$ip; vmId=[string]$vm.Id } }
            Start-Sleep -Seconds 3
        }
        throw 'The existing VM has not reported a LAN address yet. It is preserved.'
    } -ErrorAction Stop
}

function ConvertTo-DuneLanShellCommand {
    param([string]$Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Script -replace "`r`n", "`n")))
    return "echo $encoded | base64 -d | sh"
}

function Get-DuneLanAuthorizeKeyCommand {
    param([string]$PublicKey)
    if ($PublicKey.Trim() -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+) [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$') {
        throw 'The SSH public key must be a single valid public-key line.'
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PublicKey.Trim()))
    return ConvertTo-DuneLanShellCommand @"
set -e
umask 077
mkdir -p "`$HOME/.ssh"
touch "`$HOME/.ssh/authorized_keys"
key=`$(echo $encoded | base64 -d)
grep -qxF -- "`$key" "`$HOME/.ssh/authorized_keys" || printf '%s\n' "`$key" >> "`$HOME/.ssh/authorized_keys"
chmod 700 "`$HOME/.ssh"
chmod 600 "`$HOME/.ssh/authorized_keys"
echo KEYOK
"@
}

function Assert-DuneLanNetwork {
    param([hashtable]$Network)
    if (-not $Network -or $Network.mode -notin @('dhcp','static')) { throw 'Choose automatic (DHCP) or a fixed VM IP address.' }
    if ($Network.mode -eq 'dhcp') { return }
    foreach ($field in @('address','gateway','dns')) {
        $value = [string]$Network[$field]
        $parsed = $null
        if ($value -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($value, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.GetAddressBytes()[0] -in @(0,127) -or $parsed.GetAddressBytes()[0] -ge 224) {
            throw "Enter a valid IPv4 $field."
        }
    }
    $prefix = 0
    if (-not [int]::TryParse([string]$Network.prefix, [ref]$prefix) -or $prefix -lt 1 -or $prefix -gt 30) { throw 'Enter a subnet prefix between 1 and 30.' }
    if ($Network.address -eq $Network.gateway) { throw 'The VM IP and gateway must be different.' }
    $address = [Net.IPAddress]::Parse($Network.address).GetAddressBytes()
    $gateway = [Net.IPAddress]::Parse($Network.gateway).GetAddressBytes()
    for ($bit = 0; $bit -lt $prefix; $bit++) {
        $index = [math]::Floor($bit / 8); $mask = 1 -shl (7 - ($bit % 8))
        if (($address[$index] -band $mask) -ne ($gateway[$index] -band $mask)) { throw 'The VM IP and gateway must be in the same subnet.' }
    }
    $hostBits = 32 - $prefix
    $numeric = ([uint64]$address[0] -shl 24) + ([uint64]$address[1] -shl 16) + ([uint64]$address[2] -shl 8) + $address[3]
    $hostMask = ([uint64]1 -shl $hostBits) - 1
    if (($numeric -band $hostMask) -in @(0, $hostMask)) { throw 'The VM IP cannot be the subnet or broadcast address.' }
}

function Invoke-DuneLanKeyCommand {
    param([string]$GuestIp, [string]$Key, [string]$Command, [string]$HostKeyAlias)
    $options = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=15','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3','-o','LogLevel=ERROR','-o','BatchMode=yes','-o','IdentitiesOnly=yes')
    if ($HostKeyAlias) { $options += @('-o', "HostKeyAlias=$HostKeyAlias") }
    $output = & ssh @options -i $Key "dune@$GuestIp" $Command 2>&1
    return @{ ok=($LASTEXITCODE -eq 0); output=($output | Out-String) }
}

function Get-DuneLanStopDhcpScript {
    # Alpine BusyBox matches argv[0] (/sbin/udhcpc), so -x udhcpc misses it.
    # Match only the eth0 client, including its absolute executable path.
    return @'
dhcp_pattern="^([^ ]*/)?udhcpc( .* )?-i eth0( |$)"
pkill -TERM -f "$dhcp_pattern" 2>/dev/null || true
for attempt in 1 2 3 4 5; do
    if ! pgrep -f "$dhcp_pattern" >/dev/null; then break; fi
    sleep 1
done
if pgrep -f "$dhcp_pattern" >/dev/null; then
    echo "The eth0 DHCP client did not stop" >&2
    exit 1
fi
'@
}

function Set-DuneLanGuestNetwork {
    param([string]$GuestIp, [string]$Key, [hashtable]$Network, [string]$VmId)
    Assert-DuneLanNetwork $Network
    if ($Network.mode -eq 'dhcp') { return $GuestIp }
    $hostAlias = if ($VmId) { 'dst-lan-' + ([guid]$VmId).ToString('N') } else { '' }
    # Match Funcom's Alpine eth0 setup. Retain a rollback copy, and restore it
    # automatically unless this client reconnects to the selected new address.
    $address = $Network.address; $prefix = [int]$Network.prefix; $gateway = $Network.gateway; $dns = $Network.dns
    $interfaces = "auto lo`niface lo inet loopback`n`nauto eth0`niface eth0 inet static`n    address $address/$prefix`n    gateway $gateway`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($interfaces))
    $marker = '/tmp/dst-network-' + [guid]::NewGuid().ToString('N')
    $stopDhcp = Get-DuneLanStopDhcpScript
    $apply = ConvertTo-DuneLanShellCommand @"
set -e
sleep 2
$stopDhcp
ip addr flush dev eth0
rc-service networking restart
touch $marker.applied
"@
    $rollback = ConvertTo-DuneLanShellCommand @"
set -e
sleep 90
if [ ! -f $marker.ok ]; then
    cp $marker.interfaces /etc/network/interfaces
    cp $marker.resolv /etc/resolv.conf
    $stopDhcp
    ip addr flush dev eth0
    rc-service networking restart
fi
"@
    $script = @"
set -e
sudo -n cp /etc/network/interfaces $marker.interfaces
sudo -n cp /etc/resolv.conf $marker.resolv
echo $b64 | base64 -d | sudo -n tee /etc/network/interfaces >/dev/null
printf 'nameserver $dns\n' | sudo -n tee /etc/resolv.conf >/dev/null
nohup sudo -n sh -c '$rollback' </dev/null >$marker.rollback.log 2>&1 &
nohup sudo -n sh -c '$apply' </dev/null >$marker.apply.log 2>&1 &
echo APPLY_OK
"@
    $result = Invoke-DuneLanKeyCommand $GuestIp $Key (ConvertTo-DuneLanShellCommand $script) -HostKeyAlias $hostAlias
    if (-not $result.ok -or $result.output -notmatch 'APPLY_OK') { throw 'Could not apply the selected VM network settings. The existing VM is preserved.' }
    Start-Sleep -Seconds 5
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        $check = Invoke-DuneLanKeyCommand $address $Key "sudo -n test -f $marker.applied && ! sudo -n pgrep -f '^([^ ]*/)?udhcpc( .* )?-i eth0( |$)' >/dev/null && sudo -n touch $marker.ok && echo NETWORK_OK" -HostKeyAlias $hostAlias
        if ($check.ok -and $check.output -match 'NETWORK_OK') {
            if ($hostAlias) { Register-DuneLanVerifiedHost -GuestIp $address -HostKeyAlias $hostAlias }
            return $address
        }
        Start-Sleep -Seconds 3
    }
    throw 'The selected VM IP could not be reached. The previous network configuration will be restored automatically; check the address, subnet and gateway before resuming.'
}

function Register-DuneLanVerifiedHost {
    param([string]$GuestIp, [string]$HostKeyAlias)
    $knownHosts = Join-Path $env:USERPROFILE '.ssh/known_hosts'
    $entries = @(& ssh-keygen -F $HostKeyAlias -f $knownHosts 2>$null | Where-Object { $_ -and $_ -notmatch '^#' })
    if (-not $entries.Count) { throw 'The verified VM host key could not be found. The VM is preserved.' }
    $keys = @($entries | ForEach-Object {
        $parts = $_ -split '\s+'
        if ($parts.Count -lt 3 -or $parts[1] -notmatch '^(ssh-|ecdsa-)') { throw 'Unexpected host key entry; preserving existing trust.' }
        "$GuestIp $($parts[1]) $($parts[2])"
    })
    # Only the explicitly selected VM IP is replaced. ssh-keygen retains its
    # normal .old backup; the VM-specific alias remains available for recovery.
    & ssh-keygen -R $GuestIp -f $knownHosts 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not replace the old VM IP host-key entry.' }
    Add-Content -LiteralPath $knownHosts -Value $keys -Encoding ascii
}

function Remove-DuneHyperVLanAttempt {
    param([string]$HostIp, [string]$User, [string]$Password, [bool]$Confirmed)
    $jobs = Get-DuneHyperVLanInstallJobs
    [System.Threading.Monitor]::Enter($jobs.SyncRoot)
    try { Remove-DuneHyperVLanAttemptInternal @PSBoundParameters }
    finally { [System.Threading.Monitor]::Exit($jobs.SyncRoot) }
}

function Remove-DuneHyperVLanAttemptInternal {
    param([string]$HostIp, [string]$User, [string]$Password, [bool]$Confirmed)
    if (-not $Confirmed) { throw 'Confirm removal of this unfinished installation.' }
    $state = Get-DuneHyperVLanInstallStatus
    if ($state.running -or $state.phase -eq 'done' -or $state.hostIp -ne $HostIp) { throw 'Only a stopped, unfinished installation on this host can be removed.' }
    if (-not $state.vmId -and -not $state.stageRoot) { throw 'No files or VM from this attempt are recorded for removal.' }
    $credential = Resolve-DuneHyperVLanCredential -HostIp $HostIp -User $User -Password $Password
    if (-not $credential.ok) { throw $credential.error }
    $session = New-PSSession -ComputerName $HostIp -Credential $credential.credential -ErrorAction Stop
    try {
        Invoke-Command -Session $session -ArgumentList $state.vmId, $state.installRoot, $state.stageRoot -ScriptBlock {
            param($vmId, $installRoot, $stageRoot)
            $targets = @()
            $vm = $null
            if ($vmId) {
                $vm = Get-VM -Id ([guid]$vmId) -ErrorAction SilentlyContinue
                $root = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')
                if ($root -notmatch '^[A-Za-z]:\\DuneAwakeningServer$') { throw 'Unexpected installation path; preserving files.' }
                if ($vm) {
                    if ($vm.Name -ne 'dune-awakening' -or -not ([IO.Path]::GetFullPath($vm.ConfigurationLocation).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $vm.ConfigurationLocation -eq $root)) { throw 'VM ownership changed; preserving it.' }
                    foreach ($disk in @(Get-VMHardDiskDrive -VM $vm)) {
                        if (-not [IO.Path]::GetFullPath($disk.Path).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'VM uses a disk outside this installation; preserving it.' }
                    }
                    $targets += $root
                } elseif (Test-Path -LiteralPath $root) {
                    throw 'The recorded VM is missing but its destination still contains files. Preserving files whose ownership cannot be checked.'
                }
            }
            if ($stageRoot) {
                $stage = [IO.Path]::GetFullPath($stageRoot)
                if ($stage -notmatch '^[A-Za-z]:\\DuneServerStage\\[a-fA-F0-9]{32}$') { throw 'Unexpected staging path; preserving files.' }
                $targets += $stage
            }
            foreach ($target in $targets) {
                if (Test-Path -LiteralPath $target) {
                    $entries = @(Get-Item -LiteralPath $target -Force) + @(Get-ChildItem -LiteralPath $target -Recurse -Force)
                    if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Installation contains a link; preserving files.' }
                }
            }
            if ($vm) { if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop }; Remove-VM -VM $vm -Force -ErrorAction Stop }
            foreach ($target in $targets) { if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop } }
        } -ErrorAction Stop
        Save-DuneHyperVLanInstallState @{ running=$false; phase='idle'; ip=''; error=''; steps=@(); finished=[datetime]::UtcNow.ToString('o') }
        return @{ ok=$true }
    } finally { if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue } }
}
