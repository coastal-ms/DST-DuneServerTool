using System.Security.Cryptography;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static object ExportDiagnostics(string input)
    {
        var bytes = ReadStable(input);
        var inspection = InspectBytes(bytes, input);
        if (inspection.CharacterCount != 1)
            throw new InvalidDataException("Diagnostics require exactly one Solo character.");
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-diagnostics-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "snapshot.sqlite");
            File.WriteAllBytes(path, Unwrap(bytes).SqliteBytes);
            using var connection = new SqliteConnection(new SqliteConnectionStringBuilder {
                DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false
            }.ToString());
            connection.Open();
            ExecuteNonQuery(connection, "PRAGMA query_only=ON;");
            // Export only the progression fields needed by support, never actor
            // properties, account identifiers, names, inventory or file paths.
            var warnings = new List<string>();
            object[] Rows(string table, string sql)
            {
                if (!TableExists(connection, table))
                {
                    warnings.Add($"Unavailable table: {table}");
                    return Array.Empty<object>();
                }
                using var command = connection.CreateCommand();
                command.CommandText = sql;
                using var reader = command.ExecuteReader();
                var rows = new List<object>();
                while (reader.Read())
                {
                    var row = new Dictionary<string, object?>();
                    for (var i = 0; i < reader.FieldCount; i++)
                        row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                    rows.Add(row);
                }
                return rows.ToArray();
            }
            var tracks = Rows("specialization_tracks", "SELECT track_type, level, xp_amount FROM specialization_tracks WHERE player_id=(SELECT player_controller_id FROM player_state LIMIT 1) ORDER BY track_type;");
            var rewardSql = TableExists(connection, "specialization_keystones_map")
                ? "SELECT p.keystone_id, m.name FROM purchased_specialization_keystones p LEFT JOIN specialization_keystones_map m ON m.id=p.keystone_id WHERE p.player_id=(SELECT player_controller_id FROM player_state LIMIT 1) ORDER BY p.keystone_id;"
                : "SELECT keystone_id FROM purchased_specialization_keystones WHERE player_id=(SELECT player_controller_id FROM player_state LIMIT 1) ORDER BY keystone_id;";
            var rewards = Rows("purchased_specialization_keystones", rewardSql);
            var journeys = Rows("journey_story_node", "SELECT story_node_id, json(complete_condition_state) AS complete_condition, json(reveal_condition_state) AS reveal_condition, has_pending_reward FROM journey_story_node WHERE character_id=(SELECT id FROM player_state LIMIT 1) ORDER BY story_node_id;");
            var tags = Rows("player_tags", "SELECT tag FROM player_tags WHERE character_id=(SELECT id FROM player_state LIMIT 1) AND (tag LIKE 'Journey.%' OR tag LIKE 'Faction.%' OR tag LIKE 'DialogueFlags.Factions.%') ORDER BY tag;");
            var standing = Rows("player_faction_reputation", "SELECT faction_id, reputation_amount FROM player_faction_reputation WHERE actor_id=(SELECT player_controller_id FROM player_state LIMIT 1) ORDER BY faction_id;");
            if (!SHA256.HashData(bytes).SequenceEqual(SHA256.HashData(ReadStable(input))))
                throw new IOException("Solo save changed during diagnostics. Close the game and try again.");
            return new { ok = true, report = new {
                format = "dst-solo-diagnostics-v1", generatedUtc = DateTime.UtcNow,
                inspection.WrapperVersion, inspection.SchemaFingerprint,
                inspection.Integrity, inspection.ForeignKeyViolations,
                inspection.CharacterCount, tracks, rewards, journeys, tags, standing, warnings
            }};
        }
        finally
        {
            try { Directory.Delete(root, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static object SetSpecialization(string input, string safetyBackup,
        string adapterPath, string track, long level)
    {
        var adapter = ReadSoloAdapter(adapterPath);
        AssertProgressionSchema(input, adapter);
        var match = adapter.Tracks.FirstOrDefault(pair => pair.Key.Equals(track, StringComparison.OrdinalIgnoreCase));
        if (match.Key is null || level < 0 || level > adapter.MaxLevel)
            throw new ArgumentException("Choose a valid specialization and a level from 0 to 100.");
        var xp = level == adapter.MaxLevel ? adapter.MaxXp
            : Math.Min(adapter.MaxXp, (long)Math.Round(3.107 * level * level + 131.1 * level));
        return RunProgressionMutation(input, safetyBackup, "set-specialization", sqlitePath => {
            using var connection = OpenWritable(sqlitePath);
            var identity = ReadIdentity(connection);
            BeginImmediate(connection);
            try
            {
                ExecuteNonQuery(connection, "INSERT INTO specialization_tracks(player_id,track_type,xp_amount,level) VALUES($player,$track,$xp,$level) ON CONFLICT(player_id,track_type) DO UPDATE SET xp_amount=excluded.xp_amount,level=excluded.level;",
                    ("$player", identity.ControllerId), ("$track", match.Value), ("$xp", xp), ("$level", level));
                if (ScalarLong(connection, "SELECT COUNT(*) FROM specialization_tracks WHERE player_id=$player AND track_type=$track AND level=$level AND xp_amount=$xp;",
                    ("$player", identity.ControllerId), ("$track", match.Value), ("$xp", xp), ("$level", level)) != 1)
                    throw new InvalidDataException("Specialization verification failed.");
                ValidateDatabase(connection);
                Commit(connection);
                return new { track = match.Key, level, xp, rewardsPreserved = true };
            }
            catch { Rollback(connection); throw; }
        });
    }
}
