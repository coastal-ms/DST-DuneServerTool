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
SCRIPT
sudo() { "$@"; }
kubectl() {
  case "$*" in
    *jsonpath*) printf '%s' Stopped ;;
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
