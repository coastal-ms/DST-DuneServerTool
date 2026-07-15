# install-dune-vm-lan.ps1 — non-interactive Hyper-V import for "Hyper-V over LAN".
#
# A DST-owned adaptation of Funcom's battlegroup-management\initial-setup.ps1,
# restricted to the Hyper-V portion and made fully non-interactive so it can run
# on a HEADLESS Hyper-V host via Invoke-Command (no Read-Host, no GUI). DST stages
# the VM image to the host, runs this there, and it returns the guest VM's IP.
# All SSH/battlegroup bootstrap is done afterwards FROM the DST PC (not here), so
# this script never needs ssh on the host.
#
# Differences from Funcom's script, by design:
#   - Every interactive prompt (drive, memory, switch, password) is a parameter.
#   - Requires an EXISTING external virtual switch (SwitchName). It never creates
#     one: New-VMSwitch on the host's NIC can blip host networking and drop the
#     WinRM session mid-install. The switch is a one-time host prerequisite.
#   - No SSH key / password / IP / bootstrap steps (DST does those over the LAN).
#
# Returns a single hashtable: @{ ok=[bool]; ip=[string]; state=[string];
# error=[string]; steps=@([string]) }. `steps` is a human-readable trace.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImageRoot,     # host-local dir holding 'Virtual Machines' + 'Virtual Hard Disks'
    [Parameter(Mandatory)][string]$DestDrive,      # e.g. 'D:' — where the VM is installed
    [Parameter(Mandatory)][long]$MemoryBytes,      # startup memory
    [Parameter(Mandatory)][string]$SwitchName,     # EXISTING external switch to attach
    [long]$VhdSizeBytes = 100GB,
    [switch]$ReplaceExisting                        # remove a pre-existing dune-awakening first
)

$ErrorActionPreference = 'Stop'
$steps = [System.Collections.Generic.List[string]]::new()
function Fail($msg) { return @{ ok=$false; ip=''; state='Failed'; error=$msg; steps=$steps.ToArray() } }

try {
    # --- Preconditions -----------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { return (Fail 'Hyper-V PowerShell module not available on the host.') }
    if ((Get-Service -Name vmms -ErrorAction SilentlyContinue).Status -ne 'Running') { return (Fail 'Hyper-V VM Management service (vmms) is not running on the host.') }

    $vmcx = Get-Item (Join-Path $ImageRoot 'Virtual Machines\*.vmcx') -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vmcx) { return (Fail "No .vmcx found under '$ImageRoot\Virtual Machines'. Image staging incomplete.") }
    $steps.Add("Found image: $($vmcx.Name)")

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        return (Fail "External switch '$SwitchName' not found on the host. Create it once (New-VMSwitch -Name '$SwitchName' -NetAdapterName <nic> -AllowManagementOS `$true) and retry.")
    }
    $steps.Add("Using existing switch: $SwitchName")

    $DestDrive = $DestDrive.TrimEnd('\')
    if ($DestDrive -notmatch '^[A-Za-z]:$') { return (Fail "DestDrive must look like 'D:'. Got '$DestDrive'.") }
    $dest = "$DestDrive\DuneAwakeningServer"

    # --- Existing VM handling ---------------------------------------------
    $existing = Get-VM -Name 'dune-awakening' -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not $ReplaceExisting) {
            return (Fail "A VM named 'dune-awakening' already exists on the host at $($existing.ConfigurationLocation). Re-run with Replace to remove it first.")
        }
        if ($existing.State -eq 'Running') {
            Stop-VM -Name 'dune-awakening' -TurnOff -Force -ErrorAction Stop
            $steps.Add('Stopped existing dune-awakening VM.')
        }
        Remove-VM -Name 'dune-awakening' -Force -ErrorAction Stop
        $steps.Add('Removed existing dune-awakening VM.')
        if (Test-Path $dest) {
            Get-ChildItem $dest -Recurse -Force | Sort-Object FullName -Descending | ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            $steps.Add('Cleared destination folder.')
        }
    }

    if (Test-Path $dest) {
        Get-ChildItem $dest -Recurse -Force | Sort-Object FullName -Descending | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
    }

    # --- Import ------------------------------------------------------------
    $steps.Add("Checking VM compatibility for import to $dest...")
    $compat = Compare-VM -Path $vmcx.FullName -Copy -VirtualMachinePath $dest -VhdDestinationPath "$dest\Virtual Hard Disks" -ErrorAction Stop
    if ($compat.Incompatibilities.Count -gt 0) {
        # Repoint the network adapter incompatibility is the common one; every
        # other incompatibility is fatal for an unattended run.
        $msgs = ($compat.Incompatibilities | ForEach-Object { $_.Message }) -join '; '
        # Try to auto-resolve adapter-connection incompatibilities by disconnecting;
        # we reconnect to the chosen switch right after import.
        $fatal = $compat.Incompatibilities | Where-Object { $_.MessageId -ne 33012 }  # 33012 = could not find switch
        if ($fatal) { return (Fail "VM is not compatible with this host: $msgs") }
        foreach ($inc in $compat.Incompatibilities) {
            if ($inc.MessageId -eq 33012) { $inc.Source | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue }
        }
        $steps.Add('Resolved network-adapter compatibility (will reconnect to chosen switch).')
    }
    Import-VM -CompatibilityReport $compat -ErrorAction Stop | Out-Null
    $steps.Add('Imported VM.')

    # --- Attach to existing switch ----------------------------------------
    Get-VMNetworkAdapter -VMName 'dune-awakening' | Connect-VMNetworkAdapter -SwitchName $SwitchName -ErrorAction Stop
    $steps.Add("Connected network adapter to '$SwitchName'.")

    # --- Disk + firmware + memory -----------------------------------------
    $vhdx = Get-Item "$dest\Virtual Hard Disks\*.vhdx" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vhdx) { Resize-VHD -Path $vhdx.FullName -SizeBytes $VhdSizeBytes -ErrorAction Stop; $steps.Add("Resized disk to $([math]::Round($VhdSizeBytes/1GB))GB.") }
    else { $steps.Add('WARNING: no .vhdx found to resize.') }

    $boot = Get-VMHardDiskDrive -VMName 'dune-awakening' | Select-Object -First 1
    if ($boot) { Set-VMFirmware -VMName 'dune-awakening' -FirstBootDevice $boot }

    Set-VMMemory -VMName 'dune-awakening' -StartupBytes $MemoryBytes
    $steps.Add("Set memory to $([math]::Round($MemoryBytes/1GB))GB.")

    # --- Start + wait for guest IP ----------------------------------------
    Start-VM -Name 'dune-awakening' -ErrorAction Stop
    $steps.Add('Started VM. Waiting for guest IP...')

    $ip = $null; $elapsed = 0
    while (-not $ip -and $elapsed -lt 180) {
        Start-Sleep -Seconds 3; $elapsed += 3
        $ip = (Get-VMNetworkAdapter -VMName 'dune-awakening').IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    }
    if (-not $ip) { return (Fail 'VM imported and started, but it did not acquire an IPv4 address within 180s. Check the external switch reaches your LAN DHCP.') }
    $steps.Add("VM acquired IP: $ip")

    return @{ ok=$true; ip="$ip"; state='Running'; error=''; steps=$steps.ToArray() }
}
catch {
    return (Fail $_.Exception.Message)
}
