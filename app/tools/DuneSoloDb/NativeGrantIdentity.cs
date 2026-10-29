using System.Globalization;
using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text.Json;

namespace DuneSoloDb;

internal static partial class Program
{
    // Local launcher binding only. Never included in public diagnostics.
    private static object ReadNativeGrantIdentity(string input)
    {
        var bytes = ReadStable(input);
        var inspection = InspectBytes(bytes, input);
        EnsureWritableInspection(inspection);
        var backpack = inspection.Inventories.Single(value => value.Kind == "backpack");
        var file = Path.Combine(Path.GetTempPath(), $"dst-native-identity-{Guid.NewGuid():N}.sqlite");
        try
        {
            File.WriteAllBytes(file, Unwrap(bytes).SqliteBytes);
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder {
                DataSource = file, Mode = SqliteOpenMode.ReadOnly, Pooling = false
            }.ToString());
            db.Open();
            using var command = db.CreateCommand();
            command.CommandText = "SELECT account_id, player_controller_id, character_name FROM player_state;";
            using var reader = command.ExecuteReader();
            if (!reader.Read()) throw new InvalidDataException("Solo character is unavailable.");
            var account = reader.GetInt64(0).ToString(CultureInfo.InvariantCulture);
            var controller = reader.GetInt64(1).ToString(CultureInfo.InvariantCulture);
            var name = reader.GetString(2);
            if (reader.Read()) throw new InvalidDataException("Choose a save containing one Solo character.");
            return new { ok = true, accountId = account, controllerId = controller, characterName = name,
                backpackKey = backpack.Key };
        }
        finally { if (File.Exists(file)) File.Delete(file); }
    }

    private static void SelfTestNativeGrantIdentity(string root, string source)
    {
        var raw = Path.Combine(root, "native-identity.sqlite");
        var wrapped = Path.Combine(root, "native-identity.db");
        File.WriteAllBytes(raw, Unwrap(File.ReadAllBytes(source)).SqliteBytes);
        using (var db = new SqliteConnection($"Data Source={raw};Pooling=False"))
        {
            db.Open();
            ExecuteNonQuery(db, "ALTER TABLE player_state ADD COLUMN account_id INTEGER NOT NULL DEFAULT 9007199254740993;");
            ExecuteNonQuery(db, "ALTER TABLE player_state ADD COLUMN character_name TEXT NOT NULL DEFAULT 'Solo';");
        }
        WrapSqlite(raw, wrapped);
        var before = SHA256.HashData(File.ReadAllBytes(wrapped));
        var result = JsonSerializer.SerializeToElement(ReadNativeGrantIdentity(wrapped));
        if (result.GetProperty("accountId").GetString() != "9007199254740993"
            || result.GetProperty("controllerId").GetString() != "11"
            || result.GetProperty("characterName").GetString() != "Solo"
            || !result.GetProperty("backpackKey").GetString()!.StartsWith("inventory:")
            || !before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(wrapped))))
            throw new InvalidOperationException("Native identity read changed the save or lost character identity precision.");
    }
}
