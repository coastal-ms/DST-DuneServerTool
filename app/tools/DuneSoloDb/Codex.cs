using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static object GrantCodex(string input, string safetyBackup, string catalogPath, string selectionPath)
    {
        using var catalog = JsonDocument.Parse(File.ReadAllText(catalogPath));
        var entries = catalog.RootElement.GetProperty("fragments").EnumerateArray()
            .ToDictionary(row => row.GetProperty("id").GetString()!, row => row.GetProperty("ancestors")
                .EnumerateArray().Select(parent => parent.GetString()!).ToArray(), StringComparer.Ordinal);
        var allowed = entries.Keys.ToHashSet(StringComparer.Ordinal);
        var selected = JsonSerializer.Deserialize<string[]>(File.ReadAllText(selectionPath))
            ?? throw new InvalidDataException("Choose codex fragments to grant.");
        if (selected.Length == 0 || selected.Length > allowed.Count
            || selected.Distinct(StringComparer.Ordinal).Count() != selected.Length
            || selected.Any(id => id is null || !allowed.Contains(id) || !id.StartsWith("DA_Dunipedia", StringComparison.Ordinal)))
            throw new InvalidDataException("Choose exact supported codex fragments.");
        var ancestors = selected.SelectMany(id => entries[id]).Distinct(StringComparer.Ordinal).ToArray();
        if (selected.Any(id => entries[id].Any(parent => !parent.StartsWith("DA_Dunipedia", StringComparison.Ordinal)
            || !id.StartsWith(parent + ".", StringComparison.Ordinal))))
            throw new InvalidDataException("Codex reveal mappings are invalid.");
        var required = selected.Concat(ancestors).Distinct(StringComparer.Ordinal).ToArray();
        return RunProgressionMutation(input, safetyBackup, "codex", path => {
            using var db = OpenWritable(path);
            var identity = ReadIdentity(db);
            BeginImmediate(db);
            try
            {
                // Reveal only the selected lore path. Never complete parents,
                // prerequisites, rewards or tags; the game derives card totals.
                foreach (var id in required)
                    if (ScalarLong(db, "SELECT COUNT(*) FROM journey_story_node WHERE character_id=$c AND story_node_id=$n;",
                        ("$c", identity.CharacterId), ("$n", id)) != 1)
                        throw new InvalidDataException("A selected fragment is unavailable in this save. No data was changed.");
                var granted = 0;
                foreach (var id in selected)
                    granted += ExecuteNonQuery(db, "UPDATE journey_story_node SET complete_condition_state=jsonb('true'),reveal_condition_state=jsonb('true') WHERE character_id=$c AND story_node_id=$n AND (json(complete_condition_state) IS NOT 'true' OR json(reveal_condition_state) IS NOT 'true');",
                        ("$c", identity.CharacterId), ("$n", id));
                foreach (var id in ancestors)
                    ExecuteNonQuery(db, "UPDATE journey_story_node SET reveal_condition_state=jsonb('true') WHERE character_id=$c AND story_node_id=$n AND json(reveal_condition_state) IS NOT 'true';",
                        ("$c", identity.CharacterId), ("$n", id));
                foreach (var id in selected)
                    if (ScalarLong(db, "SELECT COUNT(*) FROM journey_story_node WHERE character_id=$c AND story_node_id=$n AND json(complete_condition_state)='true' AND json(reveal_condition_state)='true';",
                        ("$c", identity.CharacterId), ("$n", id)) != 1)
                        throw new InvalidDataException("Codex grant verification failed.");
                foreach (var id in ancestors)
                    if (ScalarLong(db, "SELECT COUNT(*) FROM journey_story_node WHERE character_id=$c AND story_node_id=$n AND json(reveal_condition_state)='true';",
                        ("$c", identity.CharacterId), ("$n", id)) != 1)
                        throw new InvalidDataException("Codex reveal verification failed.");
                ValidateDatabase(db);
                Commit(db);
                return new { granted, selected = selected.Length };
            }
            catch { Rollback(db); throw; }
        }, requireGameClosed: true);
    }

    private static object ReadCodex(string input)
    {
        var bytes = ReadStable(input);
        var inspection = InspectBytes(bytes, input);
        if (inspection.CharacterCount != 1)
            throw new InvalidDataException("Codex reading requires exactly one Solo character.");
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-codex-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "snapshot.sqlite");
            File.WriteAllBytes(path, Unwrap(bytes).SqliteBytes);
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder {
                DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false
            }.ToString());
            db.Open();
            ExecuteNonQuery(db, "PRAGMA query_only=ON;");
            if (!TableExists(db, "journey_story_node"))
                throw new InvalidDataException("Codex records are unavailable in this save.");
            using var command = db.CreateCommand();
            command.CommandText = """
                SELECT story_node_id, json(complete_condition_state) = 'true', json(reveal_condition_state) = 'true'
                FROM journey_story_node
                WHERE character_id=(SELECT id FROM player_state LIMIT 1)
                  AND substr(story_node_id,1,12)='DA_Dunipedia'
                ORDER BY story_node_id;
                """;
            var nodes = new List<object>();
            using (var reader = command.ExecuteReader())
                while (reader.Read())
                    nodes.Add(new { node_id = reader.GetString(0),
                        is_complete = !reader.IsDBNull(1) && reader.GetBoolean(1),
                        is_revealed = !reader.IsDBNull(2) && reader.GetBoolean(2) });
            if (!SHA256.HashData(bytes).SequenceEqual(SHA256.HashData(ReadStable(input))))
                throw new IOException("Solo save changed while reading codex. Refresh and try again.");
            return new { ok = true, nodes, saveSha256 = Convert.ToHexString(SHA256.HashData(bytes)) };
        }
        finally
        {
            try { Directory.Delete(root, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
