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

    private static string RequireLegitimateCustomization(string catalogPath, string id)
    {
        var catalog = JsonNode.Parse(File.ReadAllText(catalogPath)) as JsonObject
            ?? throw new InvalidDataException("Invalid reviewed customization catalog.");
        if (catalog["schemaVersion"]?.GetValue<int>() != 1 || catalog["entries"] is not JsonArray entries)
            throw new InvalidDataException("Unsupported reviewed customization catalog.");
        var matches = entries.OfType<JsonObject>().Where(e =>
            string.Equals(e["id"]?.GetValue<string>(), id, StringComparison.Ordinal)).ToArray();
        if (matches.Length != 1 || string.IsNullOrWhiteSpace(matches[0]["acquisition"]?.GetValue<string>())
            || string.IsNullOrWhiteSpace(matches[0]["mappingEvidence"]?.GetValue<string>()))
            throw new ArgumentException("Choose an exact reviewed ordinary gameplay customization.");
        return id;
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
        id = RequireLegitimateCustomization(catalogPath, id);
        AssertProgressionAdapter(input, ReadSoloAdapter(adapterPath));
        return RunProgressionMutation(input, backup, "grant-legitimate-customization", path => {
            using var db = OpenWritable(path);
            BeginImmediate(db);
            try {
                var player = ReadIdentity(db);
                var properties = ReadActorProperties(db, player.PawnId);
                var added = AppendLegitimateCustomization(properties, id);
                if (added) WriteActorProperties(db, player.PawnId, properties);
                var verified = ReadActorProperties(db, player.PawnId);
                if (!JsonNode.DeepEquals(properties, verified))
                    throw new InvalidDataException("Customization readback failed.");
                ExecuteNonQuery(db, "COMMIT;");
                return new { ok = true, added = added ? 1 : 0, customizationId = id,
                    message = "Reviewed customization saved. Open the game and check the customization menu." };
            } catch { ExecuteNonQuery(db, "ROLLBACK;"); throw; }
        }, requireGameClosed: true);
    }
}
