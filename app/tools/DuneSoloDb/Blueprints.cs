using System.Globalization;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private const long MaxBlueprintFileBytes = 64L * 1024 * 1024;
    private const int MaxBlueprintRowsPerTable = 200_000;

    private static readonly HashSet<string> StructuralBuildingTypes =
        new(StringComparer.Ordinal)
        {
            "Atreides_Outpost_Column",
            "Atreides_Outpost_Column_Corner",
            "Atreides_Outpost_Foundation",
            "Atreides_Outpost_Foundation_Round_Corner",
            "Atreides_Outpost_Foundation_Wedge",
            "Atreides_Outpost_Pillar_Bottom",
            "Atreides_Outpost_Pillar_Middle",
            "Atreides_Outpost_Pillar_Top",
            "Choam_Level2_Column",
            "Choam_Level2_Foundation",
            "Choam_Level2_Pillar_Bottom",
            "Choam_Shelter_Column_Corner_New",
            "Choam_Shelter_Column_New",
            "Harkonnen_Outpost_Column",
            "Harkonnen_Outpost_Foundation",
            "MTX_Neut_DesertMechanic_Center_Column",
            "MTX_Neut_DesertMechanic_Corner_Column",
            "MTX_Neut_DesertMechanic_Foundation",
            "MTX_Smug_Foundation"
        };

    private static object ImportBlueprint(
        string input,
        string safetyBackup,
        string blueprintPath)
    {
        var originalBytes = ReadStable(input);
        EnsureWritableInspection(InspectBytes(originalBytes, input));
        var blueprint = ReadPortableBlueprint(blueprintPath);
        var wrapped = Unwrap(originalBytes);

        var root = Path.Combine(
            Path.GetTempPath(),
            $"dune-solo-blueprint-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var sqlitePath = Path.Combine(root, "blueprint.sqlite");
            File.WriteAllBytes(sqlitePath, wrapped.SqliteBytes);
            var imported = ApplyBlueprintImport(sqlitePath, blueprint);

            var mutated = Path.Combine(root, "game.db");
            WrapSqlite(sqlitePath, mutated);
            EnsureWritableInspection(InspectPath(mutated));
            Restore(mutated, input, safetyBackup);
            return new
            {
                ok = true,
                imported.BlueprintId,
                imported.ItemId,
                blueprint.Name,
                instances = blueprint.Instances.Count,
                placeables = blueprint.Placeables.Count,
                pentashields = blueprint.Pentashields.Count,
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
                // A stale temp directory is safer than hiding the import result.
            }
        }
    }

    private static PortableBlueprint ReadPortableBlueprint(string path)
    {
        var file = new FileInfo(path);
        if (!file.Exists)
        {
            throw new FileNotFoundException("Blueprint file was not found.", path);
        }
        if (file.Length is <= 0 or > MaxBlueprintFileBytes)
        {
            throw new InvalidDataException(
                "Blueprint file must be between 1 byte and 64 MB.");
        }

        using var document = JsonDocument.Parse(
            File.ReadAllBytes(path),
            new JsonDocumentOptions { MaxDepth = 32 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Blueprint file must contain a JSON object.");
        }

        var name = root.TryGetProperty("name", out var nameElement)
            && nameElement.ValueKind == JsonValueKind.String
            ? (nameElement.GetString() ?? string.Empty).Trim()
            : string.Empty;
        if (name.Length > 256 || name.Any(char.IsControl))
        {
            throw new InvalidDataException("Blueprint name is invalid.");
        }

        var instanceElements = ReadBlueprintArray(root, "instances");
        var placeableElements = ReadBlueprintArray(root, "placeables");
        var pentashieldElements = ReadBlueprintArray(root, "pentashields");
        if (instanceElements.Length == 0 && placeableElements.Length == 0)
        {
            throw new InvalidDataException(
                "Blueprint has no instances or placeables.");
        }
        if (instanceElements.Length > MaxBlueprintRowsPerTable
            || placeableElements.Length > MaxBlueprintRowsPerTable
            || pentashieldElements.Length > MaxBlueprintRowsPerTable)
        {
            throw new InvalidDataException(
                "Blueprint exceeds the supported 200000-row limit.");
        }

        var instances = new List<PortableBlueprintInstance>(instanceElements.Length);
        for (var index = 0; index < instanceElements.Length; index++)
        {
            var element = RequireBlueprintObject(instanceElements[index], $"instances[{index}]");
            var buildingType = ReadBlueprintBuildingType(
                element,
                "building_type",
                $"instances[{index}].building_type");
            var id = ReadBlueprintPositiveId(
                element,
                "instance_id",
                index + 1,
                $"instances[{index}].instance_id");
            var providesStability = element.TryGetProperty(
                "provides_stability",
                out var stabilityElement)
                ? ReadBlueprintBoolean(
                    stabilityElement,
                    $"instances[{index}].provides_stability")
                : StructuralBuildingTypes.Contains(buildingType);
            instances.Add(new PortableBlueprintInstance(
                Id: id,
                BuildingType: buildingType,
                X: ReadRequiredBlueprintFloat(
                    element,
                    "x",
                    $"instances[{index}].x"),
                Y: ReadRequiredBlueprintFloat(
                    element,
                    "y",
                    $"instances[{index}].y"),
                Z: ReadRequiredBlueprintFloat(
                    element,
                    "z",
                    $"instances[{index}].z"),
                Yaw: ReadRequiredBlueprintFloat(
                    element,
                    "rotation",
                    $"instances[{index}].rotation"),
                ProvidesStability: providesStability));
        }
        EnsureDistinctBlueprintIds(
            instances.Select(value => value.Id),
            "instance");

        var explicitPlaceableIds = placeableElements.Count(element =>
            element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty("placeable_id", out var id)
            && id.ValueKind != JsonValueKind.Null);
        if (explicitPlaceableIds != 0
            && explicitPlaceableIds != placeableElements.Length)
        {
            throw new InvalidDataException(
                "Blueprint placeable ids must be present on every placeable or omitted from all placeables.");
        }
        var hasExplicitPlaceableIds = explicitPlaceableIds > 0;
        var placeables = new List<PortableBlueprintPlaceable>(placeableElements.Length);
        for (var index = 0; index < placeableElements.Length; index++)
        {
            var element = RequireBlueprintObject(
                placeableElements[index],
                $"placeables[{index}]");
            placeables.Add(new PortableBlueprintPlaceable(
                Id: ReadBlueprintPositiveId(
                    element,
                    "placeable_id",
                    index + 1,
                    $"placeables[{index}].placeable_id"),
                BuildingType: ReadBlueprintBuildingType(
                    element,
                    "building_type",
                    $"placeables[{index}].building_type"),
                X: ReadRequiredBlueprintFloat(
                    element,
                    "x",
                    $"placeables[{index}].x"),
                Y: ReadRequiredBlueprintFloat(
                    element,
                    "y",
                    $"placeables[{index}].y"),
                Z: ReadRequiredBlueprintFloat(
                    element,
                    "z",
                    $"placeables[{index}].z"),
                Yaw: ReadOptionalBlueprintFloat(
                    element,
                    "rx",
                    $"placeables[{index}].rx"),
                Pitch: ReadRequiredBlueprintFloat(
                    element,
                    "ry",
                    $"placeables[{index}].ry"),
                Roll: ReadOptionalBlueprintFloat(
                    element,
                    "rz",
                    $"placeables[{index}].rz")));
        }
        EnsureDistinctBlueprintIds(
            placeables.Select(value => value.Id),
            "placeable");

        var rawPentashieldIds = new long[pentashieldElements.Length];
        for (var index = 0; index < pentashieldElements.Length; index++)
        {
            var element = RequireBlueprintObject(
                pentashieldElements[index],
                $"pentashields[{index}]");
            rawPentashieldIds[index] = ReadBlueprintNonNegativeId(
                element,
                "placeable_id",
                $"pentashields[{index}].placeable_id");
        }
        var legacyZeroBasedPentashields = !hasExplicitPlaceableIds;
        var placeableIds = placeables
            .Select(value => value.Id)
            .ToHashSet();
        var pentashields = new List<PortableBlueprintPentashield>(
            pentashieldElements.Length);
        for (var index = 0; index < pentashieldElements.Length; index++)
        {
            var element = RequireBlueprintObject(
                pentashieldElements[index],
                $"pentashields[{index}]");
            if (!element.TryGetProperty("scale", out var scale)
                || scale.ValueKind != JsonValueKind.Array
                || scale.GetArrayLength() < 3)
            {
                throw new InvalidDataException(
                    $"pentashields[{index}].scale must contain three values.");
            }
            var placeableId = legacyZeroBasedPentashields
                ? checked(rawPentashieldIds[index] + 1)
                : rawPentashieldIds[index];
            if (placeableId <= 0 || !placeableIds.Contains(placeableId))
            {
                throw new InvalidDataException(
                    $"pentashields[{index}].placeable_id does not reference an imported placeable.");
            }
            pentashields.Add(new PortableBlueprintPentashield(
                PlaceableId: placeableId,
                ScaleX: ReadBlueprintInt16(scale[0], $"pentashields[{index}].scale[0]"),
                ScaleY: ReadBlueprintInt16(scale[1], $"pentashields[{index}].scale[1]"),
                ScaleZ: ReadBlueprintInt16(scale[2], $"pentashields[{index}].scale[2]")));
        }
        EnsureDistinctBlueprintIds(
            pentashields.Select(value => value.PlaceableId),
            "pentashield placeable");

        return new PortableBlueprint(name, instances, placeables, pentashields);
    }

    private static BlueprintImportResult ApplyBlueprintImport(
        string sqlitePath,
        PortableBlueprint blueprint)
    {
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = sqlitePath,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false
        }.ToString();
        using var connection = new SqliteConnection(connectionString);
        connection.Open();
        ExecuteNonQuery(connection, "PRAGMA foreign_keys = ON;");

        foreach (var table in new[]
        {
            "items",
            "inventories",
            "player_state",
            "building_blueprints",
            "building_blueprint_instances",
            "building_blueprint_placeables",
            "building_blueprint_pentashields"
        })
        {
            if (!TableExists(connection, table))
            {
                throw new InvalidDataException(
                    $"Solo save is missing required table: {table}");
            }
        }

        long inventoryId;
        long maxItemCount;
        long currentRows;
        using (var command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT inv.id, inv.max_item_count, COUNT(items.id)
                FROM inventories AS inv
                LEFT JOIN items ON items.inventory_id = inv.id
                WHERE inv.actor_id = (
                    SELECT player_pawn_id FROM player_state LIMIT 1
                )
                  AND inv.inventory_type = 0
                GROUP BY inv.id
                ORDER BY inv.id
                LIMIT 1;
                """;
            using var reader = command.ExecuteReader();
            if (!reader.Read())
            {
                throw new InvalidDataException(
                    "No Solo backpack inventory was found.");
            }
            inventoryId = reader.GetInt64(0);
            maxItemCount = reader.IsDBNull(1) ? 0 : reader.GetInt64(1);
            currentRows = reader.GetInt64(2);
        }
        if (maxItemCount > 0 && currentRows + 1 > maxItemCount)
        {
            throw new InvalidDataException(
                "The Solo backpack does not have a free slot for this blueprint.");
        }

        var usedPositions = ReadUsedPositions(connection, inventoryId);
        var position = 0;
        while (usedPositions.Contains(position))
        {
            position++;
        }

        ExecuteNonQuery(connection, "BEGIN IMMEDIATE;");
        try
        {
            const string placeholder =
                """{"FCustomizationStats":[[],{}],"FBuildingBlueprintItemStats":[[],{"PlayerBlueprintId":"!!bbp#0"}],"FItemStackAndDurabilityStats":[[],{"DecayedMaxDurability":0.0}]}""";
            var itemId = ScalarLong(
                connection,
                """
                INSERT INTO items (
                    inventory_id,
                    stack_size,
                    position_index,
                    template_id,
                    is_new,
                    acquisition_time,
                    stats,
                    quality_level,
                    volume_override
                ) VALUES (
                    $inventory,
                    1,
                    $position,
                    'BuildingBlueprint_CopyDevice',
                    1,
                    $time,
                    $stats,
                    0,
                    NULL
                );
                SELECT last_insert_rowid();
                """,
                ("$inventory", inventoryId),
                ("$position", position),
                ("$time", DateTimeOffset.UtcNow.ToUnixTimeSeconds()),
                ("$stats", placeholder));
            var blueprintId = ScalarLong(
                connection,
                """
                INSERT INTO building_blueprints (
                    item_id,
                    player_id,
                    building_blueprint_map
                ) VALUES ($item, NULL, '');
                SELECT last_insert_rowid();
                """,
                ("$item", itemId));
            var stats = BuildBlueprintItemStats(blueprintId, blueprint.Name);
            ExecuteNonQuery(
                connection,
                "UPDATE items SET stats=$stats WHERE id=$item;",
                ("$stats", stats),
                ("$item", itemId));

            foreach (var instance in blueprint.Instances)
            {
                ExecuteNonQuery(
                    connection,
                    """
                    INSERT INTO building_blueprint_instances (
                        building_blueprint_id,
                        instance_id,
                        building_type,
                        transform_x,
                        transform_y,
                        transform_z,
                        transform_yaw,
                        provides_stability,
                        health,
                        hologram
                    ) VALUES (
                        $blueprint,
                        $id,
                        $type,
                        $x,
                        $y,
                        $z,
                        $yaw,
                        $stable,
                        0,
                        1
                    );
                    """,
                    ("$blueprint", blueprintId),
                    ("$id", instance.Id),
                    ("$type", instance.BuildingType),
                    ("$x", instance.X),
                    ("$y", instance.Y),
                    ("$z", instance.Z),
                    ("$yaw", instance.Yaw),
                    ("$stable", instance.ProvidesStability ? 1 : 0));
            }

            foreach (var placeable in blueprint.Placeables)
            {
                ExecuteNonQuery(
                    connection,
                    """
                    INSERT INTO building_blueprint_placeables (
                        building_blueprint_id,
                        placeable_id,
                        building_type,
                        transform_x,
                        transform_y,
                        transform_z,
                        transform_yaw,
                        transform_pitch,
                        transform_roll,
                        hologram
                    ) VALUES (
                        $blueprint,
                        $id,
                        $type,
                        $x,
                        $y,
                        $z,
                        $yaw,
                        $pitch,
                        $roll,
                        1
                    );
                    """,
                    ("$blueprint", blueprintId),
                    ("$id", placeable.Id),
                    ("$type", placeable.BuildingType),
                    ("$x", placeable.X),
                    ("$y", placeable.Y),
                    ("$z", placeable.Z),
                    ("$yaw", placeable.Yaw),
                    ("$pitch", placeable.Pitch),
                    ("$roll", placeable.Roll));
            }

            foreach (var pentashield in blueprint.Pentashields)
            {
                ExecuteNonQuery(
                    connection,
                    """
                    INSERT INTO building_blueprint_pentashields (
                        building_blueprint_id,
                        placeable_id,
                        scale_x,
                        scale_y,
                        scale_z
                    ) VALUES (
                        $blueprint,
                        $placeable,
                        $x,
                        $y,
                        $z
                    );
                    """,
                    ("$blueprint", blueprintId),
                    ("$placeable", pentashield.PlaceableId),
                    ("$x", pentashield.ScaleX),
                    ("$y", pentashield.ScaleY),
                    ("$z", pentashield.ScaleZ));
            }

            var insertedInstances = ScalarLong(
                connection,
                """
                SELECT COUNT(*)
                FROM building_blueprint_instances
                WHERE building_blueprint_id=$id;
                """,
                ("$id", blueprintId));
            var insertedPlaceables = ScalarLong(
                connection,
                """
                SELECT COUNT(*)
                FROM building_blueprint_placeables
                WHERE building_blueprint_id=$id;
                """,
                ("$id", blueprintId));
            var insertedPentashields = ScalarLong(
                connection,
                """
                SELECT COUNT(*)
                FROM building_blueprint_pentashields
                WHERE building_blueprint_id=$id;
                """,
                ("$id", blueprintId));
            var savedReference = ScalarString(
                connection,
                "SELECT stats FROM items WHERE id=$id;",
                ("$id", itemId));
            if (insertedInstances != blueprint.Instances.Count
                || insertedPlaceables != blueprint.Placeables.Count
                || insertedPentashields != blueprint.Pentashields.Count
                || !savedReference.Contains(
                    $"!!bbp#{blueprintId}",
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Blueprint import failed exact post-write verification.");
            }

            var integrity = ScalarString(connection, "PRAGMA integrity_check;");
            var foreignKeys = ScalarLong(
                connection,
                "SELECT COUNT(*) FROM pragma_foreign_key_check;");
            if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase)
                || foreignKeys != 0)
            {
                throw new InvalidDataException(
                    "Blueprint import failed SQLite integrity or foreign-key verification.");
            }

            ExecuteNonQuery(connection, "COMMIT;");
            return new BlueprintImportResult(blueprintId, itemId);
        }
        catch
        {
            try
            {
                ExecuteNonQuery(connection, "ROLLBACK;");
            }
            catch
            {
                // Preserve the original exception.
            }
            throw;
        }
    }

    private static string BuildBlueprintItemStats(long blueprintId, string name)
    {
        var blueprintStats = new Dictionary<string, object?>
        {
            ["PlayerBlueprintId"] = $"!!bbp#{blueprintId}"
        };
        if (!string.IsNullOrEmpty(name))
        {
            blueprintStats["BuildingBlueprintName"] = name;
        }
        var value = new Dictionary<string, object?>
        {
            ["FCustomizationStats"] = new object?[]
            {
                Array.Empty<object>(),
                new Dictionary<string, object?>()
            },
            ["FBuildingBlueprintItemStats"] = new object?[]
            {
                Array.Empty<object>(),
                blueprintStats
            },
            ["FItemStackAndDurabilityStats"] = new object?[]
            {
                Array.Empty<object>(),
                new Dictionary<string, object?>
                {
                    ["DecayedMaxDurability"] = 0.0
                }
            }
        };
        return JsonSerializer.Serialize(value, JsonOptions);
    }

    private static JsonElement RequireBlueprintObject(JsonElement element, string label)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException($"{label} must be a JSON object.");
        }
        return element;
    }

    private static JsonElement[] ReadBlueprintArray(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var element)
            || element.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (element.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException($"{name} must be a JSON array.");
        }
        return element.EnumerateArray().ToArray();
    }

    private static string ReadBlueprintBuildingType(
        JsonElement element,
        string property,
        string label)
    {
        if (!element.TryGetProperty(property, out var value)
            || value.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException($"{label} is required.");
        }
        var result = (value.GetString() ?? string.Empty).Trim();
        if (result.Length is 0 or > 512 || result.Any(char.IsControl))
        {
            throw new InvalidDataException($"{label} is invalid.");
        }
        return result;
    }

    private static long ReadBlueprintPositiveId(
        JsonElement element,
        string property,
        long fallback,
        string label)
    {
        if (!element.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            if (fallback > 0)
            {
                return fallback;
            }
            throw new InvalidDataException($"{label} is required.");
        }

        long result;
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetInt64(out result))
        {
            // Parsed below.
        }
        else if (value.ValueKind == JsonValueKind.String
            && long.TryParse(
                value.GetString(),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out result))
        {
            // Parsed below.
        }
        else
        {
            throw new InvalidDataException(
                $"{label} must be a positive integer.");
        }
        if (result <= 0)
        {
            throw new InvalidDataException(
                $"{label} must be a positive integer.");
        }
        return result;
    }

    private static long ReadBlueprintNonNegativeId(
        JsonElement element,
        string property,
        string label)
    {
        if (!element.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            throw new InvalidDataException($"{label} is required.");
        }

        long result;
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetInt64(out result))
        {
            // Parsed below.
        }
        else if (value.ValueKind == JsonValueKind.String
            && long.TryParse(
                value.GetString(),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out result))
        {
            // Parsed below.
        }
        else
        {
            throw new InvalidDataException(
                $"{label} must be a non-negative integer.");
        }
        if (result < 0)
        {
            throw new InvalidDataException(
                $"{label} must be a non-negative integer.");
        }
        return result;
    }

    private static float ReadRequiredBlueprintFloat(
        JsonElement element,
        string property,
        string label)
    {
        if (!element.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            throw new InvalidDataException($"{label} is required.");
        }
        return ReadBlueprintFloatValue(value, label);
    }

    private static float ReadOptionalBlueprintFloat(
        JsonElement element,
        string property,
        string label)
    {
        if (!element.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return 0f;
        }
        return ReadBlueprintFloatValue(value, label);
    }

    private static float ReadBlueprintFloatValue(
        JsonElement value,
        string label)
    {
        double parsed;
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetDouble(out parsed))
        {
            // Parsed below.
        }
        else if (value.ValueKind == JsonValueKind.String
            && double.TryParse(
                value.GetString(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out parsed))
        {
            // Parsed below.
        }
        else
        {
            throw new InvalidDataException($"{label} must be a finite number.");
        }

        var result = (float)parsed;
        if (!double.IsFinite(parsed) || !float.IsFinite(result))
        {
            throw new InvalidDataException($"{label} must be a finite number.");
        }
        return result;
    }

    private static bool ReadBlueprintBoolean(JsonElement value, string label)
    {
        if (value.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            return value.GetBoolean();
        }
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var number)
            && number is 0 or 1)
        {
            return number == 1;
        }
        if (value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString();
            if (string.Equals(text, "true", StringComparison.OrdinalIgnoreCase)
                || text == "1")
            {
                return true;
            }
            if (string.Equals(text, "false", StringComparison.OrdinalIgnoreCase)
                || text == "0")
            {
                return false;
            }
        }
        throw new InvalidDataException($"{label} must be true or false.");
    }

    private static short ReadBlueprintInt16(JsonElement value, string label)
    {
        int parsed;
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out parsed))
        {
            // Parsed below.
        }
        else if (value.ValueKind == JsonValueKind.String
            && int.TryParse(
                value.GetString(),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out parsed))
        {
            // Parsed below.
        }
        else
        {
            throw new InvalidDataException(
                $"{label} must be a 16-bit integer.");
        }
        if (parsed is < short.MinValue or > short.MaxValue)
        {
            throw new InvalidDataException(
                $"{label} must be a 16-bit integer.");
        }
        return (short)parsed;
    }

    private static void EnsureDistinctBlueprintIds(
        IEnumerable<long> values,
        string label)
    {
        var seen = new HashSet<long>();
        foreach (var value in values)
        {
            if (!seen.Add(value))
            {
                throw new InvalidDataException(
                    $"Blueprint contains duplicate {label} ids.");
            }
        }
    }

    private sealed record PortableBlueprint(
        string Name,
        IReadOnlyList<PortableBlueprintInstance> Instances,
        IReadOnlyList<PortableBlueprintPlaceable> Placeables,
        IReadOnlyList<PortableBlueprintPentashield> Pentashields);

    private sealed record PortableBlueprintInstance(
        long Id,
        string BuildingType,
        float X,
        float Y,
        float Z,
        float Yaw,
        bool ProvidesStability);

    private sealed record PortableBlueprintPlaceable(
        long Id,
        string BuildingType,
        float X,
        float Y,
        float Z,
        float Yaw,
        float Pitch,
        float Roll);

    private sealed record PortableBlueprintPentashield(
        long PlaceableId,
        short ScaleX,
        short ScaleY,
        short ScaleZ);

    private sealed record BlueprintImportResult(long BlueprintId, long ItemId);
}
