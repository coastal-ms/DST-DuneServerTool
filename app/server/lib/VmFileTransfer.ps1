# VmFileTransfer.ps1 — stream files between the DST VM and this PC over ssh.
#
# The DST VM (Alpine minimal) has no `scp` binary and no `sftp-server`
# subsystem installed. Since OpenSSH 9.0 the Windows `scp` client defaults to
# the SFTP protocol for the actual transfer, so every `scp dune@vm:...` call
# dies with `bash: line 1: /usr/lib/ssh/sftp-server: No such file or directory`
# followed by `scp: Connection closed` (rc=255). That broke the manual
# Database → Download button, the manual Upload button, and every tick of the
# v12.18.10 Local Backup Mirror. Adding scp `-O` (legacy SCP protocol) doesn't
# help either — the VM has no `scp` executable to receive the transfer.
#
# So DST no longer uses scp at all. This module wraps `ssh + sudo cat` for
# pulls and `ssh + sudo tee` for pushes, streaming raw bytes through the
# process's redirected stdio. That's the same ssh key + toolset every other
# VM interaction already uses (Invoke-DuneBackupShell, etc.), so there is no
# new VM-side requirement — if a user can reach their VM at all, transfers
# work.
#
# Callers:
#   * lib/BackupMirror.ps1  — Invoke-DuneBackupMirrorTick per-file pull
#   * routes/BackupTransfer.ps1 — Download + Upload

# Pull a file from the VM into a local path. Streams raw bytes over
# `ssh dune@vm sudo cat <path>` into a local FileStream so binary backups
# survive intact. Returns @{ ok; localPath?; error? }.
function Copy-DuneVmFileToLocal {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$VmPath,
        [Parameter(Mandatory)][string]$LocalPath,
        [int]$TimeoutSec = 300
    )
    # Refuse anything that isn't an absolute posix path so an accidental
    # $null / relative path can't turn into `sudo cat` of the ssh CWD.
    if ($VmPath -notmatch '^/') {
        return @{ ok = $false; error = "VM path must be absolute: $VmPath" }
    }

    $localDir = Split-Path -Parent $LocalPath
    if ($localDir -and -not (Test-Path -LiteralPath $localDir)) {
        try { New-Item -ItemType Directory -Path $localDir -Force -ErrorAction Stop | Out-Null }
        catch { return @{ ok = $false; error = "Cannot create local directory: $($_.Exception.Message)" } }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'ssh'
    # Single-quoted VmPath because it's already validated to start with '/'
    # and Alpine's find never emits characters that need escaping (posix
    # dump-dir paths only). Wrapping in single quotes stops the local
    # shell + remote shell from re-interpreting whitespace or globs.
    $psi.Arguments = "-o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -i `"$KeyPath`" `"dune@$Ip`" sudo cat '$VmPath'"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $fs = $null
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $errTask = $proc.StandardError.ReadToEndAsync()
        try {
            $fs = [System.IO.File]::Create($LocalPath)
        } catch {
            try { $proc.Kill() } catch {}
            return @{ ok = $false; error = "Cannot open local file for write: $($_.Exception.Message)" }
        }
        # CopyTo blocks until ssh closes stdout (EOF) or the process dies.
        $proc.StandardOutput.BaseStream.CopyTo($fs)
        $fs.Flush()
        $fs.Close()
        $fs = $null

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch {}
            return @{ ok = $false; error = "ssh cat timed out after ${TimeoutSec}s" }
        }
        [void]$proc.WaitForExit()
        # Bound the stderr drain: a grandchild holding the pipe open past exit
        # would otherwise make a bare .GetResult() block forever.
        $stderr = $null
        try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch {}
        if ($proc.ExitCode -ne 0) {
            # Clean up the partial file — a 0-byte or half-written backup
            # would poison the local mirror folder / the local target.
            try { Remove-Item -LiteralPath $LocalPath -Force -ErrorAction SilentlyContinue } catch {}
            $tail = if ($stderr) { ": $($stderr.Trim())" } else { '' }
            return @{ ok = $false; error = "ssh cat failed rc=$($proc.ExitCode)$tail" }
        }
    } finally {
        if ($fs) { try { $fs.Close() } catch {} }
        try { $proc.Dispose() } catch {}
    }

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        return @{ ok = $false; error = 'ssh cat reported success but local file not present.' }
    }
    return @{ ok = $true; localPath = $LocalPath }
}

# Push a local file to the VM. Streams raw bytes into `ssh dune@vm sudo tee
# <path> > /dev/null` so the remote file is written with root ownership +
# perms directly at $VmPath. Returns @{ ok; vmPath?; error? }.
function Copy-DuneLocalFileToVm {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$VmPath,
        [int]$TimeoutSec = 600
    )
    if ($VmPath -notmatch '^/') {
        return @{ ok = $false; error = "VM path must be absolute: $VmPath" }
    }
    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        return @{ ok = $false; error = "Local file not found: $LocalPath" }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'ssh'
    # `sudo tee` writes stdin to the target; `> /dev/null` suppresses tee's
    # stdout copy so the ssh stdout stays quiet. `sudo chmod 644` follows so
    # the file is world-readable (matches how `battlegroup backup` writes it).
    $psi.Arguments = "-o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -i `"$KeyPath`" `"dune@$Ip`" `"sudo tee '$VmPath' > /dev/null && sudo chmod 644 '$VmPath'`""
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $inFs = $null
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        try {
            $inFs = [System.IO.File]::OpenRead($LocalPath)
        } catch {
            try { $proc.Kill() } catch {}
            return @{ ok = $false; error = "Cannot open local file for read: $($_.Exception.Message)" }
        }
        # Pump the file into ssh stdin. Close stdin so `tee` sees EOF.
        $inFs.CopyTo($proc.StandardInput.BaseStream)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()
        $inFs.Close()
        $inFs = $null

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch {}
            return @{ ok = $false; error = "ssh tee timed out after ${TimeoutSec}s" }
        }
        [void]$proc.WaitForExit()
        # Drain stdout (redirected but otherwise unused here) + stderr with a
        # bounded grace so a grandchild holding either pipe can't hang us post-exit.
        try { [void]$outTask.Wait(5000) } catch {}
        $stderr = $null
        try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch {}
        if ($proc.ExitCode -ne 0) {
            $tail = if ($stderr) { ": $($stderr.Trim())" } else { '' }
            return @{ ok = $false; error = "ssh tee failed rc=$($proc.ExitCode)$tail" }
        }
    } finally {
        if ($inFs) { try { $inFs.Close() } catch {} }
        try { $proc.Dispose() } catch {}
    }
    return @{ ok = $true; vmPath = $VmPath }
}
