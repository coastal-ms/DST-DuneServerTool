using System.Diagnostics;
using System.Drawing;
using System.Net.Http;
using System.Text;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DuneShell;

internal sealed class MainForm : Form
{
    private readonly WebView2 _web = new();
    private readonly Label _status = new();

    private readonly string? _initialUrl;
    private readonly bool _useWaitFile;

    private bool _firstLoadDone;
    private string? _targetUrl;
    private int _navRetries;
    private const int MaxNavRetries = 20;

    public MainForm(string? initialUrl, bool useWaitFile)
    {
        _initialUrl = initialUrl;
        _useWaitFile = useWaitFile;

        Text = "Dune Server Tool";
        MinimumSize = new Size(960, 600);
        // Restore the last window size/position; default to 2000x1100 centered
        // on first run. The window stays freely resizable and its bounds are
        // saved on close so they persist across launches.
        StartPosition = FormStartPosition.Manual;
        ApplyStartupBounds();
        BackColor = Color.FromArgb(17, 19, 24);
        TryLoadIcon();

        FormClosing += (_, _) =>
        {
            SaveWindowState();
            StopCompanionProcesses();
        };

        // The React portal owns its own top menu bar, so the native window has
        // just the WebView and a transient status label — no MenuStrip.
        BuildWebView();
        BuildStatus();

        Load += async (_, _) => await InitializeAsync();
    }

    private void BuildStatus()
    {
        _status.Dock = DockStyle.Fill;
        _status.TextAlign = ContentAlignment.MiddleCenter;
        _status.ForeColor = Color.Gainsboro;
        _status.Font = new Font(FontFamily.GenericSansSerif, 11f);
        _status.Text = "Connecting to Dune Server Tool…";
        Controls.Add(_status);
    }

    private void BuildWebView()
    {
        _web.Dock = DockStyle.Fill;
        _web.Visible = false;
        Controls.Add(_web);
    }

    private async Task InitializeAsync()
    {
        string? url = await ResolveUrlAsync();
        if (string.IsNullOrWhiteSpace(url))
        {
            _status.Text = "Could not find the Dune Server Tool URL.\r\n" +
                           "Start the server first, then reopen this window.";
            return;
        }

        try
        {
            string userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DuneServer", "WebView2");
            Directory.CreateDirectory(userData);

            var env = await CoreWebView2Environment.CreateAsync(null, userData);
            await _web.EnsureCoreWebView2Async(env);
        }
        catch (Exception ex)
        {
            _status.Text = "WebView2 failed to initialize.\r\n" + ex.Message;
            return;
        }

        var core = _web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = true;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDevToolsEnabled = false;

        core.NewWindowRequested += OnNewWindowRequested;
        core.NavigationCompleted += OnNavigationCompleted;
        core.WebMessageReceived += OnWebMessageReceived;
        core.DocumentTitleChanged += (_, _) =>
        {
            var t = core.DocumentTitle;
            Text = string.IsNullOrWhiteSpace(t) ? "Dune Server Tool" : $"{t} — Dune Server Tool";
        };

        _web.Source = new Uri(url);
        _targetUrl = url;
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (_firstLoadDone) return;

        if (e.IsSuccess)
        {
            _firstLoadDone = true;
            _navRetries = 0;
            _status.Visible = false;
            _web.Visible = true;
            return;
        }

        // Navigation failed at the transport level (IsSuccess == false means the
        // request never got an HTTP response — typically CannotConnect /
        // ConnectionAborted because the WebView started a moment before the
        // HttpListener was accepting). A real server error page would still be a
        // *successful* navigation. So retry a bounded number of times instead of
        // leaving the user staring at a permanent "can't reach this page".
        if (_navRetries < MaxNavRetries && !string.IsNullOrWhiteSpace(_targetUrl))
        {
            _navRetries++;
            _status.Visible = true;
            _web.Visible = false;
            _status.Text = $"Connecting to Dune Server Tool… (attempt {_navRetries})";
            await Task.Delay(600);
            try { _web.CoreWebView2?.Navigate(_targetUrl); }
            catch { /* surfaces on the next NavigationCompleted */ }
            return;
        }

        // Out of retries: reveal whatever loaded so the user sees the error page
        // and can F5 / Reload manually.
        _firstLoadDone = true;
        _status.Visible = false;
        _web.Visible = true;
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        // window.open / target=_blank routing:
        //   * Same-origin as the portal's own URL (loopback + same port) -> keep
        //     in this shell. Covers in-portal "open in new tab" flows like the
        //     updater's safe-to-close page or any future window.open from React.
        //   * Anything else, including OTHER loopback ports (e.g. dune-admin's
        //     own HTTP port via the iframe's "Open in browser" link, or any
        //     localhost game-tool URL) -> hand to the OS default browser. Just
        //     checking `IsLoopback` here was too broad and caused dune-admin's
        //     "Open in browser" to navigate the shell off the portal instead.
        e.Handled = true;
        if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var u)) return;

        bool keepInShell = false;
        if (u.IsLoopback &&
            Uri.TryCreate(_targetUrl, UriKind.Absolute, out var portal) &&
            portal.IsLoopback &&
            u.Port == portal.Port &&
            string.Equals(u.Scheme, portal.Scheme, StringComparison.OrdinalIgnoreCase))
        {
            keepInShell = true;
        }

        if (keepInShell)
            _web.CoreWebView2?.Navigate(e.Uri);
        else
            OpenExternal(e.Uri.ToString());
    }

    /// <summary>
    /// Bridge for the "Web Portal" sidebar button. The React UI posts a JSON
    /// message {"action":"open-and-close","url":"http://127.0.0.1:..."} after
    /// calling /api/portal/open-in-browser (which sets the server-side detach
    /// flag). We open the URL via Process.Start with UseShellExecute=true so
    /// the OS default browser handles it as a non-elevated process — important
    /// because Chrome/Edge refuse to run from an elevated parent — and then
    /// close ourselves. The elevated DuneServer console keeps running.
    /// </summary>
    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string? action = null;
        string? url = null;
        try
        {
            // The portal sends a JS object via postMessage(obj). For non-string
            // payloads WebView2 exposes the serialized JSON on WebMessageAsJson;
            // TryGetWebMessageAsString() throws InvalidOperationException for
            // object payloads (it only succeeds when JS posts a raw string).
            string? json = e.WebMessageAsJson;
            if (string.IsNullOrWhiteSpace(json))
            {
                // Fallback: a caller that posts a JSON *string* (e.g.
                // postMessage(JSON.stringify(obj))) — read the inner string and
                // re-parse it. Wrapped in try/catch so a plain-text payload
                // doesn't blow up the handler.
                try { json = e.TryGetWebMessageAsString(); } catch { return; }
                if (string.IsNullOrWhiteSpace(json)) return;
            }
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;

            // Unwrap one layer of string-encoded JSON if the caller stringified
            // before posting. WebMessageAsJson returns "\"{\\\"action\\\"...}\""
            // in that case, which parses to a JSON string, not an object.
            if (root.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                string inner = root.GetString() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(inner)) return;
                using var inner_doc = System.Text.Json.JsonDocument.Parse(inner);
                var inner_root = inner_doc.RootElement;
                if (inner_root.ValueKind != System.Text.Json.JsonValueKind.Object) return;
                if (inner_root.TryGetProperty("action", out var ia)) action = ia.GetString();
                if (inner_root.TryGetProperty("url",    out var iu)) url    = iu.GetString();
            }
            else if (root.ValueKind == System.Text.Json.JsonValueKind.Object)
            {
                if (root.TryGetProperty("action", out var a)) action = a.GetString();
                if (root.TryGetProperty("url",    out var u)) url    = u.GetString();
            }
            else
            {
                return;
            }
        }
        catch
        {
            // Malformed payload — ignore. The portal is the only sender so
            // this would mean a code bug rather than user input.
            return;
        }

        if (string.Equals(action, "open-and-close", StringComparison.OrdinalIgnoreCase))
        {
            if (!string.IsNullOrWhiteSpace(url)) OpenExternal(url);
            // Defer the actual close to the next message loop tick so the
            // WebMessageReceived handler can return cleanly first.
            BeginInvoke(new Action(() => { try { Close(); } catch { } }));
        }
    }

    private static void OpenExternal(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch
        {
            // best-effort; ignore launch failures
        }
    }

    private async Task<string?> ResolveUrlAsync()
    {
        if (!string.IsNullOrWhiteSpace(_initialUrl))
            return _initialUrl;

        if (!_useWaitFile)
            return null;

        string file = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DuneServer", "last-url.txt");

        // The launcher writes last-url.txt right before opening the window; poll
        // briefly in case the shell starts a moment ahead of the server.
        for (int i = 0; i < 40; i++)
        {
            try
            {
                if (File.Exists(file))
                {
                    string text = (await File.ReadAllTextAsync(file)).Trim();
                    if (!string.IsNullOrWhiteSpace(text))
                        return text;
                }
            }
            catch
            {
                // file may be mid-write; retry
            }
            await Task.Delay(500);
        }
        return null;
    }

    private void TryLoadIcon()
    {
        try
        {
            string ico = Path.Combine(AppContext.BaseDirectory, "app.ico");
            if (File.Exists(ico))
                Icon = new Icon(ico);
        }
        catch
        {
            // optional; ignore
        }
    }

    // ----- Window size/position persistence ----------------------------------

    private sealed class WinState
    {
        public int X { get; set; }
        public int Y { get; set; }
        public int W { get; set; }
        public int H { get; set; }
        public bool Max { get; set; }
    }

    private static string WindowStateFile => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DuneServer", "shell-window.json");

    private void ApplyStartupBounds()
    {
        var def = new Size(2000, 1196);
        var saved = LoadWindowState();

        Rectangle bounds;
        if (saved != null && saved.W >= MinimumSize.Width && saved.H >= MinimumSize.Height)
        {
            bounds = ClampToVisible(new Rectangle(saved.X, saved.Y, saved.W, saved.H), def);
        }
        else
        {
            bounds = CenteredDefault(def);
        }

        Bounds = bounds;
        if (saved?.Max == true)
            WindowState = FormWindowState.Maximized;
    }

    /// <summary>
    /// Guarantee the restored window lands on a currently-connected monitor with
    /// its title bar reachable. Picks the screen the saved rect overlaps most (or
    /// the primary if it overlaps none — e.g. a monitor was unplugged), shrinks the
    /// window to fit that screen's working area, then nudges it fully inside so no
    /// part — especially the title bar — sits off-screen.
    /// </summary>
    private static Rectangle ClampToVisible(Rectangle bounds, Size def)
    {
        Screen target = BestScreenFor(bounds);
        Rectangle wa = target.WorkingArea;

        int w = Math.Min(bounds.Width, wa.Width);
        int h = Math.Min(bounds.Height, wa.Height);
        if (w < 1 || h < 1) return CenteredDefault(def);

        int x = Math.Min(Math.Max(bounds.X, wa.X), wa.Right - w);
        int y = Math.Min(Math.Max(bounds.Y, wa.Y), wa.Bottom - h);
        return new Rectangle(x, y, w, h);
    }

    private static Screen BestScreenFor(Rectangle bounds)
    {
        Screen best = Screen.PrimaryScreen ?? Screen.AllScreens[0];
        long bestArea = -1;
        foreach (var s in Screen.AllScreens)
        {
            var inter = Rectangle.Intersect(s.WorkingArea, bounds);
            long area = (long)inter.Width * inter.Height;
            if (area > bestArea)
            {
                bestArea = area;
                best = s;
            }
        }
        return best;
    }

    private static Rectangle CenteredDefault(Size desired)
    {
        var wa = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1600, 1000);
        int w = Math.Min(desired.Width, wa.Width);
        int h = Math.Min(desired.Height, wa.Height);
        int x = wa.X + (wa.Width - w) / 2;
        int y = wa.Y + (wa.Height - h) / 2;
        return new Rectangle(x, y, w, h);
    }

    private WinState? LoadWindowState()
    {
        try
        {
            if (!File.Exists(WindowStateFile))
                return null;
            string json = File.ReadAllText(WindowStateFile);
            return System.Text.Json.JsonSerializer.Deserialize<WinState>(json);
        }
        catch
        {
            return null;
        }
    }

    private void SaveWindowState()
    {
        try
        {
            // Persist the *normal* bounds even when maximized/minimized so the
            // restored size is sensible, plus a flag to reopen maximized.
            Rectangle b = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            var st = new WinState
            {
                X = b.X,
                Y = b.Y,
                W = b.Width,
                H = b.Height,
                Max = WindowState == FormWindowState.Maximized
            };
            string dir = Path.GetDirectoryName(WindowStateFile)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(WindowStateFile,
                System.Text.Json.JsonSerializer.Serialize(st));
        }
        catch
        {
            // best-effort; ignore
        }
    }

    /// <summary>
    /// When the portal window closes, also stop the helper processes the user
    /// thinks of as "DST": the elevated PowerShell backend (DuneServer.exe)
    /// and the bundled dune-admin terminal window. Closing the visible window
    /// used to leave both running silently in the background, which surprised
    /// users — especially now that dune-admin can render inside this window
    /// via the in-app embed, removing the last reason to keep its console
    /// window alive separately.
    ///
    /// Order matters:
    ///   1. Ask the backend to shut down gracefully via POST /api/shutdown.
    ///      That endpoint flushes the response, stops the HttpListener, and
    ///      lets the script exit cleanly, releasing its mutex and the
    ///      battlegroup VM is left in a known state.
    ///   2. Kill any dune-admin.exe processes. dune-admin has no graceful
    ///      stop hook, but it's a stateless watcher — terminating it just
    ///      closes the terminal window.
    ///   3. Schedule a short fallback that force-kills DuneServer.exe a few
    ///      seconds later in case the HTTP shutdown didn't take (backend
    ///      hung, port already moved, etc.). The fallback runs on a thread
    ///      pool task so we don't block the UI close.
    ///
    /// Skipped when the shell was launched standalone (`--no-wait-file`):
    /// in that mode the shell wasn't started by the backend launcher and we
    /// must not assume there's a paired DuneServer process to stop.
    /// </summary>
    private void StopCompanionProcesses()
    {
        if (!_useWaitFile) return;

        // Keep-alive opt-out: when the backend wrote keep-alive.flag, the
        // user has registered DST autostart (or launched --headless), and
        // closing the viewer must NOT take the backend + wrapped dune-admin
        // console down with it. They re-attach to the live backend by
        // clicking the shortcut again, and stop it explicitly via the
        // tray's "Quit (stop server)" or the console window. The flag is
        // refreshed live by the backend on startup AND on every autostart
        // toggle, so this reflects current intent rather than launch-time
        // state.
        try
        {
            string keepAliveFlag = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DuneServer", "keep-alive.flag");
            if (File.Exists(keepAliveFlag)) return;
        }
        catch { /* defensive -- fall through to the normal teardown */ }

        // 1) Graceful backend shutdown via the same loopback URL + token the
        //    WebView is using. Send synchronously with a tight timeout so we
        //    don't drag out window close past ~750ms in the worst case.
        try
        {
            string? url = _targetUrl;
            if (string.IsNullOrWhiteSpace(url))
            {
                try
                {
                    string file = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "DuneServer", "last-url.txt");
                    if (File.Exists(file)) url = File.ReadAllText(file).Trim();
                }
                catch { /* fall through to direct kill */ }
            }

            if (!string.IsNullOrWhiteSpace(url) &&
                Uri.TryCreate(url, UriKind.Absolute, out var u))
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(750) };
                var shutdownUri = new Uri(u, "/api/shutdown" + u.Query);
                var content = new StringContent("{}", Encoding.UTF8, "application/json");
                try { _ = http.PostAsync(shutdownUri, content).GetAwaiter().GetResult(); }
                catch { /* expected when listener tears down before responding */ }
            }
        }
        catch { /* best-effort */ }

        // 2) Always terminate dune-admin terminal windows — they have no
        //    graceful stop and are safe to nuke. Two binary names are possible
        //    depending on the dune-admin build (Go binary or wrapper).
        foreach (var name in new[] { "dune-admin", "dune-admin-windows-amd64" })
        {
            try
            {
                foreach (var p in Process.GetProcessesByName(name))
                {
                    try
                    {
                        if (!p.HasExited) p.Kill(entireProcessTree: true);
                    }
                    catch { /* access denied / already gone */ }
                }
            }
            catch { /* defensive */ }
        }

        // 3) Sweep up any remaining DuneServer.exe. If /api/shutdown succeeded
        //    above the process is already gone (or has HasExited=true) and
        //    this is a no-op; if the listener was hung or the token expired,
        //    this is the safety net that guarantees the user's intent ("close
        //    the window, stop the service") actually happens. The name
        //    "DuneServer" is unique to DST so killing by name is safe.
        //
        //    This MUST run synchronously inside FormClosing — scheduling it
        //    on a background Task would not work because our own process
        //    exits within milliseconds of this method returning, killing the
        //    scheduled task before its delay elapses. We skip the current
        //    process defensively in case a future build ever renames our own
        //    exe to something that overlaps.
        try
        {
            int me = Environment.ProcessId;
            foreach (var p in Process.GetProcessesByName("DuneServer"))
            {
                try
                {
                    if (p.Id == me) continue;
                    if (!p.HasExited) p.Kill(entireProcessTree: true);
                }
                catch { /* best-effort */ }
            }
        }
        catch { /* defensive */ }
    }
}
