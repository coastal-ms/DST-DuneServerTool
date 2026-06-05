using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DstFriendHelper;

/// <summary>
/// Friend-side configuration. Loaded from <c>config.json</c> sitting next
/// to the published .exe. The friend edits this once after dropping in the
/// .exe; the helper re-reads it on every launch.
/// </summary>
public sealed class FriendConfig
{
    [JsonPropertyName("bridgeHost")]
    public string BridgeHost { get; init; } = string.Empty;

    [JsonPropertyName("bridgePort")]
    public int BridgePort { get; init; } = 47900;

    [JsonIgnore]
    public string BridgeUrl => $"http://{BridgeHost}:{BridgePort}";

    public static FriendConfig LoadOrThrow()
    {
        var path = ResolveConfigPath();
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"config.json not found at {path}. " +
                "Copy config.sample.json -> config.json and set bridgeHost to Neil's Tailscale hostname.",
                path);
        }

        var json = File.ReadAllText(path);
        var cfg = JsonSerializer.Deserialize<FriendConfig>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        }) ?? throw new InvalidDataException("config.json parsed to null.");

        if (string.IsNullOrWhiteSpace(cfg.BridgeHost))
        {
            throw new InvalidDataException("config.json: bridgeHost is required.");
        }
        if (cfg.BridgePort <= 0 || cfg.BridgePort > 65535)
        {
            throw new InvalidDataException($"config.json: bridgePort {cfg.BridgePort} is out of range.");
        }

        return cfg;
    }

    private static string ResolveConfigPath()
    {
        // Resolve relative to the executable, not the current working directory.
        // AppContext.BaseDirectory is the correct API under PublishSingleFile
        // (Assembly.Location returns an empty string there).
        var baseDir = AppContext.BaseDirectory;
        if (string.IsNullOrEmpty(baseDir))
        {
            baseDir = Directory.GetCurrentDirectory();
        }
        return Path.Combine(baseDir, "config.json");
    }
}
