using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Nodes;

try
{
    if (args.Length == 1 && args[0] == "--self-test")
    {
        var names = new JsonArray("TankGenerator", "TankLocomotion");
        var rows = new JsonArray();
        foreach (var name in new[] { "TankGenerator_6", "TankLocomotionFrontLeft_6", "TankLocomotionFrontRight_6", "TankLocomotionBackLeft_6", "TankLocomotionBackRight_6" })
        {
            var raw = new byte[8];
            BinaryPrimitives.WriteInt32LittleEndian(raw, name.StartsWith("TankGenerator") ? 0 : 1);
            BinaryPrimitives.WriteInt32LittleEndian(raw.AsSpan(4), 7);
            rows.Add(new JsonObject { ["Name"] = name, ["Value"] = new JsonArray(new JsonObject { ["Name"] = "m_ItemTemplate", ["Value"] = Convert.ToBase64String(raw) }) });
        }
        var doc = new JsonObject { ["NameMap"] = names, ["Exports"] = new JsonArray(new JsonObject { ["Table"] = new JsonObject { ["Data"] = rows } }) };
        RewriteModules(doc);
        if (doc["NameMap"]!.AsArray().Count != 4) throw new InvalidDataException("Module rewrite self-test failed.");
        Console.WriteLine("{\"ok\":true}");
        return 0;
    }
    if (args.Length != 3 || args[0] is not ("modules" or "blueprint")) throw new ArgumentException("Choose modules or blueprint, input JSON and new output JSON.");
    var input = Path.GetFullPath(args[1]); var output = Path.GetFullPath(args[2]);
    if (input.Equals(output, StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new ArgumentException("Generated output must be a new file.");
    var asset = JsonNode.Parse(File.ReadAllText(input))?.AsObject() ?? throw new InvalidDataException("Invalid asset JSON.");
    if (!(asset["Info"]?.GetValue<string>() ?? "").Contains("UAssetAPI 1.1.0")) throw new InvalidDataException("Unsupported asset serializer.");
    if (args[0] == "modules") RewriteModules(asset); else RewriteBlueprint(asset);
    File.WriteAllText(output, asset.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    Console.WriteLine("{\"ok\":true}");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine(JsonSerializer.Serialize(new { ok = false, error = error.Message }));
    return 1;
}

static void RewriteModules(JsonObject asset)
{
    var names = asset["NameMap"]?.AsArray() ?? throw new InvalidDataException("Missing asset names.");
    var rows = asset["Exports"]?[0]?["Table"]?["Data"]?.AsArray() ?? throw new InvalidDataException("Missing Tank module rows.");
    var expected = new HashSet<string> { "TankGenerator_6", "TankLocomotionFrontLeft_6", "TankLocomotionFrontRight_6", "TankLocomotionBackLeft_6", "TankLocomotionBackRight_6" };
    foreach (var row in rows)
    {
        var name = row?["Name"]?.GetValue<string>() ?? "";
        if (!expected.Contains(name)) continue;
        var props = row!["Value"]!.AsArray().Where(p => p?["Name"]?.GetValue<string>() == "m_ItemTemplate").ToArray();
        if (props.Length != 1) throw new InvalidDataException("Ambiguous Tank module item.");
        var property = props[0]!;
        var raw = Convert.FromBase64String(property["Value"]!.GetValue<string>());
        if (raw.Length != 8 || BinaryPrimitives.ReadInt32LittleEndian(raw.AsSpan(4)) != 7) throw new InvalidDataException("Unsupported Tank module item encoding.");
        var oldIndex = BinaryPrimitives.ReadInt32LittleEndian(raw);
        if (oldIndex < 0 || oldIndex >= names.Count) throw new InvalidDataException("Invalid Tank module name index.");
        var oldName = names[oldIndex]!.GetValue<string>();
        var newName = name == "TankGenerator_6" ? "TreadwheelGenerator" : "TreadwheelLocomotion";
        if (oldName != (name == "TankGenerator_6" ? "TankGenerator" : "TankLocomotion")) throw new InvalidDataException("Unexpected stock Tank module.");
        var index = Enumerable.Range(0, names.Count).FirstOrDefault(i => names[i]?.GetValue<string>() == newName, -1);
        if (index < 0) { index = names.Count; names.Add(newName); }
        BinaryPrimitives.WriteInt32LittleEndian(raw, index);
        property["Value"] = Convert.ToBase64String(raw);
        if (!expected.Remove(name)) throw new InvalidDataException("Duplicate Tank module row.");
    }
    if (expected.Count != 0) throw new InvalidDataException("Stock Tank module rows are incomplete.");
    asset["NamesReferencedFromExportDataCount"] = names.Count;
}

static void RewriteBlueprint(JsonObject asset)
{
    var expected = new HashSet<string> { "Default__BP_Tank_CHOAM_C:m_bIsDeprecated", "DriverSeat_GEN_VARIABLEAbilityShortcuts:SkipSaving" };
    foreach (var export in asset["Exports"]!.AsArray())
    {
        if (export?["Data"] is not JsonArray props) continue;
        foreach (var property in props)
        {
            var key = export!["ObjectName"]?.GetValue<string>() + ":" + property?["Name"]?.GetValue<string>();
            if (!expected.Contains(key)) continue;
            if (property!["Value"]?.GetValue<bool>() != true) throw new InvalidDataException("Unexpected stock Tank flag.");
            property["Value"] = false;
            expected.Remove(key);
        }
    }
    if (expected.Count != 0) throw new InvalidDataException("Stock Tank flags are incomplete.");
    asset["NamesReferencedFromExportDataCount"] = asset["NameMap"]!.AsArray().Count;
}
