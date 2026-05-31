using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DuneShell;

internal sealed class MainForm : Form
{
    private readonly WebView2 _web = new();
    private readonly MenuStrip _menu = new();
    private readonly Label _status = new();

    private readonly string? _initialUrl;
    private readonly bool _useWaitFile;

    private bool _firstLoadDone;

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

        FormClosing += (_, _) => SaveWindowState();

        // Add order matters for docking: the Fill controls (WebView, status)
        // must sit BEHIND the Top-docked menu so the menu reserves the top
        // strip instead of the WebView painting underneath it.
        BuildWebView();
        BuildStatus();
        BuildMenu();

        Load += async (_, _) => await InitializeAsync();
    }

    private void BuildMenu()
    {
        _menu.RenderMode = ToolStripRenderMode.System;

        var serverHealth = new ToolStripMenuItem("Server Health");
        serverHealth.Click += (_, _) => NavigateRoute("/");

        var settings = new ToolStripMenuItem("Settings");
        settings.Click += (_, _) => NavigateRoute("/settings");

        var view = new ToolStripMenuItem("View");
        var reload = new ToolStripMenuItem("Reload") { ShortcutKeys = Keys.F5 };
        reload.Click += (_, _) => _web.CoreWebView2?.Reload();
        var openExternal = new ToolStripMenuItem("Open in browser");
        openExternal.Click += (_, _) =>
        {
            var src = _web.Source?.ToString();
            if (!string.IsNullOrEmpty(src)) OpenExternal(src);
        };
        view.DropDownItems.Add(reload);
        view.DropDownItems.Add(openExternal);

        _menu.Items.Add(serverHealth);
        _menu.Items.Add(settings);
        _menu.Items.Add(view);

        MainMenuStrip = _menu;
        Controls.Add(_menu);
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
        core.DocumentTitleChanged += (_, _) =>
        {
            var t = core.DocumentTitle;
            Text = string.IsNullOrWhiteSpace(t) ? "Dune Server Tool" : $"{t} — Dune Server Tool";
        };

        _web.Source = new Uri(url);
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (_firstLoadDone) return;
        _firstLoadDone = true;
        _status.Visible = false;
        _web.Visible = true;
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        // window.open / target=_blank: keep loopback (the portal itself) in the
        // shell, send everything else (websites, dune-admin web UI) to the OS browser.
        e.Handled = true;
        if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var u))
        {
            if (u.IsLoopback)
                _web.CoreWebView2?.Navigate(e.Uri);
            else
                OpenExternal(e.Uri.ToString());
        }
    }

    /// <summary>
    /// Navigate within the SPA without a server round-trip. The portal uses
    /// react-router BrowserRouter, so pushState + a synthetic popstate makes it
    /// switch routes client-side — no dependency on server SPA fallback.
    /// </summary>
    private async void NavigateRoute(string path)
    {
        var core = _web.CoreWebView2;
        if (core == null) return;
        string js =
            "(function(){try{history.pushState({},'','" + path + "');" +
            "window.dispatchEvent(new PopStateEvent('popstate'));}catch(e){location.pathname='" + path + "';}})();";
        await core.ExecuteScriptAsync(js);
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
            bounds = new Rectangle(saved.X, saved.Y, saved.W, saved.H);
            if (!IsOnAnyScreen(bounds))
                bounds = CenteredDefault(def);
        }
        else
        {
            bounds = CenteredDefault(def);
        }

        Bounds = bounds;
        if (saved?.Max == true)
            WindowState = FormWindowState.Maximized;
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

    private static bool IsOnAnyScreen(Rectangle bounds)
    {
        foreach (var s in Screen.AllScreens)
            if (s.WorkingArea.IntersectsWith(bounds))
                return true;
        return false;
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
}
