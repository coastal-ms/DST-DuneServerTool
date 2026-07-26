# Tests the probe v2 additions in app/server/lib/VmMemoryPressure.ps1: the
# VM-health signals DST was completely blind to before 2026-07-26 (stuck
# DatabaseOperations, disk/DiskPressure, retained Funcom build images, the game
# UDP DNAT bridge, and per-map memory limits crushed by Funcom's experimental
# swap preset). Pure parsing only - no SSH, no IO.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'VmMemoryPressure.ps1'
}

Describe 'VM health blockers (probe v2)' -Tag 'Pure' {

    # The confirmed 2026-07-26 field case: server down ~24h on a stuck
    # DatabaseOperation, 94.2% of RAM free, operators at 215+ restarts, per-map
    # limits on swap-mode values, and (from the second case the same day) no
    # game-UDP DNAT rules after the VM moved to a new Hyper-V host.
    BeforeAll {
        $script:v2Fixture = @'
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
maplim=DeepDesert_1~LIM:10Gi
maplim=CB_Overland_M_01~LIM:1Gi
img=registry/seabass-server~TAG:2025705~SIZE:4.46GB
img=registry/seabass-server~TAG:2051294~SIZE:4.46GB
dnat_udp_rules=0
dnat_udp_ports=
probe_done=1
'@

        $script:healthyV2 = @'
probe=dune-mem-pressure/2
mem_total_k=49392000
mem_avail_k=46500000
swap_total_k=0
node_cond=MemoryPressure=False
node_cond=DiskPressure=False
node_cond=Ready=True
disk_root_use_pct=41
bg_database_phase=Ready
dbop_total=211
dbop_open=0
maplim=Survival_1~LIM:12Gi
maplim=Overmap~LIM:2Gi
dnat_udp_rules=34
dnat_udp_ports=7777 7778
probe_done=1
'@
    }

    It 'reports the stuck DatabaseOperation as a critical blocker' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture
        $b = @($r.blockers | Where-Object { $_.id -eq 'db-operation-stuck' })
        $b.Count                | Should -Be 1
        $b[0].severity          | Should -Be 'critical'
        $b[0].detail            | Should -Match 'sh-abc-import-20260725-162348'
        $r.bg.databasePhase     | Should -Be 'Operation'
        @($r.dbOps.stuck).Count | Should -Be 1
    }

    It 'does NOT report memory pressure on that same fixture' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture
        $r.pressure     | Should -BeFalse
        $r.mem.availPct | Should -BeGreaterThan 90
    }

    It 'detects swap-mode per-map memory limits and leaves correct ones alone' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture
        $r.mapLimits.swapMode         | Should -BeTrue
        @($r.mapLimits.drifted).Count | Should -Be 3
        ($r.mapLimits.entries | Where-Object { $_.map -eq 'Survival_1' }).drifted | Should -BeFalse
        ($r.mapLimits.entries | Where-Object { $_.map -eq 'Overmap' }).expected   | Should -Be '2Gi'
    }

    It 'never treats a limit ABOVE the default as drift' {
        $raised = @'
maplim=Survival_1~LIM:16Gi
maplim=Overmap~LIM:2Gi
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $raised
        @($r.mapLimits.drifted).Count | Should -Be 0
    }

    It 'only calls the UDP bridge missing when a public IP is configured' {
        $withPublic = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture -PublicIpConfigured $true
        $withPublic.dnat.missing | Should -BeTrue
        @($withPublic.blockers | Where-Object { $_.id -eq 'udp-bridge-missing' }).Count | Should -Be 1

        $lanOnly = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture -PublicIpConfigured $false
        $lanOnly.dnat.missing | Should -BeFalse
        @($lanOnly.blockers | Where-Object { $_.id -eq 'udp-bridge-missing' }).Count | Should -Be 0
    }

    It 'does not call the UDP bridge missing while the battlegroup is stopped' {
        # No bound listeners means the watchdog correctly keeps no rules.
        $stopped = @'
dnat_udp_rules=0
dnat_udp_ports=
game_pods_running=0
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $stopped -PublicIpConfigured $true
        $r.dnat.missing | Should -BeFalse
    }

    It 'does not call the UDP bridge missing when iptables could not be run' {
        # /sbin is not on a non-interactive SSH PATH; the probe emits no rule
        # count at all in that case rather than a misleading zero.
        $noIptables = @'
dnat_probe=unavailable
game_pods_running=5
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $noIptables -PublicIpConfigured $true
        $r.dnat.udpRules | Should -BeNullOrEmpty
        $r.dnat.missing  | Should -BeFalse
    }

    It 'parses disk usage and stays quiet below the warn threshold' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture
        $r.disk.usePct | Should -Be 52
        $r.disk.high   | Should -BeFalse
        @($r.blockers | Where-Object { $_.id -like 'disk-*' }).Count | Should -Be 0
    }

    It 'raises a disk blocker at the warn threshold' {
        $filling = @'
disk_root_size_k=103275396
disk_root_used_k=88000000
disk_root_avail_k=15000000
disk_root_use_pct=86
node_cond=DiskPressure=False
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $filling
        $r.disk.high | Should -BeTrue
        @($r.blockers | Where-Object { $_.id -eq 'disk-filling' }).Count | Should -Be 1
    }

    It 'raises a DiskPressure blocker when the node reports it' {
        $pressured = @'
disk_root_size_k=103275396
disk_root_used_k=99000000
disk_root_avail_k=1000000
disk_root_use_pct=96
node_cond=DiskPressure=True
probe_done=1
'@
        $p = ConvertFrom-DuneMemPressureProbe -Raw $pressured
        $p.node.diskPressure | Should -BeTrue
        @($p.blockers | Where-Object { $_.id -eq 'disk-pressure' }).Count | Should -Be 1
    }

    It 'counts retained Funcom build images but only warns once the disk is also filling' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v2Fixture
        $r.images.buildCount | Should -Be 2
        $r.images.totalBytes | Should -BeGreaterThan 0
        @($r.blockers | Where-Object { $_.id -eq 'stale-build-images' }).Count | Should -Be 0

        $bloated = @'
disk_root_use_pct=78
img=registry/seabass-server~TAG:2025705~SIZE:4.46GB
img=registry/seabass-server~TAG:2036754~SIZE:4.46GB
img=registry/seabass-server~TAG:2048594~SIZE:4.46GB
img=registry/seabass-server~TAG:2051294~SIZE:4.46GB
probe_done=1
'@
        $b = ConvertFrom-DuneMemPressureProbe -Raw $bloated
        $b.images.buildCount | Should -Be 4
        @($b.blockers | Where-Object { $_.id -eq 'stale-build-images' }).Count | Should -Be 1
    }

    It 'stays completely silent on a healthy v2 probe' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $healthyV2 -PublicIpConfigured $true
        $r.pressure            | Should -BeFalse
        @($r.blockers).Count   | Should -Be 0
        @($r.dnat.ports).Count | Should -Be 2
    }

    It 'still parses a v1 probe (no v2 keys) without inventing blockers' {
        $v1 = @'
probe=dune-mem-pressure/1
mem_total_k=24671232
mem_avail_k=12000000
swap_total_k=4194304
op=x-controller-manager-a~P:Running~PR:~R:0 0 ~E:  ~X:  ~W:
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $v1 -PublicIpConfigured $true
        $r.ok                | Should -BeTrue
        @($r.blockers).Count | Should -Be 0
        $r.disk.known        | Should -BeFalse
        $r.dnat.udpRules     | Should -BeNullOrEmpty
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
    It 'flags the exact values Funcom experimental swap writes' {
        (New-DuneMapLimitEntry -Map 'Overmap'    -Limit '1Gi').swapModeValue  | Should -BeTrue
        (New-DuneMapLimitEntry -Map 'Overmap'    -Limit '200Mi').swapModeValue| Should -BeTrue
        (New-DuneMapLimitEntry -Map 'DeepDesert_1' -Limit '10Gi').drifted     | Should -BeTrue
    }
    It 'ignores maps that are not in the Funcom template table' {
        $e = New-DuneMapLimitEntry -Map 'Some_Future_Map' -Limit '1Gi'
        $e.drifted  | Should -BeFalse
        $e.expected | Should -Be ''
    }
}
