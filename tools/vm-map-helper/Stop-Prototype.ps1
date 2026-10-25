param(
    [Parameter(Mandatory)][string]$VmIp,
    [Parameter(Mandatory)][string]$SshKey,
    [string]$SshUser = 'dune'
)
$ErrorActionPreference = 'Stop'
if ($VmIp -notmatch '^[0-9a-fA-F:.]+$' -or $SshUser -notmatch '^[a-z_][a-z0-9_-]*$') {
    throw 'Invalid SSH target.'
}
& ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -i $SshKey "$SshUser@$VmIp" `
    'sudo k3s kubectl delete pod -n dst-map-prototype map-helper --ignore-not-found=true --wait=true'
if ($LASTEXITCODE -ne 0) { throw 'Prototype stop failed.' }
