# Tests the pure parser in app/server/lib/VmMemoryPressure.ps1: it turns the
# read-only probe's key=value output into a memory-pressure finding. No SSH /
# IO - the live probe is exercised only on a real VM.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'VmMemoryPressure.ps1'
}

Describe 'Format-DuneMemKiB' -Tag 'Pure' {
    It 'scales KiB up to the right unit' {
        Format-DuneMemKiB 512        | Should -Be '512 KiB'
        Format-DuneMemKiB 71060      | Should -Be '69.4 MiB'
        Format-DuneMemKiB 24671232   | Should -Be '23.5 GiB'
    }
    It 'returns ? for null / negative' {
        Format-DuneMemKiB $null | Should -Be '?'
        Format-DuneMemKiB -5    | Should -Be '?'
    }
}

Describe 'ConvertFrom-DuneMemPressureProbe' -Tag 'Pure' {

    # Mirrors Pat's case (2026-07-07): 23.5 GiB VM, 69 MiB available, Swap: 0,
    # two operators OOM-killed (exit 137) with restart counts in the 30s.
    # Defined in BeforeAll (with $script: scope) so it survives Pester v5's
    # discovery -> run phase split and is visible inside the It blocks.
    BeforeAll {
        $script:patFixture = @'
probe=dune-mem-pressure/1
mem_total_k=24671232
mem_avail_k=71060
swap_total_k=0
swap_free_k=0
__FREE_H_BEGIN__
              total        used        free
Mem:           23Gi        22Gi       200Mi
Swap:            0B          0B          0B
__FREE_H_END__
ns_operators=funcom-operators
op=battlegroup-operator-controller-manager-abc~P:Running~PR:~R:34 0 ~E:137  ~X:Error  ~W:
op=database-operator-controller-manager-xyz~P:Running~PR:~R:32 0 ~E:137  ~X:OOMKilled  ~W:
ns_seabass=funcom-seabass-sh-abc-def
db=sh-abc-def-db-dbdepl-sts-0~P:Running~PR:~R:5 0 ~E:  ~X:  ~W:
probe_done=1
'@
    }

    It 'detects critical memory pressure on the Pat case' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $patFixture
        $r.pressure          | Should -BeTrue
        $r.severity          | Should -Be 'critical'
        $r.signals.oomKills  | Should -Be 2
        $r.signals.maxRestarts | Should -Be 34
        $r.mem.swapZero      | Should -BeTrue
        $r.mem.lowAvailable  | Should -BeTrue
        $r.headline          | Should -Match 'killed 34x'
    }

    It 'captures the free -h block and per-pod detail' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw $patFixture
        $r.mem.freeH         | Should -Match 'Swap:'
        @($r.operators).Count | Should -Be 2
        # short name drops the sh-<hash>-<rand>- prefix on the DB pod
        ($r.db[0].shortName) | Should -Be 'db-dbdepl-sts-0'
        ($r.db[0].oom)       | Should -BeFalse   # restarts=5, no 137
    }

    It 'reports no pressure on a healthy VM' {
        $healthy = @'
mem_total_k=24671232
mem_avail_k=12000000
swap_total_k=4194304
swap_free_k=4194304
ns_operators=funcom-operators
op=x-controller-manager-a~P:Running~PR:~R:0 0 ~E:  ~X:  ~W:
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $healthy
        $r.pressure           | Should -BeFalse
        $r.severity           | Should -Be 'none'
        @($r.warnings).Count  | Should -Be 0
    }

    It 'does NOT flag low available when swap provides a cushion' {
        $lowButSwap = @'
mem_total_k=24671232
mem_avail_k=200000
swap_total_k=8388608
swap_free_k=8000000
op=x-controller-manager-a~P:Running~PR:~R:1 ~E:  ~X:  ~W:
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $lowButSwap
        $r.mem.lowAvailable    | Should -BeTrue
        $r.signals.lowMemory   | Should -BeFalse   # swap present -> not the signature
        $r.pressure            | Should -BeFalse
    }

    It 'treats a bare Error exit (no 137) as a crash, not an OOM' {
        $churn = @'
mem_total_k=24671232
mem_avail_k=9000000
swap_total_k=0
op=x-controller-manager-a~P:Running~PR:~R:9 0 ~E:1  ~X:Error  ~W:
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $churn
        $r.signals.oomKills       | Should -Be 0
        $r.signals.highRestartPods | Should -Be 1
        $r.severity               | Should -Be 'warn'
    }

    It 'flags an Evicted pod-level reason as OOM' {
        $evicted = @'
mem_total_k=24671232
mem_avail_k=50000
swap_total_k=0
db=sh-a-b-db-0~P:Failed~PR:Evicted~R:0 ~E:  ~X:  ~W:
probe_done=1
'@
        $r = ConvertFrom-DuneMemPressureProbe -Raw $evicted
        ($r.db[0].oom)      | Should -BeTrue
        $r.signals.oomKills | Should -Be 1
        $r.pressure         | Should -BeTrue
    }

    It 'returns ok=false for empty input' {
        $r = ConvertFrom-DuneMemPressureProbe -Raw ''
        $r.ok       | Should -BeFalse
        $r.pressure | Should -BeFalse
    }
}
