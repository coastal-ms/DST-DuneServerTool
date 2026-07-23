# HyperVLanCredential - persist the remote Hyper-V HOST admin credential used
# by "Hyper-V over LAN" mode in Windows Credential Manager, scoped to the
# signed-in Windows user running DST.
#
# Why this exists: the LAN routing toggle (VmHostMode='lan' + HyperVHostIp in
# Config.ps1) only ever supplied -ComputerName to Hyper-V cmdlets. Every
# ongoing call (VM status, start/stop, RAM readout) therefore ran under
# whatever Windows identity DST itself is running as, which almost never has
# rights on a SEPARATE Hyper-V host - especially in a workgroup, where the
# host's admin account is a completely different local account than DST's own
# PC account. That is the exact failure a field tester hit: Setup Wizard Step
# 2 could not query Hyper-V under DST's own identity, and only Step 3's
# one-off WinRM probe (which already took an explicit username/password)
# succeeded.
#
# Fix: collect the host admin credential explicitly, persist it here, and hand
# it back as -Credential on every remote Hyper-V call (Get-DuneHyperVSplat in
# HyperV.ps1). Local mode is completely unaffected.
#
# Storage model: ONE generic Windows Credential Manager entry per DST install
# (fixed TargetName below) represents "the current LAN host's credential".
# VmHostMode/HyperVHostIp are singular in Config.ps1 (DST manages one LAN host
# at a time), so a single credential slot matches that model. The credential's
# Comment field records which host IP it was saved for, so a credential left
# over from a since-changed HyperVHostIp is detected as stale (never silently
# reused against the wrong host) without being auto-deleted - changing the
# host IP never destroys a saved credential; only an explicit
# Remove-DuneHyperVLanCredential call does that.
#
# The password itself NEVER touches dune-server.config, API responses, logs,
# diagnostics, state files, or process command lines - only CredWrite/CredRead
# see the plaintext, and CredRead's result is only ever unwrapped into an
# in-memory PSCredential for immediate use by the calling Hyper-V cmdlet.

$script:DuneHyperVLanCredTarget  = 'DuneServerTool:HyperVLan'
$script:DuneHyperVLanCredType    = 1   # CRED_TYPE_GENERIC
$script:DuneHyperVLanCredPersist = 2   # CRED_PERSIST_LOCAL_MACHINE (survives reboots, this Windows user only)

# Idempotent native type registration for the Credential Manager APIs DST
# needs. Uses Add-Type -TypeDefinition (a full class body) rather than
# -MemberDefinition: a nested struct declared via -MemberDefinition compiles
# but Marshal]::PtrToStructure() then rejects it ("must be blittable or have
# layout information") on Windows PowerShell 5.1 - verified empirically. A
# full TypeDefinition does not have that problem.
function Register-DuneCredentialManagerType {
    if ('DuneCredMgr' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DuneCredMgr
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL userCredential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr cred);
}
'@
}

# Save (or replace) the LAN host credential. Returns @{ ok; error }.
function Save-DuneHyperVLanCredential {
    param(
        [Parameter(Mandatory)][string]$HostIp,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password
    )
    Register-DuneCredentialManagerType
    $blobPtr = [IntPtr]::Zero
    $bytes = $null
    try {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($Password)
        $blobPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $blobPtr, $bytes.Length)

        $cred = New-Object DuneCredMgr+CREDENTIAL
        $cred.Type               = $script:DuneHyperVLanCredType
        $cred.TargetName         = $script:DuneHyperVLanCredTarget
        $cred.Comment            = $HostIp.Trim()
        $cred.CredentialBlobSize = [uint32]$bytes.Length
        $cred.CredentialBlob     = $blobPtr
        $cred.Persist            = $script:DuneHyperVLanCredPersist
        $cred.UserName           = $User.Trim()

        $ok = [DuneCredMgr]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            return @{ ok = $false; error = "Could not save the Hyper-V host credential to Windows Credential Manager (Win32 error $code). Make sure Credential Manager is available for the signed-in Windows user running DST." }
        }
        return @{ ok = $true; error = $null }
    } catch {
        return @{ ok = $false; error = "Could not save the Hyper-V host credential: $($_.Exception.Message)" }
    } finally {
        # Zero the unmanaged copy before freeing it so the plaintext password
        # doesn't linger in process memory longer than necessary.
        if ($blobPtr -ne [IntPtr]::Zero) {
            try {
                if ($bytes) { for ($i = 0; $i -lt $bytes.Length; $i++) { [System.Runtime.InteropServices.Marshal]::WriteByte($blobPtr, $i, 0) } }
            } catch {}
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
        }
    }
}

# Read the saved credential back as a PSCredential, IF one exists AND it was
# saved for the given host IP. A credential saved for a different (older)
# host IP is treated as "no credential for this host" - not deleted, not
# reused against the wrong host. Returns:
#   @{ ok; exists; matchesHost; user; hostIp; credential; error }
# 'credential' is $null unless ok+exists+matchesHost are all true.
function Get-DuneHyperVLanCredential {
    param([Parameter(Mandatory)][string]$HostIp)
    Register-DuneCredentialManagerType
    $ptr = [IntPtr]::Zero
    try {
        $found = [DuneCredMgr]::CredRead($script:DuneHyperVLanCredTarget, $script:DuneHyperVLanCredType, 0, [ref]$ptr)
        if (-not $found) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($code -eq 1168) {
                # ERROR_NOT_FOUND - normal "nothing saved yet" case.
                return @{ ok = $true; exists = $false; matchesHost = $false; user = ''; hostIp = ''; credential = $null; error = $null }
            }
            return @{ ok = $false; exists = $false; matchesHost = $false; user = ''; hostIp = ''; credential = $null; error = "Could not read the saved Hyper-V host credential from Windows Credential Manager (Win32 error $code)." }
        }

        $native = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][DuneCredMgr+CREDENTIAL])
        $savedHost = [string]$native.Comment
        $user      = [string]$native.UserName
        $passBytes = $null
        if ($native.CredentialBlobSize -gt 0) {
            $passBytes = New-Object byte[] ($native.CredentialBlobSize)
            [System.Runtime.InteropServices.Marshal]::Copy($native.CredentialBlob, $passBytes, 0, $native.CredentialBlobSize)
        }
        $password = if ($passBytes) { [System.Text.Encoding]::Unicode.GetString($passBytes) } else { '' }

        $isMatch = ($savedHost.Trim().ToLowerInvariant() -eq $HostIp.Trim().ToLowerInvariant())
        if (-not $isMatch) {
            return @{ ok = $true; exists = $true; matchesHost = $false; user = $user; hostIp = $savedHost; credential = $null; error = $null }
        }

        $sec = ConvertTo-SecureString $password -AsPlainText -Force
        $psCred = [System.Management.Automation.PSCredential]::new($user, $sec)
        return @{ ok = $true; exists = $true; matchesHost = $true; user = $user; hostIp = $savedHost; credential = $psCred; error = $null }
    } catch {
        return @{ ok = $false; exists = $false; matchesHost = $false; user = ''; hostIp = ''; credential = $null; error = "Could not read the saved Hyper-V host credential: $($_.Exception.Message)" }
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [DuneCredMgr]::CredFree($ptr) }
    }
}

# Non-secret status for the UI (Settings card + wizard): does a credential
# exist, which user/host was it saved for, does it match the currently
# configured host. Never includes the password.
function Get-DuneHyperVLanCredentialInfo {
    param([string]$HostIp = '')
    if (-not $HostIp) { $HostIp = Get-DuneHyperVHostIp }
    $r = Get-DuneHyperVLanCredential -HostIp $HostIp
    return @{
        ok          = $r.ok
        exists      = [bool]$r.exists
        matchesHost = [bool]$r.matchesHost
        user        = $r.user
        savedHostIp = $r.hostIp
        error       = $r.error
    }
}

# Explicitly delete the saved credential (Settings/wizard "Remove credential"
# action). Never called implicitly just because LAN mode was turned off -
# turning LAN mode off only flips VmHostMode back to 'local' and leaves any
# saved credential in place for next time it's re-enabled.
function Remove-DuneHyperVLanCredential {
    Register-DuneCredentialManagerType
    try {
        $ok = [DuneCredMgr]::CredDelete($script:DuneHyperVLanCredTarget, $script:DuneHyperVLanCredType, 0)
        if (-not $ok) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($code -eq 1168) { return @{ ok = $true; error = $null } }   # already gone
            return @{ ok = $false; error = "Could not remove the saved Hyper-V host credential (Win32 error $code)." }
        }
        return @{ ok = $true; error = $null }
    } catch {
        return @{ ok = $false; error = "Could not remove the saved Hyper-V host credential: $($_.Exception.Message)" }
    }
}
