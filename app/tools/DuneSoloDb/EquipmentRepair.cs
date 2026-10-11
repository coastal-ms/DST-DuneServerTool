using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
namespace DuneSoloDb;

internal static partial class Program
{
    private static object RepairEquipment(string input, string safetyBackup, string catalogPath, string destination = "carried", bool requireGameClosed = true)
    {
        if (requireGameClosed) AssertSoloGameClosedForMutation();
        var catalog = ReadCatalog(catalogPath);
        var original = ReadStable(input);
        EnsureWritableInspection(InspectBytes(original, input, catalog));
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-repair-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var sqlite = Path.Combine(root, "repair.sqlite");
            File.WriteAllBytes(sqlite, Unwrap(original).SqliteBytes);
            var updates = new List<(long Id, string Stats)>();
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = sqlite, Mode = SqliteOpenMode.ReadWrite, Pooling = false }.ToString()))
            {
                connection.Open();
                ExecuteNonQuery(connection, "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;");
                var pawn = ScalarLong(connection, "SELECT player_pawn_id FROM player_state LIMIT 1;");
                if (pawn <= 0) throw new InvalidDataException("Solo character was not found.");
                long inventoryId = 0;
                if (destination != "carried")
                {
                    var selected = ReadInventoryDestinations(connection, catalog).SingleOrDefault(value => value.Key == destination);
                    if (selected is null || selected.Kind is not ("storage" or "developer-storage")) throw new InvalidDataException("Choose one supported storage container.");
                    inventoryId = selected.Id;
                }
                using var rules = JsonDocument.Parse(File.ReadAllText(catalogPath));
                using (var command = connection.CreateCommand())
                {
                    command.CommandText = inventoryId == 0
                        ? "SELECT i.id, i.template_id, json(i.stats) FROM items i JOIN inventories inv ON inv.id=i.inventory_id WHERE inv.actor_id=$pawn AND inv.inventory_type IN (0,1,15);"
                        : "SELECT i.id, i.template_id, json(i.stats) FROM items i WHERE i.inventory_id=$inventory;";
                    if (inventoryId != 0) command.Parameters.AddWithValue("$inventory", inventoryId);
                    command.Parameters.AddWithValue("$pawn", pawn);
                    using var reader = command.ExecuteReader();
                    while (reader.Read())
                    {
                        var stats = JsonNode.Parse(reader.GetString(2)) as JsonObject ?? throw new InvalidDataException("Invalid equipment stats.");
                        if (stats["FItemStackAndDurabilityStats"] is not JsonArray pair || pair.Count != 2 || pair[1] is not JsonObject durability) continue;
                        var maximum = 0.0;
                        if (rules.RootElement.TryGetProperty("items", out var items) && items.TryGetProperty(reader.GetString(1), out var rule) && rule.TryGetProperty("max_durability", out var cap)) maximum = cap.GetDouble();
                        foreach (var key in new[] { "MaxDurability", "CurrentDurability", "DecayedMaxDurability" })
                        {
                            if (durability[key] is null) continue;
                            var value = durability[key]!.GetValue<double>();
                            if (!double.IsFinite(value) || value < 0) throw new InvalidDataException("Invalid equipment durability.");
                            maximum = Math.Max(maximum, value);
                        }
                        if (maximum <= 0 && durability["CurrentDurability"] is null) continue;
                        maximum = maximum < 100 ? 100 : maximum < 200 && maximum > 100 ? 200 : maximum;
                        if (!double.IsFinite(maximum)) throw new InvalidDataException("Invalid equipment durability cap.");
                        var changed = false;
                        foreach (var key in new[] { "MaxDurability", "CurrentDurability", "DecayedMaxDurability" })
                        {
                            if (durability[key] is null || durability[key]!.GetValue<double>() != maximum) changed = true;
                            durability[key] = maximum;
                        }
                        if (changed) updates.Add((reader.GetInt64(0), stats.ToJsonString()));
                    }
                }
                foreach (var update in updates)
                {
                    ExecuteNonQuery(connection, "UPDATE items SET stats=$stats WHERE id=$id;", ("$stats", update.Stats), ("$id", update.Id));
                    using var verify = connection.CreateCommand();
                    verify.CommandText = "SELECT json(stats) FROM items WHERE id=$id;";
                    verify.Parameters.AddWithValue("$id", update.Id);
                    if (!JsonNode.DeepEquals(JsonNode.Parse((string)verify.ExecuteScalar()!), JsonNode.Parse(update.Stats))) throw new InvalidDataException("Equipment repair readback failed.");
                }
                if (ScalarString(connection, "PRAGMA integrity_check;") != "ok" || ScalarLong(connection, "SELECT COUNT(*) FROM pragma_foreign_key_check;") != 0) throw new InvalidDataException("Equipment repair integrity check failed.");
                ExecuteNonQuery(connection, "COMMIT;");
            }
            if (updates.Count > 0)
            {
                var mutated = Path.Combine(root, "game.db");
                WrapSqlite(sqlite, mutated);
                EnsureWritableInspection(InspectPath(mutated, catalogPath));
                Restore(mutated, input, safetyBackup, expectedTargetBytes: original, requireGameClosed);
            }
            return new { ok = true, repaired = updates.Count, safetyBackup = updates.Count > 0 ? safetyBackup : "", inspection = InspectPath(input, catalogPath) };
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }
    private static void TestEquipmentRepair(string source, string catalogPath, string root)
    {
        var sqlite = Path.Combine(root, "repair-test.sqlite");
        File.WriteAllBytes(sqlite, Unwrap(File.ReadAllBytes(source)).SqliteBytes);
        long storage;
        using (var connection = new SqliteConnection($"Data Source={sqlite};Pooling=False"))
        {
            connection.Open();
            storage = ReadInventoryDestinations(connection).First(value => value.Kind == "developer-storage").Id;
            ExecuteNonQuery(connection, "INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats,quality_level) VALUES(9000,$inventory,1,0,'TestSword',$stats,0);",
                ("$inventory", storage), ("$stats", "{\"FItemStackAndDurabilityStats\":[[],{\"CurrentDurability\":1,\"MaxDurability\":250,\"DecayedMaxDurability\":200}],\"keep\":7}"));
        }
        var target = Path.Combine(root, "repair-test.db");
        WrapSqlite(sqlite, target);
        var before = File.ReadAllBytes(target);
        var backup = Path.Combine(root, "repair-test-backup.db");
        RepairEquipment(target, backup, catalogPath, $"inventory:{storage}", requireGameClosed: false);
        if (!File.ReadAllBytes(backup).SequenceEqual(before)) throw new InvalidOperationException("Repair backup changed.");
        var after = File.ReadAllBytes(target);
        RepairEquipment(target, Path.Combine(root, "repair-test-noop.db"), catalogPath, $"inventory:{storage}", requireGameClosed: false);
        if (!File.ReadAllBytes(target).SequenceEqual(after)) throw new InvalidOperationException("Repair is not idempotent.");
        File.WriteAllBytes(sqlite, Unwrap(after).SqliteBytes);
        using (var connection = new SqliteConnection($"Data Source={sqlite};Pooling=False"))
        {
            connection.Open();
            var stats = JsonNode.Parse(ScalarString(connection, "SELECT json(stats) FROM items WHERE id=9000;"))!;
            if (stats["keep"]!.GetValue<int>() != 7 || stats["FItemStackAndDurabilityStats"]![1]!["CurrentDurability"]!.GetValue<double>() != 250) throw new InvalidOperationException("Repair stats preservation failed.");
        }
        var rejected = false;
        try { RepairEquipment(target, backup, catalogPath, "inventory:999999", requireGameClosed: false); } catch (InvalidDataException) { rejected = true; }
        if (!rejected || !File.ReadAllBytes(target).SequenceEqual(after)) throw new InvalidOperationException("Invalid repair target changed save.");
    }

}
