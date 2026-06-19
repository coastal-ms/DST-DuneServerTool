# PublicIp - Settings-driven public IP / DDNS switch.

function Test-DuneIPv4Literal {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { return $false }
    foreach ($p in @($Ip -split '\.')) {
        if ($p -notmatch '^\d+$') { return $false }
        $n = [int]$p
        if ($n -lt 0 -or $n -gt 255) { return $false }
    }
    return $true
}

function Test-DunePublicIPv4 {
    param([string]$Ip)
    if (-not (Test-DuneIPv4Literal -Ip $Ip)) {
        return @{ ok = $false; status = 400; message = 'Enter a valid IPv4 address, for example 8.8.8.8.' }
    }
    $parts = @($Ip -split '\.' | ForEach-Object { [int]$_ })
    $a = $parts[0]; $b = $parts[1]
    if ($a -eq 0 -or $a -eq 255) { return @{ ok=$false; status=400; message='Public IP cannot be unspecified, broadcast, or reserved.' } }
    if ($a -eq 10 -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168)) {
        return @{ ok=$false; status=400; message='Public IP cannot be a private LAN address.' }
    }
    if ($a -eq 127) { return @{ ok=$false; status=400; message='Public IP cannot be a loopback address.' } }
    if ($a -eq 169 -and $b -eq 254) { return @{ ok=$false; status=400; message='Public IP cannot be a link-local address.' } }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return @{ ok=$false; status=400; message='Public IP cannot be a carrier-grade NAT address.' } }
    if ($a -ge 224) { return @{ ok=$false; status=400; message='Public IP cannot be multicast or reserved.' } }
    if (($a -eq 192 -and $b -eq 0) -or ($a -eq 198 -and ($b -eq 18 -or $b -eq 19)) -or ($a -eq 198 -and $b -eq 51) -or ($a -eq 203 -and $b -eq 0)) {
        return @{ ok=$false; status=400; message='Public IP cannot be documentation, benchmark, or reserved address space.' }
    }
    return @{ ok = $true; ip = $Ip }
}

function Test-DunePublicIpUnchanged {
    param([string]$PublicIp)
    $cfg = Read-DuneConfig
    if ($cfg.LastAppliedPublicIp -and $cfg.LastAppliedPublicIp -eq $PublicIp) {
        return @{ ok=$false; status=409; message="Target IP is unchanged ($PublicIp)." }
    }
    return @{ ok=$true }
}

function Assert-DuneManualPublicIp {
    param([string]$PublicIp, [switch]$AllowUnchanged)
    $ip = ([string]$PublicIp).Trim()
    $v = Test-DunePublicIPv4 -Ip $ip
    if (-not $v.ok) { return $v }
    if (-not $AllowUnchanged.IsPresent) {
        $u = Test-DunePublicIpUnchanged -PublicIp $ip
        if (-not $u.ok) { return $u }
    }
    return @{ ok=$true; publicIp=$ip }
}

function Test-DuneDdnsHostname {
    param([string]$Hostname)
    $h = ([string]$Hostname).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($h)) { return @{ ok=$false; status=400; message='Enter a DDNS hostname.' } }
    if ($h.Length -gt 253 -or $h -notmatch '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' -or $h -match '\.\.' -or $h -notmatch '\.') {
        return @{ ok=$false; status=400; message='Enter a valid hostname, for example your-server.ddns.net.' }
    }
    foreach ($label in @($h -split '\.')) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$') {
            return @{ ok=$false; status=400; message='Enter a valid hostname. Labels may contain letters, numbers, and hyphens.' }
        }
    }
    return @{ ok=$true; hostname=$h }
}

function Resolve-DunePublicIpHostname {
    param([string]$Hostname)
    $hv = Test-DuneDdnsHostname -Hostname $Hostname
    if (-not $hv.ok) { return $hv }
    $records = @()
    try {
        $records = @(Resolve-DnsName -Name $hv.hostname -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -ExpandProperty IPAddress -Unique)
    } catch {
        try {
            $records = @([System.Net.Dns]::GetHostAddresses($hv.hostname) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.ToString() } |
                Select-Object -Unique)
        } catch {
            return @{ ok=$false; status=400; message="Could not resolve hostname '$($hv.hostname)' to an IPv4 address." }
        }
    }
    $public = @()
    foreach ($r in $records) {
        $v = Test-DunePublicIPv4 -Ip ([string]$r)
        if ($v.ok) { $public += $v.ip }
    }
    $public = @($public | Select-Object -Unique)
    if ($public.Count -lt 1) {
        return @{ ok=$false; status=400; message="Hostname '$($hv.hostname)' did not resolve to a usable public IPv4 address."; candidates=@($records) }
    }
    return @{ ok=$true; hostname=$hv.hostname; publicIp=$public[0]; candidates=@($public) }
}

function Save-DunePublicIpHostname {
    param([string]$Hostname)
    $hv = Test-DuneDdnsHostname -Hostname $Hostname
    if (-not $hv.ok) { return $hv }

    $save = {
        Save-DuneConfig -Config @{
            PublicIpMode = 'ddns'
            DdnsHostname = $hv.hostname
        } | Out-Null
    }
    if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
        Invoke-WithDuneLock -Name 'config' -Script $save | Out-Null
    } else {
        & $save
    }
    return @{ ok=$true; hostname=$hv.hostname }
}

function New-DuneSettingsConfText {
    param(
        [Parameter(Mandatory)][string]$Battlegroup,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$VmIp,
        [Parameter(Mandatory)][string]$PublicIp
    )
    $bg = $Battlegroup.Trim()
    $img = $Image.Trim()
    $vm = $VmIp.Trim()
    $pub = $PublicIp.Trim()
    if (-not $bg) { throw 'Battlegroup name is empty.' }
    if ($img -notmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:[^\s]+$') {
        throw "Funcom image is not a single seabass-server image string: $img"
    }
    if (-not (Test-DuneIPv4Literal -Ip $vm)) { throw "VM IP is invalid: $vm" }
    $pv = Test-DunePublicIPv4 -Ip $pub
    if (-not $pv.ok) { throw $pv.message }
    return "$bg`n$img`n$vm`n$pub`n"
}

function Test-DuneAdminElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function ConvertTo-DuneBashSingleQuoted {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return "'" + ([string]$Value -replace "'", "'\''") + "'"
}

function Invoke-DunePublicIpRemoteScript {
    param([string]$Ip, [string]$Script, [string[]]$Arguments = @(), [int]$TimeoutSec = 120)
    $argText = (@($Arguments) | ForEach-Object { ConvertTo-DuneBashSingleQuoted $_ }) -join ' '
    $cmd = "tmp=/tmp/dst-public-ip-`$`$-`$RANDOM.sh; cat > `$tmp; chmod 700 `$tmp; /bin/sh `$tmp $argText 2>&1; code=`$?; echo __DST_EXIT__:`$code; rm -f `$tmp; exit 0"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData ($Script -replace "`r`n","`n") -TimeoutSec $TimeoutSec
    $text = (($out -join "`n")).Trim()
    if ($text -notmatch '(?m)^__DST_EXIT__:(\d+)\s*$') {
        throw "Remote script did not report an exit code. Output: $text"
    }
    $code = [int]$Matches[1]
    $clean = (($text -split "`n") | Where-Object { $_ -notmatch '^__DST_EXIT__:\d+\s*$' }) -join "`n"
    $clean = $clean.Trim()
    if ($code -ne 0) { throw "Remote script failed with exit $code. Output: $clean" }
    return $clean
}

function New-DunePublicIpStepResult {
    param([string]$Id, [string]$Label, [string]$Status, [string]$Detail = '', [string]$Raw = '')
    return @{ id=$Id; label=$Label; status=$Status; detail=$Detail; raw=$Raw }
}

function Get-DunePublicIpStatus {
    $cfg = Read-DuneConfig
    $vm = $null
    try { $vm = Get-DuneVmStatus } catch {}
    $status = @{
        mode                = if ($cfg.PublicIpMode -eq 'manual') { 'manual' } else { 'ddns' }
        hostname            = [string]$cfg.DdnsHostname
        manualPublicIp      = [string]$cfg.ManualPublicIp
        lastResolvedPublicIp= [string]$cfg.LastResolvedPublicIp
        lastAppliedPublicIp = [string]$cfg.LastAppliedPublicIp
        currentPublicIp     = $null
        vmIp                = if ($vm) { $vm.ip } else { $null }
        k3sExternalIp       = ''
    }
    try { $status.currentPublicIp = Get-DunePublicIp } catch {}
    if ($vm -and $vm.running -and $vm.ip) {
        try {
            $raw = Invoke-V6Ssh -Ip $vm.ip -Cmd "sudo kubectl get node -o jsonpath='{range .items[0].status.addresses[?(@.type==`"ExternalIP`")]}{.address}{end}' 2>/dev/null" -TimeoutSec 15
            $status.k3sExternalIp = (($raw -join '').Trim())
        } catch {}
    }
    return $status
}

function Invoke-DunePublicIpHostRoute {
    param([string]$PublicIp, [string]$VmIp)
    if (-not (Test-DuneAdminElevated)) { throw 'DST is not elevated. Restart Dune Server Tool as administrator before applying a public IP change.' }
    $route = $null
    try { $route = Find-NetRoute -RemoteIPAddress $VmIp -ErrorAction Stop | Select-Object -First 1 } catch {}
    if (-not $route) { throw "Could not find a Windows route to VM IP $VmIp." }
    $iface = [int]$route.InterfaceIndex
    $existing = @(Get-NetRoute -DestinationPrefix "$PublicIp/32" -ErrorAction SilentlyContinue)
    foreach ($r in $existing) {
        if ($r.NextHop -ne $VmIp -or [int]$r.InterfaceIndex -ne $iface) {
            throw "A host route for $PublicIp/32 already exists but does not point to $VmIp. Remove it manually before applying."
        }
    }
    if (-not $existing) {
        New-NetRoute -DestinationPrefix "$PublicIp/32" -InterfaceIndex $iface -NextHop $VmIp -RouteMetric 1 -ErrorAction Stop | Out-Null
    }
    return "Route $PublicIp/32 via $VmIp is present."
}

function Invoke-DunePublicIpApply {
    param([Parameter(Mandatory)][string]$PublicIp, [string]$Mode = 'manual', [string]$Hostname = '')
    $steps = [System.Collections.Generic.List[object]]::new()
    try {
        Invoke-WithDuneLock -Name 'public-ip-change' -TimeoutSec 5 -Script {
            $target = ([string]$PublicIp).Trim()
            $steps.Add((New-DunePublicIpStepResult 'validate' 'Validate target IP' 'running' "Checking $target.")) | Out-Null
            $valid = Assert-DuneManualPublicIp -PublicIp $target
            if (-not $valid.ok) { throw $valid.message }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'validate' 'Validate target IP' 'done' "Target $target accepted."

            $steps.Add((New-DunePublicIpStepResult 'preflight' 'Preflight host and VM' 'running' 'Checking VM and SSH.')) | Out-Null
            $vm = Get-DuneVmStatus
            if (-not $vm.exists) { throw "VM '$($vm.name)' does not exist." }
            if (-not $vm.running) { throw "VM '$($vm.name)' is not running." }
            if (-not $vm.ip) { throw 'VM is running but has no IP yet.' }
            $cfg = Read-DuneConfig
            if (-not $cfg.SshKey -or -not (Test-Path -LiteralPath $cfg.SshKey)) { throw 'SSH key is not configured in Settings.' }
            $ssh = Invoke-DuneSshHidden -Ip $vm.ip -KeyPath $cfg.SshKey -TimeoutSec 12 -SshOptions @(
                '-o','StrictHostKeyChecking=no','-o','LogLevel=ERROR','-o','ConnectTimeout=8','-o','BatchMode=yes'
            ) -RemoteCommand 'echo DST_SSH_OK'
            if ($ssh.Exit -ne 0 -or ($ssh.Stdout -notmatch 'DST_SSH_OK')) {
                $reason = Get-DuneSshFailureReason -Stderr $ssh.Stderr -ExitCode $ssh.Exit -KeyPath $cfg.SshKey
                if (-not $reason) { $reason = 'SSH reachability check failed.' }
                throw $reason
            }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'preflight' 'Preflight host and VM' 'done' "VM $($vm.ip) reachable."

            $steps.Add((New-DunePublicIpStepResult 'host-route' 'Update Windows host route' 'running' "Adding route for $target.")) | Out-Null
            $routeMsg = Invoke-DunePublicIpHostRoute -PublicIp $target -VmIp $vm.ip
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'host-route' 'Update Windows host route' 'done' $routeMsg

            $remoteScript = @'
set -eu
NEW_IP="$1"
VM_IP="$2"

step() { printf '\n=== %s ===\n' "$1"; }

step discover
BG_NS=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.namespace' 2>/dev/null | head -1 | tr -d ' ')
BG_NAME=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 | tr -d ' ')
IMAGE=$(sudo kubectl get battlegroup "$BG_NAME" -n "$BG_NS" -o jsonpath='{.spec.serverGroup.template.spec.sets[0].image}' 2>/dev/null || true)
if [ -z "$IMAGE" ]; then IMAGE=$(sed -n '2p' /home/dune/.dune/settings.conf 2>/dev/null || true); fi
case "$IMAGE" in registry.funcom.com/funcom/self-hosting/seabass-server:*) ;; *) IMAGE="registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping";; esac
if [ -z "$BG_NS" ] || [ -z "$BG_NAME" ]; then echo "No battlegroup found"; exit 2; fi
printf 'BG=%s NS=%s IMAGE=%s\n' "$BG_NAME" "$BG_NS" "$IMAGE"

step alias
for addr in $(/sbin/ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1); do
  if [ "$addr" != "$VM_IP" ] && [ "$addr" != "$NEW_IP" ]; then
    sudo ip addr del "$addr/32" dev eth0 2>/dev/null || true
  fi
done
if ! /sbin/ip -4 addr show dev eth0 | grep -q " $NEW_IP/32"; then
  sudo ip addr add "$NEW_IP/32" dev eth0 label eth0:1
fi
/sbin/ip -4 -o addr show dev eth0

step interfaces
GW=$(awk '/^[[:space:]]*gateway[[:space:]]+/ {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
if [ -z "$GW" ]; then GW="192.168.23.1"; fi
sudo cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || true
cat > /tmp/dst-interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $VM_IP/24
    gateway $GW

auto eth0:1
iface eth0:1 inet static
    address $NEW_IP
    netmask 255.255.255.255
EOF
sudo install -m 0644 /tmp/dst-interfaces /etc/network/interfaces
rm -f /tmp/dst-interfaces

step settings
sudo -u dune mkdir -p /home/dune/.dune
if [ -f /home/dune/.dune/settings.conf ]; then sudo cp /home/dune/.dune/settings.conf "/home/dune/.dune/settings.conf.bak.$(date -u +%Y%m%d%H%M%S)"; fi
printf '%s\n%s\n%s\n%s\n' "$BG_NAME" "$IMAGE" "$VM_IP" "$NEW_IP" | sudo tee /home/dune/.dune/settings.conf >/dev/null
sudo chown dune:dune /home/dune/.dune/settings.conf
test "$(sudo wc -l < /home/dune/.dune/settings.conf | tr -d ' ')" = "4"
sed -n '1,4p' /home/dune/.dune/settings.conf

step runner
runner=/usr/local/bin/k3s-custom-runner.sh
target='dynamic_ip=$(/sbin/ip addr show eth0 | awk '\''/inet / {print $2; exit}'\'' | cut -d/ -f1)'
if [ -f "$runner" ]; then
  sudo cp "$runner" "$runner.bak.$(date -u +%Y%m%d%H%M%S)"
  awk -v target="$target" 'BEGIN{done=0} /^dynamic_ip=/{print target; done=1; next} {print} END{if(!done) print target}' "$runner" > /tmp/dst-runner
  sudo install -m 0755 /tmp/dst-runner "$runner"
  rm -f /tmp/dst-runner
  grep -F "$target" "$runner"
fi

step k3s
NODE=$(sudo kubectl get nodes --no-headers -o custom-columns=':metadata.name' | head -1 | tr -d ' ')
sudo kubectl annotate node "$NODE" "k3s.io/external-ip=$NEW_IP" --overwrite
sudo kubectl patch node "$NODE" --subresource=status --type=merge -p "{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"$VM_IP\"},{\"type\":\"ExternalIP\",\"address\":\"$NEW_IP\"},{\"type\":\"Hostname\",\"address\":\"$NODE\"}]}}" >/dev/null
sudo kubectl get node "$NODE" -o wide

step helper
if [ -x /home/dune/.dune/bin/battlegroup ]; then /home/dune/.dune/bin/battlegroup change-battlegroup-ip "$NEW_IP" || true; else echo "battlegroup helper not found"; fi

step nat
cat > /tmp/dune-iptables.start <<EOF
#!/bin/sh
# Restore DNAT rules for Dune Awakening server on boot.

NEW_IP="$NEW_IP"
VM_IP="$VM_IP"
GAME_PORTS="7777:7810"
RABBIT_PORT="31982"

sleep 30

iptables -t nat -I PREROUTING 1 -d "\$VM_IP" -p udp --dport "\$GAME_PORTS" -j DNAT --to-destination "\$NEW_IP"

POD_IP=\$(k3s kubectl get endpoints --all-namespaces -o wide 2>/dev/null | grep mq-game | awk '{print \$3}' | cut -d, -f1 | cut -d: -f1)
if [ -n "\$POD_IP" ]; then
    iptables -t nat -I PREROUTING 1 -d "\$NEW_IP" -p tcp --dport "\$RABBIT_PORT" -j DNAT --to-destination "\${POD_IP}:5672"
fi
EOF
sudo install -m 0755 /tmp/dune-iptables.start /etc/local.d/dune-iptables.start
rm -f /tmp/dune-iptables.start
sh -n /etc/local.d/dune-iptables.start
MQ_IP=$(sudo kubectl get endpoints --all-namespaces -o wide 2>/dev/null | grep mq-game | awk '{print $3}' | cut -d, -f1 | cut -d: -f1 | head -1)
sudo iptables -t nat -I PREROUTING 1 -d "$VM_IP" -p udp --dport 7777:7810 -j DNAT --to-destination "$NEW_IP"
if [ -n "$MQ_IP" ]; then sudo iptables -t nat -I PREROUTING 1 -d "$NEW_IP" -p tcp --dport 31982 -j DNAT --to-destination "${MQ_IP}:5672"; fi
echo "NAT refreshed"

step pods
sudo kubectl -n "$BG_NS" delete pod -l app.kubernetes.io/part-of="$BG_NAME" --wait=false 2>/dev/null || true
sudo kubectl -n "$BG_NS" get pod --field-selector=status.phase=Running --no-headers 2>/dev/null |
  awk '/-sg-/ {print $1}' |
  xargs -r sudo kubectl -n "$BG_NS" delete pod --wait=false 2>/dev/null || true
for i in $(seq 1 36); do
  surv=$(sudo kubectl -n "$BG_NS" get serverset "$BG_NAME-sg-survival-1" -o jsonpath='{.status.ready}' 2>/dev/null || echo 0)
  over=$(sudo kubectl -n "$BG_NS" get serverset "$BG_NAME-sg-overmap" -o jsonpath='{.status.ready}' 2>/dev/null || echo 0)
  [ "$surv" = "1" ] && [ "$over" = "1" ] && break
  sleep 5
done
sudo kubectl -n "$BG_NS" get serverset | awk 'NR==1 || /survival-1|overmap|deepdesert-1/'

step verify
sudo kubectl get node "$NODE" -o wide
sudo kubectl -n "$BG_NS" get battlegroup "$BG_NAME" -o wide || true
echo "Done"
'@
            $steps.Add((New-DunePublicIpStepResult 'vm' 'Update VM and Dune stack' 'running' 'Applying documented IP-change workflow over SSH.')) | Out-Null
            $raw = Invoke-DunePublicIpRemoteScript -Ip $vm.ip -Script $remoteScript -Arguments @($target, $vm.ip) -TimeoutSec 420
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'vm' 'Update VM and Dune stack' 'done' 'VM alias, persistent files, K3s, NAT, and pods updated.' $raw

            $steps.Add((New-DunePublicIpStepResult 'verify-port' 'Verify RabbitMQ port' 'running' "Checking TCP $target:31982.")) | Out-Null
            $tcp = $false
            try { $tcp = Test-NetConnection -ComputerName $target -Port 31982 -InformationLevel Quiet -WarningAction SilentlyContinue } catch { $tcp = $false }
            if (-not $tcp) { throw "Test-NetConnection $target -Port 31982 failed." }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'verify-port' 'Verify RabbitMQ port' 'done' "TCP $target:31982 is reachable."

            Save-DuneConfig -Config @{
                PublicIpMode = $Mode
                DdnsHostname = if ($Mode -eq 'ddns') { $Hostname } else { '' }
                ManualPublicIp = if ($Mode -eq 'manual') { $target } else { '' }
                LastResolvedPublicIp = $target
                LastAppliedPublicIp = $target
            } | Out-Null
        }
        return @{ ok=$true; publicIp=$PublicIp; steps=@($steps) }
    } catch {
        if ($steps.Count -gt 0 -and $steps[$steps.Count - 1].status -eq 'running') {
            $last = $steps[$steps.Count - 1]
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult $last.id $last.label 'failed' $_.Exception.Message $last.raw
        }
        return @{ ok=$false; publicIp=$PublicIp; error=$_.Exception.Message; steps=@($steps) }
    }
}
