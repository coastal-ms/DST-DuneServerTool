using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DuneShell;

internal static class Program
{
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    private const int SW_RESTORE = 9;

    /// <summary>
    /// Thin native host for the Dune Server Tool web portal.
    ///
    /// Usage:
    ///   DuneShell.exe --url http://127.0.0.1:47823/?t=TOKEN
    ///   DuneShell.exe                (polls %LOCALAPPDATA%\DuneServer\last-url.txt)
    ///
    /// The PowerShell backend (DuneServer) still owns the HTTP server and the
    /// Hyper-V elevation. This shell only renders the portal in a standalone
    /// WebView2 window with a slim native menu; external links and console
    /// commands continue to open outside the window.
    ///
    /// A launch with no arguments (the common case: DuneServer.ps1 never
    /// passes --url) validates last-url.txt is actually reachable before
    /// trusting it, and starts the sibling DuneServer.exe itself if no backend
    /// is running at all — see MainForm.ResolveUrlAsync. That makes a
    /// taskbar-pinned DuneShell.exe (Windows pins the running window's own
    /// exe, not the DuneServer.exe shortcut that launched it) safe to reopen
    /// even after the backend has fully shut down.
    /// </summary>
    [STAThread]
    private static void Main(string[] args)
    {
        // Single-instance: if a DuneShell window is already open (e.g. the user
        // clicked the desktop shortcut again while the server — and its app
        // window — were already running), focus that window instead of opening
        // a second one, then exit.
        using var mutex = new Mutex(true, @"Global\DuneShell-Portal-Window", out bool createdNew);
        if (!createdNew)
        {
            FocusExistingWindow();
            return;
        }

        ApplicationConfiguration.Initialize();

        string? url = GetArgValue(args, "--url");
        bool useWaitFile = !HasFlag(args, "--no-wait-file");

        Application.Run(new MainForm(url, useWaitFile));
        GC.KeepAlive(mutex);
    }

    private static void FocusExistingWindow()
    {
        try
        {
            int me = Environment.ProcessId;
            foreach (var p in Process.GetProcessesByName("DuneShell"))
            {
                if (p.Id == me) continue;
                IntPtr h = p.MainWindowHandle;
                if (h == IntPtr.Zero) continue;
                if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
                SetForegroundWindow(h);
                break;
            }
        }
        catch
        {
            // best-effort; ignore
        }
    }

    private static string? GetArgValue(string[] args, string name)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                return args[i + 1];
            if (args[i].StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                return args[i][(name.Length + 1)..];
        }
        return null;
    }

    private static bool HasFlag(string[] args, string name)
        => args.Any(a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));
}
