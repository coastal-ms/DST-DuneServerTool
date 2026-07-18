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

    # A sietch is a PARTITION on the (single) non-dedicated Survival_1 set, NOT a
    # separate set. Funcom's CRD enforces a unique `map` across server sets, so
    # multiple Hagga shards live as multiple partition ids on the one Survival_1
    # set (replicas == partition count). Enumerate one entry per partition.
    $list = @()
    $idx = 0
    $sietchNum = 0
    foreach ($s in $sets) {
        $isSurvival = ($s.map -eq 'Survival_1')
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($isSurvival -and -not $isDedicated) {
            $mem = '?'
            if ($s.PSObject.Properties['resources'] -and $s.resources.PSObject.Properties['limits']) {
                $mem = $s.resources.limits.memory
            }
            foreach ($pid in @($s.partitions)) {
                $sietchNum++
                $list += @{
                    SetIndex     = $idx
                    SietchNumber = $sietchNum
                    Map          = $s.map
                    PartitionId  = [int]$pid
                    Partitions   = @([int]$pid)
                    Replicas     = $s.replicas
                    Memory       = $mem
                }
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

# Apply a JSON-patch to the battlegroup CR over SSH and REPORT whether it
# actually applied. The old sietch add/remove returned Success=$true regardless
# of the kubectl result, so a rejected patch (e.g. Funcom's newer CRD refusing a
# duplicate map across sets) looked like a success while nothing changed. This
# captures the remote exit code so callers surface the real error.
function _Invoke-V6BgJsonPatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)]$Info, [Parameter(Mandatory)][array]$Patches)

    $patchJson = $Patches | ConvertTo-Json -Depth 30 -Compress
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($Info.Name) -n $($Info.Ns) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1; echo __DST_RC=`$?"
    $out  = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 60
    $text = (($out -join "`n")).Trim()
    $rc   = $null
    if ($text -match '__DST_RC=(\d+)') { $rc = [int]$Matches[1] }
    $clean = ($text -replace '__DST_RC=\d+\s*$', '').Trim()
    # Definitive signal is the remote exit code; fall back to text if unparsed.
    $ok = if ($null -ne $rc) { $rc -eq 0 } else { $clean -match '(?im)\bpatched\b' -and $clean -notmatch '(?im)\b(error|invalid|Duplicate value)\b' }
    return @{ Success = [bool]$ok; Error = (if ($ok) { $null } else { $clean }); Raw = $clean; Rc = $rc }
}

# Add a sietch = add ONE more Survival_1 partition to the EXISTING non-dedicated
# Survival_1 set (bump its replicas to match) plus the matching worldPartitions
# entry. The previous approach cloned the whole set as a SECOND Survival_1 set,
# which Funcom's CRD now rejects with "Map needs to be unique across server
# sets" (validated live). The new shard's pod is an ordinal on the same core set,
# so DST's partition self-heal already covers a stuck pod (core-map pass evicts a
# stuck pod without touching the pin). Takes effect after a battlegroup restart.
function Add-V6Sietch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)

    $info = Get-V6Battlegroup -Ip $Ip
    $bg   = $info.Bg
    $sets = $bg.spec.serverGroup.template.spec.sets
    $worldPartitions = $bg.spec.database.template.spec.deployment.spec.worldPartitions

    # Locate the (single) non-dedicated Survival_1 set + its worldPartitions entry.
    $setIdx = -1; $set = $null; $i = 0
    foreach ($s in $sets) {
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($s.map -eq 'Survival_1' -and -not $isDedicated) { $setIdx = $i; $set = $s; break }
        $i++
    }
    if ($setIdx -lt 0) { throw "No Survival_1 set found to add a sietch to." }

    $wpIdx = -1; $j = 0
    foreach ($wp in $worldPartitions) {
        if ($wp.map -eq 'Survival_1') { $wpIdx = $j; break }
        $j++
    }
    if ($wpIdx -lt 0) { throw "No Survival_1 worldPartitions entry found." }

    # New partition id must be globally unique across ALL worldPartitions.
    $maxPartitionId = 0
    foreach ($wp in $worldPartitions) {
        foreach ($p in $wp.partitions) { if ($p.id -gt $maxPartitionId) { $maxPartitionId = [int]$p.id } }
    }
    $newPartitionId = $maxPartitionId + 1
    $curParts    = @($set.partitions)
    $newReplicas = $curParts.Count + 1

    $patches = @()
    if ($set.PSObject.Properties['partitions'] -and $curParts.Count -gt 0) {
        $patches += @{ op='add'; path="/spec/serverGroup/template/spec/sets/$setIdx/partitions/-"; value = $newPartitionId }
    } else {
        $patches += @{ op='add'; path="/spec/serverGroup/template/spec/sets/$setIdx/partitions"; value = @($newPartitionId) }
    }
    if ($set.PSObject.Properties['replicas']) {
        $patches += @{ op='replace'; path="/spec/serverGroup/template/spec/sets/$setIdx/replicas"; value = $newReplicas }
    } else {
        $patches += @{ op='add';     path="/spec/serverGroup/template/spec/sets/$setIdx/replicas"; value = $newReplicas }
    }
    $patches += @{ op='add'; path="/spec/database/template/spec/deployment/spec/worldPartitions/$wpIdx/partitions/-"; value = @{
            dimension=0; disable=$false; id=$newPartitionId; maxX=1; maxY=1; minX=0; minY=0
        } }

    $res = _Invoke-V6BgJsonPatch -Ip $Ip -Info $info -Patches $patches
    if (-not $res.Success) {
        return @{ Success = $false; PartitionId = $newPartitionId; Error = $res.Error; Raw = $res.Raw }
    }
    return @{
        Success      = $true
        PartitionId  = $newPartitionId
        SietchNumber = $newReplicas
        Raw          = $res.Raw
    }
}

# Remove the LAST Survival_1 sietch = drop the highest partition id from the
# existing Survival_1 set (decrement replicas) plus its worldPartitions entry.
# Mirror of Add-V6Sietch; refuses to remove the final sietch.
function Remove-V6Sietch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)

    $info = Get-V6Battlegroup -Ip $Ip
    $bg   = $info.Bg
    $sets = $bg.spec.serverGroup.template.spec.sets
    $worldPartitions = $bg.spec.database.template.spec.deployment.spec.worldPartitions

    $setIdx = -1; $set = $null; $i = 0
    foreach ($s in $sets) {
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($s.map -eq 'Survival_1' -and -not $isDedicated) { $setIdx = $i; $set = $s; break }
        $i++
    }
    if ($setIdx -lt 0) { throw "No Survival_1 set found." }

    $curParts = @($set.partitions)
    if ($curParts.Count -le 1) { throw "Cannot remove the last sietch." }
    $lastPartIdx     = $curParts.Count - 1
    $lastPartitionId = [int]$curParts[$lastPartIdx]
    $newReplicas     = $curParts.Count - 1

    # Locate that partition id within the Survival_1 worldPartitions entry.
    $wpIdx = -1; $partIdxInWp = -1; $j = 0
    foreach ($wp in $worldPartitions) {
        if ($wp.map -eq 'Survival_1') {
            $k = 0
            foreach ($p in $wp.partitions) {
                if ([int]$p.id -eq $lastPartitionId) { $wpIdx = $j; $partIdxInWp = $k; break }
                $k++
            }
        }
        if ($wpIdx -ge 0) { break }
        $j++
    }

    $patches = @()
    $patches += @{ op='remove'; path="/spec/serverGroup/template/spec/sets/$setIdx/partitions/$lastPartIdx" }
    if ($set.PSObject.Properties['replicas']) {
        $patches += @{ op='replace'; path="/spec/serverGroup/template/spec/sets/$setIdx/replicas"; value = $newReplicas }
    }
    if ($wpIdx -ge 0 -and $partIdxInWp -ge 0) {
        $patches += @{ op='remove'; path="/spec/database/template/spec/deployment/spec/worldPartitions/$wpIdx/partitions/$partIdxInWp" }
    }

    $res = _Invoke-V6BgJsonPatch -Ip $Ip -Info $info -Patches $patches
    if (-not $res.Success) {
        return @{ Success = $false; RemovedPartition = $lastPartitionId; Error = $res.Error; Raw = $res.Raw }
    }
    return @{
        Success           = $true
        RemovedPartition  = $lastPartitionId
        RemainingSietches = $newReplicas
        Raw               = $res.Raw
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
