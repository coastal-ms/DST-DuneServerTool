using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace DunePlatformStore;

internal static class InventoryStore
{
    private const int MaxRows = 100_000;
    private const int MaxFacetRows = 500;
    private static readonly HashSet<string> EntityTypes =
        new(["player", "storage"], StringComparer.Ordinal);
    private static readonly HashSet<string> Kinds =
        new(["item", "emote", "contract"], StringComparer.Ordinal);
    private static readonly HashSet<string> RefreshTriggers =
        new(
        [
            "startup",
            "ttl-expired",
            "postgres-change",
            "inventory-write",
            "manual",
            "recovery",
            "configuration-change"
        ], StringComparer.Ordinal);
    private static readonly IReadOnlyDictionary<string, string> GroupSorts =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["name-asc"] = "sort_name ASC, template_id_normalized ASC",
            ["name-desc"] = "sort_name DESC, template_id_normalized ASC",
            ["quantity-desc"] = "total_quantity DESC, sort_name ASC, template_id_normalized ASC",
            ["quantity-asc"] = "total_quantity ASC, sort_name ASC, template_id_normalized ASC",
            ["unit-volume-desc"] = "unit_volume IS NULL, unit_volume DESC, sort_name ASC, template_id_normalized ASC",
            ["unit-volume-asc"] = "unit_volume IS NULL, unit_volume ASC, sort_name ASC, template_id_normalized ASC",
            ["total-volume-desc"] = "total_volume IS NULL, total_volume DESC, sort_name ASC, template_id_normalized ASC",
            ["total-volume-asc"] = "total_volume IS NULL, total_volume ASC, sort_name ASC, template_id_normalized ASC",
            ["tier-desc"] = "item_tier IS NULL, item_tier DESC, sort_name ASC, template_id_normalized ASC",
            ["tier-asc"] = "item_tier IS NULL, item_tier ASC, sort_name ASC, template_id_normalized ASC",
            ["quality-desc"] = "quality_max DESC, quality_min DESC, sort_name ASC, template_id_normalized ASC",
            ["quality-asc"] = "quality_max ASC, quality_min ASC, sort_name ASC, template_id_normalized ASC",
            ["occurrences-desc"] = "occurrence_count DESC, sort_name ASC, template_id_normalized ASC",
            ["occurrences-asc"] = "occurrence_count ASC, sort_name ASC, template_id_normalized ASC",
            ["locations-desc"] = "location_count DESC, sort_name ASC, template_id_normalized ASC",
            ["locations-asc"] = "location_count ASC, sort_name ASC, template_id_normalized ASC"
        };
    private static readonly IReadOnlyDictionary<string, string> OccurrenceSorts =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["player-asc"] = "player_name IS NULL, lower(player_name) ASC, item_id ASC",
            ["player-desc"] = "player_name IS NULL, lower(player_name) DESC, item_id ASC",
            ["location-asc"] = "entity_label IS NULL, lower(entity_label) ASC, item_id ASC",
            ["location-desc"] = "entity_label IS NULL, lower(entity_label) DESC, item_id ASC",
            ["quantity-desc"] = "quantity IS NULL, quantity DESC, item_id ASC",
            ["quantity-asc"] = "quantity IS NULL, quantity ASC, item_id ASC",
            ["quality-desc"] = "quality IS NULL, quality DESC, item_id ASC",
            ["quality-asc"] = "quality IS NULL, quality ASC, item_id ASC"
        };

    internal static object Replace(string databasePath, ReplaceInventoryRequest request)
    {
        ValidateReplace(request);
        var stopwatch = Stopwatch.StartNew();
        using var secured = Schema.Open(databasePath, readOnly: false);
        var connection = secured.Connection;
        EnsureSchema(connection);
        using var transaction = connection.BeginTransaction();

        Schema.Execute(connection, transaction,
            """
            DELETE FROM inventory_generations WHERE generation=$generation;
            INSERT INTO inventory_generations(
              generation, observed_at_utc, cached_at_utc, expires_at_utc,
              source_fingerprint, row_count)
            VALUES ($generation, $observed, $cached, $expires, $fingerprint, $rows);
            """,
            ("$generation", request.Generation),
            ("$observed", Timestamp(request.ObservedAt)),
            ("$cached", Timestamp(request.CachedAt)),
            ("$expires", Timestamp(request.ExpiresAt)),
            ("$fingerprint", request.SourceFingerprint),
            ("$rows", request.Items.Count));
        var generationId = ScalarLong(
            connection,
            "SELECT generation_id FROM inventory_generations WHERE generation=$generation;",
            transaction,
            ("$generation", request.Generation));
        InsertItems(connection, transaction, generationId, request.Items);
        Schema.Execute(connection, transaction,
            """
            UPDATE derived_cache_domains
            SET active_generation=$generation,
                refresh_requested_at_utc=NULL,
                invalidated_at_utc=NULL,
                last_trigger='replacement',
                updated_at_utc=$now
            WHERE domain_key='inventory';
            DELETE FROM inventory_generations
            WHERE generation_id NOT IN (
              SELECT generation_id FROM inventory_generations
              ORDER BY generation_id DESC LIMIT 2
            );
            """,
            ("$generation", request.Generation),
            ("$now", Timestamp(DateTimeOffset.UtcNow)));
        transaction.Commit();
        stopwatch.Stop();
        return new
        {
            ok = true,
            schemaVersion = Schema.Version,
            generation = request.Generation,
            rowCount = request.Items.Count,
            retainedGenerations = ScalarLong(connection, "SELECT COUNT(*) FROM inventory_generations;"),
            replaceMs = stopwatch.Elapsed.TotalMilliseconds,
            workingSetBytes = Environment.WorkingSet
        };
    }

    internal static object Status(string databasePath)
    {
        if (!File.Exists(databasePath))
        {
            return new
            {
                ok = true,
                available = false,
                schemaVersion = Schema.Version,
                errorCode = "cache-missing"
            };
        }
        using var secured = Schema.Open(databasePath, readOnly: true);
        var connection = secured.Connection;
        EnsureSchema(connection);
        var domain = ReadDomainState(connection);
        var generation = ReadActiveGeneration(connection);
        return generation is null
            ? MissingSnapshot("inventory-snapshot-missing", domain)
            : Envelope(generation, domain, new
            {
                retainedGenerations = ScalarLong(connection, "SELECT COUNT(*) FROM inventory_generations;")
            });
    }

    internal static object RequestRefresh(
        string databasePath,
        InventoryRefreshTriggerRequest request) =>
        Trigger(databasePath, request, invalidate: false);

    internal static object Invalidate(
        string databasePath,
        InventoryRefreshTriggerRequest request) =>
        Trigger(databasePath, request, invalidate: true);

    internal static object Query(string databasePath, QueryInventoryRequest request)
    {
        ValidateQuery(request);
        if (!File.Exists(databasePath))
        {
            return MissingSnapshot("cache-missing");
        }
        using var secured = Schema.Open(databasePath, readOnly: true);
        var connection = secured.Connection;
        EnsureSchema(connection);
        var domain = ReadDomainState(connection);
        var generation = ReadActiveGeneration(connection);
        if (generation is null)
        {
            return MissingSnapshot("inventory-snapshot-missing", domain);
        }

        var filter = BuildFilter(request, request.Query, includePlayer: true, includeLocation: true);
        using var command = connection.CreateCommand();
        command.CommandText =
            $"""
            WITH filtered AS (
              SELECT * FROM inventory_items
              WHERE generation_id=$generationId AND {filter.Sql}
            ), grouped AS (
              SELECT template_id_normalized,
                     MIN(template_id) AS template_id,
                     MAX(display_name) AS display_name,
                     lower(MAX(display_name)) AS sort_name,
                     SUM(quantity) AS total_quantity,
                     COUNT(*) AS occurrence_count,
                     COUNT(DISTINCT entity_type || ':' || entity_id) AS location_count,
                     MIN(quality) AS quality_min,
                     MAX(quality) AS quality_max,
                     MAX(category) AS category,
                     MAX(tier) AS item_tier,
                     MAX(rarity) AS rarity,
                     MAX(icon) AS icon,
                     MAX(stack_maximum) AS stack_maximum,
                     MAX(volume) AS unit_volume,
                     SUM(quantity * volume) AS total_volume,
                     MAX(vendor_price) AS vendor_price,
                     MAX(is_gradeable) AS is_gradeable
              FROM filtered
              GROUP BY template_id_normalized
            )
            SELECT template_id_normalized, template_id, display_name, total_quantity,
                   occurrence_count, location_count, quality_min, quality_max, category,
                   item_tier, rarity, icon, stack_maximum, unit_volume, vendor_price,
                   is_gradeable
            FROM grouped
            ORDER BY {GroupSorts[request.Sort]}
            LIMIT $take OFFSET $offset;
            """;
        command.Parameters.AddWithValue("$generationId", generation.Id);
        filter.AddParameters(command);
        command.Parameters.AddWithValue("$take", request.Limit + 1);
        command.Parameters.AddWithValue("$offset", request.Offset);
        var groups = ReadGroups(command);
        var truncated = groups.Count > request.Limit;
        if (truncated)
        {
            groups.RemoveAt(groups.Count - 1);
        }

        var players = ReadPlayerFacets(
            connection,
            generation.Id,
            BuildFilter(request, request.Query, includePlayer: false, includeLocation: false));
        var locations = ReadLocationFacets(
            connection,
            generation.Id,
            BuildFilter(request, request.Query, includePlayer: true, includeLocation: false));
        var validity = ReadValidity(connection, generation.Id, request);
        return Envelope(generation, domain, new
        {
            groups,
            players,
            locations,
            selectedPlayerValid = validity.Player,
            selectedLocationValid = validity.Location,
            offset = request.Offset,
            nextOffset = truncated ? request.Offset + request.Limit : (int?)null,
            truncated
        });
    }

    internal static object QueryOccurrences(
        string databasePath,
        QueryInventoryOccurrencesRequest request)
    {
        ValidateOccurrenceQuery(request);
        if (!File.Exists(databasePath))
        {
            return MissingSnapshot("cache-missing");
        }
        using var secured = Schema.Open(databasePath, readOnly: true);
        var connection = secured.Connection;
        EnsureSchema(connection);
        var domain = ReadDomainState(connection);
        var generation = ReadActiveGeneration(connection);
        if (generation is null)
        {
            return MissingSnapshot("inventory-snapshot-missing", domain);
        }

        var normalizedTemplate = NormalizeTemplate(request.TemplateId);
        var filter = BuildFilter(request, "", includePlayer: true, includeLocation: true);
        using var command = connection.CreateCommand();
        command.CommandText =
            $"""
            SELECT item_id, template_id, display_name, kind, quantity, quality,
                   durability, max_durability, water_amount, water_type, category,
                   tier, rarity, icon, stack_maximum, volume, vendor_price,
                   is_gradeable, inventory_id, inventory_type, entity_type, entity_id,
                   entity_label, owner_name, map_name, entity_class, player_id, player_name
            FROM inventory_items
            WHERE generation_id=$generationId
              AND template_id_normalized=$template
              AND {filter.Sql}
            ORDER BY {OccurrenceSorts[request.Sort]}
            LIMIT $take OFFSET $offset;
            """;
        command.Parameters.AddWithValue("$generationId", generation.Id);
        command.Parameters.AddWithValue("$template", normalizedTemplate);
        filter.AddParameters(command);
        command.Parameters.AddWithValue("$take", request.Limit + 1);
        command.Parameters.AddWithValue("$offset", request.Offset);
        var items = ReadItems(command);
        var truncated = items.Count > request.Limit;
        if (truncated)
        {
            items.RemoveAt(items.Count - 1);
        }

        var baseFilter = BuildFilter(request, "", includePlayer: false, includeLocation: false);
        baseFilter.ExtraSql = "template_id_normalized=$facetTemplate";
        baseFilter.ExtraParameters.Add(("$facetTemplate", normalizedTemplate));
        var players = ReadPlayerFacets(connection, generation.Id, baseFilter);
        var locationFilter = BuildFilter(request, "", includePlayer: true, includeLocation: false);
        locationFilter.ExtraSql = "template_id_normalized=$facetTemplate";
        locationFilter.ExtraParameters.Add(("$facetTemplate", normalizedTemplate));
        var locations = ReadLocationFacets(connection, generation.Id, locationFilter);
        var validity = ReadValidity(connection, generation.Id, request, normalizedTemplate);
        return Envelope(generation, domain, new
        {
            templateId = request.TemplateId.Trim(),
            items,
            players,
            locations,
            selectedPlayerValid = validity.Player,
            selectedLocationValid = validity.Location,
            offset = request.Offset,
            nextOffset = truncated ? request.Offset + request.Limit : (int?)null,
            truncated
        });
    }

    private static object Trigger(
        string databasePath,
        InventoryRefreshTriggerRequest request,
        bool invalidate)
    {
        if (!RefreshTriggers.Contains(request.Trigger))
        {
            throw new InvalidDataException($"Unsupported inventory refresh trigger '{request.Trigger}'.");
        }
        using var secured = Schema.Open(databasePath, readOnly: false);
        var connection = secured.Connection;
        EnsureSchema(connection);
        var now = Timestamp(DateTimeOffset.UtcNow);
        Schema.Execute(connection, null,
            invalidate
                ? """
                  UPDATE derived_cache_domains
                  SET active_generation='',
                      refresh_revision=refresh_revision + 1,
                      refresh_requested_at_utc=$now,
                      invalidated_at_utc=$now,
                      last_trigger=$trigger,
                      updated_at_utc=$now
                  WHERE domain_key='inventory';
                  """
                : """
                  UPDATE derived_cache_domains
                  SET refresh_revision=refresh_revision + 1,
                      refresh_requested_at_utc=$now,
                      last_trigger=$trigger,
                      updated_at_utc=$now
                  WHERE domain_key='inventory';
                  """,
            ("$now", now),
            ("$trigger", request.Trigger));
        var domain = ReadDomainState(connection);
        return new
        {
            ok = true,
            schemaVersion = Schema.Version,
            domain = domain.Domain,
            invalidated = domain.InvalidatedAt is not null,
            refreshRevision = domain.RefreshRevision,
            refreshRequestedAt = domain.RefreshRequestedAt,
            invalidatedAt = domain.InvalidatedAt,
            lastTrigger = domain.LastTrigger
        };
    }

    internal static long PruneGenerations(SqliteConnection connection, SqliteTransaction transaction)
    {
        var before = ScalarLong(connection, "SELECT COUNT(*) FROM inventory_generations;", transaction);
        Schema.Execute(connection, transaction,
            """
            DELETE FROM inventory_generations
            WHERE generation_id NOT IN (
              SELECT generation_id FROM inventory_generations
              ORDER BY generation_id DESC LIMIT 2
            );
            """);
        return before - ScalarLong(
            connection,
            "SELECT COUNT(*) FROM inventory_generations;",
            transaction);
    }

    internal static object SelfTest(string databasePath)
    {
        var first = BuildFixture("inventory-1", 1);
        Replace(databasePath, first);
        try
        {
            Replace(databasePath, first with
            {
                Generation = "inventory-invalid",
                Items = [first.Items[0], first.Items[0]]
            });
            throw new InvalidOperationException("An invalid inventory replacement was accepted.");
        }
        catch (InvalidDataException)
        {
        }
        RequireActiveGeneration(databasePath, "inventory-1");

        Replace(databasePath, BuildFixture("inventory-2", 2));
        Replace(databasePath, BuildFixture("inventory-3", 3));
        using (var secured = Schema.Open(databasePath, readOnly: true))
        {
            var connection = secured.Connection;
            EnsureSchema(connection);
            if (ScalarLong(connection, "SELECT COUNT(*) FROM inventory_generations;") != 2)
            {
                throw new InvalidOperationException("Inventory generation retention is not bounded to two.");
            }
        }

        using var groupedJson = JsonDocument.Parse(JsonSerializer.Serialize(
            Query(databasePath, new QueryInventoryRequest
            {
                Sort = "quantity-desc",
                Limit = 1
            }),
            Program.SerializerOptions));
        var groupedRoot = groupedJson.RootElement;
        var groupedData = groupedRoot.GetProperty("data");
        if (!groupedRoot.GetProperty("available").GetBoolean() ||
            groupedData.GetProperty("groups").GetArrayLength() != 1 ||
            !groupedData.GetProperty("truncated").GetBoolean() ||
            groupedData.GetProperty("nextOffset").GetInt32() != 1)
        {
            throw new InvalidOperationException("Bounded inventory group query returned invalid paging.");
        }

        using var occurrencesJson = JsonDocument.Parse(JsonSerializer.Serialize(
            QueryOccurrences(databasePath, new QueryInventoryOccurrencesRequest
            {
                TemplateId = "  SPICE_FIBER ",
                Sort = "player-asc",
                Limit = 100
            }),
            Program.SerializerOptions));
        var occurrenceData = occurrencesJson.RootElement.GetProperty("data");
        if (occurrenceData.GetProperty("items").GetArrayLength() != 2 ||
            occurrenceData.GetProperty("players").GetArrayLength() != 1 ||
            occurrenceData.GetProperty("locations").GetArrayLength() != 2)
        {
            throw new InvalidOperationException(
                "Normalized inventory occurrence query or facets returned invalid results.");
        }

        RequestRefresh(databasePath, new InventoryRefreshTriggerRequest { Trigger = "ttl-expired" });
        using (var refreshJson = JsonDocument.Parse(JsonSerializer.Serialize(
                   Query(databasePath, new QueryInventoryRequest()),
                   Program.SerializerOptions)))
        {
            if (refreshJson.RootElement.GetProperty("freshness").GetProperty("state").GetString() !=
                "refreshing")
            {
                throw new InvalidOperationException("An inventory refresh trigger was not exposed.");
            }
        }
        Invalidate(databasePath, new InventoryRefreshTriggerRequest { Trigger = "postgres-change" });
        using (var invalidJson = JsonDocument.Parse(JsonSerializer.Serialize(
                   Query(databasePath, new QueryInventoryRequest()),
                   Program.SerializerOptions)))
        {
            var invalidRoot = invalidJson.RootElement;
            if (invalidRoot.GetProperty("available").GetBoolean() ||
                !invalidRoot.GetProperty("lifecycle").GetProperty("invalidated").GetBoolean())
            {
                throw new InvalidOperationException("Inventory invalidation did not hide the generation.");
            }
        }
        Replace(databasePath, BuildFixture("inventory-3", 3));

        return new
        {
            atomicValidation = true,
            normalizedGrouping = true,
            boundedQueries = true,
            generationRetention = true,
            typedRefreshTrigger = true,
            typedInvalidationTrigger = true
        };
    }

    internal static void RequireActiveGeneration(string databasePath, string expected)
    {
        using var secured = Schema.Open(databasePath, readOnly: true);
        var connection = secured.Connection;
        EnsureSchema(connection);
        var active = ReadActiveGeneration(connection);
        if (active is null || !string.Equals(active.Generation, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The active inventory generation was not preserved.");
        }
    }

    private static void ValidateReplace(ReplaceInventoryRequest request)
    {
        RequiredKey(request.Generation, 128, nameof(request.Generation));
        RequiredText(request.SourceFingerprint, 256, nameof(request.SourceFingerprint));
        RequiredTimestamp(request.ObservedAt, nameof(request.ObservedAt));
        RequiredTimestamp(request.CachedAt, nameof(request.CachedAt));
        RequiredTimestamp(request.ExpiresAt, nameof(request.ExpiresAt));
        if (request.CachedAt < request.ObservedAt || request.ExpiresAt < request.CachedAt)
        {
            throw new InvalidDataException(
                "Inventory timestamps must be ordered observedAt, cachedAt, expiresAt.");
        }
        if (request.Items is null || request.Items.Count > MaxRows)
        {
            throw new InvalidDataException($"Inventory replacement exceeds {MaxRows} rows.");
        }
        var ids = new HashSet<long>();
        foreach (var item in request.Items)
        {
            if (item.ItemId <= 0 || !ids.Add(item.ItemId))
            {
                throw new InvalidDataException("Inventory item IDs must be unique positive integers.");
            }
            RequiredText(item.TemplateId, 256, nameof(item.TemplateId));
            RequiredText(item.DisplayName, 512, nameof(item.DisplayName));
            if (!Kinds.Contains(item.Kind))
            {
                throw new InvalidDataException($"Unsupported inventory item kind '{item.Kind}'.");
            }
            if (item.Metadata is null)
            {
                throw new InvalidDataException("Inventory item metadata is required.");
            }
            if (item.Quantity is < 0 or > 1_000_000_000 || item.Quality is < 0 or > 1_000_000 ||
                item.InventoryId <= 0 || item.InventoryType is < 0 or > 1_000_000 ||
                item.EntityId <= 0)
            {
                throw new InvalidDataException("Inventory numeric fields are outside their allowed range.");
            }
            if (!EntityTypes.Contains(item.EntityType))
            {
                throw new InvalidDataException($"Unsupported inventory entity type '{item.EntityType}'.");
            }
            OptionalText(item.Durability, 128, nameof(item.Durability));
            OptionalText(item.MaxDurability, 128, nameof(item.MaxDurability));
            OptionalText(item.WaterAmount, 128, nameof(item.WaterAmount));
            OptionalText(item.WaterType, 128, nameof(item.WaterType));
            OptionalText(item.EntityLabel, 512, nameof(item.EntityLabel));
            OptionalText(item.Owner, 512, nameof(item.Owner));
            OptionalText(item.Map, 256, nameof(item.Map));
            OptionalText(item.EntityClass, 512, nameof(item.EntityClass));
            OptionalText(item.Metadata.Category, 128, "metadata.category");
            OptionalText(item.Metadata.Rarity, 128, "metadata.rarity");
            OptionalText(item.Metadata.Icon, 512, "metadata.icon");
            if (item.Metadata.Tier is < 0 or > 1_000_000 ||
                item.Metadata.StackMaximum is < 0 or > 1_000_000_000 ||
                (item.Metadata.Volume is double volume &&
                 (!double.IsFinite(volume) || volume is < 0 or > 1_000_000_000)) ||
                item.Metadata.VendorPrice is < 0 or > 1_000_000_000_000)
            {
                throw new InvalidDataException("Inventory metadata numeric fields are outside their allowed range.");
            }
            var hasPlayerId = item.PlayerId is > 0;
            var hasPlayerName = !string.IsNullOrWhiteSpace(item.PlayerName);
            if (hasPlayerId != hasPlayerName ||
                (item.EntityType == "player" &&
                 (!hasPlayerId || item.PlayerId != item.EntityId)))
            {
                throw new InvalidDataException("Inventory player identity is incomplete or inconsistent.");
            }
            if (item.PlayerName is not null)
            {
                RequiredText(item.PlayerName, 512, nameof(item.PlayerName));
            }
        }
    }

    private static void ValidateQuery(QueryInventoryRequest request)
    {
        ValidateFilter(request);
        OptionalText(request.Query, 256, nameof(request.Query));
        if (!GroupSorts.ContainsKey(request.Sort))
        {
            throw new InvalidDataException($"Unsupported inventory sort '{request.Sort}'.");
        }
        if (request.Limit is < 1 or > 500)
        {
            throw new InvalidDataException("Inventory query limit must be between 1 and 500.");
        }
    }

    private static void ValidateOccurrenceQuery(QueryInventoryOccurrencesRequest request)
    {
        ValidateFilter(request);
        RequiredText(request.TemplateId, 256, nameof(request.TemplateId));
        if (!OccurrenceSorts.ContainsKey(request.Sort))
        {
            throw new InvalidDataException($"Unsupported inventory occurrence sort '{request.Sort}'.");
        }
        if (request.Limit is < 1 or > 100)
        {
            throw new InvalidDataException("Inventory occurrence limit must be between 1 and 100.");
        }
    }

    private static void ValidateFilter(InventoryFilterRequest request)
    {
        if (request.Offset is < 0 or > 1_000_000)
        {
            throw new InvalidDataException("Inventory query offset must be between 0 and 1000000.");
        }
        if (request.EntityTypes is null || request.EntityTypes.Count is < 1 or > 2 ||
            request.EntityTypes.Any(value => !EntityTypes.Contains(value)) ||
            request.EntityTypes.Distinct(StringComparer.Ordinal).Count() != request.EntityTypes.Count)
        {
            throw new InvalidDataException("entityTypes must contain unique 'player' or 'storage' values.");
        }
        ValidatePair(request.ScopeType, request.ScopeId, "scope");
        ValidatePair(request.LocationType, request.LocationId, "location");
        if (request.ScopeType is not null && !request.EntityTypes.Contains(request.ScopeType))
        {
            throw new InvalidDataException("scopeType must be one of the requested entityTypes.");
        }
        if (request.PlayerId is <= 0)
        {
            throw new InvalidDataException("playerId must be a positive integer when supplied.");
        }
    }

    private static void ValidatePair(string? type, long? id, string name)
    {
        if ((type is null) != (id is null) || (type is not null && !EntityTypes.Contains(type)) ||
            id is <= 0)
        {
            throw new InvalidDataException(
                $"{name}Type and {name}Id must be supplied together with a supported type and positive ID.");
        }
    }

    private static void InsertItems(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long generationId,
        IReadOnlyList<InventoryItemInput> items)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO inventory_items(
              generation_id, item_id, template_id, template_id_normalized, display_name,
              kind, quantity, quality, durability, max_durability, water_amount, water_type,
              category, tier, rarity, icon, stack_maximum, volume, vendor_price, is_gradeable,
              inventory_id, inventory_type, entity_type, entity_id, entity_label, owner_name,
              map_name, entity_class, player_id, player_name)
            VALUES (
              $generationId, $itemId, $templateId, $normalized, $displayName,
              $kind, $quantity, $quality, $durability, $maxDurability, $waterAmount, $waterType,
              $category, $tier, $rarity, $icon, $stackMaximum, $volume, $vendorPrice, $isGradeable,
              $inventoryId, $inventoryType, $entityType, $entityId, $entityLabel, $owner,
              $map, $entityClass, $playerId, $playerName);
            """;
        var names = new[]
        {
            "$generationId", "$itemId", "$templateId", "$normalized", "$displayName",
            "$kind", "$quantity", "$quality", "$durability", "$maxDurability", "$waterAmount",
            "$waterType", "$category", "$tier", "$rarity", "$icon", "$stackMaximum", "$volume",
            "$vendorPrice", "$isGradeable", "$inventoryId", "$inventoryType", "$entityType",
            "$entityId", "$entityLabel", "$owner", "$map", "$entityClass", "$playerId", "$playerName"
        };
        var parameters = names.Select(name => command.Parameters.Add(name, SqliteType.Text)).ToArray();
        foreach (var item in items)
        {
            var values = new object[]
            {
                generationId, item.ItemId, item.TemplateId.Trim(), NormalizeTemplate(item.TemplateId),
                item.DisplayName, item.Kind, item.Quantity, item.Quality, item.Durability,
                item.MaxDurability, item.WaterAmount, item.WaterType, item.Metadata.Category,
                item.Metadata.Tier ?? (object)DBNull.Value, item.Metadata.Rarity, item.Metadata.Icon,
                item.Metadata.StackMaximum, item.Metadata.Volume ?? (object)DBNull.Value, item.Metadata.VendorPrice,
                item.Metadata.IsGradeable ? 1 : 0, item.InventoryId, item.InventoryType,
                item.EntityType, item.EntityId, item.EntityLabel, item.Owner, item.Map,
                item.EntityClass, item.PlayerId ?? (object)DBNull.Value,
                item.PlayerName ?? (object)DBNull.Value
            };
            for (var index = 0; index < parameters.Length; index++)
            {
                parameters[index].Value = values[index];
            }
            command.ExecuteNonQuery();
        }
    }

    private static Filter BuildFilter(
        InventoryFilterRequest request,
        string query,
        bool includePlayer,
        bool includeLocation)
    {
        var clauses = new List<string>();
        var parameters = new List<(string, object)>();
        var typeNames = new List<string>();
        for (var index = 0; index < request.EntityTypes.Count; index++)
        {
            var name = $"$entityType{index}";
            typeNames.Add(name);
            parameters.Add((name, request.EntityTypes[index]));
        }
        clauses.Add($"entity_type IN ({string.Join(",", typeNames)})");
        if (request.ScopeType is not null)
        {
            clauses.Add("entity_type=$scopeType AND entity_id=$scopeId");
            parameters.Add(("$scopeType", request.ScopeType));
            parameters.Add(("$scopeId", request.ScopeId!.Value));
        }
        if (!string.IsNullOrWhiteSpace(query))
        {
            clauses.Add(
                """
                (instr(lower(template_id), lower($query)) > 0 OR
                 instr(lower(display_name), lower($query)) > 0 OR
                 instr(lower(entity_label), lower($query)) > 0 OR
                 instr(lower(owner_name), lower($query)) > 0 OR
                 instr(lower(map_name), lower($query)) > 0 OR
                 instr(lower(entity_type), lower($query)) > 0 OR
                 instr(lower(entity_class), lower($query)) > 0 OR
                 instr(lower(kind), lower($query)) > 0 OR
                 instr(CAST(entity_id AS TEXT), $query) > 0 OR
                 instr(CAST(inventory_type AS TEXT), $query) > 0)
                """);
            parameters.Add(("$query", query.Trim()));
        }
        if (includePlayer && request.PlayerId is not null)
        {
            clauses.Add("player_id=$playerId");
            parameters.Add(("$playerId", request.PlayerId.Value));
        }
        if (includeLocation && request.LocationType is not null)
        {
            clauses.Add("entity_type=$locationType AND entity_id=$locationId");
            parameters.Add(("$locationType", request.LocationType));
            parameters.Add(("$locationId", request.LocationId!.Value));
        }
        return new Filter(string.Join(" AND ", clauses), parameters);
    }

    private static List<object> ReadGroups(SqliteCommand command)
    {
        using var reader = command.ExecuteReader();
        var values = new List<object>();
        while (reader.Read())
        {
            var qualityMin = reader.GetInt32(6);
            var qualityMax = reader.GetInt32(7);
            values.Add(new
            {
                groupKey = reader.GetString(0),
                templateId = reader.GetString(1),
                displayName = reader.GetString(2),
                totalQuantity = reader.GetInt64(3),
                occurrenceCount = reader.GetInt64(4),
                locationCount = reader.GetInt64(5),
                quality = new { min = qualityMin, max = qualityMax, mixed = qualityMin != qualityMax },
                metadata = new
                {
                    category = reader.GetString(8),
                    tier = reader.IsDBNull(9) ? (int?)null : reader.GetInt32(9),
                    rarity = reader.GetString(10),
                    icon = reader.GetString(11),
                    stackMaximum = reader.GetInt32(12),
                    volume = reader.IsDBNull(13) ? (double?)null : reader.GetDouble(13),
                    vendorPrice = reader.GetInt64(14),
                    isGradeable = reader.GetInt64(15) == 1
                }
            });
        }
        return values;
    }

    private static List<object> ReadItems(SqliteCommand command)
    {
        using var reader = command.ExecuteReader();
        var values = new List<object>();
        while (reader.Read())
        {
            var entityType = reader.GetString(20);
            var entityId = reader.GetInt64(21);
            var value = new Dictionary<string, object?>
            {
                ["id"] = reader.GetInt64(0),
                ["templateId"] = reader.GetString(1),
                ["displayName"] = reader.GetString(2),
                ["kind"] = reader.GetString(3),
                ["quantity"] = reader.GetInt64(4),
                ["quality"] = reader.GetInt32(5),
                ["durability"] = reader.GetString(6),
                ["maxDurability"] = reader.GetString(7),
                ["waterAmount"] = reader.GetString(8),
                ["waterType"] = reader.GetString(9),
                ["metadata"] = new
                {
                    category = reader.GetString(10),
                    tier = reader.IsDBNull(11) ? (int?)null : reader.GetInt32(11),
                    rarity = reader.GetString(12),
                    icon = reader.GetString(13),
                    stackMaximum = reader.GetInt32(14),
                    volume = reader.IsDBNull(15) ? (double?)null : reader.GetDouble(15),
                    vendorPrice = reader.GetInt64(16),
                    isGradeable = reader.GetInt64(17) == 1
                },
                ["entity"] = new
                {
                    type = entityType,
                    id = entityId,
                    label = reader.GetString(22),
                    owner = reader.GetString(23),
                    map = reader.GetString(24),
                    @class = reader.GetString(25),
                    inventoryId = reader.GetInt64(18),
                    inventoryType = reader.GetInt32(19),
                    workspacePath = entityType == "player"
                        ? $"/players?view=inventory&scope_type=player&scope_id={entityId}"
                        : $"/bases?view=inventory&scope_type=storage&scope_id={entityId}"
                }
            };
            if (!reader.IsDBNull(26))
            {
                value["player"] = new { id = reader.GetInt64(26), name = reader.GetString(27) };
            }
            values.Add(value);
        }
        return values;
    }

    private static List<object> ReadPlayerFacets(
        SqliteConnection connection,
        long generationId,
        Filter filter)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            $"""
            SELECT player_id, MAX(player_name), COUNT(*)
            FROM inventory_items
            WHERE generation_id=$generationId AND player_id IS NOT NULL
              AND {filter.SqlWithExtra}
            GROUP BY player_id
            ORDER BY lower(MAX(player_name)), player_id
            LIMIT {MaxFacetRows};
            """;
        command.Parameters.AddWithValue("$generationId", generationId);
        filter.AddParameters(command);
        using var reader = command.ExecuteReader();
        var values = new List<object>();
        while (reader.Read())
        {
            values.Add(new
            {
                id = reader.GetInt64(0),
                name = reader.GetString(1),
                occurrenceCount = reader.GetInt64(2)
            });
        }
        return values;
    }

    private static List<object> ReadLocationFacets(
        SqliteConnection connection,
        long generationId,
        Filter filter)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            $"""
            SELECT entity_type, entity_id,
                   MAX(CASE WHEN entity_type='player' THEN 'Backpack' ELSE entity_label END),
                   MAX(owner_name), MAX(player_id), MAX(player_name), COUNT(*)
            FROM inventory_items
            WHERE generation_id=$generationId AND {filter.SqlWithExtra}
            GROUP BY entity_type, entity_id
            ORDER BY entity_type, lower(MAX(entity_label)), entity_id
            LIMIT {MaxFacetRows};
            """;
        command.Parameters.AddWithValue("$generationId", generationId);
        filter.AddParameters(command);
        using var reader = command.ExecuteReader();
        var values = new List<object>();
        while (reader.Read())
        {
            values.Add(new
            {
                type = reader.GetString(0),
                id = reader.GetInt64(1),
                label = reader.GetString(2),
                owner = reader.GetString(3),
                playerId = reader.IsDBNull(4) ? 0 : reader.GetInt64(4),
                playerName = reader.IsDBNull(5) ? "" : reader.GetString(5),
                occurrenceCount = reader.GetInt64(6)
            });
        }
        return values;
    }

    private static (bool Player, bool Location) ReadValidity(
        SqliteConnection connection,
        long generationId,
        InventoryFilterRequest request,
        string? normalizedTemplate = null)
    {
        var visible = BuildFilter(request, "", includePlayer: false, includeLocation: false);
        if (normalizedTemplate is not null)
        {
            visible.ExtraSql = "template_id_normalized=$validTemplate";
            visible.ExtraParameters.Add(("$validTemplate", normalizedTemplate));
        }
        using var command = connection.CreateCommand();
        var playerClause = request.PlayerId is null
            ? "1"
            : "EXISTS(SELECT 1 FROM inventory_items WHERE generation_id=$generationId AND " +
              visible.SqlWithExtra + " AND player_id=$validPlayer)";
        var locationClause = request.LocationType is null
            ? "1"
            : "EXISTS(SELECT 1 FROM inventory_items WHERE generation_id=$generationId AND " +
              visible.SqlWithExtra +
              " AND ($validPlayer IS NULL OR player_id=$validPlayer)" +
              " AND entity_type=$validLocationType AND entity_id=$validLocationId)";
        command.CommandText = $"SELECT {playerClause}, {locationClause};";
        command.Parameters.AddWithValue("$generationId", generationId);
        visible.AddParameters(command);
        command.Parameters.AddWithValue("$validPlayer", request.PlayerId ?? (object)DBNull.Value);
        if (request.LocationType is not null)
        {
            command.Parameters.AddWithValue("$validLocationType", request.LocationType);
            command.Parameters.AddWithValue("$validLocationId", request.LocationId!.Value);
        }
        using var reader = command.ExecuteReader();
        reader.Read();
        return (reader.GetInt64(0) == 1, reader.GetInt64(1) == 1);
    }

    private static InventoryGeneration? ReadActiveGeneration(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT g.generation_id, g.generation, g.observed_at_utc, g.cached_at_utc,
                   g.expires_at_utc, g.source_fingerprint, g.row_count
            FROM inventory_generations g
            JOIN derived_cache_domains d
              ON d.domain_key='inventory' AND d.active_generation=g.generation
            LIMIT 1;
            """;
        using var reader = command.ExecuteReader();
        return !reader.Read()
            ? null
            : new InventoryGeneration(
                reader.GetInt64(0),
                reader.GetString(1),
                ParseTimestamp(reader.GetString(2)),
                ParseTimestamp(reader.GetString(3)),
                ParseTimestamp(reader.GetString(4)),
                reader.GetString(5),
                reader.GetInt32(6));
    }

    private static DomainState ReadDomainState(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT domain_key, active_generation, refresh_revision, refresh_requested_at_utc,
                   invalidated_at_utc, last_trigger, updated_at_utc
            FROM derived_cache_domains
            WHERE domain_key='inventory';
            """;
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            throw new InvalidDataException("Inventory cache domain lifecycle state is missing.");
        }
        return new DomainState(
            reader.GetString(0),
            reader.GetString(1),
            reader.GetInt64(2),
            reader.IsDBNull(3) ? null : ParseTimestamp(reader.GetString(3)),
            reader.IsDBNull(4) ? null : ParseTimestamp(reader.GetString(4)),
            reader.IsDBNull(5) ? null : reader.GetString(5),
            ParseTimestamp(reader.GetString(6)));
    }

    private static object Envelope(
        InventoryGeneration generation,
        DomainState domain,
        object data)
    {
        var now = DateTimeOffset.UtcNow;
        return new
        {
            ok = true,
            available = true,
            schemaVersion = Schema.Version,
            generation = generation.Generation,
            observedAt = generation.ObservedAt,
            cachedAt = generation.CachedAt,
            expiresAt = generation.ExpiresAt,
            sourceFingerprint = generation.SourceFingerprint,
            rowCount = generation.RowCount,
            lifecycle = Lifecycle(domain),
            freshness = new
            {
                observedAt = generation.ObservedAt,
                cachedAt = generation.CachedAt,
                expiresAt = generation.ExpiresAt,
                ageSeconds = Math.Max(0, (long)(now - generation.CachedAt).TotalSeconds),
                state = domain.RefreshRequestedAt is not null
                    ? "refreshing"
                    : generation.ExpiresAt > now ? "fresh" : "stale"
            },
            data
        };
    }

    private static object MissingSnapshot(
        string errorCode = "inventory-snapshot-missing",
        DomainState? domain = null) => new
    {
        ok = true,
        available = false,
        schemaVersion = Schema.Version,
        errorCode,
        lifecycle = domain is null ? null : Lifecycle(domain),
        data = (object?)null
    };

    private static object Lifecycle(DomainState domain) => new
    {
        domain = domain.Domain,
        activeGeneration = string.IsNullOrEmpty(domain.ActiveGeneration)
            ? null
            : domain.ActiveGeneration,
        refreshRevision = domain.RefreshRevision,
        refreshRequestedAt = domain.RefreshRequestedAt,
        invalidatedAt = domain.InvalidatedAt,
        invalidated = domain.InvalidatedAt is not null,
        lastTrigger = domain.LastTrigger,
        updatedAt = domain.UpdatedAt
    };

    private static void EnsureSchema(SqliteConnection connection)
    {
        Schema.EnsureSupported(connection);
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "SELECT version, checksum FROM schema_migrations WHERE version IN (1,2,3) ORDER BY version;";
            using var reader = command.ExecuteReader();
            if (!reader.Read() || reader.GetInt32(0) != 1 ||
                !string.Equals(reader.GetString(1), Schema.V1Checksum, StringComparison.Ordinal) ||
                !reader.Read() || reader.GetInt32(0) != 2 ||
                !string.Equals(reader.GetString(1), Schema.V2Checksum, StringComparison.Ordinal) ||
                !reader.Read() || reader.GetInt32(0) != 3 ||
                !string.Equals(reader.GetString(1), Schema.Checksum, StringComparison.Ordinal) ||
                reader.Read())
            {
                throw new InvalidDataException("Cache schema migration identity is missing or invalid.");
            }
        }
        if (ScalarLong(connection,
                "SELECT COUNT(*) FROM derived_cache_domains WHERE domain_key='inventory';") != 1)
        {
            throw new InvalidDataException("Inventory cache domain lifecycle state is missing.");
        }
    }

    private static long ScalarLong(
        SqliteConnection connection,
        string sql,
        SqliteTransaction? transaction = null,
        params (string Name, object Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        foreach (var parameter in parameters)
        {
            command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        }
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static string NormalizeTemplate(string value) => value.Trim().ToLowerInvariant();
    private static string Timestamp(DateTimeOffset value) => value.ToUniversalTime().ToString("O");
    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);

    private static void RequiredTimestamp(DateTimeOffset value, string name)
    {
        if (value == default)
        {
            throw new InvalidDataException($"{name} is required.");
        }
    }

    private static void RequiredKey(string value, int maximum, string name)
    {
        RequiredText(value, maximum, name);
        if (value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || "._:/-".Contains(character))))
        {
            throw new InvalidDataException($"{name} contains unsupported characters.");
        }
    }

    private static void RequiredText(string value, int maximum, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidDataException($"{name} is required.");
        }
        OptionalText(value, maximum, name);
    }

    private static void OptionalText(string value, int maximum, string name)
    {
        if (value.Length > maximum || value.Any(char.IsControl))
        {
            throw new InvalidDataException($"{name} is too long or contains control characters.");
        }
    }

    private static ReplaceInventoryRequest BuildFixture(string generation, int revision)
    {
        var now = DateTimeOffset.UtcNow;
        var metadata = new InventoryMetadataInput
        {
            Category = "resource",
            Tier = 2,
            Rarity = "common",
            Icon = "spice.png",
            StackMaximum = 100,
            Volume = 0.5,
            VendorPrice = 10
        };
        return new ReplaceInventoryRequest
        {
            Generation = generation,
            ObservedAt = now.AddSeconds(-1),
            CachedAt = now,
            ExpiresAt = now.AddMinutes(5),
            SourceFingerprint = $"fixture-{revision}",
            Items =
            [
                new InventoryItemInput
                {
                    ItemId = revision * 1000 + 1,
                    TemplateId = "Spice_Fiber",
                    DisplayName = "Spice Fiber",
                    Kind = "item",
                    Quantity = 20,
                    Quality = 1,
                    Durability = "N/A",
                    MaxDurability = "N/A",
                    WaterAmount = "N/A",
                    Metadata = metadata,
                    InventoryId = 1000,
                    InventoryType = 1,
                    EntityType = "player",
                    EntityId = 100,
                    EntityLabel = "Alice",
                    Owner = "Alice",
                    Map = "Arrakis",
                    PlayerId = 100,
                    PlayerName = "Alice"
                },
                new InventoryItemInput
                {
                    ItemId = revision * 1000 + 2,
                    TemplateId = " spice_fiber ",
                    DisplayName = "Spice Fiber",
                    Kind = "item",
                    Quantity = 40,
                    Quality = 2,
                    Durability = "N/A",
                    MaxDurability = "N/A",
                    WaterAmount = "N/A",
                    Metadata = metadata,
                    InventoryId = 2000,
                    InventoryType = 4,
                    EntityType = "storage",
                    EntityId = 200,
                    EntityLabel = "Spice Locker",
                    Owner = "Alice",
                    Map = "Arrakis",
                    EntityClass = "BP_Storage_C",
                    PlayerId = 100,
                    PlayerName = "Alice"
                },
                new InventoryItemInput
                {
                    ItemId = revision * 1000 + 3,
                    TemplateId = "Water",
                    DisplayName = "Water",
                    Kind = "item",
                    Quantity = 5,
                    Quality = 0,
                    Durability = "N/A",
                    MaxDurability = "N/A",
                    WaterAmount = "5",
                    WaterType = "water",
                    Metadata = metadata with { Category = "consumable", Icon = "water.png" },
                    InventoryId = 3000,
                    InventoryType = 1,
                    EntityType = "player",
                    EntityId = 300,
                    EntityLabel = "Bob",
                    Owner = "Bob",
                    Map = "Arrakis",
                    PlayerId = 300,
                    PlayerName = "Bob"
                }
            ]
        };
    }

    private sealed record InventoryGeneration(
        long Id,
        string Generation,
        DateTimeOffset ObservedAt,
        DateTimeOffset CachedAt,
        DateTimeOffset ExpiresAt,
        string SourceFingerprint,
        int RowCount);

    private sealed record DomainState(
        string Domain,
        string ActiveGeneration,
        long RefreshRevision,
        DateTimeOffset? RefreshRequestedAt,
        DateTimeOffset? InvalidatedAt,
        string? LastTrigger,
        DateTimeOffset UpdatedAt);

    private sealed class Filter(string sql, List<(string Name, object Value)> parameters)
    {
        internal string Sql { get; } = sql;
        internal string? ExtraSql { get; set; }
        internal List<(string Name, object Value)> ExtraParameters { get; } = [];
        internal string SqlWithExtra => ExtraSql is null ? Sql : $"{Sql} AND {ExtraSql}";

        internal void AddParameters(SqliteCommand command)
        {
            foreach (var parameter in parameters.Concat(ExtraParameters))
            {
                if (!command.Parameters.Contains(parameter.Name))
                {
                    command.Parameters.AddWithValue(parameter.Name, parameter.Value);
                }
            }
        }
    }
}
