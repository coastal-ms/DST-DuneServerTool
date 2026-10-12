using System.Text.Json.Nodes;

namespace DuneSoloDb;

internal static partial class Program
{
    private static void SelfTestLegitimateCustomizations()
    {
        var original = JsonNode.Parse("""
            {"Other":{"keep":7},"CustomizationLibraryActorComponent":{"other":"preserved","m_UnlockedCustomizationSerializableList":{"metadata":12,"m_UnlockedCustomizationIds":[{"m_CustomizationId":"Existing","extra":true}]}}}
            """)!.AsObject();
        var properties = original.DeepClone().AsObject();
        if (!AppendLegitimateCustomization(properties, "Reviewed") || AppendLegitimateCustomization(properties, "Reviewed"))
            throw new InvalidDataException("Reviewed customization append must be idempotent.");
        var entries = properties["CustomizationLibraryActorComponent"]!["m_UnlockedCustomizationSerializableList"]!["m_UnlockedCustomizationIds"]!.AsArray();
        entries.RemoveAt(entries.Count - 1);
        if (!JsonNode.DeepEquals(original, properties))
            throw new InvalidDataException("Reviewed customization changed unrelated properties.");
        try {
            AppendLegitimateCustomization(new JsonObject(), "Reviewed");
            throw new Exception("Absent library was accepted.");
        } catch (InvalidDataException) { }
    }

    private static (string[] Ids, JsonArray? Recipes) RequireLegitimateCustomization(string catalogPath, string id)
    {
        var catalog = JsonNode.Parse(File.ReadAllText(catalogPath)) as JsonObject
            ?? throw new InvalidDataException("Invalid reviewed customization catalog.");
        if (catalog["schemaVersion"]?.GetValue<int>() != 1 || catalog["entries"] is not JsonArray entries)
            throw new InvalidDataException("Unsupported reviewed customization catalog.");
        var matches = entries.OfType<JsonObject>().Where(e =>
            string.Equals(e["id"]?.GetValue<string>(), id, StringComparison.Ordinal)).ToArray();
        if (matches.Length != 1 || string.IsNullOrWhiteSpace(matches[0]["acquisition"]?.GetValue<string>())
            || string.IsNullOrWhiteSpace(matches[0]["mappingEvidence"]?.GetValue<string>()))
            throw new ArgumentException("Choose an exact supported character customization selection.");
        if (matches[0]["recipeEntries"] is JsonArray recipes)
        {
            var keys = new HashSet<(string, int)>();
            if (recipes.Count == 0) throw new InvalidDataException("Empty recipe selection.");
            foreach (var node in recipes)
            {
                if (node is not JsonObject recipe
                    || string.IsNullOrWhiteSpace(recipe["BaseRecipeId"]?["Name"]?.GetValue<string>())
                    || recipe["m_QualityLevel"]?.GetValue<int>() is not int quality || quality < 0 || quality > 5
                    || recipe["m_NumberOfRecipeUses"]?.GetValue<int>() is not int uses || uses < -1
                    || recipe["m_bIsLimitedUseRecipe"] is not JsonValue
                    || recipe["m_Source"]?.GetValue<string>() != "SchematicPickup"
                    || !keys.Add((recipe["BaseRecipeId"]!["Name"]!.GetValue<string>(), quality)))
                    throw new InvalidDataException("Invalid reviewed recipe mapping.");
                if (uses == -1 && recipe["m_bIsLimitedUseRecipe"]!.GetValue<bool>())
                    throw new InvalidDataException("Unlimited recipe sentinel conflicts with limited-use flag.");
            }
            return ([], recipes);
        }
        var ids = matches[0]["customizationIds"] is JsonArray mapped
            ? mapped.Select(e => e!.GetValue<string>()).ToArray() : [id];
        if (ids.Length == 0 || ids.Any(string.IsNullOrWhiteSpace)
            || ids.Distinct(StringComparer.Ordinal).Count() != ids.Length)
            throw new InvalidDataException("Invalid reviewed customization mapping.");
        return (ids, null);
    }

    private static bool AppendLegitimateCustomization(JsonObject properties, string id)
    {
        if (properties["CustomizationLibraryActorComponent"] is not JsonObject component
            || component["m_UnlockedCustomizationSerializableList"] is not JsonObject library
            || library["m_UnlockedCustomizationIds"] is not JsonArray entries
            || entries.Any(e => e is not JsonObject || e["m_CustomizationId"] is not JsonValue))
            throw new InvalidDataException("Unsupported customization library; no unlock was saved.");
        if (entries.Any(e => string.Equals(e!["m_CustomizationId"]!.GetValue<string>(), id, StringComparison.Ordinal)))
            return false;
        entries.Add(new JsonObject { ["m_CustomizationId"] = id });
        return true;
    }

    private static object GrantLegitimateCustomization(string input, string backup, string adapterPath,
        string catalogPath, string id)
    {
        var selection = RequireLegitimateCustomization(catalogPath, id);
        AssertProgressionAdapter(input, ReadSoloAdapter(adapterPath));
        return RunProgressionMutation(input, backup, "grant-legitimate-customization", path => {
            using var db = OpenWritable(path);
            BeginImmediate(db);
            try {
                var player = ReadIdentity(db);
                var properties = ReadActorProperties(db, player.PawnId);
                var added = 0;
                foreach (var mappedId in selection.Ids)
                    if (AppendLegitimateCustomization(properties, mappedId)) added++;
                if (selection.Recipes is not null)
                {
                    var known = properties["CraftingRecipesLibraryActorComponent"]?["m_KnownItemRecipes"] as JsonArray
                        ?? throw new InvalidDataException("Unsupported crafting recipe library.");
                    if (known.Any(node => node is not JsonObject
                        || node["BaseRecipeId"]?["Name"] is not JsonValue
                        || node["m_QualityLevel"] is not JsonValue))
                        throw new InvalidDataException("Unsupported existing recipe entry.");
                    foreach (var recipe in selection.Recipes)
                    {
                        var name = recipe!["BaseRecipeId"]!["Name"]!.GetValue<string>();
                        var quality = recipe["m_QualityLevel"]!.GetValue<int>();
                        if (known.Any(node => node!["BaseRecipeId"]!["Name"]!.GetValue<string>() == name
                            && node["m_QualityLevel"]!.GetValue<int>() == quality)) continue;
                        known.Add(recipe.DeepClone());
                        added++;
                    }
                }
                if (added > 0) WriteActorProperties(db, player.PawnId, properties);
                var verified = ReadActorProperties(db, player.PawnId);
                if (!JsonNode.DeepEquals(properties, verified))
                    throw new InvalidDataException("Customization readback failed.");
                ExecuteNonQuery(db, "COMMIT;");
                return new { ok = true, added, customizationId = id,
                    message = selection.Recipes is null
                        ? "Character customization IDs saved. Open the game and check the customization menu."
                        : "Schematic recipe entries saved. Open the game and check crafting; existing recipe uses were preserved." };
            } catch { ExecuteNonQuery(db, "ROLLBACK;"); throw; }
        }, requireGameClosed: true);
    }
}
