BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:phasePatch = Join-Path (Get-DstRepoRoot) 'app/resources/remote-scripts/reconcile-battlegroup-phase.sh'
}
Describe 'Battlegroup phase with spaced display names' {
    It 'reads the real phase, preserves the original script and is idempotent' {
        $bash = 'C:/Program Files/Git/bin/bash.exe'
        if (-not (Test-Path $bash)) { Set-ItResult -Skipped -Because 'Git Bash unavailable'; return }
        $patch = [IO.File]::ReadAllText($script:phasePatch).Replace('target=$(readlink -f /home/dune/.dune/bin/battlegroup)', 'target="$fixture"')
        $fixture = @'
set -eu
fixture=$(mktemp)
cat > "$fixture" <<'SCRIPT'
#!/bin/bash
bgname=world
BATTLEGROUP_PREFIX=namespace-
phase=$(sudo kubectl get battlegroup "$bgname" -n "$BATTLEGROUP_PREFIX$bgname" --no-headers 2>/dev/null | awk '{print $3}')
printf '%s\n' "$phase"
wait_for_battlegroup_stopped() {
        local timeout=90 elapsed=0 phase
        while [ "$elapsed" -lt "$timeout" ]; do
                phase=$(sudo kubectl get battlegroup "$bgname" -n "$BATTLEGROUP_PREFIX$bgname" -o jsonpath='{.status.phase}' 2>/dev/null)
                if [ "$phase" = Stopped ]; then return 0; fi
                elapsed=$((elapsed + 5))
        done
        printf 'WARNING: battlegroup %s did not report %s within %ss' "$bgname" Stopped "$timeout" >&2
}
SCRIPT
sudo() { "$@"; }
kubectl() {
  case "$*" in
    *jsonpath*) printf '%s' "${FIXTURE_PHASE:-Stopped}" ;;
    *) printf '%s\n' 'world DST Official Stopped' ;;
  esac
}
export -f sudo kubectl
test "$(bash "$fixture")" = Official
reconcile() (
__PATCH__
)
reconcile
test "$(bash "$fixture")" = Stopped
grep -q 'local timeout=360' "$fixture"
test "$(grep -c 'return 1' "$fixture")" -eq 1
bash -c '. "$1" >/dev/null; wait_for_battlegroup_stopped' fixture "$fixture"
if FIXTURE_PHASE=Reconciling bash -c '. "$1" >/dev/null; wait_for_battlegroup_stopped' fixture "$fixture"; then
    echo 'Stop timeout incorrectly returned success' >&2
    exit 1
fi
reconcile
test "$(bash "$fixture")" = Stopped
test "$(find "$(dirname "$fixture")" -maxdepth 1 -name "$(basename "$fixture").dst-before-phase-*" | wc -l)" -eq 1
grep -q -- '--no-headers' "$fixture".dst-before-phase-*
rm -f "$fixture" "$fixture".dst-before-phase-*
echo FIXTURE_OK
'@
        $info = [Diagnostics.ProcessStartInfo]::new($bash)
        $info.ArgumentList.Add('-s')
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $process.StandardInput.Write(($fixture.Replace('__PATCH__', $patch) -replace "`r", ''))
            $process.StandardInput.Close()
            $out = $process.StandardOutput.ReadToEnd()
            $err = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because $err
            $out | Should -Match 'FIXTURE_OK'
        } finally { $process.Dispose() }
    }
}
