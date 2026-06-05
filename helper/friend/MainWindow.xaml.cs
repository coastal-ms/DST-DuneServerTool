using System;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace DstFriendHelper;

public partial class MainWindow : Window
{
    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(5),
    };

    private FriendConfig? _config;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += MainWindow_Loaded;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        await ConnectAsync();
    }

    private async void RetryButton_Click(object sender, RoutedEventArgs e)
    {
        await ConnectAsync();
    }

    private async Task ConnectAsync()
    {
        ShowStatus("Connecting to Neil's PC...", "Reading config and probing the bridge over Tailscale.");

        try
        {
            _config ??= FriendConfig.LoadOrThrow();
        }
        catch (Exception ex)
        {
            ShowError("Couldn't read config.json", ex.Message + "\n\nMake sure config.json sits next to the .exe and contains bridgeHost + bridgePort.");
            return;
        }

        TokenResponse token;
        try
        {
            token = await FetchTokenAsync(_config);
        }
        catch (Exception ex)
        {
            ShowError(
                "Can't reach Neil's PC",
                $"Tried {_config.BridgeUrl}/_dst/token but got: {ex.Message}\n\n" +
                "Checklist:\n" +
                "  • Is Tailscale running on this PC?\n" +
                "  • Is Neil's PC online and on the tailnet?\n" +
                "  • Is the DST Friend Helper Bridge running on Neil's PC?");
            return;
        }

        try
        {
            await EnsureWebViewAsync();
        }
        catch (Exception ex)
        {
            ShowError(
                "WebView2 runtime missing",
                $"{ex.Message}\n\nInstall the Microsoft Edge WebView2 Runtime from https://developer.microsoft.com/microsoft-edge/webview2/");
            return;
        }

        // Navigate WebView2 through the bridge using the freshly fetched token.
        // The bridge proxies / -> 127.0.0.1:<DSTport>/ on Neil's PC, and the
        // token query-param is exactly what DST's portal expects to auth.
        var targetUrl = $"{_config.BridgeUrl}/?t={Uri.EscapeDataString(token.Token)}";
        Web.CoreWebView2.Navigate(targetUrl);

        StatusOverlay.Visibility = Visibility.Collapsed;
        Web.Visibility = Visibility.Visible;
    }

    private async Task EnsureWebViewAsync()
    {
        if (Web.CoreWebView2 != null) return;

        // Per-friend isolated user data folder, so the WebView profile doesn't
        // collide with any other Edge install on the friend's PC.
        var userDataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DSTConsole",
            "WebView2");
        Directory.CreateDirectory(userDataDir);

        var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
        await Web.EnsureCoreWebView2Async(env);
    }

    private async Task<TokenResponse> FetchTokenAsync(FriendConfig cfg)
    {
        var url = $"{cfg.BridgeUrl}/_dst/token";
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var json = await Http.GetStringAsync(url, cts.Token);
        var parsed = JsonSerializer.Deserialize<TokenResponse>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        });
        if (parsed is null || string.IsNullOrEmpty(parsed.Token))
        {
            throw new InvalidDataException("Bridge returned empty / malformed token JSON.");
        }
        return parsed;
    }

    private void ShowStatus(string title, string body)
    {
        StatusTitle.Text = title;
        StatusBody.Text = body;
        RetryButton.Visibility = Visibility.Collapsed;
        StatusOverlay.Visibility = Visibility.Visible;
        Web.Visibility = Visibility.Hidden;
    }

    private void ShowError(string title, string body)
    {
        StatusTitle.Text = title;
        StatusBody.Text = body;
        RetryButton.Visibility = Visibility.Visible;
        StatusOverlay.Visibility = Visibility.Visible;
        Web.Visibility = Visibility.Hidden;
    }

    private sealed record TokenResponse(string Url, string Token);
}
