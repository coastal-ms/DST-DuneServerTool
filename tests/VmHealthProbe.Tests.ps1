# Tests the probe v2 additions in app/server/lib/VmMemoryPressure.ps1.
#
# The governing rule for these tests, and for the code: DST reports what it
# reads and does not pass judgement on a configuration. Only three signatures
# are treated as faults, and each is a STATE the system itself reports as
# broken rather than a threshold generalised from a couple of support cases:
#
#   * an unfinished DatabaseOperation WHILE the battlegroup says DATABASE is
#     not Ready
#   * Kubernetes' own DiskPressure node condition
#   * a public IP configured, game pods running, and zero game UDP rules
#
# Everything else the probe reads - disk usage, retained build images, per-map
# memory limits - is information with no verdict attached. The most important
# test in this file is the first one: a healthy server must produce NOTHING.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'VmMemoryPressure.ps1'
}

Describe 'VM facts and faults (probe v2)' -Tag 'Pure' {

    BeforeAll {
        # The confirmed 2026-07-26 outage: a Pending DatabaseOperation with the
        # battlegroup on DATABASE=Operation, 94.2% of RAM free, operators at
        # 215+ restarts, and no game UDP rules (battlegroup down).
        $script:outageFixture = @'
probe=dune-mem-pressure/2
mem_total_k=49392000
mem_avail_k=46500000
swap_total_k=31457280
swap_free_k=31457280
op=battlegroup-operator-controller-manager-a~P:Running~PR:~R:215 0 ~E:255  ~X:Unknown  ~W:
db=sh-abc-def-db-dbdepl-sts-0~P:Running~PR:~R:0 0 ~E:  ~X:  ~W:
node_cond=MemoryPressure=False
node_cond=DiskPressure=False
node_cond=Ready=True
disk_root_size_k=103275396
disk_root_used_k=51681792
disk_root_avail_k=51593604
disk_root_use_pct=52
bg_name=sh-abc
bg_database_phase=Operation
dbop=sh-abc-import-20260725-162348~PH:Pending~CT:2026-07-25T16:23:48Z
dbop_total=211
dbop_open=1
maplim=Survival_1~LIM:12Gi
maplim=Overmap~LIM:1Gi
game_pods_running=0
dnat_udp_rules=0
dnat_udp_ports=
probe_done=1
'@

        # A REAL healthy server, read live on 2026-07-26. Note what is in here:
        # Hagga and Deep Desert deliberately raised to 16Gi (ABOVE the 2026-05
        # reference), several small story/DLC maps BELOW it because Funcom
        # lowered them since, swap off, four retained builds, and no
        # experimental-swap values anywhere. An earlier "below default" rule
        # flagged five maps on this exact server.
        $script:healthyLiveFixture = @'
probe=dune-mem-pressure/2
mem_total_k=49392000
mem_avail_k=46500000
swap_total_k=0
swap_free_k=0
op=battlegroup-operator-controller-manager-a~P:Running~PR:~R:215 0 ~E:255  ~X:Unknown  ~W:
op=database-operator-controller-manager-b~P:Running~PR:~R:222 0 ~E:255  ~X:Unknown  ~W:
db=sh-abc-def-db-dbdepl-sts-0~P:Running~PR:~R:0 0 ~E:  ~X:  ~W:
node_cond=MemoryPressure=False
node_cond=DiskPressure=False
node_cond=Ready=True
disk_root_size_k=103275396
disk_root_used_k=51681792
disk_root_avail_k=51593604
disk_root_use_pct=52
bg_name=sh-abc
bg_database_phase=Ready
dbop_total=211
dbop_open=0
maplim=Survival_1~LIM:16Gi
maplim=DeepDesert_1~LIM:16Gi
maplim=Overmap~LIM:3Gi
maplim=Story_ProcesVerbal~LIM:2Gi
maplim=DLC_Story_LostHarvest_EcolabA~LIM:3Gi
maplim=DLC_Story_LostHarvest_EcolabB~LIM:2Gi
maplim=DLC_Story_LostHarvest_ForgottenLab~LIM:2Gi
maplim=Story_ArtOfKanly~LIM:2Gi
img=registry/seabass-server~TAG:2025705~SIZE:4.46GB
img=registry/seabass-server~TAG:2036754~SIZE:4.46GB
img=registry/seabass-server~TAG:2048594~SIZE:4.46GB
img=registry/seabass-server~TAG:2051294~SIZE:4.46GB
game_pods_running=6
dnat_udp_rules=34
dnat_udp_ports=7777 7778
probe_done=1
'@
    }

    # ---- the one that matters most ----------------------------------------
    It 'says NOTHING about a real healthy server' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $healthyLiveFixture -PublicIpConfigured $true
        @($r.faults).Count   | Should -Be 0
        $r.pressure          | Should -BeFalse
        @($r.warnings).Count | Should -Be 0
    }

    It 'still reads the healthy server facts so the operator can see them' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $healthyLiveFixture -PublicIpConfigured $true
        $r.disk.usePct                | Should -Be 52
        $r.images.buildCount          | Should -Be 4
        @($r.mapLimits.entries).Count | Should -Be 8
        $r.dnat.udpRules              | Should -Be 34
        ($r.mapLimits.entries | Where-Object { $_.map -eq 'Survival_1' }).reference | Should -Be '12Gi'
    }

    # ---- the three fault signatures ---------------------------------------
    It 'reports a database operation only when the battlegroup also says DATABASE is not Ready' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $outageFixture
        $f = @($r.faults | Where-Object { $_.id -eq 'db-operation-stuck' })
        $f.Count     | Should -Be 1
        $f[0].detail | Should -Match 'sh-abc-import-20260725-162348'
    }

    It 'stays silent on an unfinished operation while DATABASE is Ready' {
        # An operation legitimately in flight is not a fault.
        $inFlight = @'
bg_database_phase=Ready
dbop=sh-abc-import-20260726-120000~PH:Running~CT:2026-07-26T12:00:00Z
dbop_total=212
dbop_open=1
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $inFlight
        @($r.faults).Count      | Should -Be 0
        @($r.dbOps.stuck).Count | Should -Be 1   # still reported as a fact
    }

    It 'separates Failed history from active database operations' {
        $mixed = @'
bg_database_phase=Ready
dbop=sh-abc-dump-old~PH:Failed~CT:2026-07-01T12:00:00Z
dbop=sh-abc-import-now~PH:Running~CT:2026-07-28T12:00:00Z
dbop_total=62
dbop_open=2
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $mixed
        $r.dbOps.failedCount | Should -Be 1
        $r.dbOps.activeCount | Should -Be 1
        $r.dbOps.failed[0].name | Should -Be 'sh-abc-dump-old'
        $r.dbOps.active[0].name | Should -Be 'sh-abc-import-now'
    }

    It 'reports DiskPressure from the node condition, not from a percentage' {
        $pressured = @'
disk_root_use_pct=96
node_cond=DiskPressure=True
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $pressured
        @($r.faults | Where-Object { $_.id -eq 'disk-pressure' }).Count | Should -Be 1
    }

    Describe 'Remove-DuneFailedDatabaseOperations' {
        BeforeAll {
            function global:Invoke-DuneBackupShell {
                param($Ip, $Script, $TimeoutSec)
                throw 'Test must mock Invoke-DuneBackupShell.'
            }
        }

        BeforeEach {
            Mock _Get-DuneVmProbeIp { '192.0.2.10' }
        }

        It 'uses an exact Failed phase guard and reports removed records' {
            Mock Invoke-DuneBackupShell {
                param($Ip, $Script, $TimeoutSec)
                $Script | Should -Match '\[ "\$phase" = "Failed" \]'
                $Script | Should -Match '\[ "\$current" = "Failed" \]'
                $Script | Should -Not -Match 'phase.*-ne.*Succeeded'
                return @{ rc=0; out="__DST_REMOVED:sh-abc-dump-old`n" }
            }

            $result = Remove-DuneFailedDatabaseOperations

            $result.ok | Should -BeTrue
            $result.removedCount | Should -Be 1
            $result.removedNames | Should -Contain 'sh-abc-dump-old'
            Assert-MockCalled Invoke-DuneBackupShell -Times 1 -Exactly
        }

        It 'returns a no-op when no Failed records exist' {
            Mock Invoke-DuneBackupShell { return @{ rc=0; out='' } }

            $result = Remove-DuneFailedDatabaseOperations

            $result.ok | Should -BeTrue
            $result.removedCount | Should -Be 0
            $result.message | Should -Be 'No failed database operation records were found.'
        }
    }

    It 'says nothing about a filling disk while Kubernetes is happy' {
        # 86% used is DST's business to display, not to warn about.
        $filling = @'
disk_root_size_k=103275396
disk_root_used_k=88000000
disk_root_avail_k=15000000
disk_root_use_pct=86
node_cond=DiskPressure=False
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $filling
        @($r.faults).Count | Should -Be 0
        $r.disk.usePct     | Should -Be 86
    }

    It 'reports a missing UDP bridge only with a public IP AND game pods running' {
        $running = @'
game_pods_running=6
dnat_udp_rules=0
dnat_udp_ports=
probe_done=1
'@
        $withPublic = ConvertFrom-DuneMemPressureProbe -Raw $running -PublicIpConfigured $true
        $withPublic.dnat.missing | Should -BeTrue
        @($withPublic.faults | Where-Object { $_.id -eq 'udp-bridge-missing' }).Count | Should -Be 1

        # LAN-only server: no public IP, so no rules is simply correct.
        $lanOnly = ConvertFrom-DuneMemPressureProbe -Raw $running -PublicIpConfigured $false
        @($lanOnly.faults).Count | Should -Be 0

        # Battlegroup stopped: no bound listeners, so no rules is correct too.
        $stopped = ConvertFrom-DuneMemPressureProbe -Raw $outageFixture -PublicIpConfigured $true
        @($stopped.faults | Where-Object { $_.id -eq 'udp-bridge-missing' }).Count | Should -Be 0
    }

    It 'says nothing about the UDP bridge when iptables could not be run' {
        # /sbin is not on a non-interactive SSH PATH; the probe emits no rule
        # count at all rather than a misleading zero.
        $noIptables = @'
dnat_probe=unavailable
game_pods_running=5
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $noIptables -PublicIpConfigured $true
        $r.dnat.udpRules   | Should -BeNullOrEmpty
        $r.dnat.missing    | Should -BeFalse
        @($r.faults).Count | Should -Be 0
    }

    It 'never raises a fault from retained build images or per-map limits' {
        # Four retained builds on a 78%-full disk, and a map on an
        # experimental-swap value. Both are worth SEEING; neither is DST's
        # verdict to make.
        $bloated = @'
disk_root_use_pct=78
node_cond=DiskPressure=False
img=registry/seabass-server~TAG:2025705~SIZE:4.46GB
img=registry/seabass-server~TAG:2036754~SIZE:4.46GB
img=registry/seabass-server~TAG:2048594~SIZE:4.46GB
img=registry/seabass-server~TAG:2051294~SIZE:4.46GB
maplim=Overmap~LIM:200Mi
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $bloated
        $r.images.buildCount | Should -Be 4
        @($r.faults).Count   | Should -Be 0
    }

    It 'still parses a v1 probe (no v2 keys) without inventing anything' {
        $v1 = @'
probe=dune-mem-pressure/1
mem_total_k=24671232
mem_avail_k=12000000
swap_total_k=4194304
op=x-controller-manager-a~P:Running~PR:~R:0 0 ~E:  ~X:  ~W:
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v1 -PublicIpConfigured $true
        $r.ok              | Should -BeTrue
        @($r.faults).Count | Should -Be 0
        $r.disk.known      | Should -BeFalse
        $r.dnat.udpRules   | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DuneMemMiB' -Tag 'Pure' {
    It 'converts Kubernetes memory quantities' {
        ConvertTo-DuneMemMiB '12Gi'   | Should -Be 12288
        ConvertTo-DuneMemMiB '200Mi'  | Should -Be 200
        ConvertTo-DuneMemMiB '1024Ki' | Should -Be 1
    }
    It 'returns null for unparseable input' {
        ConvertTo-DuneMemMiB ''     | Should -BeNullOrEmpty
        ConvertTo-DuneMemMiB 'lots' | Should -BeNullOrEmpty
    }
}

Describe 'New-DuneMapLimitEntry' -Tag 'Pure' {
    It 'records the limit and the reference without judging either' {
        $e = New-DuneMapLimitEntry -Map 'Overmap' -Limit '1Gi'
        $e.limit     | Should -Be '1Gi'
        $e.reference | Should -Be '2Gi'
        # No verdict field exists to be wrong about.
        $e.ContainsKey('drifted') | Should -BeFalse
    }
    It 'records a limit raised above the reference just the same' {
        $e = New-DuneMapLimitEntry -Map 'Survival_1' -Limit '16Gi'
        $e.limit     | Should -Be '16Gi'
        $e.reference | Should -Be '12Gi'
    }
    It 'leaves the reference empty for maps not in the snapshot' {
        (New-DuneMapLimitEntry -Map 'Some_Future_Map' -Limit '1Gi').reference | Should -Be ''
    }
}

Describe 'Get-DuneFuncomImageCleanupPlan' -Tag 'Pure' {
    BeforeAll {
        function New-TestImage {
            param([char]$IdChar, [string[]]$Tags, [long]$Size = 1000, [bool]$Pinned = $false)
            return @{ id=('sha256:' + ([string]$IdChar * 64)); repoTags=$Tags; size=$Size; pinned=$Pinned }
        }

        function New-TestContainer {
            param([char]$IdChar, [string]$Tag, [string]$State = 'CONTAINER_EXITED')
            $id = 'sha256:' + ([string]$IdChar * 64)
            return @{ state=$State; image=@{ image=$id; userSpecifiedImage=$Tag }; imageRef=$id }
        }

        $script:funcom = 'registry.funcom.com/funcom/self-hosting'
    }

    It 'selects only older unreferenced images and preserves the previous build' {
        $images = @{ images=@(
            (New-TestImage 'a' @("$funcom/seabass-server:2030000-0-shipping") 3000)
            (New-TestImage 'b' @("$funcom/seabass-server:2040000-0-shipping") 4000)
            (New-TestImage 'c' @("$funcom/seabass-server:2050000-0-shipping") 5000)
            (New-TestImage 'd' @("$funcom/seabass-server-db-utils:2020000-0-shipping") 2000)
            (New-TestImage 'e' @("$funcom/igw-k8s-battlegroup-operator:1.2.3") 9000)
        ) } | ConvertTo-Json -Depth 8
        $containers = @{ containers=@(
            (New-TestContainer 'c' "$funcom/seabass-server:2050000-0-shipping" 'CONTAINER_RUNNING')
            (New-TestContainer 'd' "$funcom/seabass-server-db-utils:2020000-0-shipping")
        ) } | ConvertTo-Json -Depth 8

        $plan = Get-DuneFuncomImageCleanupPlan -ImagesJson $images -ContainersJson $containers

        $plan.ok | Should -BeTrue
        @($plan.activeBuilds) | Should -Be @(2050000)
        @($plan.preservedBuilds) | Should -Be @(2040000, 2050000)
        @($plan.candidateBuilds) | Should -Be @(2030000)
        @($plan.candidates).Count | Should -Be 1
        $plan.candidates[0].id | Should -Be ('sha256:' + ('a' * 64))
        $plan.estimatedBytes | Should -Be 3000
    }

    It 'never selects referenced, future, operator, or ambiguously tagged images' {
        $images = @{ images=@(
            (New-TestImage 'a' @("$funcom/seabass-server:2030000-0-shipping"))
            (New-TestImage 'b' @("$funcom/seabass-server:2040000-0-shipping"))
            (New-TestImage 'c' @("$funcom/seabass-server:2050000-0-shipping"))
            (New-TestImage 'd' @("$funcom/seabass-server:2060000-0-shipping"))
            (New-TestImage 'e' @("$funcom/igw-k8s-database-operator:1.2.3"))
            (New-TestImage 'f' @("$funcom/seabass-server:2020000-0-shipping", 'other.example/image:latest'))
            (New-TestImage '1' @("$funcom/seabass-server:2010000-0-shipping") 1000 $true)
        ) } | ConvertTo-Json -Depth 8
        $containers = @{ containers=@(
            (New-TestContainer 'c' "$funcom/seabass-server:2050000-0-shipping" 'CONTAINER_RUNNING')
            (New-TestContainer 'a' "$funcom/seabass-server:2030000-0-shipping")
        ) } | ConvertTo-Json -Depth 8

        $plan = Get-DuneFuncomImageCleanupPlan -ImagesJson $images -ContainersJson $containers

        $plan.ok | Should -BeTrue
        @($plan.candidates).Count | Should -Be 0
    }

    It 'fails closed when no running Funcom build can be identified' {
        $images = @{ images=@(
            (New-TestImage 'a' @("$funcom/seabass-server:2030000-0-shipping"))
        ) } | ConvertTo-Json -Depth 8
        $containers = @{ containers=@(
            (New-TestContainer 'a' "$funcom/seabass-server:2030000-0-shipping")
        ) } | ConvertTo-Json -Depth 8

        $plan = Get-DuneFuncomImageCleanupPlan -ImagesJson $images -ContainersJson $containers

        $plan.ok | Should -BeFalse
        @($plan.candidates).Count | Should -Be 0
        $plan.message | Should -Match 'No active Funcom server build'
    }
}
