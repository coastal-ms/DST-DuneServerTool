#requires -RunAsAdministrator
# Navigates the Dune Server window through every v6 page and captures each
# via Capture-One.ps1. Must run elevated to reach the elevated app's UIA tree.

Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$p = Get-Process pwsh, DuneServer -EA SilentlyContinue |
        Where-Object MainWindowTitle -eq 'Dune Server' | Select-Object -First 1
if (-not $p) { Write-Error "Dune Server window not found"; pause; exit 1 }

$root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)

# Pages: order matters — Terminal output may linger from prior nav so capture it
# last in its group; Characters waits longer for async DB load to settle.
$pages = @(
    @{ id='NavDashboard';    name='dashboard'    ; wait=2 },
    @{ id='NavMonitoring';   name='monitoring'   ; wait=3 },
    @{ id='NavTerminal';     name='terminal'     ; wait=2 },
    @{ id='NavCharacters';   name='characters'   ; wait=6 },
    @{ id='NavGameConfig';   name='gameconfig'   ; wait=4 },
    @{ id='NavDatabase';     name='database'     ; wait=3 },
    @{ id='NavSettings';     name='settings'     ; wait=2 },
    @{ id='NavSetupWizard';  name='setup-wizard' ; wait=2 },
    @{ id='NavExperimental'; name='multi-sietch' ; wait=2 }
)

foreach ($pg in $pages) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $pg.id)
    $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $el) { Write-Warning "Not found: $($pg.id)"; continue }

    $sip = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $sip.Select()
    Start-Sleep -Seconds $pg.wait

    & "$PSScriptRoot\Capture-One.ps1" -Name $pg.name
}

Write-Host "=== All 9 pages captured ==="
Start-Sleep 2
