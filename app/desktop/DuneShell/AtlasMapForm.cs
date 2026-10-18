using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Drawing;
using System.Windows.Forms;

namespace DuneShell;

internal sealed class AtlasMapForm : Form
{
    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    private readonly Action<string> _openExternal;

    internal AtlasMapForm(Action<string> openExternal)
    {
        _openExternal = openExternal;
        Text = "DD Atlas — Map";
        Size = new Size(1100, 850);
        MinimumSize = new Size(650, 500);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(12, 18, 23);
        MaximizeBox = true;
        ShowInTaskbar = true;
        Controls.Add(_web);
    }

    internal CoreWebView2 Core => _web.CoreWebView2;

    internal async Task InitializeAsync(CoreWebView2Environment environment)
    {
        // Share the parent's profile so account cookies and selection storage
        // remain synchronized, while using a separate non-modal native window.
        await _web.EnsureCoreWebView2Async(environment);
        Core.Settings.IsStatusBarEnabled = false;
        Core.WindowCloseRequested += (_, _) => Close();
        Core.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) &&
                (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
                _openExternal(uri.AbsoluteUri);
        };
    }
}
