BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'PortalAuth.ps1'
    Import-DstLib 'VmStorage.ps1'
    function global:Invoke-WithDuneLock {param($Name,$Script) & $Script}
    function global:Get-DuneBackupContext {}
    function global:Get-V6Battlegroup {param($Ip)}
    function global:Get-V6DbPort {}
    function global:New-DuneSafetyBackupScript {param($World,$Stem,$ProofLabel,$DbPort)}
    function global:Invoke-V6Ssh {param($Ip,$Cmd,$StdinData,$TimeoutSec)}
    $script:previousLocalAppData=$env:LOCALAPPDATA
}
AfterAll {$env:LOCALAPPDATA=$script:previousLocalAppData}
Describe 'Guest storage backup and mutation boundaries' {
    BeforeEach {
        $env:LOCALAPPDATA=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:revision='a'*64;$script:operation='b'*32;$script:hash='c'*64;$script:events=[Collections.Generic.List[string]]::new()
        Mock Get-DuneBackupContext {@{ok=$true;ip='test'}}
        Mock Get-V6Battlegroup {@{Name='sh-test'}}
        Mock Get-V6DbPort {15432}
        Mock New-DuneSafetyBackupScript {'verified backup script'}
        Mock Get-DuneVmStorageStatus {@{phase='idle'}}
        Mock Invoke-V6Ssh {
            param($Cmd)
            if($Cmd -eq 'base64 -d | bash 2>&1'){$script:events.Add('backup');return 'DST_STORAGE_BACKUP=/funcom/artifacts/database-dumps/sh-test/dst-storage-test.backup|2048'}
            if($Cmd -like 'sudo sha256sum*'){return ($script:hash+'  file')}
            throw 'Unexpected transport'
        }
        Mock Copy-DuneVmStorageRecoveryFile {param($VmPath) $script:events.Add('copy:'+([IO.Path]::GetFileName($VmPath)))}
        Mock Invoke-DuneVmStorageTool {
            param($Action,$Operation,$MetadataSha256)
            $script:events.Add($Action)
            switch($Action){
                inspect {@{supported=$true;canGrow=$true;revision=$script:revision}}
                prepare {@{id=$script:operation;metadataPath=('/var/lib/dune-server/storage-expansion/'+$script:operation+'/metadata.tar.gz');metadataSha256=$script:hash}}
                apply {$Operation|Should -Be $script:operation;$MetadataSha256|Should -Be $script:hash;@{phase='completed';message='expanded';after=@{canGrow=$false}}}
            }
        }
    }
    It 'verifies database and metadata copies off the VM before applying exactly once' {
        (Expand-DuneVmStorage -Revision $script:revision).phase|Should -Be completed
        ($script:events -join ',')|Should -Be 'inspect,backup,copy:dst-storage-test.backup,copy:dst-storage-test.backup.yaml,prepare,copy:metadata.tar.gz,apply'
        Should -Invoke Invoke-DuneVmStorageTool -Times 1 -ParameterFilter {$Action -eq 'apply'}
    }
    It 'rejects changed previews before any backup or growth' {
        {Expand-DuneVmStorage -Revision ('d'*64)}|Should -Throw '*Inspect it again*'
        Should -Invoke Invoke-V6Ssh -Times 0
        Should -Invoke Invoke-DuneVmStorageTool -Times 0 -ParameterFilter {$Action -in @('prepare','apply')}
    }
    It 'blocks growth when a fresh database backup is not confirmed' {
        Mock Invoke-V6Ssh {'old backup only'}
        {Expand-DuneVmStorage -Revision $script:revision}|Should -Throw '*fresh database backup*'
        Should -Invoke Invoke-DuneVmStorageTool -Times 0 -ParameterFilter {$Action -in @('prepare','apply')}
        $state=Get-Content (Get-DuneVmStorageStatePath) -Raw|ConvertFrom-Json
        $state.phase|Should -Be failed
    }
    It 'blocks growth when the off-VM metadata copy fails' {
        Mock Copy-DuneVmStorageRecoveryFile {param($VmPath) if($VmPath -like '*metadata.tar.gz'){throw 'checksum mismatch'}}
        {Expand-DuneVmStorage -Revision $script:revision}|Should -Throw '*checksum mismatch*'
        Should -Invoke Invoke-DuneVmStorageTool -Times 0 -ParameterFilter {$Action -eq 'apply'}
    }
    It 'never retries an uncertain apply transport' {
        Mock Invoke-DuneVmStorageTool {throw 'SSH disconnected'} -ParameterFilter {$Action -eq 'apply'}
        {Expand-DuneVmStorage -Revision $script:revision}|Should -Throw '*SSH disconnected*'
        Should -Invoke Invoke-DuneVmStorageTool -Times 1 -ParameterFilter {$Action -eq 'apply'}
        $state=Get-Content (Get-DuneVmStorageStatePath) -Raw|ConvertFrom-Json
        $state.phase|Should -Be failed;$state.guestOperation|Should -Be $script:operation
    }
    It 'installs prerequisites only through the explicit action and never starts growth' {
        Mock Invoke-V6Ssh {'DST_STORAGE_TOOLS_READY'}
        Install-DuneVmStorageTools|Out-Null
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter {$Cmd -match 'apk add --no-cache python3 findmnt lsblk sfdisk e2fsprogs-extra lvm2 cloud-utils-growpart'}
        Should -Invoke Invoke-DuneVmStorageTool -Times 2 -ParameterFilter {$Action -eq 'inspect'}
        Should -Invoke Invoke-DuneVmStorageTool -Times 0 -ParameterFilter {$Action -in @('prepare','apply')}
    }

    It 'reports existing tools without reinstalling or attempting growth' {
        Mock Invoke-DuneVmStorageTool {@{supported=$true;toolsReady=$true;canGrow=$false}} -ParameterFilter {$Action -eq 'inspect'}
        (Install-DuneVmStorageTools).toolsReady|Should -BeTrue
        Should -Invoke Invoke-V6Ssh -Times 0
        Should -Invoke Invoke-DuneVmStorageTool -Times 0 -ParameterFilter {$Action -in @('prepare','apply')}
    }

}
