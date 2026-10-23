BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'GameConfig.ps1'
    function Invoke-V6Ssh { param($Ip,$Cmd,$TimeoutSec) throw 'Unexpected SSH' }
    function Invoke-DefaultsShellFixture {
        param([string]$Command, [switch]$MissingEngine)
        $bash = 'C:/Program Files/Git/bin/bash.exe'
        if (-not (Test-Path $bash)) { throw 'Git Bash unavailable' }
        $fixture = @'
set -eu
testroot=$(mktemp -d)
calls="$testroot/calls"
kubectl() {
  case "$*" in
    'get battlegroups -A '*) printf namespace-world ;;
    'get pods '*) : ;;
    'get battlegroups -n '*) printf registry.funcom.com/server:current ;;
    *) return 1 ;;
  esac
}
k3s() {
  printf '%s\n' "$*" >> "$calls"
  if [ "$5" = mount ]; then
    test "$#" -eq 7
    mkdir -p "$7/home/dune/server/DuneSandbox/Config"
    printf '%s\n' '[Spice]' 'm_PerMapSystemSettings=(Complete=1)' > "$7/home/dune/server/DuneSandbox/Config/DefaultGame.ini"
    __ENGINE__
  elif [ "$5" = unmount ]; then
    rm -f "$6/home/dune/server/DuneSandbox/Config/DefaultGame.ini" "$6/home/dune/server/DuneSandbox/Config/DefaultEngine.ini"
    rmdir "$6/home/dune/server/DuneSandbox/Config" "$6/home/dune/server/DuneSandbox" "$6/home/dune/server" "$6/home/dune" "$6/home"
  else return 1; fi
}
sudo() { "$@"; }
(
__COMMAND__
)
grep -q 'images mount registry.funcom.com/server:current' "$calls"
grep -q 'images unmount ' "$calls"
rm -f "$calls"
rmdir "$testroot"
'@
        $engine = if ($MissingEngine) { ':' } else { 'printf ''%s\n'' ''[Engine]'' ''Keep=8'' > "$7/home/dune/server/DuneSandbox/Config/DefaultEngine.ini"' }
        $info = [Diagnostics.ProcessStartInfo]::new($bash)
        $info.ArgumentList.Add('-s')
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $process.StandardInput.Write(($fixture.Replace('__ENGINE__', $engine).Replace('__COMMAND__', $Command) -replace "`r", ''))
            $process.StandardInput.Close()
            $out = $process.StandardOutput.ReadToEnd()
            $err = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw "Defaults fixture failed: $err" }
            return $out
        } finally { $process.Dispose() }
    }
}
Describe 'Cold defaults read while the battlegroup is already stopped' {
    BeforeEach {
        $script:DuneApiLockTable = $null
        $script:DuneGameConfigDefaultsGame = $null
        $script:DuneGameConfigDefaultsEngine = $null
    }
    It 'reads the configured installed image without starting a pod or requiring an earlier cached read' {
        Mock Invoke-V6Ssh { Invoke-DefaultsShellFixture -Command $Cmd }
        $result = Get-DuneGameConfigDefaults -Ip '192.0.2.1' -Force
        $result.game | Should -Match 'm_PerMapSystemSettings=\(Complete=1\)'
        $result.engine | Should -Match 'Keep=8'
        $result.source.pod | Should -Be 'image:registry.funcom.com/server:current'
    }
    It 'cleans up its read-only image mount when a defaults file cannot be read' {
        Mock Invoke-V6Ssh { Invoke-DefaultsShellFixture -Command $Cmd -MissingEngine }
        { Get-DuneGameConfigDefaults -Ip '192.0.2.1' -Force } | Should -Throw '*image defaults could not be read*'
    }
}
Describe 'Reviewed local settings preflight' {
    BeforeEach {
        Mock Test-DuneGameClientRunning { $false }
        Mock Get-DuneGameConfigClientEngineEnabled { $false }
    }
    It 'checks a proposed local write without changing the INI or creating backups' {
        $dir = Join-Path $TestDrive 'client'
        [void](New-Item -ItemType Directory -Path $dir)
        $path = Join-Path $dir 'Game.ini'
        [IO.File]::WriteAllText($path, "[Manual]`nKeep=7`n")
        $before = [IO.File]::ReadAllText($path)
        $result = Save-DuneGameConfigClient -Dir $dir -ReviewedRaw -ValidateOnly -Updates @(
            @{file='game';section='Manual';key='Keep';value='8'}
        )
        $result.validated | Should -BeTrue
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
        @(Get-ChildItem $dir -Recurse -File).Count | Should -Be 1
    }
    It 'rejects unavailable full spice defaults in preflight before any local write' {
        $dir = Join-Path $TestDrive 'missing-defaults'
        [void](New-Item -ItemType Directory -Path $dir)
        { Save-DuneGameConfigClient -Dir $dir -ReviewedRaw -ValidateOnly -Updates @(
            @{file='game';section=$script:DuneGcSecSpice;key='DST.SpiceStartup.DeepDesert.Large.Max';value='2'}
        ) } | Should -Throw '*m_PerMapSystemSettings*'
        @(Get-ChildItem $dir -Recurse -File).Count | Should -Be 0
    }
}
Describe 'Defaults retained across the reviewed server stop' {
    BeforeEach {
        $script:DuneApiLockTable = [hashtable]::Synchronized(@{})
        $script:DuneGameConfigDefaultsGame = $null
        $script:DuneGameConfigDefaultsEngine = $null
        $script:DuneGameConfigDefaultsIp = $null
        Mock Invoke-V6Ssh { @('===META===','NS=selected-world','POD=sg-0','===GAME===','[Game]','Keep=7','===ENGINE===','[Engine]','Keep=8','===END===') }
    }
    AfterEach { $script:DuneApiLockTable = $null; $script:DuneGameConfigDefaultsGame = $null; $script:DuneGameConfigDefaultsEngine = $null }
    It 'allows another HTTP worker to use the same verified defaults after pods stop' {
        $first = Get-DuneGameConfigDefaults -Ip '192.0.2.1'
        $script:DuneGameConfigDefaultsGame = $null
        $script:DuneGameConfigDefaultsEngine = $null
        Mock Invoke-V6Ssh { throw 'No running game pod' }
        $next = Get-DuneGameConfigDefaults -Ip '192.0.2.1'
        $next.cached | Should -BeTrue
        $next.game | Should -BeExactly $first.game
        $next.engine | Should -BeExactly $first.engine
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly
        { Get-DuneGameConfigDefaults -Ip '192.0.2.2' } | Should -Throw '*No running game pod*'
    }
    It 'does not reuse an expired shared snapshot' {
        Get-DuneGameConfigDefaults -Ip '192.0.2.1' | Out-Null
        $script:DuneApiLockTable['gameconfig.defaults:192.0.2.1'].fetched = [datetime]::UtcNow.AddMinutes(-11)
        $script:DuneGameConfigDefaultsFetched = [datetime]::UtcNow.AddMinutes(-11)
        Mock Invoke-V6Ssh { throw 'No running game pod' }
        { Get-DuneGameConfigDefaults -Ip '192.0.2.1' } | Should -Throw '*No running game pod*'
    }
}
