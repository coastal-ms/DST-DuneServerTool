using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static readonly HashSet<string> RangedCategories = new(StringComparer.OrdinalIgnoreCase)
    {
        "items/weapons/battlerifle", "items/weapons/fireballer",
        "items/weapons/flamethrower", "items/weapons/heavypistol",
        "items/weapons/heavyrifle", "items/weapons/heavyshotgun",
        "items/weapons/lasgun", "items/weapons/missilelauncher",
        "items/weapons/pistol", "items/weapons/shotgun",
        "items/weapons/smg", "items/weapons/spitdart"
    };

    private static bool TryReadWeaponAmmo(string stats, string templateId,
        IReadOnlyDictionary<string, CatalogRule>? catalog, out long ammo)
    {
        ammo = 0;
        if (JsonNode.Parse(stats) is not JsonObject root) return false;
        var knownRanged = false;
        if (catalog is not null && catalog.TryGetValue(templateId, out var rule))
        {
            if (rule.IsSchematic) return false;
            knownRanged = RangedCategories.Contains(rule.Category);
            if (rule.Category.Length > 0 && !knownRanged) return false;
        }
        if (!root.ContainsKey("FWeaponItemStats")) return knownRanged;
        if (root["FWeaponItemStats"] is not JsonArray block
            || block.Count != 2 || block[0] is not JsonArray
            || block[1] is not JsonObject fields) return false;
        if (!fields.ContainsKey("CurrentAmmo")) return true;
        if (fields["CurrentAmmo"] is not JsonValue value
            || !value.TryGetValue<double>(out var number)
            || !double.IsFinite(number) || number < 0
            || number > 2_000_000_000 || number != Math.Truncate(number)) return false;
        ammo = (long)number;
        return true;
    }

    private static string WithWeaponAmmo(string stats, long ammo)
    {
        var root = JsonNode.Parse(stats)!.AsObject();
        if (!root.ContainsKey("FWeaponItemStats"))
            root["FWeaponItemStats"] = new JsonArray(new JsonArray(), new JsonObject());
        root["FWeaponItemStats"]![1]!["CurrentAmmo"] = ammo;
        return root.ToJsonString();
    }

    // Display-only containers: do not expose equipment as grant/delete destinations.
    private static InventoryDestination[] ReadCharacterEquipment(SqliteConnection connection)
    {
        var pawn = ScalarLong(connection, "SELECT player_pawn_id FROM player_state LIMIT 1;");
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT inv.id, inv.inventory_type, COUNT(items.id)
            FROM inventories inv
            LEFT JOIN items ON items.inventory_id = inv.id
            WHERE inv.actor_id = $pawn AND inv.inventory_type IN (1, 15)
            GROUP BY inv.id ORDER BY inv.id;
            """;
        command.Parameters.AddWithValue("$pawn", pawn);
        using var reader = command.ExecuteReader();
        var result = new List<InventoryDestination>();
        while (reader.Read())
            result.Add(new InventoryDestination(reader.GetInt64(0), $"inventory:{reader.GetInt64(0)}",
                reader.GetInt64(1) == 1 ? "Worn equipment" : "Equipped weapons and tools",
                "equipment", reader.GetInt64(2), 0, 0, 0));
        return result.ToArray();
    }

    private static void SelfTestAmmoEquipment(string root, string source, string catalogPath)
    {
        var catalogJson = JsonNode.Parse(File.ReadAllText(catalogPath))!.AsObject();
        var rules = catalogJson["items"]!.AsObject();
        var fixtures = new List<(string Template, string Stats, bool Editable)>();
        foreach (var category in RangedCategories)
        {
            var template = "TestRanged_" + category.Split('/').Last();
            rules[template] = new JsonObject { ["category"] = category };
            fixtures.Add((template, "{\"FCustomizationStats\":[[],{\"Keep\":7}]}", true));
        }
        rules["TestMelee"] = new JsonObject { ["category"] = "items/weapons/shortblades" };
        rules["TestSchematic"] = new JsonObject { ["category"] = "items/weapons/shotgun", ["is_schematic"] = true };
        rules["TestMalformed"] = new JsonObject { ["category"] = "items/weapons/shotgun" };
        fixtures.Add(("TestEmptyBlock", "{\"FWeaponItemStats\":[[],{}]}", true));
        fixtures.Add(("TestMelee", "{}", false));
        fixtures.Add(("TestSchematic", "{}", false));
        fixtures.Add(("TestUnknown", "{}", false));
        fixtures.Add(("TestMalformed", "{\"FWeaponItemStats\":[[],null]}", false));
        fixtures.Add(("TestNullAmmo", "{\"FWeaponItemStats\":[[],{\"CurrentAmmo\":null}]}", false));
        fixtures.Add(("TestTextAmmo", "{\"FWeaponItemStats\":[[],{\"CurrentAmmo\":\"0\"}]}", false));
        var testCatalog = Path.Combine(root, "ammo-equipment-catalog.json");
        File.WriteAllText(testCatalog, catalogJson.ToJsonString());
        var sqlite = Path.Combine(root, "ammo-equipment.sqlite");
        File.WriteAllBytes(sqlite, Unwrap(File.ReadAllBytes(source)).SqliteBytes);
        using (var connection = new SqliteConnection($"Data Source={sqlite};Pooling=False"))
        {
            connection.Open();
            ExecuteNonQuery(connection, "INSERT INTO inventories VALUES (500,10,1,8,0);");
            ExecuteNonQuery(connection, "INSERT INTO items VALUES (500,500,1,0,'TestWorn',0,0,'{}',0,NULL);");
            for (var index = 0; index < fixtures.Count; index++)
                ExecuteNonQuery(connection, "INSERT INTO items VALUES ($id,8,1,$position,$template,0,0,$stats,0,NULL);",
                    ("$id", 501 + index), ("$position", index + 10),
                    ("$template", fixtures[index].Template), ("$stats", fixtures[index].Stats));
        }
        var target = Path.Combine(root, "ammo-equipment.db");
        WrapSqlite(sqlite, target);
        var inspection = InspectPath(target, testCatalog);
        if (!inspection.InventoryItems.Any(item => item.TemplateId == "TestWorn" && item.DestinationKind == "equipment")
            || inspection.Inventories.Any(inventory => inventory.Id == 500))
            throw new InvalidOperationException("Worn equipment display widened writable destinations or omitted equipment.");
        for (var index = 0; index < fixtures.Count; index++)
        {
            var itemId = 501 + index;
            var fixture = fixtures[index];
            if (inspection.RangedWeapons.Any(item => item.ItemId == itemId) != fixture.Editable)
                throw new InvalidOperationException($"Ranged discovery incorrect for {fixture.Template}.");
            var before = File.ReadAllBytes(target);
            var safety = Path.Combine(root, $"ammo-equipment-before-{itemId}.db");
            var rejected = false;
            try { SetWeaponAmmo(target, safety, itemId, 250, testCatalog, requireGameClosed: false); }
            catch (InvalidDataException) { rejected = true; }
            if (rejected == fixture.Editable)
                throw new InvalidOperationException($"Ammo edit eligibility incorrect for {fixture.Template}.");
            if (!fixture.Editable)
            {
                if (!before.SequenceEqual(File.ReadAllBytes(target)) || File.Exists(safety))
                    throw new InvalidOperationException("Rejected ammo edit changed the save or created a backup.");
                continue;
            }
            if (!before.SequenceEqual(File.ReadAllBytes(safety))
                || InspectPath(target, testCatalog).RangedWeapons.Single(item => item.ItemId == itemId).CurrentAmmo != 250)
                throw new InvalidOperationException("Ammo initialization did not preserve exact backup and readback.");
            var mutatedSqlite = Path.Combine(root, "ammo-equipment-readback.sqlite");
            File.WriteAllBytes(mutatedSqlite, Unwrap(File.ReadAllBytes(target)).SqliteBytes);
            using var verify = new SqliteConnection($"Data Source={mutatedSqlite};Pooling=False");
            verify.Open();
            var stats = JsonNode.Parse(ScalarString(verify, "SELECT json(stats) FROM items WHERE id=$id;", ("$id", itemId)))!.AsObject();
            stats.Remove("FWeaponItemStats");
            var original = JsonNode.Parse(fixture.Stats)!.AsObject();
            original.Remove("FWeaponItemStats");
            if (!JsonNode.DeepEquals(stats, original))
                throw new InvalidOperationException("Ammo initialization changed unrelated item stats.");
        }
    }
}
