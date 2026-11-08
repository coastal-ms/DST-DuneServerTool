using System.Text.Json.Nodes;

namespace DuneSoloDb;

internal static partial class Program
{
    private static void SelfTestLegitimateCustomizations()
    {
        var catalogFile = Path.Combine(Path.GetTempPath(), "dst-appearance-selftest-" + Guid.NewGuid().ToString("N") + ".json");
        try {
            File.WriteAllText(catalogFile, """
                {"schemaVersion":1,"entries":[{"id":"ObservedGearAppearances","acquisition":"observed","mappingEvidence":"verified","customizationIds":["B1C3_Shaman_Raider_Top","AgentX_Stillsuit_Torso"]}]}
                """);
            foreach (var id in new[] { "B1C3_Shaman_Raider_Top", "AgentX_Stillsuit_Torso" }) {
                var selected = RequireLegitimateCustomization(catalogFile, "appearance:" + id);
                if (selected.Ids.Length != 1 || selected.Ids[0] != id || selected.Recipes is not null)
                    throw new InvalidDataException("Individual appearance selection must match its batch ID exactly.");
            }
            foreach (var id in new[] { "appearance:Unknown", "appearance:agentx_stillsuit_torso", "appearance:ObservedGearAppearances" }) {
                try { RequireLegitimateCustomization(catalogFile, id); throw new InvalidDataException("Unlisted appearance was accepted."); }
                catch (ArgumentException) { }
            }
        } finally { File.Delete(catalogFile); }
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
        var recipe = JsonNode.Parse("""{"BaseRecipeId":{"Name":"FixtureRecipe"},"m_QualityLevel":5,"m_NumberOfRecipeUses":1,"m_bIsLimitedUseRecipe":true,"m_bIsNew":true,"m_Source":"SchematicPickup"}""")!.AsObject();
        var exhausted = recipe.DeepClone().AsObject();exhausted["m_NumberOfRecipeUses"] = 0;exhausted["customMetadata"] = 42;
        var otherGrade = recipe.DeepClone().AsObject();otherGrade["m_QualityLevel"] = 1;otherGrade["m_NumberOfRecipeUses"] = 7;
        var known = new JsonArray(exhausted, otherGrade);
        if (!GrantReviewedRecipe(known, recipe, false) || GrantReviewedRecipe(known, recipe, false)
            || exhausted["m_NumberOfRecipeUses"]!.GetValue<int>() != 1 || exhausted["customMetadata"]!.GetValue<int>() != 42
            || otherGrade["m_NumberOfRecipeUses"]!.GetValue<int>() != 7)
            throw new InvalidDataException("Exhausted recipe reissue changed usable recipes or metadata.");
        if (!GrantReviewedRecipe(known, recipe, true) || !GrantReviewedRecipe(known, recipe, true)
            || exhausted["m_NumberOfRecipeUses"]!.GetValue<int>() != 3 || known.Count != 2)
            throw new InvalidDataException("Repeated augmentation grant must add one use without duplicate entries.");
        exhausted["m_bIsLimitedUseRecipe"] = false;exhausted["m_NumberOfRecipeUses"] = -1;
        if (GrantReviewedRecipe(known, recipe, false) || GrantReviewedRecipe(known, recipe, true)
            || exhausted["m_NumberOfRecipeUses"]!.GetValue<int>() != -1)
            throw new InvalidDataException("Unlimited recipe was changed by reissue.");
    }

    private static bool GrantReviewedRecipe(JsonArray known, JsonObject recipe, bool reissueAll)
    {
        var name = recipe["BaseRecipeId"]!["Name"]!.GetValue<string>();
        var quality = recipe["m_QualityLevel"]!.GetValue<int>();
        var existing = known.OfType<JsonObject>()
            .Where(node => node["BaseRecipeId"]!["Name"]!.GetValue<string>() == name
                && node["m_QualityLevel"]!.GetValue<int>() == quality)
            .OrderBy(node => node["m_bIsLimitedUseRecipe"]?.GetValue<bool>() != true ? 0
                : node["m_NumberOfRecipeUses"]?.GetValue<int>() != 0 ? 1 : 2).FirstOrDefault();
        if (existing is null) { known.Add(recipe.DeepClone()); return true; }
        if (!recipe["m_bIsLimitedUseRecipe"]!.GetValue<bool>() || existing["m_bIsLimitedUseRecipe"]?.GetValue<bool>() != true
            || !(existing["m_NumberOfRecipeUses"]?.GetValue<int>() == 0
                || (reissueAll && existing["m_NumberOfRecipeUses"]?.GetValue<int>() >= 0))) return false;
        existing["m_NumberOfRecipeUses"] = reissueAll
            ? JsonValue.Create(checked(existing["m_NumberOfRecipeUses"]!.GetValue<int>() + 1))
            : recipe["m_NumberOfRecipeUses"]!.DeepClone();
        existing["m_bIsNew"] = true;
        return true;
    }

    private static (string[] Ids, JsonArray? Recipes, bool ReissueAll) RequireLegitimateCustomization(string catalogPath, string id)
    {
        var catalog = JsonNode.Parse(File.ReadAllText(catalogPath)) as JsonObject
            ?? throw new InvalidDataException("Invalid reviewed customization catalog.");
        if (catalog["schemaVersion"]?.GetValue<int>() != 1 || catalog["entries"] is not JsonArray entries)
            throw new InvalidDataException("Unsupported reviewed customization catalog.");
        if (id.StartsWith("appearance:", StringComparison.Ordinal))
        {
            var raw = id[11..];
            var parents = entries.OfType<JsonObject>().Where(e =>
                e["id"]?.GetValue<string>() is "ObservedGearAppearances" or "ObservedCharacterSwatches"
                && e["customizationIds"] is JsonArray ids && ids.Any(v => v?.GetValue<string>() == raw)).ToArray();
            if (parents.Length != 1 || string.IsNullOrWhiteSpace(parents[0]["acquisition"]?.GetValue<string>())
                || string.IsNullOrWhiteSpace(parents[0]["mappingEvidence"]?.GetValue<string>()))
                throw new ArgumentException("Choose an exact supported character appearance.");
            return ([raw], null, false);
        }
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
            return ([], recipes, id == "MaxAugmentationSchematics");
        }
        var ids = matches[0]["customizationIds"] is JsonArray mapped
            ? mapped.Select(e => e!.GetValue<string>()).ToArray() : [id];
        if (ids.Length == 0 || ids.Any(string.IsNullOrWhiteSpace)
            || ids.Distinct(StringComparer.Ordinal).Count() != ids.Length)
            throw new InvalidDataException("Invalid reviewed customization mapping.");
        return (ids, null, false);
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
                        if (GrantReviewedRecipe(known, recipe!.AsObject(), selection.ReissueAll)) added++;
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
                        : selection.ReissueAll
                            ? "Maximum-level augmentation schematic uses granted. Other recipe levels were preserved."
                            : "Missing and exhausted schematic recipes granted. Recipes with uses remaining and unlimited unlocks were preserved." };
            } catch { ExecuteNonQuery(db, "ROLLBACK;"); throw; }
        }, requireGameClosed: true);
    }
}
