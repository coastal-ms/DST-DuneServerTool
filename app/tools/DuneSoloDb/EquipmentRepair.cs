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
                var durabilityRules = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
                if (rules.RootElement.TryGetProperty("items", out var definitions))
                    foreach (var definition in definitions.EnumerateObject()) durabilityRules[definition.Name] = definition.Value;
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
                        var known = false;
                        if (durabilityRules.TryGetValue(reader.GetString(1), out var rule))
                        {
                            if (rule.TryGetProperty("max_durability", out var cap)) maximum = cap.GetDouble();
                            known = rule.TryGetProperty("durability_known", out var flag) && flag.ValueKind == JsonValueKind.True;
                        }
                        var storedMaximum = durability["MaxDurability"]?.GetValue<double>() ?? 0;
                        if (known && maximum <= 0 && storedMaximum <= 0) continue;
                        foreach (var key in new[] { "MaxDurability", "DecayedMaxDurability" })
                        {
                            if (durability[key] is null) continue;
                            var value = durability[key]!.GetValue<double>();
                            if (!double.IsFinite(value) || value < 0) throw new InvalidDataException("Invalid equipment durability.");
                            maximum = Math.Max(maximum, value);
                        }
                        if (maximum <= 0) continue;
                        if (durability["CurrentDurability"] is JsonValue current)
                        {
                            var value = current.GetValue<double>();
                            if (!double.IsFinite(value) || value < 0) throw new InvalidDataException("Invalid equipment durability.");
                            maximum = Math.Max(maximum, value);
                        }
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
        var repairCatalog = JsonNode.Parse(File.ReadAllText(catalogPath))!.AsObject();
        var repairRules = repairCatalog["items"]!.AsObject();
        repairRules["FullStabilizationBelt"] = JsonNode.Parse("""{"max_durability":100,"durability_known":true}""");
        repairRules["PortableLight"] = JsonNode.Parse("""{"max_durability":100,"durability_known":true}""");
        repairRules["HealthPack_Channeled_2"] = JsonNode.Parse("""{"max_durability":0,"durability_known":true}""");
        catalogPath = Path.Combine(root, "repair-catalog.json");
        File.WriteAllText(catalogPath, repairCatalog.ToJsonString());
        var sqlite = Path.Combine(root, "repair-test.sqlite");
        File.WriteAllBytes(sqlite, Unwrap(File.ReadAllBytes(source)).SqliteBytes);
        long storage;
        using (var connection = new SqliteConnection($"Data Source={sqlite};Pooling=False"))
        {
            connection.Open();
            storage = ReadInventoryDestinations(connection).First(value => value.Kind == "developer-storage").Id;
            ExecuteNonQuery(connection, "INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats,quality_level) VALUES(9000,$inventory,1,0,'TestSword',$stats,0);",
                ("$inventory", storage), ("$stats", "{\"FItemStackAndDurabilityStats\":[[],{\"CurrentDurability\":1,\"MaxDurability\":250,\"DecayedMaxDurability\":200}],\"keep\":7}"));
            foreach (var (id, template, json) in new[] {
                (9001, "FullStabilizationBelt", """{"FItemStackAndDurabilityStats":[[],{"CurrentDurability":28.669025,"DecayedMaxDurability":56.992908}],"keep":7}"""),
                (9002, "HealthPack_Channeled_2", """{"FItemStackAndDurabilityStats":[[],{"CurrentDurability":0,"DecayedMaxDurability":100}],"keep":7}"""),
                (9003, "CustomSword", """{"FItemStackAndDurabilityStats":[[],{"CurrentDurability":10,"MaxDurability":150,"DecayedMaxDurability":140}],"keep":7}"""),
                (9004, "portablelight", """{"FItemStackAndDurabilityStats":[[],{"CurrentDurability":0}],"keep":7}"""),
                (9005, "UnknownNoCap", """{"FItemStackAndDurabilityStats":[[],{"CurrentDurability":15}],"keep":7}""") })
                ExecuteNonQuery(connection, "INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats,quality_level) VALUES($id,$inventory,1,0,$template,$stats,0);", ("$id", id), ("$inventory", storage), ("$template", template), ("$stats", json));
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
            foreach (var (id, expected) in new[] { (9001,100.0), (9002,0.0), (9003,150.0), (9004,100.0), (9005,15.0) })
            {
                var item = JsonNode.Parse(ScalarString(connection, $"SELECT json(stats) FROM items WHERE id={id};"))!;
                if (item["FItemStackAndDurabilityStats"]![1]!["CurrentDurability"]!.GetValue<double>() != expected || item["keep"]!.GetValue<int>() != 7) throw new InvalidOperationException($"Repair cap coverage failed for {id}.");
            }
        }
        var rejected = false;
        try { RepairEquipment(target, backup, catalogPath, "inventory:999999", requireGameClosed: false); } catch (InvalidDataException) { rejected = true; }
        if (!rejected || !File.ReadAllBytes(target).SequenceEqual(after)) throw new InvalidOperationException("Invalid repair target changed save.");
    }

}
