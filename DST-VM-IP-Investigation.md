# DST VM IP-Loss Investigation Brief

Use this brief with ChatGPT Codex to investigate the affected Windows host and
Dune: Awakening Linux VM. Attach the relevant `dune-server.log` and any captured
command output.

## Objective

Determine why the running Hyper-V VM sometimes stops reporting an IPv4 address.
Do not assume DST, a DST update, MobileBridge, scheduled restarts, or the DNAT
watchdog caused the condition. Establish the failure at the guest, Hyper-V, and
host-network layers using timestamped evidence.

Start read-only. Do not reboot the VM, restart networking, reinstall components,
or change addresses/routes/firewall rules until the failure state is captured.
Redact public IP addresses, tokens, credentials, and private personal data before
sharing results.

## Reported behavior

- DST and the VM run on the same Windows server.
- After some DST updates, the VM allegedly loses local IPv4, public IPv4, and
  IPv6 one or two days later.
- Hyper-V still reports the VM as running.
- Rebooting the VM reportedly restores networking.
- The failure is intermittent and has not occurred after every update or every
  scheduled restart.

## What the supplied DST log establishes

The message `VM is running but has no IP yet` means DST queried the Windows
Hyper-V `Get-VMNetworkAdapter` `IPAddresses` property and found no IPv4 address.
It does **not** prove that Linux had no configured addresses. Hyper-V guest
address reporting can also be absent or stale when Data Exchange/KVP integration
is unhealthy.

Observed counterexamples:

- DST v12.21.2 reported no IPv4 on July 27, but scheduled restarts succeeded on
  July 28 and July 29.
- DST v12.21.3 started with an IPv4 on July 29. The July 30 restart succeeded.
  On July 31, DST observed no IPv4 before the scheduled restart attempted to run.
- DST v13.0.2 started while no IPv4 was reported, but the next scheduled restart
  succeeded.
- DST v13.0.6 reported no IPv4 at one startup, then detected an IPv4 at another
  DST startup approximately seven minutes later.
- DST v13.2.4 completed scheduled restarts successfully on August 4, 5, 6, and 7.
- Across the reviewed period, MobileBridge auto-heal was common during healthy
  operation and did not reliably correlate with missing IPv4 observations.

## Relevant DST design facts

### DST updates

DST's updater and installer stop and replace Windows-side DST processes and
files. They do not connect to the VM or alter guest networking during an update.

### MobileBridge

MobileBridge is a Windows loopback helper using `127.0.0.1:47900`. Its auto-heal
checks or reinstalls its Windows scheduled task and local listener. It has no
Hyper-V, SSH, VM, DNAT, `iptables`, interface, address, or route operations.

### DNAT watchdog

Affected DST versions already used a transactional watchdog lifecycle:

- remove old watchdog cron entries;
- stop the OpenRC service;
- terminate remaining old watchdog processes;
- install and verify one replacement;
- install one canonical cron entry.

The watchdog reconciles targeted `iptables` DNAT rules. It does not run
`ip addr`, rewrite `/etc/network/interfaces`, alter routes, manage IPv6, or
restart guest networking. Even duplicate instances could contend over DNAT
rules, but they could not erase interface addresses.

### Scheduled restarts

The July 31 scheduled restart encountered a missing Hyper-V-reported IPv4 before
it could broadcast or execute the restart. It was a downstream failure, not
evidence that the scheduled restart removed the address.

### Public IP Apply

DST's explicit **Settings > Public IP / DDNS > Apply** operation can modify
guest IPv4 addresses and rewrite `/etc/network/interfaces`. It requires a
confirmed user action and is not invoked by updates, startup, MobileBridge,
scheduled restarts, or the watchdog.

Determine whether Public IP Apply was used near each failure. If it was, inspect
that path separately. The supplied DST log does not establish that it ran.

## Critical distinction to prove

At the next failure, determine which condition exists:

1. Linux still has valid addresses, but Hyper-V stopped reporting them.
2. Linux interfaces remain up, but addresses/routes were removed.
3. The Linux virtual NIC went down, detached, or reset.
4. Guest networking or Hyper-V integration services failed.
5. The host vSwitch, physical NIC, VLAN, bridge, or driver failed.
6. A user-triggered configuration action changed guest networking.

## Capture from Windows host

Run PowerShell as Administrator. Replace `<VM_NAME>` with the exact VM name.
Save all output with timestamps.

```powershell
$VmName = '<VM_NAME>'
Get-Date -Format o
Get-VM -Name $VmName |
  Format-List Name, State, Status, Uptime, Generation, Version
Get-VMNetworkAdapter -VMName $VmName |
  Format-List Name, SwitchName, Status, MacAddress, IPAddresses,
    Connected, DeviceNaming, IsManagementOs
Get-VMIntegrationService -VMName $VmName |
  Format-Table Name, Enabled, PrimaryStatusDescription,
    SecondaryStatusDescription -AutoSize
Get-VMSwitch |
  Format-Table Name, SwitchType, NetAdapterInterfaceDescription -AutoSize
Get-NetAdapter |
  Format-Table Name, InterfaceDescription, Status, LinkSpeed, MacAddress -AutoSize
Get-NetIPAddress |
  Sort-Object InterfaceAlias, AddressFamily |
  Format-Table InterfaceAlias, AddressFamily, IPAddress, PrefixLength,
    AddressState -AutoSize
Get-NetRoute |
  Sort-Object InterfaceAlias, AddressFamily, DestinationPrefix |
  Format-Table InterfaceAlias, AddressFamily, DestinationPrefix,
    NextHop, RouteMetric -AutoSize
```

Discover available Hyper-V event logs, then export relevant events covering at
least two hours before the failure:

```powershell
Get-WinEvent -ListLog '*Hyper-V*' |
  Select-Object LogName, RecordCount, IsEnabled
```

Pay particular attention to VMMS, Worker, Network, VMSwitch, and integration
service warnings or errors. Do not clear any event logs.

## Capture from VM console

Use the Hyper-V console rather than SSH because SSH depends on working IP
connectivity. Run these commands while the fault is active:

```sh
date -Iseconds
uname -a
ip -br link
ip -4 addr show
ip -6 addr show
ip -4 route show table all
ip -6 route show table all
ip -s link
cat /etc/network/interfaces
rc-status
rc-service networking status
lsmod | grep -E '(^|_)(hv|hyperv)|hv_netvsc'
dmesg | grep -iE 'hyper-v|hv_netvsc|netvsc|eth|link|network|address|route' | tail -n 300
```

If present, collect these logs without modifying them:

```sh
tail -n 500 /var/log/messages
logread | tail -n 500
```

Record:

- whether the virtual NIC exists;
- its interface name and MAC address;
- whether it is `UP` and has carrier;
- all configured IPv4 and IPv6 addresses;
- default routes;
- networking service state;
- Hyper-V `hv_netvsc` or link-reset errors.

## Capture DNAT watchdog state

These checks determine whether the watchdog is healthy; they do not assume it
caused address loss.

```sh
rc-service dune-dnat-watch status
pgrep -af dune-dnat-watch
crontab -l
iptables-save
tail -n 500 /var/log/dune-dnat-watch.log
```

If filenames or service names differ, locate them read-only before proceeding:

```sh
find /etc/init.d /usr/local/bin /var/log -maxdepth 2 \
  -iname '*dune*watch*' -o -iname '*dnat*'
```

## Timeline correlation

Build one table containing:

- exact DST update/install start and completion;
- DST process starts and stops;
- VM starts, stops, and reboots;
- MobileBridge auto-heal events;
- watchdog install/restart events;
- scheduled restart attempts and outcomes;
- Public IP Apply actions;
- first known-good and first known-bad network observations;
- Windows Hyper-V/network event-log warnings;
- guest kernel, link, networking-service, and integration-service events.

Do not treat "failure noticed" as "failure began." Bound the onset between the
last confirmed healthy observation and first confirmed unhealthy observation.

## Analysis requirements for Codex

Produce:

1. An evidence table separating observed facts from user inference.
2. A timestamped failure timeline.
3. A determination of whether addresses were absent inside Linux or merely not
   reported by Hyper-V.
4. Ranked root-cause hypotheses with supporting and contradicting evidence.
5. An explicit assessment of DST update, MobileBridge, scheduled restart, DNAT
   watchdog, Public IP Apply, Hyper-V integration, guest networking, vSwitch,
   and host NIC/driver involvement.
6. The smallest next diagnostic test capable of distinguishing the top
   hypotheses.
7. Any proposed remediation separately from diagnosis, with no changes executed
   without explicit approval.

Avoid claiming causation from update proximity alone. A hypothesis must identify
a concrete mechanism capable of producing the observed guest or Hyper-V state.
