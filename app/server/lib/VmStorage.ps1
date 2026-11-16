function Get-DuneVmStorageStatePath { Join-Path $env:LOCALAPPDATA 'DuneServer\storage-operation.json' }
function Save-DuneVmStorageState {
    param([hashtable]$State)
    $path=Get-DuneVmStorageStatePath;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';[IO.File]::WriteAllText($temp,($State|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,($path+'.previous'))}else{[IO.File]::Move($temp,$path)}
}
function Invoke-DuneVmStorageTool {
    param([string]$Ip,[ValidateSet('inspect','prepare','apply','status')][string]$Action,[string]$Revision,[string]$Operation,[string]$MetadataSha256)
    if($Revision -and $Revision -notmatch '^[a-f0-9]{64}$'){throw 'Invalid storage revision.'}
    if($Operation -and $Operation -notmatch '^[a-f0-9]{32}$'){throw 'Invalid storage operation.'}
    if($MetadataSha256 -and $MetadataSha256 -notmatch '^[a-f0-9]{64}$'){throw 'Invalid recovery checksum.'}
    $file=Join-Path $PSScriptRoot '../../tools/VmStorage/storage.py';$source=[IO.File]::ReadAllText($file)
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $cmd="base64 -d | sudo env PATH=/usr/sbin:/usr/bin:/sbin:/bin python3 - $Action"
    if($Action -eq 'inspect'){
        $probe=@'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
if ! command -v python3 >/dev/null 2>&1; then
  if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
    printf '%s\n' '{"ok":true,"data":{"supported":false,"canGrow":false,"toolsReady":false,"canInstallTools":true,"reason":"Install the guest storage tools, then inspect again."}}'
  else
    printf '%s\n' '{"ok":true,"data":{"supported":false,"canGrow":false,"toolsReady":false,"reason":"The guest requires Python 3 and storage tools before inspection."}}'
  fi
  exit 0
fi
'@
        $cmd=$probe+"`n"+$cmd
    }
    if($Revision){$cmd+=" --revision $Revision"};if($Operation){$cmd+=" --operation $Operation"};if($MetadataSha256){$cmd+=" --metadata-sha256 $MetadataSha256"}
    # Unlike the general backup-shell wrapper, this transport never retries an
    # uncertain operation. The guest journal is the recovery authority.
    $output=@(Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData $payload -TimeoutSec $(if($Action -eq 'apply'){300}else{45}))
    $line=@($output|Where-Object {$_ -match '^\{"ok":'}|Select-Object -Last 1)
    if($line.Count -ne 1){throw 'Storage helper did not return a confirmed result. Inspect status before retrying. The guest requires Python 3 and the listed storage tools.'}
    $reply=ConvertTo-DunePortalHashtable ($line[0]|ConvertFrom-Json)
    if(-not $reply.ok){throw [string]$reply.error};return $reply.data
}
function Install-DuneVmStorageTools {
    Invoke-WithDuneLock -Name 'vm-storage-expansion' -Script {
        $status=Get-DuneVmStorageStatus
        if($status.phase -in @('backup','preparing','expanding','partition','physical-volume','logical-volume','filesystem')){throw 'Wait for the current storage operation to finish.'}
        $ctx=Get-DuneBackupContext;if(-not $ctx.ok){throw $ctx.message}
        $existing=Invoke-DuneVmStorageTool -Ip $ctx.ip -Action inspect
        if($existing.toolsReady){return $existing}
        $cmd=@'
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ -f /etc/alpine-release ] && command -v apk >/dev/null
sudo env PATH="$PATH" apk add --no-cache python3 findmnt lsblk sfdisk e2fsprogs-extra lvm2 cloud-utils-growpart
for tool in python3 findmnt lsblk sfdisk dumpe2fs resize2fs lvm growpart; do command -v "$tool" >/dev/null; done
printf '\nDST_STORAGE_TOOLS_READY\n'
'@
        $reply=(Invoke-V6Ssh -Ip $ctx.ip -Cmd $cmd -TimeoutSec 300)-join "`n"
        if($reply -notmatch '(?m)^DST_STORAGE_TOOLS_READY\r?$'){throw 'Guest tools installation was not confirmed. Inspect again before retrying.'}
        return Invoke-DuneVmStorageTool -Ip $ctx.ip -Action inspect
    }
}
function Get-DuneVmStoragePlan {
    $ctx=Get-DuneBackupContext;if(-not $ctx.ok){throw $ctx.message}
    Invoke-DuneVmStorageTool -Ip $ctx.ip -Action inspect
}
function Get-DuneVmStorageStatus {
    $path=Get-DuneVmStorageStatePath
    if(-not (Test-Path -LiteralPath $path)){return @{phase='idle'}}
    $state=ConvertTo-DunePortalHashtable ([IO.File]::ReadAllText($path)|ConvertFrom-Json)
    if($state.phase -in @('completed','idle')){return $state}
    if($state.guestOperation){
        try {
            $ctx=Get-DuneBackupContext;if(-not $ctx.ok){throw $ctx.message}
            if($ctx.ip -cne $state.vmIp){throw 'Selected VM changed.'}
            $guest=Invoke-DuneVmStorageTool -Ip $ctx.ip -Action status
            if($guest.id -cne $state.guestOperation){throw 'Guest operation identity changed.'}
            if($state.phase -eq 'expanding' -or $guest.phase -in @('failed','completed')){$state.phase=$guest.phase;$state.message=$guest.message;$state.error=$guest.error;if($guest.after){$state.after=$guest.after}}
        }catch{$state.statusError=$_.Exception.Message}
    }
    if($state.phase -notin @('completed','failed')){
        $alive=$false;try{$process=Get-Process -Id ([int]$state.ownerPid) -ErrorAction Stop;$alive=$process.StartTime.ToUniversalTime().Ticks.ToString() -eq $state.ownerStarted}catch{}
        if(-not $alive){$state.phase='interrupted';$state.message='The local request ended before completion was confirmed. Recovery data is retained; inspect the current guest layout before continuing.'}
    }
    return $state
}
function Copy-DuneVmStorageRecoveryFile {
    param([string]$Ip,[string]$VmPath,[string]$LocalPath,[string]$Sha256)
    $copy=Copy-DuneVmFileToLocal -Ip $Ip -KeyPath (Get-V6SshKeyPath) -VmPath $VmPath -LocalPath $LocalPath -TimeoutSec 300
    if(-not $copy.ok){throw 'The recovery file could not be copied to this PC. No disk growth was started.'}
    if((Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Sha256){throw 'Recovery copy checksum mismatch. No disk growth was started.'}
}
function Expand-DuneVmStorage {
    param([string]$Revision)
    if($Revision -notmatch '^[a-f0-9]{64}$'){throw 'Inspect storage before expanding.'}
    return Invoke-WithDuneLock -Name 'vm-storage-expansion' -Script {
        $status=Get-DuneVmStorageStatus
        if($status.phase -in @('backup','preparing','expanding','partition','physical-volume','logical-volume','filesystem')){throw 'A storage expansion is already active. Check its progress.'}
        $ctx=Get-DuneBackupContext;if(-not $ctx.ok){throw $ctx.message}
        $plan=Invoke-DuneVmStorageTool -Ip $ctx.ip -Action inspect
        if(-not $plan.supported -or -not $plan.canGrow -or $plan.revision -cne $Revision){throw 'Storage changed or no supported expansion remains. Inspect it again.'}
        $id=[guid]::NewGuid().ToString('N');$directory=Join-Path $env:LOCALAPPDATA ('DuneServer\storage-recovery\'+$id);[void][IO.Directory]::CreateDirectory($directory)
        $owner=Get-Process -Id $PID
        $state=@{id=$id;phase='backup';message='Creating and verifying a fresh database backup.';startedAt=[datetime]::UtcNow.ToString('o');ownerPid=$PID;ownerStarted=$owner.StartTime.ToUniversalTime().Ticks.ToString();vmIp=$ctx.ip;recoveryDirectory=$directory}
        Save-DuneVmStorageState $state
        try {
            $bg=Get-V6Battlegroup -Ip $ctx.ip;$world=[string]$bg.Name
            $scriptText=New-DuneSafetyBackupScript -World $world -Stem ('dst-storage-'+$id) -ProofLabel 'DST_STORAGE_BACKUP' -DbPort (Get-V6DbPort)
            $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
            $output=(Invoke-V6Ssh -Ip $ctx.ip -Cmd 'base64 -d | bash 2>&1' -StdinData $payload -TimeoutSec 300)-join "`n"
            $match=[regex]::Match($output,'(?m)^DST_STORAGE_BACKUP=(/funcom/artifacts/database-dumps/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\.backup)\|([0-9]+)\r?$')
            if(-not $match.Success -or [long]$match.Groups[2].Value -le 1024){throw 'A fresh database backup could not be verified. No disk changes were started.'}
            $backupPath=$match.Groups[1].Value
            foreach($suffix in @('','.yaml')){
                $remote=$backupPath+$suffix;$hashLine=(Invoke-V6Ssh -Ip $ctx.ip -Cmd "sudo sha256sum -- '$remote'" -TimeoutSec 30)-join "`n"
                if($hashLine -notmatch '^([a-f0-9]{64})\s'){throw 'Recovery backup checksum could not be read.'};$hash=$Matches[1]
                Copy-DuneVmStorageRecoveryFile -Ip $ctx.ip -VmPath $remote -LocalPath (Join-Path $directory ('database.backup'+$suffix)) -Sha256 $hash
            }
            $state.phase='preparing';$state.message='Saving partition and LVM recovery metadata to the VM and this PC.';Save-DuneVmStorageState $state
            $prepared=Invoke-DuneVmStorageTool -Ip $ctx.ip -Action prepare -Revision $Revision
            if($prepared.id -notmatch '^[a-f0-9]{32}$' -or $prepared.metadataPath -cne ('/var/lib/dune-server/storage-expansion/'+$prepared.id+'/metadata.tar.gz') -or $prepared.metadataSha256 -notmatch '^[a-f0-9]{64}$'){throw 'Recovery metadata identity could not be verified.'}
            $state.guestOperation=$prepared.id;Save-DuneVmStorageState $state
            Copy-DuneVmStorageRecoveryFile -Ip $ctx.ip -VmPath $prepared.metadataPath -LocalPath (Join-Path $directory 'metadata.tar.gz') -Sha256 $prepared.metadataSha256
            $state.phase='expanding';$state.message='Expanding the qualified partition, LVM volume and ext4 filesystem.';Save-DuneVmStorageState $state
            $result=Invoke-DuneVmStorageTool -Ip $ctx.ip -Action apply -Operation $prepared.id -MetadataSha256 $prepared.metadataSha256
            if($result.phase -ne 'completed'){throw 'Expansion completion was not confirmed. Inspect the retained operation record.'}
            $state.phase='completed';$state.message=$result.message;$state.after=$result.after;Save-DuneVmStorageState $state;return $state
        }catch{$state.phase='failed';$state.error=$_.Exception.Message;$state.message='Expansion was not completed. Recovery data was retained; inspect storage before retrying.';Save-DuneVmStorageState $state;throw}
    }
}
