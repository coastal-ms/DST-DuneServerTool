using System.Text.Json;
using System.Text.Json.Nodes;

namespace DuneSoloDb;

internal static partial class Program
{
    private sealed record GrantAugmentRule(
        IReadOnlyList<string> Tags,
        IReadOnlyDictionary<int, int> RollCounts);

    private sealed record GrantAugmentCatalog(
        IReadOnlyDictionary<string, GrantAugmentRule> Augments,
        IReadOnlyDictionary<string, IReadOnlyList<string>> MethodItems,
        IReadOnlyDictionary<string, IReadOnlyList<string>> ItemAliases);

    private static GrantAugmentCatalog? ReadGrantAugmentCatalog(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        var augments = new Dictionary<string, GrantAugmentRule>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in root.GetProperty("augments").EnumerateObject())
        {
            var tags = property.Value.GetProperty("tags")
                .EnumerateArray()
                .Select(value => value.GetString() ?? string.Empty)
                .Where(value => value.Length > 0)
                .ToArray();
            var rollCounts = new Dictionary<int, int>();
            if (property.Value.TryGetProperty("gradeEffects", out var grades))
            {
                foreach (var grade in grades.EnumerateObject())
                {
                    if (int.TryParse(grade.Name, out var gradeNumber)
                        && grade.Value.ValueKind == JsonValueKind.Array)
                    {
                        rollCounts[gradeNumber] = grade.Value.GetArrayLength();
                    }
                }
            }
            augments[property.Name] = new GrantAugmentRule(tags, rollCounts);
        }
        return new GrantAugmentCatalog(
            augments,
            ReadTagMap(root.GetProperty("methodItems")),
            ReadTagMap(root.GetProperty("itemAliases")));
    }

    private static IReadOnlyDictionary<string, IReadOnlyList<string>> ReadTagMap(JsonElement element)
    {
        var result = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in element.EnumerateObject())
        {
            result[property.Name] = property.Value
                .EnumerateArray()
                .Select(value => value.GetString() ?? string.Empty)
                .Where(value => value.Length > 0)
                .ToArray();
        }
        return result;
    }

    private static string BuildAugmentedGrantStats(
        int stackMax,
        GrantItem item,
        CatalogRule itemRule,
        GrantAugmentCatalog? catalog)
    {
        if (item.Augments.Count == 0)
        {
            return ItemStatsJson(stackMax);
        }
        if (stackMax > 1 || item.Quantity != 1)
        {
            throw new InvalidDataException("Pre-augmented grants require one non-stackable item.");
        }
        if (catalog is null)
        {
            throw new InvalidDataException("DST augment compatibility data is unavailable.");
        }
        if (item.TemplateId.EndsWith("_Schematic", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Schematics cannot receive augments.");
        }

        var itemTags = catalog.ItemAliases.TryGetValue(item.TemplateId, out var aliasTags)
            ? aliasTags
            : catalog.MethodItems.TryGetValue(itemRule.DisplayName, out var namedTags)
                ? namedTags
                : Array.Empty<string>();
        var slotLimit = itemTags.Any(tag => tag.StartsWith("Items.Clothes", StringComparison.OrdinalIgnoreCase))
            ? 2
            : itemTags.Any(tag => tag.StartsWith("Items.Holsters", StringComparison.OrdinalIgnoreCase))
                ? 3
                : 0;
        var selected = item.Augments.ToArray();
        if (selected.Select(value => value.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count()
            != selected.Length)
        {
            throw new InvalidDataException("The same augment cannot be selected more than once.");
        }
        if (slotLimit == 0)
        {
            throw new InvalidDataException(
                $"DST has no verified augment compatibility mapping for {item.TemplateId}.");
        }
        if (selected.Length == 0 || selected.Length > slotLimit)
        {
            throw new InvalidDataException(
                $"{item.TemplateId} supports between 1 and {slotLimit} selected augment(s).");
        }

        var appliedAugments = new JsonArray();
        var appliedQualities = new JsonArray();
        var appliedRollData = new JsonArray();
        foreach (var selection in selected)
        {
            var augmentId = selection.Id;
            if (!catalog.Augments.TryGetValue(augmentId, out var augment))
            {
                throw new InvalidDataException($"Unknown augment id: {augmentId}");
            }
            var compatible = itemTags.Any(itemTag => augment.Tags.Any(augmentTag =>
                itemTag.Equals(augmentTag, StringComparison.OrdinalIgnoreCase)
                || itemTag.StartsWith($"{augmentTag}.", StringComparison.OrdinalIgnoreCase)));
            if (!compatible)
            {
                throw new InvalidDataException(
                    $"{augmentId} is not compatible with {item.TemplateId}.");
            }
            if (!augment.RollCounts.TryGetValue(selection.Quality, out var rollCount)
                || rollCount < 1)
            {
                throw new InvalidDataException(
                    $"{augmentId} does not support augment grade {selection.Quality}.");
            }

            appliedAugments.Add(new JsonObject { ["Name"] = augmentId });
            appliedQualities.Add(selection.Quality);
            var rolls = new JsonArray();
            for (var index = 0; index < rollCount; index++)
            {
                rolls.Add(DuneAugmentMaxRoll);
            }
            appliedRollData.Add(new JsonObject
            {
                ["StatRolls"] = rolls,
                ["AppliedEffectIndices"] = new JsonArray()
            });
        }

        var stats = new JsonObject
        {
            ["FCustomizationStats"] = new JsonArray(new JsonArray(), new JsonObject()),
            ["FAugmentedItemStats"] = new JsonArray(
                new JsonArray(),
                new JsonObject
                {
                    ["AppliedAugments"] = appliedAugments,
                    ["AppliedAugmentQualities"] = appliedQualities,
                    ["AppliedAugmentRollData"] = appliedRollData
                }),
            ["FItemStackAndDurabilityStats"] = new JsonArray(new JsonArray(), new JsonObject())
        };
        if (itemTags.Any(tag =>
                tag.StartsWith("Items.Holsters.RangedWeapons", StringComparison.OrdinalIgnoreCase)))
        {
            stats["FWeaponItemStats"] = new JsonArray(
                new JsonArray(),
                new JsonObject { ["CurrentAmmo"] = 0 });
        }
        return stats.ToJsonString();
    }
}
