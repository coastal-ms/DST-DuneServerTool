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

    // ----- Minimize-to-tray state --------------------------------------------
    // When enabled, minimizing the window hides it (and its taskbar button) and
    // leaves a single NotifyIcon in the system tray that reopens the portal.
    // Closing the window via the X still tears the backend down as before; the
    // tray's "Quit (stops server)" is the explicit shutdown from the tray.
    private NotifyIcon? _tray;
    private ToolStripMenuItem? _trayMinItem;
    private bool _minimizeToTray;
    private bool _trayBalloonShown;
    private FormWindowState _restoreState = FormWindowState.Normal;

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
        BuildTrayIcon();

        Resize += OnResizeToTray;

        FormClosing += (_, _) =>
        {
            SaveWindowState();
            StopCompanionProcesses();
            DisposeTrayIcon();
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
        // v12.0.1: DevTools enabled so users can press F12 and read JS console
        // errors when a page misbehaves. The console output is also captured to
        // %APPDATA%\DuneServer\webview2-debug.log by InitDiagnosticLogging below
        // and bundled into Help -> Create GitHub Issue + Save Logs.
        core.Settings.AreDevToolsEnabled = true;

        core.NewWindowRequested += OnNewWindowRequested;
        core.NavigationCompleted += OnNavigationCompleted;
        core.WebMessageReceived += OnWebMessageReceived;
        core.DocumentTitleChanged += (_, _) =>
        {
            var t = core.DocumentTitle;
            Text = string.IsNullOrWhiteSpace(t) ? "Dune Server Tool" : $"{t} — Dune Server Tool";
        };

        await InitDiagnosticLoggingAsync(core);

        _web.Source = new Uri(url);
        _targetUrl = url;
    }

    // ----- Diagnostic logging -------------------------------------------------
    //
    // v12.0.1: subscribe to WebView2 DevTools Protocol events so unhandled JS
    // exceptions and console.error/warn calls land in
    // %APPDATA%\DuneServer\webview2-debug.log. The diagnostics bundle
    // (Help -> Create GitHub Issue + Save Logs) tails the last 200 KB of that
    // file, which previously was always missing because nothing ever wrote it.
    //
    // We cap the file at WebView2LogMaxBytes and trim from the front on the
    // next write when we exceed it, so a chatty page can't fill the user's
    // disk. Writes are best-effort and silently swallow IO errors.

    private const long WebView2LogMaxBytes = 2L * 1024 * 1024;  // 2 MB cap
    private static readonly object _logLock = new();

    private static string WebView2LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "DuneServer", "webview2-debug.log");

    private async Task InitDiagnosticLoggingAsync(CoreWebView2 core)
    {
        try
        {
            // Runtime.enable is a prerequisite for consoleAPICalled /
            // exceptionThrown events to fire on the protocol channel.
            await core.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}");

            var consoleRecv = core.GetDevToolsProtocolEventReceiver("Runtime.consoleAPICalled");
            consoleRecv.DevToolsProtocolEventReceived += OnConsoleApiCalled;

            var exceptionRecv = core.GetDevToolsProtocolEventReceiver("Runtime.exceptionThrown");
            exceptionRecv.DevToolsProtocolEventReceived += OnRuntimeExceptionThrown;

            core.ProcessFailed += OnProcessFailed;

            AppendDiagnosticLine($"[shell] DST v{typeof(MainForm).Assembly.GetName().Version} logging started; WebView2 runtime {core.Environment.BrowserVersionString}");
        }
        catch (Exception ex)
        {
            // Logging is best-effort. If the DevTools protocol can't be wired
            // (older WebView2 runtime, etc.) the app still works — we just
            // won't capture console output.
            AppendDiagnosticLine($"[shell] failed to wire diagnostic logging: {ex.Message}");
        }
    }

    private void OnConsoleApiCalled(object? sender, CoreWebView2DevToolsProtocolEventReceivedEventArgs e)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(e.ParameterObjectAsJson);
            var root = doc.RootElement;
            string type = root.TryGetProperty("type", out var t) ? (t.GetString() ?? "log") : "log";

            // We only persist console.error / console.warn / console.assert /
            // console.trace — debug / info / log are extremely noisy on a
            // live React page and rarely useful for postmortem analysis.
            bool keep = type is "error" or "warning" or "warn" or "assert" or "trace";
            if (!keep) return;

            var sb = new StringBuilder();
            sb.Append("[console.").Append(type).Append("] ");
            if (root.TryGetProperty("args", out var args) && args.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                bool first = true;
                foreach (var a in args.EnumerateArray())
                {
                    if (!first) sb.Append(' ');
                    first = false;
                    if (a.TryGetProperty("value", out var v))
                        sb.Append(v.ToString());
                    else if (a.TryGetProperty("description", out var d))
                        sb.Append(d.GetString());
                    else
                        sb.Append(a.ToString());
                }
            }
            if (root.TryGetProperty("stackTrace", out var st) &&
                st.TryGetProperty("callFrames", out var cf) &&
                cf.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var frame in cf.EnumerateArray())
                {
                    string fn  = frame.TryGetProperty("functionName", out var f) ? (f.GetString() ?? "") : "";
                    string url = frame.TryGetProperty("url",          out var u) ? (u.GetString() ?? "") : "";
                    int line   = frame.TryGetProperty("lineNumber",   out var l) ? l.GetInt32() : 0;
                    sb.Append("\r\n    at ").Append(string.IsNullOrEmpty(fn) ? "(anonymous)" : fn)
                      .Append(" (").Append(url).Append(':').Append(line + 1).Append(')');
                }
            }
            AppendDiagnosticLine(sb.ToString());
        }
        catch { /* best-effort */ }
    }

    private void OnRuntimeExceptionThrown(object? sender, CoreWebView2DevToolsProtocolEventReceivedEventArgs e)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(e.ParameterObjectAsJson);
            var root = doc.RootElement;
            if (!root.TryGetProperty("exceptionDetails", out var ex)) return;

            var sb = new StringBuilder("[exception] ");
            if (ex.TryGetProperty("text", out var txt)) sb.Append(txt.GetString());
            if (ex.TryGetProperty("exception", out var exo) &&
                exo.TryGetProperty("description", out var exd))
            {
                sb.Append(" :: ").Append(exd.GetString());
            }
            else if (ex.TryGetProperty("exception", out var exo2) &&
                     exo2.TryGetProperty("value", out var exv))
            {
                sb.Append(" :: ").Append(exv.ToString());
            }
            if (ex.TryGetProperty("url",        out var u))  sb.Append("\r\n    url:    ").Append(u.GetString());
            if (ex.TryGetProperty("lineNumber", out var ln)) sb.Append("\r\n    line:   ").Append(ln.GetInt32() + 1);
            if (ex.TryGetProperty("stackTrace", out var st) &&
                st.TryGetProperty("callFrames", out var cf) &&
                cf.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var frame in cf.EnumerateArray())
                {
                    string fn  = frame.TryGetProperty("functionName", out var f) ? (f.GetString() ?? "") : "";
                    string url = frame.TryGetProperty("url",          out var u2) ? (u2.GetString() ?? "") : "";
                    int line   = frame.TryGetProperty("lineNumber",   out var l) ? l.GetInt32() : 0;
                    sb.Append("\r\n    at ").Append(string.IsNullOrEmpty(fn) ? "(anonymous)" : fn)
                      .Append(" (").Append(url).Append(':').Append(line + 1).Append(')');
                }
            }
            AppendDiagnosticLine(sb.ToString());
        }
        catch { /* best-effort */ }
    }

    private void OnProcessFailed(object? sender, CoreWebView2ProcessFailedEventArgs e)
    {
        try
        {
            AppendDiagnosticLine(
                $"[process-failed] kind={e.ProcessFailedKind} reason={e.Reason} exitCode={e.ExitCode} status={e.ProcessDescription}");
        }
        catch { /* best-effort */ }
    }

    private static void AppendDiagnosticLine(string line)
    {
        if (string.IsNullOrEmpty(line)) return;
        try
        {
            string path = WebView2LogPath;
            string dir = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(dir);
            string stamped = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}  {line}\r\n";

            lock (_logLock)
            {
                // Front-trim when over cap so the file behaves like a ring buffer.
                // Keeps the most recent ~half so old context still survives a
                // single noisy burst.
                try
                {
                    var fi = new FileInfo(path);
                    if (fi.Exists && fi.Length > WebView2LogMaxBytes)
                    {
                        long keep = WebView2LogMaxBytes / 2;
                        var bytes = File.ReadAllBytes(path);
                        if (bytes.Length > keep)
                        {
                            int start = (int)(bytes.Length - keep);
                            // Skip to the next line boundary so we don't leave
                            // a half line at the top of the file.
                            for (; start < bytes.Length; start++)
                                if (bytes[start] == (byte)'\n') { start++; break; }
                            File.WriteAllBytes(path, new ArraySegment<byte>(bytes, start, bytes.Length - start).ToArray());
                        }
                    }
                }
                catch { /* best-effort trim */ }

                File.AppendAllText(path, stamped, Encoding.UTF8);
            }
        }
        catch { /* logging must never throw into the caller */ }
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
        //   * Anything else, including OTHER loopback ports (e.g. any
        //     localhost game-tool URL) -> hand to the OS default browser. Just
        //     checking `IsLoopback` here is too broad and can navigate the
        //     shell off the portal instead.
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
        else if (string.Equals(action, "open", StringComparison.OrdinalIgnoreCase))
        {
            // Issue #280: open the portal in the default browser but KEEP this
            // window open. The React UI waits for the browser to check in with
            // the server before asking us to close (a separate "close" message),
            // so a browser that can't reach 127.0.0.1 leaves the user with a
            // working app window + Copy URL fallback instead of a dead window.
            if (!string.IsNullOrWhiteSpace(url)) OpenExternal(url);
        }
        else if (string.Equals(action, "close", StringComparison.OrdinalIgnoreCase))
        {
            // Browser confirmed it reached the server — safe to close now.
            BeginInvoke(new Action(() => { try { Close(); } catch { } }));
        }
        else if (string.Equals(action, "pick-save-file", StringComparison.OrdinalIgnoreCase))
        {
            // Show a native Save As dialog and return the chosen path to the frontend.
            string? id = null;
            string? defaultName = null;
            try
            {
                string? json = e.WebMessageAsJson;
                if (!string.IsNullOrWhiteSpace(json))
                {
                    using var doc2 = System.Text.Json.JsonDocument.Parse(json);
                    var r2 = doc2.RootElement.ValueKind == System.Text.Json.JsonValueKind.String
                        ? System.Text.Json.JsonDocument.Parse(doc2.RootElement.GetString()!).RootElement
                        : doc2.RootElement;
                    if (r2.TryGetProperty("id", out var idProp)) id = idProp.GetString();
                    if (r2.TryGetProperty("defaultName", out var dnProp)) defaultName = dnProp.GetString();
                }
            }
            catch { /* best-effort parse */ }
            BeginInvoke(new Action(() => ShowSaveDialog(id, defaultName)));
        }
        else if (string.Equals(action, "pick-open-file", StringComparison.OrdinalIgnoreCase))
        {
            // Show a native Open File dialog and return the chosen path to the frontend.
            string? id = null;
            string? filter = null;
            try
            {
                string? json = e.WebMessageAsJson;
                if (!string.IsNullOrWhiteSpace(json))
                {
                    using var doc2 = System.Text.Json.JsonDocument.Parse(json);
                    var r2 = doc2.RootElement.ValueKind == System.Text.Json.JsonValueKind.String
                        ? System.Text.Json.JsonDocument.Parse(doc2.RootElement.GetString()!).RootElement
                        : doc2.RootElement;
                    if (r2.TryGetProperty("id", out var idProp)) id = idProp.GetString();
                    if (r2.TryGetProperty("filter", out var fProp)) filter = fProp.GetString();
                }
            }
            catch { /* best-effort parse */ }
            BeginInvoke(new Action(() => ShowOpenDialog(id, filter)));
        }
    }

    // ----- Native file dialog bridge ------------------------------------------
    // The frontend posts "pick-save-file" / "pick-open-file" with an id and
    // optional filter/defaultName. We show the native WinForms dialog and post
    // the result back so the React app can call the backend with a local path.

    private void ShowSaveDialog(string? id, string? defaultName)
    {
        using var dlg = new SaveFileDialog();
        dlg.Title = "Save backup as…";
        dlg.Filter = "Database backups (*.backup)|*.backup|All files (*.*)|*.*";
        if (!string.IsNullOrWhiteSpace(defaultName)) dlg.FileName = defaultName;
        string? chosen = dlg.ShowDialog(this) == DialogResult.OK ? dlg.FileName : null;
        PostFilePickResult(id, chosen);
    }

    private void ShowOpenDialog(string? id, string? filter)
    {
        using var dlg = new OpenFileDialog();
        dlg.Title = "Select backup to upload";
        dlg.Filter = filter ?? "Database backups (*.backup)|*.backup|All files (*.*)|*.*";
        string? chosen = dlg.ShowDialog(this) == DialogResult.OK ? dlg.FileName : null;
        PostFilePickResult(id, chosen);
    }

    private void PostFilePickResult(string? id, string? path)
    {
        if (_web.CoreWebView2 == null) return;
        var payload = new System.Text.Json.Nodes.JsonObject
        {
            ["action"] = "file-picked",
            ["id"] = id,
            ["path"] = path  // null when cancelled
        };
        _web.CoreWebView2.PostWebMessageAsJson(payload.ToJsonString());
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

    // ----- Minimize to tray ---------------------------------------------------
    //
    // A single NotifyIcon, visible for the lifetime of the window, lets the user
    // tuck DST out of the way without stopping the backend. Left-click or
    // double-click reopens; the right-click menu exposes a persisted
    // "Minimize to tray" toggle and an explicit "Quit (stops server)".

    private void BuildTrayIcon()
    {
        try
        {
            var menu = new ContextMenuStrip();

            var open = new ToolStripMenuItem("Open Dune Server Tool", null, (_, _) => RestoreFromTray());
            open.Font = new Font(open.Font, FontStyle.Bold);

            _trayMinItem = new ToolStripMenuItem("Minimize to tray", null, (_, _) => ToggleMinimizeToTray())
            {
                CheckOnClick = true,
                Checked = _minimizeToTray,
            };

            var quit = new ToolStripMenuItem("Quit (stops server)", null, (_, _) => Close());

            menu.Items.Add(open);
            menu.Items.Add(_trayMinItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(quit);

            _tray = new NotifyIcon
            {
                Text = "Dune Server Tool",
                Visible = true,
                ContextMenuStrip = menu,
                Icon = Icon ?? SystemIcons.Application,
            };
            _tray.MouseClick += (_, e) =>
            {
                if (e.Button == MouseButtons.Left) RestoreFromTray();
            };
            _tray.DoubleClick += (_, _) => RestoreFromTray();
        }
        catch
        {
            // tray is a convenience; never block startup on it
        }
    }

    private void OnResizeToTray(object? sender, EventArgs e)
    {
        if (WindowState == FormWindowState.Minimized)
        {
            if (_minimizeToTray) HideToTray();
        }
        else
        {
            // Remember whether to restore to Normal or Maximized later.
            _restoreState = WindowState;
        }
    }

    private void HideToTray()
    {
        ShowInTaskbar = false;
        Hide();

        if (_tray != null && !_trayBalloonShown)
        {
            _trayBalloonShown = true;
            try
            {
                _tray.BalloonTipTitle = "Dune Server Tool";
                _tray.BalloonTipText =
                    "Still running in the tray. Click the icon to reopen, or right-click \u2192 Quit to stop the server.";
                _tray.ShowBalloonTip(4000);
            }
            catch
            {
                // balloon is optional
            }
        }
    }

    private void RestoreFromTray()
    {
        Show();
        ShowInTaskbar = true;
        WindowState = _restoreState == FormWindowState.Minimized
            ? FormWindowState.Normal
            : _restoreState;
        Activate();
    }

    private void ToggleMinimizeToTray()
    {
        // CheckOnClick has already flipped the menu item before this fires.
        _minimizeToTray = _trayMinItem?.Checked ?? false;
        SaveWindowState();
    }

    private void DisposeTrayIcon()
    {
        try
        {
            if (_tray != null)
            {
                _tray.Visible = false;
                _tray.Dispose();
                _tray = null;
            }
        }
        catch
        {
            // best-effort
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
        // Nullable so pre-12.10.1 state files (no field) default to disabled.
        public bool? MinTray { get; set; }
    }

    private static string WindowStateFile => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DuneServer", "shell-window.json");

    private void ApplyStartupBounds()
    {
        var def = new Size(2000, 1300);
        var saved = LoadWindowState();

        _minimizeToTray = saved?.MinTray ?? false;

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
        {
            WindowState = FormWindowState.Maximized;
            _restoreState = FormWindowState.Maximized;
        }
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
                Max = WindowState == FormWindowState.Maximized,
                MinTray = _minimizeToTray
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
    /// When the portal window closes, also stop the helper process the user
    /// thinks of as "DST": the elevated PowerShell backend (DuneServer.exe).
    /// Closing the visible window used to leave it running silently in the
    /// background, which surprised users.
    ///
    /// Order matters:
    ///   1. Ask the backend to shut down gracefully via POST /api/shutdown.
    ///      That endpoint flushes the response, stops the HttpListener, and
    ///      lets the script exit cleanly, releasing its mutex and the
    ///      battlegroup VM is left in a known state.
    ///   2. Sweep any remaining DuneServer.exe processes in case the HTTP
    ///      shutdown didn't take (backend hung, port already moved, etc.).
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
        // closing the viewer must NOT take the backend down with it. They
        // re-attach to the live backend by
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

        // 2) Sweep up any remaining DuneServer.exe. If /api/shutdown succeeded
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
