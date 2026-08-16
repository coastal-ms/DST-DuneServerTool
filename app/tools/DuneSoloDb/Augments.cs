using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private const decimal DuneAugmentMaxRoll = 1.003398m;

    private static object MaxAugmentAttributes(string input, string safetyBackup)
    {
        var originalBytes = ReadStable(input);
        var originalInspection = InspectBytes(originalBytes, input);
        EnsureWritableInspection(originalInspection);
        var wrapped = Unwrap(originalBytes);
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-augment-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var sqlitePath = Path.Combine(root, "augment.sqlite");
            File.WriteAllBytes(sqlitePath, wrapped.SqliteBytes);
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = sqlitePath,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false
            }.ToString();
            var updated = 0;
            using (var connection = new SqliteConnection(connectionString))
            {
                connection.Open();
                ExecuteNonQuery(connection, "PRAGMA foreign_keys = ON;");
                ExecuteNonQuery(connection, "BEGIN IMMEDIATE;");
                try
                {
                    updated = ApplyAugmentMax(connection);
                    var integrity = ScalarString(connection, "PRAGMA integrity_check;");
                    var foreignKeys = ScalarLong(
                        connection,
                        "SELECT COUNT(*) FROM pragma_foreign_key_check;");
                    if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase)
                        || foreignKeys != 0)
                    {
                        throw new InvalidDataException(
                            $"Augment write validation failed (integrity={integrity}, foreignKeys={foreignKeys}).");
                    }
                    ExecuteNonQuery(connection, "COMMIT;");
                }
                catch
                {
                    try { ExecuteNonQuery(connection, "ROLLBACK;"); } catch { }
                    throw;
                }
            }

            if (updated == 0)
            {
                return new
                {
                    ok = true,
                    updated,
                    safetyBackup = string.Empty,
                    inspection = originalInspection
                };
            }

            var mutated = Path.Combine(root, "game.db");
            WrapSqlite(sqlitePath, mutated);
            EnsureWritableInspection(InspectPath(mutated));
            Restore(mutated, input, safetyBackup);
            return new
            {
                ok = true,
                updated,
                safetyBackup,
                inspection = InspectPath(input)
            };
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    Directory.Delete(root, recursive: true);
                }
            }
            catch
            {
                // A stale temp directory is safer than hiding the write result.
            }
        }
    }

    private static int ApplyAugmentMax(SqliteConnection connection)
    {
        var pawnId = ScalarLong(
            connection,
            "SELECT player_pawn_id FROM player_state LIMIT 1;");
        var candidates = new List<(long Id, string Stats)>();
        using (var command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT i.id, i.stats
                FROM items AS i
                JOIN inventories AS inv ON inv.id = i.inventory_id
                WHERE inv.actor_id = $pawn
                  AND lower(i.template_id) LIKE '%augment%'
                ORDER BY i.id;
                """;
            command.Parameters.AddWithValue("$pawn", pawnId);
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                candidates.Add((reader.GetInt64(0), reader.GetString(1)));
            }
        }

        var updated = 0;
        foreach (var candidate in candidates)
        {
            JsonNode? stats;
            try
            {
                stats = JsonNode.Parse(candidate.Stats);
            }
            catch (JsonException ex)
            {
                throw new InvalidDataException(
                    $"Augment item {candidate.Id} contains invalid stats JSON.",
                    ex);
            }
            var rolls = GetAugmentRolls(stats);
            if (rolls is null || rolls.Count == 0)
            {
                continue;
            }

            for (var index = 0; index < rolls.Count; index++)
            {
                if (TryReadJsonDecimal(rolls[index], out var value) && value != 0m)
                {
                    rolls[index] = JsonValue.Create(DuneAugmentMaxRoll);
                }
            }
            var serialized = stats!.ToJsonString();
            var affected = ExecuteNonQuery(
                connection,
                "UPDATE items SET stats = $stats WHERE id = $id;",
                ("$stats", serialized),
                ("$id", candidate.Id));
            if (affected != 1)
            {
                throw new InvalidDataException(
                    $"Augment item {candidate.Id} was not updated exactly once.");
            }
            using var verification = connection.CreateCommand();
            verification.CommandText = "SELECT stats FROM items WHERE id = $id;";
            verification.Parameters.AddWithValue("$id", candidate.Id);
            var verified = Convert.ToString(verification.ExecuteScalar()) ?? string.Empty;
            if (!string.Equals(verified, serialized, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"Augment item {candidate.Id} failed post-write verification.");
            }
            updated++;
        }
        return updated;
    }

    private static JsonArray? GetAugmentRolls(JsonNode? stats)
    {
        if (stats is not JsonObject root
            || root["FAugmentItemStats"] is not JsonArray outer
            || outer.Count < 2
            || outer[1] is not JsonObject values)
        {
            return null;
        }
        return values["StatRolls"] as JsonArray;
    }

    private static bool TryReadJsonDecimal(JsonNode? node, out decimal value)
    {
        value = 0m;
        if (node is null)
        {
            return false;
        }
        using var document = JsonDocument.Parse(node.ToJsonString());
        return document.RootElement.ValueKind == JsonValueKind.Number
            && document.RootElement.TryGetDecimal(out value);
    }
}
