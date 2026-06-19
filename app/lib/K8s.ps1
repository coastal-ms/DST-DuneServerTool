# K8s.ps1
# Wrappers for kubectl operations against the in-VM K8s cluster, used by the
# Multi-Sietch (Experimental) page. Patch payloads cribbed from the MIT
# dune-awakening-server-manager reference (server.js lines 1514-1659) and
# translated to PowerShell + SSH.

function Get-V6Battlegroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)

    # Single round-trip: find namespace + name + dump the CRD JSON.
    $cmd = @'
NS=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.namespace' 2>/dev/null | head -1 | tr -d ' ')
NAME=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 | tr -d ' ')
if [ -z "$NS" ] || [ -z "$NAME" ]; then echo "__NOBG__"; exit 0; fi
echo "===BG_META==="
echo "$NS"
echo "$NAME"
echo "===BG_JSON==="
sudo kubectl get battlegroup -n "$NS" "$NAME" -o json 2>/dev/null
'@
    $raw = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 30
    $text = ($raw -join "`n")
    if ($text -match '__NOBG__') { throw "No battlegroup CRD found on the VM." }
    $parts = $text -split '===BG_JSON==='
    if ($parts.Count -lt 2) { throw "Unexpected kubectl response." }
    $metaLines = ($parts[0] -split "`n") | Where-Object { $_ -and ($_ -notmatch '===BG_META===') }
    $ns   = $metaLines[0].Trim()
    $name = $metaLines[1].Trim()
    $json = $parts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($json)) { throw "Empty battlegroup JSON." }
    $bg = $json | ConvertFrom-Json -ErrorAction Stop
    return @{ Ns = $ns; Name = $name; Bg = $bg }
}

function Get-V6SietchList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)

    $info = Get-V6Battlegroup -Ip $Ip
    $bg   = $info.Bg
    $sets = $bg.spec.serverGroup.template.spec.sets
    $worldPartitions = $bg.spec.database.template.spec.deployment.spec.worldPartitions

    $list = @()
    $idx = 0
    foreach ($s in $sets) {
        $isSurvival = ($s.map -eq 'Survival_1')
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($isSurvival -and -not $isDedicated) {
            $mem = '?'
            if ($s.PSObject.Properties['resources'] -and $s.resources.PSObject.Properties['limits']) {
                $mem = $s.resources.limits.memory
            }
            $list += @{
                SetIndex    = $idx
                Map         = $s.map
                Partitions  = @($s.partitions)
                Replicas    = $s.replicas
                Memory      = $mem
            }
        }
        $idx++
    }

    $maxPartitionId = 0
    foreach ($wp in $worldPartitions) {
        foreach ($p in $wp.partitions) {
            if ($p.id -gt $maxPartitionId) { $maxPartitionId = [int]$p.id }
        }
    }

    return @{
        Ns                = $info.Ns
        Name              = $info.Name
        Sietches          = $list
        SietchCount       = $list.Count
        MaxPartitionId    = $maxPartitionId
        TotalSets         = $sets.Count
        WorldPartitions   = $worldPartitions.Count
    }
}

function Add-V6Sietch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)

    $info = Get-V6Battlegroup -Ip $Ip
    $bg   = $info.Bg
    $sets = $bg.spec.serverGroup.template.spec.sets
    $worldPartitions = $bg.spec.database.template.spec.deployment.spec.worldPartitions

    # Clone first non-dedicated Survival_1 set as the template
    $template = $null
    foreach ($s in $sets) {
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($s.map -eq 'Survival_1' -and -not $isDedicated) {
            $template = ($s | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json)
            break
        }
    }
    if (-not $template) { throw "No Survival_1 set found to clone." }

    $maxPartitionId = 0
    foreach ($wp in $worldPartitions) {
        foreach ($p in $wp.partitions) { if ($p.id -gt $maxPartitionId) { $maxPartitionId = [int]$p.id } }
    }
    $newPartitionId = $maxPartitionId + 1
    $template.partitions = @($newPartitionId)

    $grid = @()
    if ($bg.metadata.annotations -and $bg.metadata.annotations.PSObject.Properties['grid']) {
        $grid = ($bg.metadata.annotations.grid -split ',') | Where-Object { $_ }
    }
    $newGrid = @($grid) + '1x1'

    $patches = @(
        @{ op='add';     path='/spec/serverGroup/template/spec/sets/-'; value = $template }
        @{ op='add';     path='/spec/database/template/spec/deployment/spec/worldPartitions/-'; value = @{
                map='Survival_1'
                partitions = @(@{ dimension=0; disable=$false; id=$newPartitionId; maxX=1; maxY=1; minX=0; minY=0 })
            } }
        @{ op='replace'; path='/metadata/annotations/grid'; value = ($newGrid -join ',') }
    )

    $patchJson = $patches | ConvertTo-Json -Depth 30 -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($info.Name) -n $($info.Ns) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 60
    return @{
        Success      = $true
        PartitionId  = $newPartitionId
        SietchNumber = ($info.Bg.spec.serverGroup.template.spec.sets.Count) + 1
        Raw          = (($out -join "`n")).Trim()
    }
}

function Remove-V6Sietch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)

    $info = Get-V6Battlegroup -Ip $Ip
    $bg   = $info.Bg
    $sets = $bg.spec.serverGroup.template.spec.sets
    $worldPartitions = $bg.spec.database.template.spec.deployment.spec.worldPartitions

    $survival = @()
    $i = 0
    foreach ($s in $sets) {
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($s.map -eq 'Survival_1' -and -not $isDedicated) {
            $survival += @{ Idx = $i; Partitions = @($s.partitions) }
        }
        $i++
    }
    if ($survival.Count -le 1) { throw "Cannot remove the last sietch." }

    $last = $survival[-1]
    $lastPartitionId = [int]$last.Partitions[0]

    $wpIdx = -1
    for ($k = 0; $k -lt $worldPartitions.Count; $k++) {
        $wp = $worldPartitions[$k]
        if ($wp.map -ne 'Survival_1') { continue }
        foreach ($p in $wp.partitions) {
            if ([int]$p.id -eq $lastPartitionId) { $wpIdx = $k; break }
        }
        if ($wpIdx -ge 0) { break }
    }

    $grid = @()
    if ($bg.metadata.annotations -and $bg.metadata.annotations.PSObject.Properties['grid']) {
        $grid = ($bg.metadata.annotations.grid -split ',') | Where-Object { $_ }
    }

    $patches = @()
    $patches += @{ op='remove'; path="/spec/serverGroup/template/spec/sets/$($last.Idx)" }
    if ($wpIdx -ge 0) {
        $patches += @{ op='remove'; path="/spec/database/template/spec/deployment/spec/worldPartitions/$wpIdx" }
    }
    if ($grid.Count -gt 1) {
        $newGrid = $grid[0..($grid.Count - 2)]
        $patches += @{ op='replace'; path='/metadata/annotations/grid'; value = ($newGrid -join ',') }
    }

    # Remove higher indices first to avoid renumbering
    $patches = $patches | Sort-Object { $_.path } -Descending

    $patchJson = $patches | ConvertTo-Json -Depth 30 -Compress
    # ConvertTo-Json on a single object emits an object not array - wrap if needed
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($info.Name) -n $($info.Ns) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 60
    return @{
        Success            = $true
        RemovedPartition   = $lastPartitionId
        RemainingSietches  = $survival.Count - 1
        Raw                = (($out -join "`n")).Trim()
    }
}

function Set-V6BattlegroupTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Title
    )

    # The player-facing server name shown in the in-game server browser and on
    # status pages (e.g. dunestatus) is the battlegroup CRD's spec.title. It is
    # owned by the user-side kubectl manager (NOT the operator), so a direct
    # JSON-patch sticks and is not reverted on reconcile. The title is injected
    # into pod env (BATTLEGROUP_TITLE / gateway_display_name) and several
    # configmaps, so the operator must recreate the pods to apply it: renaming
    # therefore RESTARTS the battlegroup (players disconnect briefly). Identity,
    # PVC and world data key off the immutable metadata.name, never the title,
    # so a rename never risks data loss.
    $clean = ([string]$Title -replace '[\x00-\x1F\x7F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { throw "Server name cannot be empty." }
    if ($clean.Length -gt 64) { throw "Server name must be 64 characters or fewer." }

    $info = Get-V6Battlegroup -Ip $Ip
    $old  = ''
    if ($info.Bg.PSObject.Properties['spec'] -and $info.Bg.spec.PSObject.Properties['title']) {
        $old = "$($info.Bg.spec.title)"
    }

    # 'add' replaces the value when the member already exists (RFC 6902) and
    # also covers the unlikely case where title is absent. The whole patch is
    # base64-encoded and decoded on the remote, so the title value never touches
    # the shell command line - no injection risk regardless of its characters.
    $patches = @( @{ op = 'add'; path = '/spec/title'; value = $clean } )
    $patchJson = $patches | ConvertTo-Json -Depth 10 -Compress
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($info.Name) -n $($info.Ns) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 60
    $raw = (($out -join "`n")).Trim()
    $ok  = ($raw -match 'patched' -or $raw -match 'no change')
    return @{
        Success  = [bool]$ok
        OldTitle = $old
        NewTitle = $clean
        Raw      = $raw
    }
}
