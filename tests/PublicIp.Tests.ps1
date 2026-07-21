BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'PublicIp.ps1'
}

Describe 'Public IP validation' {
    BeforeEach {
        function global:Read-DuneConfig { @{ LastAppliedPublicIp = '' } }
    }

    It 'accepts a public IPv4 literal' {
        $r = Assert-DuneManualPublicIp -PublicIp '8.8.8.8'
        $r.ok | Should -BeTrue
        $r.publicIp | Should -Be '8.8.8.8'
    }

    It 'rejects malformed IPv4' {
        $r = Assert-DuneManualPublicIp -PublicIp '999.1.1.1'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 400
    }

    It 'rejects private IPv4' {
        $r = Assert-DuneManualPublicIp -PublicIp '192.168.1.50'
        $r.ok | Should -BeFalse
        $r.message | Should -Match 'private'
    }

    It 'rejects loopback and link-local IPv4' {
        (Assert-DuneManualPublicIp -PublicIp '127.0.0.1').ok | Should -BeFalse
        (Assert-DuneManualPublicIp -PublicIp '169.254.1.2').ok | Should -BeFalse
    }

    It 'rejects unchanged last-applied IP' {
        function global:Read-DuneConfig { @{ LastAppliedPublicIp = '8.8.8.8' } }
        $r = Assert-DuneManualPublicIp -PublicIp '8.8.8.8'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 409
    }
}

Describe 'DDNS hostname validation' {
    It 'normalizes a valid hostname' {
        $r = Test-DuneDdnsHostname -Hostname 'Your-Server.DDNS.net'
        $r.ok | Should -BeTrue
        $r.hostname | Should -Be 'your-server.ddns.net'
    }

    It 'rejects invalid hostname labels' {
        (Test-DuneDdnsHostname -Hostname '-bad.example.com').ok | Should -BeFalse
    }

    It 'saves a normalized hostname without resolving it' {
        $script:savedPublicIpConfig = $null
        function Save-DuneConfig {
            param([hashtable]$Config)
            $script:savedPublicIpConfig = $Config
            return $Config
        }

        $r = Save-DunePublicIpHostname -Hostname 'Your-Server.DDNS.net'

        $r.ok | Should -BeTrue
        $r.hostname | Should -Be 'your-server.ddns.net'
        $script:savedPublicIpConfig.PublicIpMode | Should -Be 'ddns'
        $script:savedPublicIpConfig.DdnsHostname | Should -Be 'your-server.ddns.net'
    }
}

Describe 'DDNS hostname resolution resilience' {
    It 'retries when the first lookup returns nothing (transient negative cache)' {
        $script:resolveCalls = 0
        Mock -CommandName Get-DuneHostnameIPv4Records -MockWith {
            $script:resolveCalls++
            if ($script:resolveCalls -lt 2) { return @() }
            return @('50.123.76.96')
        }
        $r = Resolve-DunePublicIpHostname -Hostname 'dunecoastal.myvnc.com'
        $r.ok | Should -BeTrue
        $r.publicIp | Should -Be '50.123.76.96'
        $script:resolveCalls | Should -BeGreaterThan 1
    }

    It 'fails cleanly after exhausting retries when nothing resolves' {
        Mock -CommandName Get-DuneHostnameIPv4Records -MockWith { @() }
        $r = Resolve-DunePublicIpHostname -Hostname 'dunecoastal.myvnc.com'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 400
        $r.message | Should -Match 'Could not resolve'
    }

    It 'ignores private answers and reports no usable public IP' {
        Mock -CommandName Get-DuneHostnameIPv4Records -MockWith { @('192.168.23.219') }
        $r = Resolve-DunePublicIpHostname -Hostname 'dunecoastal.myvnc.com'
        $r.ok | Should -BeFalse
        $r.message | Should -Match 'usable public IPv4'
    }
}

Describe 'settings.conf renderer' {
    It 'renders exactly four lines' {
        $text = New-DuneSettingsConfText -Battlegroup 'sh-test' -Image 'registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping' -VmIp '192.168.1.50' -PublicIp '8.8.8.8'
        $lines = $text -split "`n"
        $lines.Count | Should -Be 5
        $lines[0] | Should -Be 'sh-test'
        $lines[1] | Should -Be 'registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping'
        $lines[2] | Should -Be '192.168.1.50'
        $lines[3] | Should -Be '8.8.8.8'
        $lines[4] | Should -Be ''
    }

    It 'rejects embedded JSON image lines' {
        { New-DuneSettingsConfText -Battlegroup 'sh-test' -Image '{"image":"bad"}' -VmIp '192.168.1.50' -PublicIp '8.8.8.8' } | Should -Throw
    }
}

Describe 'Public IP apply state file' {
    BeforeAll {
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) ("dst-apply-state-{0}.json" -f ([guid]::NewGuid()))
        function global:Get-DunePublicIpApplyStatePath { $script:tmpState }
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tmpState -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-DunePublicIpApplyStatePath -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:tmpState -Force -ErrorAction SilentlyContinue
    }

    It 'returns an idle state when no file exists' {
        $st = Read-DunePublicIpApplyState
        $st.phase | Should -Be 'idle'
        $st.running | Should -BeFalse
    }

    It 'round-trips a saved state' {
        Save-DunePublicIpApplyState -State @{ phase='running'; running=$true; publicIp='8.8.8.8'; steps=@(@{ id='a'; label='A'; status='done' }) }
        $st = Read-DunePublicIpApplyState
        $st.phase | Should -Be 'running'
        $st.publicIp | Should -Be '8.8.8.8'
        @($st.steps).Count | Should -Be 1
    }

    It 'self-heals a stale running flag (no progress for >15 min)' {
        $old = (Get-Date).ToUniversalTime().AddMinutes(-20).ToString('o')
        Save-DunePublicIpApplyState -State @{ phase='running'; running=$true; publicIp='8.8.8.8'; steps=@(); updated=$old }
        $st = Get-DunePublicIpApplyStatus
        $st.running | Should -BeFalse
        $st.phase | Should -Be 'error'
    }

    It 'leaves a fresh running state alone' {
        $fresh = (Get-Date).ToUniversalTime().ToString('o')
        Save-DunePublicIpApplyState -State @{ phase='running'; running=$true; publicIp='8.8.8.8'; steps=@(); updated=$fresh }
        $st = Get-DunePublicIpApplyStatus
        $st.running | Should -BeTrue
    }
}

Describe 'Mixed-bind game UDP bridge' {
    BeforeAll {
        $script:dnatWatchPath = Join-Path $PSScriptRoot '..\app\resources\remote-scripts\dune-dnat-watch-install.sh'
        $script:dnatWatchSource = Get-Content -LiteralPath $script:dnatWatchPath -Raw
        $script:publicIpSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\app\server\lib\PublicIp.ps1') -Raw
        $script:launcherSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\dune-server.ps1') -Raw

        $script:posixShell = Get-Command sh -ErrorAction SilentlyContinue
        if (-not $script:posixShell) {
            $gitShell = Join-Path $env:ProgramFiles 'Git\bin\sh.exe'
            if (Test-Path -LiteralPath $gitShell) {
                $script:posixShell = Get-Item -LiteralPath $gitShell
            }
        }
    }

    It 'classifies each active port independently from one listener snapshot' {
        if (-not $script:posixShell) {
            Set-ItResult -Skipped -Because 'A POSIX shell is not installed.'
            return
        }

        $functionMatch = [regex]::Match(
            $script:dnatWatchSource,
            '(?ms)^game_port_state\(\) \{\r?\n.*?^\}'
        )
        $functionMatch.Success | Should -BeTrue

        $harness = @'
PUB=203.0.113.10
VM_IP=192.168.1.20
_udp_snapshot='203.0.113.10:7777
203.0.113.10:7779
0.0.0.0:7779
192.168.1.20:7780'
'@ + "`n" + $functionMatch.Value + "`n" + @'
game_port_state 7777
game_port_state 7779
game_port_state 7780
game_port_state 7781
'@

        $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("dst-dnat-state-{0}.sh" -f [guid]::NewGuid())
        try {
            [System.IO.File]::WriteAllText(
                $tempScript,
                $harness,
                [System.Text.UTF8Encoding]::new($false)
            )
            $actual = @(& $script:posixShell.FullName $tempScript)
            $LASTEXITCODE | Should -Be 0
            $actual | Should -Be @('pub', 'pub', 'lan', 'none')
        } finally {
            Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        }
    }

    It 'prefers the public listener when different processes dual-bind one port' {
        $script:dnatWatchSource | Should -Match 'if \[ "\$_pub" = 1 \]; then'
        $script:publicIpSource | Should -Match 'if \[ "\$_pub" = 1 \]; then echo pub; elif \[ "\$_lanwild" = 1 \]'
        $script:publicIpSource | Should -Match 'if \[ "\$gb_pub" = 1 \]; then echo pub; elif \[ "\$gb_lanwild" = 1 \]'
    }

    It 'scopes watchdog cleanup to UDP DNAT rules for the Dune VM' {
        $script:dnatWatchSource | Should -Match 'game_bridge_rules\(\)'
        $script:dnatWatchSource | Should -Match 'grep -F -- "-d \$\{VM_IP\}/32"'
        $script:dnatWatchSource | Should -Match "grep -F -- '-p udp'"
        $script:dnatWatchSource | Should -Not -Match '(?m)iptables .* -I PREROUTING .*--dport "\$GAME_PORTS"'
    }

    It 'preserves the legacy bridge while listener state is fully indeterminate' {
        $script:dnatWatchSource | Should -Match '\[ "\$_state" != none \] && \[ "\$_legacy_reconciled" = 0 \]'
        $script:publicIpSource | Should -Match '\[ "\$_state" != none \] && \[ "\$_legacy_reconciled" = 0 \]'
        $script:publicIpSource | Should -Match '\[ "\$gb_state" != none \] && \[ "\$gb_legacy_reconciled" = 0 \]'
    }

    It 'uses per-port reconciliation in both embedded Public IP apply paths' {
        $script:publicIpSource | Should -Match 'game_port_state\(\)'
        $script:publicIpSource | Should -Match 'gb_port_state\(\)'
        $script:publicIpSource | Should -Match '_udp_snapshot=\$\(udp_listeners\)'
        $script:publicIpSource | Should -Match 'gb_udp_snapshot=\$\(gb_listeners\)'
        $script:publicIpSource | Should -Not -Match '(?m)iptables .* -I PREROUTING .*--dport "\$GAME_PORTS"'
        $script:publicIpSource | Should -Not -Match '(?m)iptables .* -I PREROUTING .*--dport "\$GBPORTS"'
    }

    It 'polls one listener snapshot per pass at one-second cadence' {
        $script:dnatWatchSource | Should -Match '(?m)^LOOP_SLEEP="\$\{DUNE_DNAT_LOOP_SLEEP:-1\}"$'
        $script:dnatWatchSource | Should -Match '(?ms)^run_loop\(\) \{.*?reconcile_game_udp.*?sleep "\$LOOP_SLEEP".*?^\}'
        $script:dnatWatchSource | Should -Match '(?ms)^reconcile_game_udp\(\) \{.*?_udp_snapshot=\$\(udp_listeners\).*?^\}'
        ([regex]::Matches(
            ([regex]::Match($script:dnatWatchSource, '(?ms)^reconcile_game_udp\(\) \{.*?^\}').Value),
            '_udp_snapshot=\$\(udp_listeners\)'
        )).Count | Should -Be 1
    }

    It 'bounds kubectl and isolates cluster refresh from the listener loop' {
        $script:dnatWatchSource | Should -Match 'kube\(\) \{ timeout 3 "\$K3S" kubectl --request-timeout=2s'
        $script:dnatWatchSource | Should -Match '(?ms)^run_cluster_pass\(\) \{.*?kube get nodes.*?kube get endpoints.*?^\}'
        $script:dnatWatchSource | Should -Match '(?ms)^run_cluster_worker\(\) \{.*?run_cluster_pass.*?^\}'
        $script:dnatWatchSource | Should -Match '(?ms)^run_loop\(\) \{.*?start_cluster_worker.*?while :; do.*?reconcile_game_udp.*?ensure_cluster_worker'
        ([regex]::Match($script:dnatWatchSource, '(?ms)^run_loop\(\) \{.*?^\}').Value) |
            Should -Not -Match '\bkube\b'
    }

    It 'installs supervised lifecycle and heartbeat health recovery' {
        $script:dnatWatchSource | Should -Match '(?m)^supervisor=supervise-daemon$'
        $script:dnatWatchSource | Should -Match '(?m)^command_args="--loop"$'
        $script:dnatWatchSource | Should -Match '(?m)^respawn_delay=2$'
        $script:dnatWatchSource | Should -Match '(?m)^respawn_max=0$'
        $script:dnatWatchSource | Should -Match '(?m)^healthcheck_timer=5$'
        $script:dnatWatchSource | Should -Match '(?ms)^healthcheck\(\) \{.*?--healthcheck.*?^\}'
        $script:dnatWatchSource | Should -Match 'rc-update add dune-dnat-watch default'
        $script:dnatWatchSource | Should -Match 'rc-service dune-dnat-watch restart'
        $script:dnatWatchSource | Should -Match 'rc-service dune-dnat-watch status'
    }

    It 'uses cron only to recover the supervisor and never to overlap reconciliation' {
        $script:dnatWatchSource | Should -Match 'CRON_LINE="\* \* \* \* \* \$WATCH --healthcheck .* \|\| \$SERVICE restart'
        $script:dnatWatchSource | Should -Not -Match '(?m)^\(.*echo "\* \* \* \* \* \$WATCH"'
    }

    It 'uses kernel-released mutation serialization instead of a stale lock gate' {
        $script:dnatWatchSource | Should -Match '(?m)^MUTATION_LOCK='
        $script:dnatWatchSource | Should -Match 'flock -x 9'
        $script:dnatWatchSource | Should -Match '(?ms)^worker_owned\(\) \{.*?OWNER_FILE.*?^\}'
        $script:dnatWatchSource | Should -Match 'Ownership is checked after acquiring the kernel-released mutation lock'
        $script:dnatWatchSource | Should -Match 'old listener exits before it can overlap'
        $script:dnatWatchSource | Should -Match '(?m)^\s*trap cleanup_loop EXIT$'
        $script:dnatWatchSource | Should -Match '(?ms)^write_cluster_state\(\) \{.*?flock -x 9.*?worker_owned.*?mv -f.*?CLUSTER_STATE.*?^\}'
        $script:dnatWatchSource | Should -Match '(?ms)^write_listener_heartbeat\(\) \{.*?flock -x 9.*?worker_owned.*?mv -f.*?LISTENER_HEARTBEAT.*?^\}'
        $script:dnatWatchSource | Should -Match '(?ms)^clear_owner\(\) \{.*?flock -x 9.*?worker_owned.*?rm -f "\$OWNER_FILE".*?^\}'
    }

    It 'fails installation unless generated files, runlevel, cron, and heartbeat are canonical' {
        $script:dnatWatchSource | Should -Match 'chmod 0755 "\$WATCH_STAGE".*\|\| fail'
        $script:dnatWatchSource | Should -Match 'sh -n "\$WATCH_STAGE".*\|\| fail'
        $script:dnatWatchSource | Should -Match 'rc-update show default'
        $script:dnatWatchSource | Should -Match 'grep -Fxc "\$CRON_LINE"'
        $script:dnatWatchSource | Should -Match 'non-canonical dune-dnat-watch cron entry remains'
        $script:dnatWatchSource | Should -Match 'replacement dune-dnat-watch did not publish a fresh owner and heartbeat'
        $script:dnatWatchSource | Should -Match '(?ms)^replacement_healthy\(\) \{.*?PRE_CUTOVER_OWNER.*?LISTENER_HEARTBEAT.*?-nt "\$CUTOVER_MARKER".*?^\}'
    }

    It 'stages atomically, supports legacy no-arg cron, and rolls migration back' {
        $script:dnatWatchSource | Should -Match 'WATCH_STAGE="\$\{WATCH\}\.new\.\$\{TXN\}"'
        $script:dnatWatchSource | Should -Match 'mv -f "\$WATCH_STAGE" "\$WATCH"'
        $script:dnatWatchSource | Should -Match "(?m)^\s*--once\|''\) run_once ;;\s*$"
        $script:dnatWatchSource | Should -Match '(?ms)^restore_prior_state\(\) \{.*?WATCH_BACKUP.*?SERVICE_BACKUP.*?CRON_BACKUP.*?PRIOR_SERVICE_RUNNING.*?^\}'
        $script:dnatWatchSource | Should -Match 'stop_watch_processes \|\| fail "prior DNAT watchdog processes did not fully exit"'
        $script:dnatWatchSource | Should -Match '(?ms)^MIGRATION_STARTED=0.*?retired legacy /usr/local/sbin/dune-mq-dnat-sync.sh'
    }

    It 'rejects a fresh stale pre-cutover heartbeat and accepts only a different new token' {
        if (-not $script:posixShell) {
            Set-ItResult -Skipped -Because 'A POSIX shell is not installed.'
            return
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dst-dnat-rollback-{0}" -f [guid]::NewGuid())
        $bin = Join-Path $tempRoot 'bin'
        $live = Join-Path $tempRoot 'live'
        $state = Join-Path $tempRoot 'state'
        New-Item -ItemType Directory -Path $bin,$live,$state -Force | Out-Null
        $escapedRoot = $tempRoot.Replace("'", "'\''")
        $posixRoot = (& $script:posixShell.FullName -lc "cygpath -u '$escapedRoot'").Trim()

        $installerPath = Join-Path $tempRoot 'install.sh'
        $watchPath = Join-Path $live 'watch.sh'
        $servicePath = Join-Path $live 'service'
        $cronPath = Join-Path $tempRoot 'crontab'
        $oldWatch = "#!/bin/sh`necho OLD_WATCH`n"
        $oldService = "#!/bin/sh`necho OLD_SERVICE`n"
        $oldCron = "7 * * * * $posixRoot/live/watch.sh`n13 * * * * echo unrelated`n"
        $process = $null
        $successProcess = $null

        try {
            [System.IO.File]::WriteAllText($installerPath, $script:dnatWatchSource, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($watchPath, $oldWatch, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($servicePath, $oldService, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($cronPath, $oldCron, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $tempRoot 'service-state'), "running`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $tempRoot 'runlevel-state'), "default`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $tempRoot 'crontab-writes'), "0`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $state 'owner'), "old-owner`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $state 'listener.heartbeat'), "old-owner`n", [System.Text.UTF8Encoding]::new($false))

            [System.IO.File]::WriteAllText((Join-Path $bin 'crontab'), @'
#!/bin/sh
case "${1:-}" in
  -l) [ -f "$FAKE_CRON_FILE" ] && cat "$FAKE_CRON_FILE" && exit 0; exit 1 ;;
  -r) rm -f "$FAKE_CRON_FILE"; exit 0 ;;
esac
_n=$(cat "$FAKE_CRON_WRITES")
_n=$((_n + 1))
printf '%s\n' "$_n" > "$FAKE_CRON_WRITES"
if [ "$1" = - ]; then
  cat > "$FAKE_CRON_FILE"
else
  cp "$1" "$FAKE_CRON_FILE"
fi
'@, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'rc-service'), @'
#!/bin/sh
case "$2" in
  status) grep -qx running "$FAKE_SERVICE_STATE" ;;
  stop) echo stopped > "$FAKE_SERVICE_STATE" ;;
  start) echo running > "$FAKE_SERVICE_STATE" ;;
  restart)
    echo running > "$FAKE_SERVICE_STATE"
    if [ "${FAKE_CREATE_HEARTBEAT:-no}" = yes ]; then
      printf '%s\n' new-owner > "$FAKE_STATE_DIR/owner"
      printf '%s\n' new-owner > "$FAKE_STATE_DIR/listener.heartbeat"
    fi
    ;;
  *) exit 1 ;;
esac
'@, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'rc-update'), @'
#!/bin/sh
case "$1" in
  show) grep -qx default "$FAKE_RUNLEVEL_STATE" && echo "dune-dnat-watch | default" ;;
  add) echo default > "$FAKE_RUNLEVEL_STATE" ;;
  del) echo absent > "$FAKE_RUNLEVEL_STATE" ;;
  *) exit 1 ;;
esac
'@, [System.Text.UTF8Encoding]::new($false))
            foreach ($name in 'supervise-daemon','timeout','flock') {
                [System.IO.File]::WriteAllText((Join-Path $bin $name), "#!/bin/sh`nexit 0`n", [System.Text.UTF8Encoding]::new($false))
            }
            [System.IO.File]::WriteAllText((Join-Path $bin 'stat'), "#!/bin/sh`ndate +%s`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'pgrep'), "#!/bin/sh`nexit 1`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'k3s'), "#!/bin/sh`nexit 0`n", [System.Text.UTF8Encoding]::new($false))

            & $script:posixShell.FullName -lc "chmod +x '$posixRoot/install.sh' '$posixRoot/live/watch.sh' '$posixRoot/live/service' '$posixRoot/bin/'*"
            $LASTEXITCODE | Should -Be 0

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $script:posixShell.FullName
            $psi.ArgumentList.Add("$posixRoot/install.sh")
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.Environment['DUNE_DNAT_PATH_PREFIX'] = "$posixRoot/bin"
            $psi.Environment['DUNE_DNAT_INSTALL_WATCH'] = "$posixRoot/live/watch.sh"
            $psi.Environment['DUNE_DNAT_INSTALL_SERVICE'] = "$posixRoot/live/service"
            $psi.Environment['DUNE_DNAT_INSTALL_LOG'] = "$posixRoot/install.log"
            $psi.Environment['DUNE_DNAT_K3S'] = "$posixRoot/bin/k3s"
            $psi.Environment['DUNE_DNAT_STATE_DIR'] = "$posixRoot/state"
            $psi.Environment['FAKE_CRON_FILE'] = "$posixRoot/crontab"
            $psi.Environment['FAKE_CRON_WRITES'] = "$posixRoot/crontab-writes"
            $psi.Environment['FAKE_SERVICE_STATE'] = "$posixRoot/service-state"
            $psi.Environment['FAKE_RUNLEVEL_STATE'] = "$posixRoot/runlevel-state"
            $psi.Environment['FAKE_STATE_DIR'] = "$posixRoot/state"
            $psi.Environment['FAKE_CREATE_HEARTBEAT'] = 'no'

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $psi
            $process.Start() | Should -BeTrue
            $process.WaitForExit(15000) | Should -BeTrue
            $process.ExitCode | Should -Be 1
            $failureOutput = $process.StandardOutput.ReadToEnd()
            $failureOutput | Should -Match 'DUNE_DNAT_WATCH_FAILED'
            $failureOutput | Should -Not -Match 'DUNE_DNAT_WATCH_OK'

            (Get-Content -LiteralPath $watchPath -Raw) | Should -Be $oldWatch
            (Get-Content -LiteralPath $servicePath -Raw) | Should -Be $oldService
            (Get-Content -LiteralPath $cronPath -Raw) | Should -Be $oldCron
            (Get-Content -LiteralPath (Join-Path $tempRoot 'service-state') -Raw).Trim() | Should -Be 'running'
            (Get-Content -LiteralPath (Join-Path $tempRoot 'runlevel-state') -Raw).Trim() | Should -Be 'default'
            Test-Path -LiteralPath (Join-Path $state 'owner') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $state 'listener.heartbeat') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $live -Filter '*.new.*').Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $live -Filter '*.previous.*').Count | Should -Be 0

            [System.IO.File]::WriteAllText((Join-Path $state 'owner'), "old-owner`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $state 'listener.heartbeat'), "old-owner`n", [System.Text.UTF8Encoding]::new($false))
            $psi.Environment['FAKE_CREATE_HEARTBEAT'] = 'yes'
            $successProcess = [System.Diagnostics.Process]::new()
            $successProcess.StartInfo = $psi
            $successProcess.Start() | Should -BeTrue
            $successProcess.WaitForExit(15000) | Should -BeTrue
            $successOutput = $successProcess.StandardOutput.ReadToEnd()
            $successError = $successProcess.StandardError.ReadToEnd()
            $successProcess.ExitCode | Should -Be 0 -Because "stdout: $successOutput stderr: $successError"
            $successOutput | Should -Match 'DUNE_DNAT_WATCH_OK'
            (Get-Content -LiteralPath (Join-Path $state 'owner') -Raw).Trim() | Should -Be 'new-owner'
            (Get-Content -LiteralPath (Join-Path $state 'listener.heartbeat') -Raw).Trim() | Should -Be 'new-owner'
        } finally {
            if ($successProcess -and -not $successProcess.HasExited) { $successProcess.Kill($true) }
            if ($process -and -not $process.HasExited) { $process.Kill($true) }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rate-limits persistent iptables insertion failures' {
        $script:dnatWatchSource | Should -Match '(?ms)^log_reconcile_failure\(\) \{.*?-ge 60.*?^\}'
        $script:dnatWatchSource | Should -Match 'log_reconcile_failure "failed to install game-UDP bridge'
        $script:dnatWatchSource | Should -Match 'log_reconcile_failure "failed to install rabbitmq DNAT'
    }

    It 'refreshes supervision before every battlegroup start or restart path' {
        $script:launcherSource | Should -Match "Invoke-DuneDnatWatchdogInstall -Ip \`$ip -Phase 'pre-startup'"
        $script:launcherSource | Should -Match "Invoke-DuneDnatWatchdogInstall -Ip \`$ip -Phase 'pre-reboot-start'"
        $script:launcherSource | Should -Match 'Invoke-DuneDnatWatchdogInstall -Ip \$ip -Phase "pre-\$cmdName"'
        $script:launcherSource | Should -Not -Match 'Invoke-DuneDnatWatchdogInstall -Ip \$ip -Phase "post-\$cmdName"'
    }

    It 'keeps legacy no-argument cron functional with one safe reconciliation pass' {
        if (-not $script:posixShell) {
            Set-ItResult -Skipped -Because 'A POSIX shell is not installed.'
            return
        }

        $watchMatch = [regex]::Match(
            $script:dnatWatchSource,
            '(?ms)^if ! cat > "\$WATCH_STAGE" <<''WATCHEOF''\r?\n(.*?)\r?\nWATCHEOF$'
        )
        $watchMatch.Success | Should -BeTrue

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dst-dnat-once-{0}" -f [guid]::NewGuid())
        $bin = Join-Path $tempRoot 'bin'
        $state = Join-Path $tempRoot 'state'
        New-Item -ItemType Directory -Path $bin,$state -Force | Out-Null
        $escapedRoot = $tempRoot.Replace("'", "'\''")
        $posixRoot = (& $script:posixShell.FullName -lc "cygpath -u '$escapedRoot'").Trim()
        $watchPath = Join-Path $tempRoot 'watch.sh'
        $iptablesLog = Join-Path $tempRoot 'iptables.log'
        $process = $null

        try {
            [System.IO.File]::WriteAllText($watchPath, $watchMatch.Groups[1].Value, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $state 'cluster.state'), "203.0.113.10`n192.168.1.20`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'ss'), @'
#!/bin/sh
echo "UNCONN 0 0 203.0.113.10:7782 0.0.0.0:*"
'@, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'iptables'), @'
#!/bin/sh
case " $* " in
  *" -C "*) exit 1 ;;
  *" -I "*) echo "$*" >> "$HARNESS_IPTABLES_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
'@, [System.Text.UTF8Encoding]::new($false))
            foreach ($name in 'flock','k3s') {
                [System.IO.File]::WriteAllText((Join-Path $bin $name), "#!/bin/sh`nexit 0`n", [System.Text.UTF8Encoding]::new($false))
            }

            & $script:posixShell.FullName -lc "chmod +x '$posixRoot/watch.sh' '$posixRoot/bin/'*"
            $LASTEXITCODE | Should -Be 0

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $script:posixShell.FullName
            $psi.ArgumentList.Add("$posixRoot/watch.sh")
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.Environment['DUNE_DNAT_PATH_PREFIX'] = "$posixRoot/bin"
            $psi.Environment['DUNE_DNAT_K3S'] = "$posixRoot/bin/k3s"
            $psi.Environment['DUNE_DNAT_STATE_DIR'] = "$posixRoot/state"
            $psi.Environment['DUNE_DNAT_LOG'] = "$posixRoot/watch.log"
            $psi.Environment['HARNESS_IPTABLES_LOG'] = "$posixRoot/iptables.log"

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $psi
            $process.Start() | Should -BeTrue
            $process.WaitForExit(10000) | Should -BeTrue
            $process.ExitCode | Should -Be 0

            Get-Content -LiteralPath $iptablesLog -Raw | Should -Match '-I PREROUTING 1 -d 192\.168\.1\.20 -p udp --dport 7782 -j DNAT --to-destination 203\.0\.113\.10'
            Test-Path -LiteralPath (Join-Path $state 'owner') | Should -BeFalse
        } finally {
            if ($process -and -not $process.HasExited) { $process.Kill($true) }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps listener passes running while the bounded cluster worker stalls' {
        if (-not $script:posixShell) {
            Set-ItResult -Skipped -Because 'A POSIX shell is not installed.'
            return
        }

        $watchMatch = [regex]::Match(
            $script:dnatWatchSource,
            '(?ms)^if ! cat > "\$WATCH_STAGE" <<''WATCHEOF''\r?\n(.*?)\r?\nWATCHEOF$'
        )
        $watchMatch.Success | Should -BeTrue

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dst-dnat-loop-{0}" -f [guid]::NewGuid())
        $bin = Join-Path $tempRoot 'bin'
        $state = Join-Path $tempRoot 'state'
        New-Item -ItemType Directory -Path $bin,$state -Force | Out-Null

        $escapedRoot = $tempRoot.Replace("'", "'\''")
        $posixRoot = (& $script:posixShell.FullName -lc "cygpath -u '$escapedRoot'").Trim()
        $watchPath = Join-Path $tempRoot 'watch.sh'
        $ssCount = Join-Path $tempRoot 'ss-count'
        $iptablesLog = Join-Path $tempRoot 'iptables.log'
        $ruleState = Join-Path $tempRoot 'rule-state'
        $k3sStarted = Join-Path $tempRoot 'k3s-started'
        $process = $null
        $replacement = $null

        try {
            [System.IO.File]::WriteAllText($watchPath, $watchMatch.Groups[1].Value, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $state 'cluster.state'), "203.0.113.10`n192.168.1.20`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'ss'), @'
#!/bin/sh
_n=0
[ ! -r "$HARNESS_SS_COUNT" ] || _n=$(cat "$HARNESS_SS_COUNT")
_n=$((_n + 1))
printf '%s\n' "$_n" > "$HARNESS_SS_COUNT"
echo "UNCONN 0 0 203.0.113.10:7782 0.0.0.0:*"
'@, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'iptables'), @'
#!/bin/sh
echo "$HARNESS_ID $*" >> "$HARNESS_IPTABLES_LOG"
case " $* " in
  *" -C "*) [ -f "$HARNESS_RULE_STATE" ] && exit 0 || exit 1 ;;
  *" -I "*) : > "$HARNESS_RULE_STATE"; exit 0 ;;
  *) exit 0 ;;
esac
'@, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'k3s'), @'
#!/bin/sh
: > "$HARNESS_K3S_STARTED"
sleep 2
exit 1
'@, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $bin 'flock'), @'
#!/bin/sh
exit 0
'@, [System.Text.UTF8Encoding]::new($false))

            & $script:posixShell.FullName -lc "chmod +x '$posixRoot/watch.sh' '$posixRoot/bin/ss' '$posixRoot/bin/iptables' '$posixRoot/bin/k3s' '$posixRoot/bin/flock'"
            $LASTEXITCODE | Should -Be 0

            function Start-DnatHarness([string] $Id, [int] $MaxPasses) {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $script:posixShell.FullName
                $psi.ArgumentList.Add("$posixRoot/watch.sh")
                $psi.ArgumentList.Add('--loop')
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.Environment['DUNE_DNAT_PATH_PREFIX'] = "$posixRoot/bin"
                $psi.Environment['DUNE_DNAT_K3S'] = "$posixRoot/bin/k3s"
                $psi.Environment['DUNE_DNAT_STATE_DIR'] = "$posixRoot/state"
                $psi.Environment['DUNE_DNAT_LOG'] = "$posixRoot/watch.log"
                $psi.Environment['DUNE_DNAT_LOOP_SLEEP'] = '0.1'
                $psi.Environment['DUNE_DNAT_CLUSTER_SLEEP'] = '5'
                $psi.Environment['DUNE_DNAT_MAX_PASSES'] = "$MaxPasses"
                $psi.Environment['HARNESS_ID'] = $Id
                $psi.Environment['HARNESS_SS_COUNT'] = "$posixRoot/ss-count"
                $psi.Environment['HARNESS_IPTABLES_LOG'] = "$posixRoot/iptables.log"
                $psi.Environment['HARNESS_RULE_STATE'] = "$posixRoot/rule-state"
                $psi.Environment['HARNESS_K3S_STARTED'] = "$posixRoot/k3s-started"
                $p = [System.Diagnostics.Process]::new()
                $p.StartInfo = $psi
                if (-not $p.Start()) { throw "Failed to start $Id harness" }
                return $p
            }

            $process = Start-DnatHarness -Id old -MaxPasses 20
            for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $ruleState); $i++) {
                Start-Sleep -Milliseconds 25
            }
            Test-Path -LiteralPath $ruleState | Should -BeTrue
            $oldOwner = Get-Content -LiteralPath (Join-Path $state 'owner') -Raw
            $oldInsertBefore = @((Get-Content -LiteralPath $iptablesLog) | Where-Object {
                $_ -match '^old .* -I PREROUTING .*--dport 7782 '
            }).Count

            $replacement = Start-DnatHarness -Id new -MaxPasses 3
            for ($i = 0; $i -lt 100; $i++) {
                $newOwner = Get-Content -LiteralPath (Join-Path $state 'owner') -Raw -ErrorAction SilentlyContinue
                if ($newOwner -and $newOwner -ne $oldOwner) { break }
                Start-Sleep -Milliseconds 25
            }
            $newOwner | Should -Not -Be $oldOwner
            Remove-Item -LiteralPath $ruleState -Force

            $replacement.WaitForExit(10000) | Should -BeTrue
            $replacement.ExitCode | Should -Be 0
            $process.WaitForExit(10000) | Should -BeTrue
            $process.ExitCode | Should -Be 0

            [int](Get-Content -LiteralPath $ssCount -Raw) | Should -BeGreaterThan 3
            Test-Path -LiteralPath $k3sStarted | Should -BeTrue
            $iptables = Get-Content -LiteralPath $iptablesLog
            @($iptables | Where-Object {
                $_ -match '^new .* -I PREROUTING 1 -d 192\.168\.1\.20 -p udp --dport 7782 -j DNAT --to-destination 203\.0\.113\.10'
            }).Count | Should -Be 1
            @($iptables | Where-Object {
                $_ -match '^old .* -I PREROUTING .*--dport 7782 '
            }).Count | Should -Be $oldInsertBefore
        } finally {
            if ($replacement -and -not $replacement.HasExited) { $replacement.Kill($true) }
            if ($process -and -not $process.HasExited) { $process.Kill($true) }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
