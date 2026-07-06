# Regression coverage for the "Battlegroup Info" raw-output pane column drift.
#
# Funcom's `battlegroup status` script awk-parses a positional row, so a server
# TITLE containing spaces or a comma (e.g. "Dune, my Arrakis") shifts the Status
# cell (and every column after it) — the raw-output pane then shows the second
# word of the name where the status should be. The Info *panel* is already
# rebuilt from the Battlegroup CRD JSON (v12.16.1); Repair-DuneBgInfoRawOutput
# also rewrites the drifted row in the raw text from those canonical values so
# the debug pane reads correctly, tagging it "(DST-corrected)".

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Status.ps1'

    $script:Info = @{ status = 'Healthy'; database = 'Healthy'; gateway = 'Running'; director = 'Ready'; uptime = '3d4h' }

    # Extract the single data row under the "Battlegroup Info" header.
    function Get-InfoRow {
        param([string] $Text)
        $lines = $Text -split "`r?`n"
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match '^\s*Battlegroup Info\s*$') { return $lines[$i + 3] }
        }
        return $null
    }
}

Describe 'Repair-DuneBgInfoRawOutput' {
    It 'rewrites a drifted row from JSON and marks it corrected' {
        # Multi-word title "Dune, my Arrakis" -> Funcom puts "my" in the Status cell.
        $drifted = @"
Battlegroup: sh-abc123
Battlegroup Info
Status     Database   Gateway    Director   Uptime
---------- ---------- ---------- ---------- --------
my         Healthy    Running    Ready      3d4h
Game Servers
"@
        $out = Repair-DuneBgInfoRawOutput -Text $drifted -Info $script:Info
        $row = Get-InfoRow -Text $out

        $row | Should -Match 'DST-corrected'
        # Each canonical value lands under its own column header.
        $vals = @(Get-BgRowValues -Line $row -Cols (Get-BgColumnSpans -Header 'Status     Database   Gateway    Director   Uptime' -Dashes '---------- ---------- ---------- ---------- --------'))
        $vals[0] | Should -Be 'Healthy'
        $vals[1] | Should -Be 'Healthy'
        $vals[2] | Should -Be 'Running'
        $vals[3] | Should -Be 'Ready'
    }

    It 'leaves an already-correct row verbatim (no marker)' {
        $clean = @"
Battlegroup: sh-abc123
Battlegroup Info
Status     Database   Gateway    Director   Uptime
---------- ---------- ---------- ---------- --------
Healthy    Healthy    Running    Ready      3d4h
"@
        $out = Repair-DuneBgInfoRawOutput -Text $clean -Info $script:Info
        $out | Should -Be ($clean -replace "`r`n", "`n")
        $out | Should -Not -Match 'DST-corrected'
    }

    It 'returns text unchanged when JSON info is absent' {
        $drifted = "Battlegroup Info`nStatus     Database`n---------- ----------`nmy         Healthy"
        Repair-DuneBgInfoRawOutput -Text $drifted -Info $null | Should -Be $drifted
    }

    It 'does nothing when there is no Battlegroup Info table' {
        $text = "Battlegroup: sh-abc123`nNo resources found in namespace"
        Repair-DuneBgInfoRawOutput -Text $text -Info $script:Info | Should -Be $text
    }
}
