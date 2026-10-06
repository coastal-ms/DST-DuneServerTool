using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private sealed record CosmeticOwnership(bool Available, string[] Unlocked, string[] Customizations, string[] Pending, string Error);

    private static void SelfTestCosmeticOwnership()
    {
        using var connection = new SqliteConnection("Data Source=:memory:");
        connection.Open();
        ExecuteNonQuery(connection, """
            CREATE TABLE player_state(id INTEGER, player_pawn_id INTEGER);
            INSERT INTO player_state VALUES(1,10);
            CREATE TABLE actors(id INTEGER, properties BLOB);
            INSERT INTO actors VALUES(10,jsonb('{"CustomizationLibraryActorComponent":{"m_UnlockedCustomizationSerializableList":{"m_UnlockedCustomizationIds":[{"m_CustomizationId":"Scout_Top"}]}}}'));
            CREATE TABLE building_progression_learned_building_sets(character_id INTEGER, learned_building_set TEXT);
            CREATE TABLE building_progression_new_buildable_pieces(character_id INTEGER, new_buildable_piece TEXT);
            INSERT INTO building_progression_learned_building_sets VALUES(1,'ChoamLevel2Set'),(2,'OtherCharacter');
            INSERT INTO building_progression_new_buildable_pieces VALUES(1,'MTX_Neut_MuadDibCage_Placeable');
            """);
        var pending = new InventoryItemGroup(1,"inventory:1","Backpack","backpack","HeldPatent","Held",1,1,0,0,[]);
        var read = ReadCosmeticOwnership(connection, [pending]);
        if (!read.Available || !read.Unlocked.Contains("ChoamLevel2Set_Patent")
            || !read.Unlocked.Contains("MTX_Neut_MuadDibCage_Placeable")
            || read.Unlocked.Contains("OtherCharacter") || !read.Customizations.Contains("Scout_Top")
            || !read.Pending.Contains("HeldPatent"))
            throw new InvalidDataException("Solo cosmetic ownership regression.");
        ExecuteNonQuery(connection,"DROP TABLE building_progression_learned_building_sets;");
        if (ReadCosmeticOwnership(connection, [pending]).Available)
            throw new InvalidDataException("Unknown Solo ownership must fail closed.");
    }

    private static CosmeticOwnership ReadCosmeticOwnership(SqliteConnection connection, InventoryItemGroup[] inventoryItems)
    {
        try
        {
            if (!TableExists(connection, "building_progression_learned_building_sets")
                || !TableExists(connection, "building_progression_new_buildable_pieces")
                || ScalarLong(connection, "SELECT COUNT(*) FROM player_state;") != 1)
                return new(false, [], [], [], "This save does not expose verified cosmetic ownership.");
            var characterId = ScalarLong(connection, "SELECT id FROM player_state LIMIT 1;");
            var pawnId = ScalarLong(connection, "SELECT player_pawn_id FROM player_state LIMIT 1;");
            var unlocked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT learned_building_set FROM building_progression_learned_building_sets WHERE character_id = $id
                UNION SELECT new_buildable_piece FROM building_progression_new_buildable_pieces WHERE character_id = $id;
                """;
            command.Parameters.AddWithValue("$id", characterId);
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var id = reader.GetString(0);
                    if (string.IsNullOrWhiteSpace(id)) continue;
                    unlocked.Add(id);
                    if (!id.EndsWith("_Patent", StringComparison.OrdinalIgnoreCase)) unlocked.Add(id + "_Patent");
                }
            }
            var properties = ReadActorProperties(connection, pawnId);
            var customizations = properties["CustomizationLibraryActorComponent"]?["m_UnlockedCustomizationSerializableList"]?["m_UnlockedCustomizationIds"] as JsonArray;
            var ids = customizations?.Select(value => value?["m_CustomizationId"]?.GetValue<string>())
                .Where(value => !string.IsNullOrWhiteSpace(value)).Cast<string>().ToArray() ?? [];
            foreach (var id in ids) unlocked.Add(id);
            return new(true, unlocked.Order().ToArray(), ids,
                inventoryItems.Where(item => item.TotalQuantity > 0).Select(item => item.TemplateId).Distinct(StringComparer.OrdinalIgnoreCase).Order().ToArray(), "");
        }
        catch (Exception error) when (error is SqliteException or InvalidOperationException or System.Text.Json.JsonException or InvalidDataException)
        {
            return new(false, [], [], [], "Cosmetic ownership could not be verified: " + error.Message);
        }
    }
}
