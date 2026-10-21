BeforeAll {
    $source = Join-Path $PSScriptRoot '../app/desktop/DuneShell/WidgetWindowPlacement.cs'
    $project = Join-Path $TestDrive 'placement'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    $escapedSource = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($source))
    @"
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup><ItemGroup><Compile Include="$escapedSource" Link="WidgetWindowPlacement.cs" /></ItemGroup></Project>
"@ | Set-Content (Join-Path $project 'PlacementProbe.csproj')
    @'
using System.Diagnostics;
using System.Drawing;
using System.Text.Json;
using DuneShell;
if (args.Length > 0) {
    var loaded = WidgetWindowPlacement.Load(args[0]);
    Console.Write(JsonSerializer.Serialize(new { loaded?.X, loaded?.Y, W = loaded?.Width, H = loaded?.Height }));
    return;
}
var root = Path.Combine(Path.GetTempPath(), "dst-widget-placement-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try {
    var widget = Path.Combine(root, "shell-widget.json");
    var full = Path.Combine(root, "shell-window.json");
    var fullState = "original full-window settings";
    File.WriteAllText(full, fullState);
    var missing = WidgetWindowPlacement.Load(widget) is null;
    var first = new Rectangle(-1200, 80, 620, 320);
    WidgetWindowPlacement.Save(widget, first);
    var negativeMonitorPosition = WidgetWindowPlacement.Load(widget) == first;
    var resized = new Rectangle(400, 150, 500, 270);
    WidgetWindowPlacement.Save(widget, resized);
    var start = new ProcessStartInfo("dotnet") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
    start.ArgumentList.Add(typeof(WidgetWindowPlacement).Assembly.Location);
    start.ArgumentList.Add(widget);
    using var child = Process.Start(start)!;
    var json = child.StandardOutput.ReadToEnd();
    child.WaitForExit();
    var state = JsonDocument.Parse(json).RootElement;
    var afterRestart = child.ExitCode == 0 && state.GetProperty("W").GetInt32() == 500 && state.GetProperty("H").GetInt32() == 270 && state.GetProperty("X").GetInt32() == 400;
    var fullUnchanged = File.ReadAllText(full) == fullState;
    var management = new Rectangle(-2054, 70, 2035, 1195);
    var migrated = WidgetWindowPlacement.Resolve(management, management);
    var legacyFullFrame = migrated.Width == 740 && migrated.Height == 285;
    var resizedPreserved = WidgetWindowPlacement.Resolve(resized, management) == resized;
    WidgetWindowPlacement.Save(widget, new Rectangle(0, 0, 1, 1));
    var ignoresMinimizedBounds = WidgetWindowPlacement.Load(widget) == resized;
    File.WriteAllText(widget, "broken");
    var corrupt = WidgetWindowPlacement.Load(widget) is null;
    File.WriteAllText(widget, "{\"W\":0,\"H\":0}");
    var invalid = WidgetWindowPlacement.Load(widget) is null;
    Console.Write(JsonSerializer.Serialize(new { missing, negativeMonitorPosition, afterRestart, fullUnchanged, legacyFullFrame, resizedPreserved, ignoresMinimizedBounds, corrupt, invalid }));
} finally { Directory.Delete(root, true); }
'@ | Set-Content (Join-Path $project 'Program.cs')
    $output = & dotnet run --project (Join-Path $project 'PlacementProbe.csproj') --configuration Release --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "Widget placement probe failed: $output" }
    $script:PlacementResult = ($output | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
}
Describe 'Durable independent Widget placement' {
    It 'restores the last resized bounds in a fresh process' { $script:PlacementResult.afterRestart | Should -BeTrue }
    It 'migrates an inherited management frame and preserves intentional Widget resizes' {
        $script:PlacementResult.legacyFullFrame | Should -BeTrue
        $script:PlacementResult.resizedPreserved | Should -BeTrue
    }
    It 'preserves valid secondary-monitor positions' { $script:PlacementResult.negativeMonitorPosition | Should -BeTrue }
    It 'does not overwrite full-window state' { $script:PlacementResult.fullUnchanged | Should -BeTrue }
    It 'rejects minimized or invalid dimensions' {
        $script:PlacementResult.ignoresMinimizedBounds | Should -BeTrue
        $script:PlacementResult.invalid | Should -BeTrue
    }
    It 'falls back safely for missing or corrupt settings' {
        $script:PlacementResult.missing | Should -BeTrue
        $script:PlacementResult.corrupt | Should -BeTrue
    }
}
