using System.Text.Json;

namespace DuneShell;

internal sealed class ShellPreferences
{
    public const int CurrentSchemaVersion = 1;

    public int SchemaVersion { get; set; } = CurrentSchemaVersion;
    public bool SoftwareRendering { get; set; }
}

internal static class ShellPreferencesStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DuneServer",
        "shell-settings.json");

    public static ShellPreferences Load()
    {
        string path = SettingsPath;
        if (!File.Exists(path)) return new ShellPreferences();

        string json = File.ReadAllText(path);
        var preferences = JsonSerializer.Deserialize<ShellPreferences>(json, JsonOptions)
            ?? throw new InvalidDataException("The shell settings file is empty.");

        if (preferences.SchemaVersion != ShellPreferences.CurrentSchemaVersion)
        {
            throw new InvalidDataException(
                $"Unsupported shell settings schema {preferences.SchemaVersion}. " +
                $"Expected {ShellPreferences.CurrentSchemaVersion}.");
        }

        return preferences;
    }

    public static void Save(ShellPreferences preferences)
    {
        preferences.SchemaVersion = ShellPreferences.CurrentSchemaVersion;

        string path = SettingsPath;
        string directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("Could not resolve the shell settings directory.");
        Directory.CreateDirectory(directory);

        string stagingPath = path + ".new";
        try
        {
            File.WriteAllText(stagingPath, JsonSerializer.Serialize(preferences, JsonOptions));
            File.Move(stagingPath, path, overwrite: true);
        }
        finally
        {
            try
            {
                if (File.Exists(stagingPath)) File.Delete(stagingPath);
            }
            catch
            {
                // Preserve the original write error; a stale staging file is harmless.
            }
        }
    }
}
