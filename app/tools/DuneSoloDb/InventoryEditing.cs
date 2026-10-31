using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
namespace DuneSoloDb;

internal static partial class Program
{
    private static JsonObject? EditableItemBlock(string raw, string key) {
        var stats = JsonNode.Parse(raw) as JsonObject;
        return stats?[key] is JsonArray pair && pair.Count == 2 && pair[1] is JsonObject block
            ? block.DeepClone() as JsonObject : null;
    }
    private static string InventoryRevision(long inventory, string template, long stack, int quality, string stats)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{inventory}|{template}|{stack}|{quality}|{stats}"))).ToLowerInvariant();

    private static object EditInventoryItem(string input, string backup, string catalogPath, long itemId,
        string expectedRevision, string field, string valuesJson, bool requireGameClosed = true)
    {
        if (requireGameClosed) AssertSoloGameClosedForMutation();
        if (itemId <= 0 || expectedRevision.Length != 64) throw new InvalidDataException("Refresh the selected inventory item before editing.");
        var catalog = ReadCatalog(catalogPath);
        var values = JsonNode.Parse(valuesJson) as JsonObject ?? throw new InvalidDataException("Invalid item values.");
        double Number(string key) {
            if (values[key] is not JsonValue value || !value.TryGetValue<double>(out var number)
                || !double.IsFinite(number) || number < 0 || number > float.MaxValue)
                throw new InvalidDataException($"{key} must be a finite nonnegative number.");
            return number;
        }
        RunProgressionMutation(input, backup, "edit-item", sqlite => {
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource=sqlite, Mode=SqliteOpenMode.ReadWrite, Pooling=false }.ToString());
            db.Open(); ExecuteNonQuery(db,"PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;");
            try {
                var allowed = ReadInventoryDestinations(db,catalog).Concat(ReadCharacterEquipment(db)).Select(i=>i.Id).ToHashSet();
                using var lookup=db.CreateCommand();
                lookup.CommandText="SELECT inventory_id,template_id,stack_size,quality_level,json(stats) FROM items WHERE id=$id;";
                lookup.Parameters.AddWithValue("$id",itemId);
                using var reader=lookup.ExecuteReader();
                if(!reader.Read()) throw new InvalidDataException("Item no longer exists. Refresh inventory.");
                var inventory=reader.GetInt64(0);var template=reader.GetString(1);var stack=reader.GetInt64(2);var quality=reader.GetInt32(3);var raw=reader.GetString(4);reader.Close();
                if(!allowed.Contains(inventory)) throw new InvalidDataException("Item is outside the supported Solo inventories.");
                if(InventoryRevision(inventory,template,stack,quality,raw)!=expectedRevision) throw new InvalidDataException("Item changed. Refresh inventory before editing.");
                var stats=JsonNode.Parse(raw) as JsonObject ?? throw new InvalidDataException("Invalid item stats.");
                JsonObject Block(string key) => stats[key] is JsonArray pair && pair.Count==2 && pair[1] is JsonObject block
                    ? block : throw new InvalidDataException("This item does not contain the selected editable stats.");
                switch(field) {
                    case "stack":
                        var quantity=Number("quantity");
                        if(quantity<1 || quantity>int.MaxValue || Math.Truncate(quantity)!=quantity) throw new InvalidDataException("Stack quantity must be a whole number between 1 and 2147483647.");
                        stack=(long)quantity; break;
                    case "water": Block("FFillableItemStats")["CurrentAmount"]=Number("amount"); break;
                    case "durability":
                        var durability=Block("FItemStackAndDurabilityStats");
                        durability["MaxDurability"]=Number("maximum"); durability["CurrentDurability"]=Number("current"); durability["DecayedMaxDurability"]=Number("decayed"); break;
                    default: throw new InvalidDataException("Unknown inventory edit.");
                }
                var updated=stats.ToJsonString();
                if (field == "stack")
                    ExecuteNonQuery(db,"UPDATE items SET stack_size=$stack WHERE id=$id;",("$stack",stack),("$id",itemId));
                else
                    ExecuteNonQuery(db,"UPDATE items SET stats=$stats WHERE id=$id;",("$stats",updated),("$id",itemId));
                using var verify=db.CreateCommand();verify.CommandText="SELECT stack_size,json(stats) FROM items WHERE id=$id;";verify.Parameters.AddWithValue("$id",itemId);
                using(var result=verify.ExecuteReader()) {
                    if(!result.Read() || result.GetInt64(0)!=stack || !JsonNode.DeepEquals(JsonNode.Parse(result.GetString(1)),stats)) throw new InvalidDataException("Item edit readback failed.");
                }
                ValidateDatabase(db); Commit(db); return new { itemId, field };
            } catch { Rollback(db); throw; }
        },requireGameClosed);
        return new { ok=true, itemId, safetyBackup=backup, inspection=InspectPath(input,catalogPath) };
    }
}
