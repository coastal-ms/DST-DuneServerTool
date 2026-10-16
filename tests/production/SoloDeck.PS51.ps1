param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$FixtureRoot,
    [switch]$UseExistingProbe
)

$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'app\server\lib\SoloDeck.ps1')
$nativeRoot = Join-Path $FixtureRoot 'windows'
$sshFolder = Join-Path $nativeRoot 'System32\OpenSSH'
$null = New-Item -ItemType Directory -Path $sshFolder -Force
# A real child process exercises stdin bytes, EOF and JSON readback without
# using a network connection, private key or game files.
if (-not $UseExistingProbe) {
Add-Type -OutputAssembly (Join-Path $sshFolder 'ssh.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class DeckTransportProbe {
    public static void Main(string[] args) {
        using (var input = Console.OpenStandardInput())
        using (var data = new MemoryStream()) {
            input.CopyTo(data);
            Console.Write("{\"ok\":true,\"inputBase64\":\"" + Convert.ToBase64String(data.ToArray()) + "\"}");
        }
    }
}
'@
}
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'ssh_key'), 'fixture')
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'known_hosts'), 'fixture')
$previousWindows = $env:WINDIR
try {
    $env:WINDIR = $nativeRoot
    # Hosted Windows runners use a UTF-8 console. Its StreamWriter may emit a
    # preamble even on Close; reproduce that independently of the local locale.
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
    # Construct Unicode without depending on the PS5.1 source-file codepage.
    $request = @{action='preview-settings';value=('Deck '+[char]0x00e9+[char]0x6c34)}
    $result = Invoke-DuneSoloDeckReader -Root $FixtureRoot -Connection @{host='192.0.2.1';user='deck';pcAddress='192.0.2.2'} -Command 'dst-settings-v1' -Request $request
    if (@($result).Count -ne 1 -or $result -isnot [pscustomobject]) { throw 'Transport returned internal task output alongside the JSON response.' }
    if ([Convert]::ToBase64String([Console]::InputEncoding.GetPreamble()) -cne '77u/') { throw 'Host input encoding was not restored.' }
    $expected = ConvertTo-Json -InputObject $request -Depth 15 -Compress
    $bytes = [Convert]::FromBase64String($result.inputBase64)
    if ($result.inputBase64 -cne [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected))) { throw 'Transfer request bytes changed.' }
    if ($bytes.Length -gt 2 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Transfer request contains a BOM.' }
    '{"ok":true}'
} finally {
    $env:WINDIR = $previousWindows
}
