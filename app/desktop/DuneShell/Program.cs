using System.Windows.Forms;

namespace DuneShell;

internal static class Program
{
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
    /// </summary>
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        string? url = GetArgValue(args, "--url");
        bool useWaitFile = !HasFlag(args, "--no-wait-file");

        Application.Run(new MainForm(url, useWaitFile));
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
