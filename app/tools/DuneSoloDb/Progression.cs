using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static object MaxSpecializations(
        string input,
        string safetyBackup,
        string adapterPath,
        string keystonePath)
    {
        var adapter = ReadPtcAdapter(adapterPath);
        AssertProgressionSchema(input, adapter);
        var keystones = ReadKeystones(keystonePath);
        return RunProgressionMutation(
            input,
            safetyBackup,
            "specializations",
            sqlitePath =>
            {
                using var connection = OpenWritable(sqlitePath);
                var identity = ReadIdentity(connection);
                BeginImmediate(connection);
                try
                {
                    foreach (var track in adapter.Tracks)
                    {
                        ExecuteNonQuery(
                            connection,
                            """
                            INSERT INTO specialization_tracks (
                                player_id, track_type, xp_amount, level
                            )
                            VALUES ($player, $track, $xp, $level)
                            ON CONFLICT(player_id, track_type)
                            DO UPDATE SET xp_amount = excluded.xp_amount,
                                          level = excluded.level;
                            """,
                            ("$player", identity.ControllerId),
                            ("$track", track.Value),
                            ("$xp", adapter.MaxXp),
                            ("$level", adapter.MaxLevel));
                    }

                    foreach (var reward in keystones)
                    {
                        ExecuteNonQuery(
                            connection,
                            """
                            INSERT INTO purchased_specialization_keystones (
                                player_id, keystone_id
                            )
                            VALUES ($player, $reward)
                            ON CONFLICT(player_id, keystone_id) DO NOTHING;
                            """,
                            ("$player", identity.ControllerId),
                            ("$reward", reward.Key));
                    }

                    var components = ReadFglComponents(connection, identity.EntityId);
                    var level = RequireComponentObject(components, "FLevelComponent");
                    var moduleData = level["ModuleData"] as JsonObject ?? new JsonObject();
                    level["ModuleData"] = moduleData;
                    var moduleSpent = SumSkillSpend(moduleData);
                    var currentBonus = GetInt(level, "KeystoneBonusSkillPoints");
                    var currentTotal = GetInt(level, "TotalSkillPoints");
                    var currentUnspent = GetInt(level, "UnspentSkillPoints");
                    var expectedBonus = ReadSpecializationBonus(
                        connection,
                        identity.ControllerId,
                        keystones)
                        + ReadCharacterKeystoneBonus(connection, identity.PawnId);
                    if (expectedBonus > currentBonus)
                    {
                        var delta = expectedBonus - currentBonus;
                        level["KeystoneBonusSkillPoints"] = expectedBonus;
                        level["TotalSkillPoints"] = currentTotal + delta;
                        if (moduleSpent + currentUnspent <= currentTotal)
                        {
                            level["UnspentSkillPoints"] = currentUnspent + delta;
                        }
                    }
                    WriteFglComponents(connection, identity.EntityId, components);

                    foreach (var track in adapter.Tracks)
                    {
                        var rowCount = ScalarLong(
                            connection,
                            """
                            SELECT COUNT(*)
                            FROM specialization_tracks
                            WHERE player_id = $player
                              AND track_type = $track
                              AND level = $level
                              AND xp_amount = $xp;
                            """,
                            ("$player", identity.ControllerId),
                            ("$track", track.Value),
                            ("$level", adapter.MaxLevel),
                            ("$xp", adapter.MaxXp));
                        if (rowCount != 1)
                        {
                            throw new InvalidDataException(
                                $"Specialization verification failed for {track.Key}.");
                        }
                    }
                    var rewardCount = ScalarLong(
                        connection,
                        """
                        SELECT COUNT(*)
                        FROM purchased_specialization_keystones
                        WHERE player_id = $player;
                        """,
                        ("$player", identity.ControllerId));
                    if (rewardCount < keystones.Count)
                    {
                        throw new InvalidDataException(
                            $"Expected {keystones.Count} specialization rewards, found {rewardCount}.");
                    }
                    ValidateDatabase(connection);
                    Commit(connection);
                    return new
                    {
                        tracks = adapter.Tracks.Count,
                        level = adapter.MaxLevel,
                        rewards = rewardCount,
                        expectedSkillPointBonus = expectedBonus
                    };
                }
                catch
                {
                    Rollback(connection);
                    throw;
                }
            });
    }

    private static object CompleteFindTheFremen(
        string input,
        string safetyBackup,
        string adapterPath)
    {
        var adapter = ReadPtcAdapter(adapterPath);
        AssertProgressionSchema(input, adapter);
        return RunProgressionMutation(
            input,
            safetyBackup,
            "find-the-fremen",
            sqlitePath =>
            {
                using var connection = OpenWritable(sqlitePath);
                var identity = ReadIdentity(connection);
                var observedNodes = ReadStrings(
                    connection,
                    """
                    SELECT story_node_id
                    FROM journey_story_node
                    WHERE character_id = $character
                      AND (
                          story_node_id = 'DA_MQ_FindTheFremen'
                          OR story_node_id LIKE 'DA_MQ_FindTheFremen.%'
                      )
                    ORDER BY story_node_id;
                    """,
                    ("$character", identity.CharacterId));
                if (!observedNodes.SequenceEqual(adapter.FremenNodes, StringComparer.Ordinal))
                {
                    throw new InvalidDataException(
                        $"PTC Find-the-Fremen adapter mismatch: expected {adapter.FremenNodes.Count} exact nodes, found {observedNodes.Length}.");
                }

                BeginImmediate(connection);
                try
                {
                    var updated = ExecuteNonQuery(
                        connection,
                        """
                        UPDATE journey_story_node
                        SET complete_condition_state = jsonb('true'),
                            reveal_condition_state = jsonb('true'),
                            has_pending_reward = 0
                        WHERE character_id = $character
                          AND (
                              story_node_id = 'DA_MQ_FindTheFremen'
                              OR story_node_id LIKE 'DA_MQ_FindTheFremen.%'
                          );
                        """,
                        ("$character", identity.CharacterId));
                    if (updated != adapter.FremenNodes.Count)
                    {
                        throw new InvalidDataException(
                            $"Expected to update {adapter.FremenNodes.Count} journey nodes, updated {updated}.");
                    }

                    foreach (var tag in adapter.FremenTags)
                    {
                        ExecuteNonQuery(
                            connection,
                            """
                            INSERT INTO player_tags (character_id, tag)
                            VALUES ($character, $tag)
                            ON CONFLICT(character_id, tag) DO NOTHING;
                            """,
                            ("$character", identity.CharacterId),
                            ("$tag", tag));
                    }

                    var properties = ReadActorProperties(connection, identity.PawnId);
                    var techComponent = EnsureObject(properties, "TechKnowledgePlayerComponent");
                    var tech = EnsureObject(techComponent, "m_TechKnowledge");
                    var recipes = tech["m_TechKnowledgeData"] as JsonArray ?? new JsonArray();
                    tech["m_TechKnowledgeData"] = recipes;
                    foreach (var recipe in adapter.FremenRecipes)
                    {
                        var existing = recipes
                            .OfType<JsonObject>()
                            .FirstOrDefault(value =>
                                string.Equals(
                                    value["ItemKey"]?.GetValue<string>(),
                                    recipe,
                                    StringComparison.Ordinal));
                        if (existing is null)
                        {
                            recipes.Add(new JsonObject
                            {
                                ["ItemKey"] = recipe,
                                ["bIsNewEntry"] = false,
                                ["UnlockedState"] = "Purchased"
                            });
                        }
                        else
                        {
                            existing["UnlockedState"] = "Purchased";
                        }
                    }
                    WriteActorProperties(connection, identity.PawnId, properties);

                    var components = ReadFglComponents(connection, identity.EntityId);
                    var spice = RequireComponentObject(components, "FSpiceAddictionComponent");
                    spice["SystemStatus"] = adapter.SpiceStatus;
                    spice["SpiceVisionEnabledStatus"] = adapter.SpiceStatus;
                    WriteFglComponents(connection, identity.EntityId, components);

                    var completedCount = ScalarLong(
                        connection,
                        """
                        SELECT COUNT(*)
                        FROM journey_story_node
                        WHERE character_id = $character
                          AND (
                              story_node_id = 'DA_MQ_FindTheFremen'
                              OR story_node_id LIKE 'DA_MQ_FindTheFremen.%'
                          )
                          AND json(complete_condition_state) = 'true'
                          AND json(reveal_condition_state) = 'true'
                          AND has_pending_reward = 0;
                        """,
                        ("$character", identity.CharacterId));
                    var tagCount = CountMatchingStrings(
                        connection,
                        "player_tags",
                        "tag",
                        "character_id",
                        identity.CharacterId,
                        adapter.FremenTags);
                    var verifyProperties = ReadActorProperties(connection, identity.PawnId);
                    var recipeCount = CountPurchasedRecipes(
                        verifyProperties,
                        adapter.FremenRecipes);
                    var verifyComponents = ReadFglComponents(connection, identity.EntityId);
                    var verifySpice = RequireComponentObject(
                        verifyComponents,
                        "FSpiceAddictionComponent");
                    if (completedCount != adapter.FremenNodes.Count
                        || tagCount != adapter.FremenTags.Count
                        || recipeCount != adapter.FremenRecipes.Count
                        || verifySpice["SystemStatus"]?.GetValue<string>() != adapter.SpiceStatus
                        || verifySpice["SpiceVisionEnabledStatus"]?.GetValue<string>() != adapter.SpiceStatus)
                    {
                        throw new InvalidDataException(
                            "Find-the-Fremen semantic verification failed.");
                    }
                    ValidateDatabase(connection);
                    Commit(connection);
                    return new
                    {
                        nodes = completedCount,
                        tags = tagCount,
                        recipes = recipeCount,
                        spiceVision = adapter.SpiceStatus
                    };
                }
                catch
                {
                    Rollback(connection);
                    throw;
                }
            });
    }

    private static object EnableAllSkills(
        string input,
        string safetyBackup,
        string adapterPath,
        string skillsPath)
    {
        var adapter = ReadPtcAdapter(adapterPath);
        AssertProgressionSchema(input, adapter);
        var catalog = ReadSkillCatalog(skillsPath);
        var included = catalog
            .Where(key => !adapter.SkillExcludes.Contains(key))
            .ToArray();
        return RunProgressionMutation(
            input,
            safetyBackup,
            "enable-all-skills",
            sqlitePath =>
            {
                using var connection = OpenWritable(sqlitePath);
                var identity = ReadIdentity(connection);
                BeginImmediate(connection);
                try
                {
                    var components = ReadFglComponents(connection, identity.EntityId);
                    var level = RequireComponentObject(components, "FLevelComponent");
                    var moduleData = level["ModuleData"] as JsonObject ?? new JsonObject();
                    level["ModuleData"] = moduleData;
                    var catalogSet = catalog.ToHashSet(StringComparer.Ordinal);
                    var unknownBefore = moduleData
                        .Where(pair => !catalogSet.Contains(pair.Key))
                        .ToDictionary(
                            pair => pair.Key,
                            pair => pair.Value?.ToJsonString() ?? "null",
                            StringComparer.Ordinal);
                    var excludedBefore = adapter.SkillExcludes.ToDictionary(
                        key => key,
                        key => moduleData[key]?.ToJsonString() ?? "null",
                        StringComparer.Ordinal);

                    foreach (var key in included)
                    {
                        var skill = moduleData[key] as JsonObject ?? new JsonObject();
                        var current = GetInt(skill, "SkillPointsSpent");
                        if (current < adapter.SkillLevel)
                        {
                            skill["SkillPointsSpent"] = adapter.SkillLevel;
                        }
                        moduleData[key] = skill;
                    }
                    var spent = SumSkillSpend(moduleData);
                    var currentUnspent = GetInt(level, "UnspentSkillPoints");
                    var unspent = Math.Max(currentUnspent, adapter.SkillBuffer);
                    level["UnspentSkillPoints"] = unspent;
                    level["TotalSkillPoints"] = Math.Max(
                        GetInt(level, "TotalSkillPoints"),
                        spent + unspent);
                    WriteFglComponents(connection, identity.EntityId, components);

                    var properties = ReadActorProperties(connection, identity.PawnId);
                    var tech = EnsureObject(properties, "TechKnowledgePlayerComponent");
                    tech["m_TechKnowledgePoints"] = Math.Max(
                        GetInt(tech, "m_TechKnowledgePoints"),
                        adapter.IntelFloor);
                    WriteActorProperties(connection, identity.PawnId, properties);

                    var verifyComponents = ReadFglComponents(connection, identity.EntityId);
                    var verifyLevel = RequireComponentObject(
                        verifyComponents,
                        "FLevelComponent");
                    var verifyModule = verifyLevel["ModuleData"] as JsonObject
                        ?? throw new InvalidDataException("ModuleData missing after skill write.");
                    var applied = included.Count(key =>
                        GetInt(verifyModule[key] as JsonObject, "SkillPointsSpent")
                        >= adapter.SkillLevel);
                    foreach (var pair in unknownBefore)
                    {
                        if ((verifyModule[pair.Key]?.ToJsonString() ?? "null") != pair.Value)
                        {
                            throw new InvalidDataException(
                                $"Unknown PTC skill key was modified: {pair.Key}");
                        }
                    }
                    foreach (var pair in excludedBefore)
                    {
                        if ((verifyModule[pair.Key]?.ToJsonString() ?? "null") != pair.Value)
                        {
                            throw new InvalidDataException(
                                $"Excluded skill key was modified: {pair.Key}");
                        }
                    }
                    var verifyProps = ReadActorProperties(connection, identity.PawnId);
                    var verifyIntel = GetInt(
                        verifyProps["TechKnowledgePlayerComponent"] as JsonObject,
                        "m_TechKnowledgePoints");
                    if (applied != included.Length
                        || GetInt(verifyLevel, "UnspentSkillPoints") < adapter.SkillBuffer
                        || GetInt(verifyLevel, "TotalSkillPoints")
                            < SumSkillSpend(verifyModule)
                                + GetInt(verifyLevel, "UnspentSkillPoints")
                        || verifyIntel < adapter.IntelFloor)
                    {
                        throw new InvalidDataException(
                            "Enable-All-Skills semantic verification failed.");
                    }
                    ValidateDatabase(connection);
                    Commit(connection);
                    return new
                    {
                        catalogSize = catalog.Length,
                        applied,
                        excluded = adapter.SkillExcludes.Count,
                        unknownPreserved = unknownBefore.Count,
                        levelValue = adapter.SkillLevel,
                        unspent = GetInt(verifyLevel, "UnspentSkillPoints"),
                        total = GetInt(verifyLevel, "TotalSkillPoints"),
                        intel = verifyIntel
                    };
                }
                catch
                {
                    Rollback(connection);
                    throw;
                }
            });
    }

    private static object RunProgressionMutation(
        string input,
        string safetyBackup,
        string action,
        Func<string, object> mutation)
    {
        var original = ReadStable(input);
        EnsureWritableInspection(InspectBytes(original, input));
        var wrapped = Unwrap(original);
        var root = Path.Combine(
            Path.GetTempPath(),
            $"dune-solo-{action}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var sqlitePath = Path.Combine(root, "progression.sqlite");
            File.WriteAllBytes(sqlitePath, wrapped.SqliteBytes);
            var details = mutation(sqlitePath);
            var mutated = Path.Combine(root, "game.db");
            WrapSqlite(sqlitePath, mutated);
            EnsureWritableInspection(InspectPath(mutated));
            Restore(mutated, input, safetyBackup);
            return new
            {
                ok = true,
                action,
                safetyBackup,
                details,
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
                // A retained temp directory is safer than hiding the result.
            }
        }
    }

    private static void AssertProgressionSchema(
        string input,
        PtcAdapter adapter)
    {
        var inspection = InspectPath(input);
        if (!string.Equals(
                inspection.SchemaFingerprint,
                adapter.SchemaFingerprint,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                $"PTC progression adapter schema mismatch: expected {adapter.SchemaFingerprint}, found {inspection.SchemaFingerprint}.");
        }
    }

    private static ProgressionSummary ReadProgressionSummary(
        SqliteConnection connection)
    {
        try
        {
            var tracks = new List<SpecializationStatus>();
            if (TableExists(connection, "specialization_tracks"))
            {
                using var command = connection.CreateCommand();
                command.CommandText = """
                    SELECT track_type, level, xp_amount
                    FROM specialization_tracks
                    WHERE player_id = (
                        SELECT player_controller_id FROM player_state LIMIT 1
                    )
                    ORDER BY track_type;
                    """;
                using var reader = command.ExecuteReader();
                while (reader.Read())
                {
                    tracks.Add(new SpecializationStatus(
                        TrackType: reader.GetInt32(0),
                        Level: reader.GetDouble(1),
                        Xp: reader.GetInt64(2)));
                }
            }
            var rewards = TableExists(connection, "purchased_specialization_keystones")
                ? ScalarLong(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM purchased_specialization_keystones
                    WHERE player_id = (
                        SELECT player_controller_id FROM player_state LIMIT 1
                    );
                    """)
                : 0;
            var fremenTotal = TableExists(connection, "journey_story_node")
                ? ScalarLong(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM journey_story_node
                    WHERE character_id = (SELECT id FROM player_state LIMIT 1)
                      AND (
                          story_node_id = 'DA_MQ_FindTheFremen'
                          OR story_node_id LIKE 'DA_MQ_FindTheFremen.%'
                      );
                    """)
                : 0;
            var fremenComplete = TableExists(connection, "journey_story_node")
                ? ScalarLong(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM journey_story_node
                    WHERE character_id = (SELECT id FROM player_state LIMIT 1)
                      AND (
                          story_node_id = 'DA_MQ_FindTheFremen'
                          OR story_node_id LIKE 'DA_MQ_FindTheFremen.%'
                      )
                      AND json(complete_condition_state) = 'true'
                      AND json(reveal_condition_state) = 'true';
                    """)
                : 0;

            var identity = ReadIdentity(connection);
            var components = ReadFglComponents(connection, identity.EntityId);
            var level = RequireComponentObject(components, "FLevelComponent");
            var moduleData = level["ModuleData"] as JsonObject ?? new JsonObject();
            var enabledAtSeven = moduleData.Count(pair =>
                pair.Key != "(TagName=\"Skills.Ability.VoiceStop\")"
                && GetInt(pair.Value as JsonObject, "SkillPointsSpent") >= 7);
            var spice = RequireComponentObject(
                components,
                "FSpiceAddictionComponent");
            var properties = ReadActorProperties(connection, identity.PawnId);
            var intel = GetInt(
                properties["TechKnowledgePlayerComponent"] as JsonObject,
                "m_TechKnowledgePoints");
            return new ProgressionSummary(
                Specializations: tracks.ToArray(),
                PurchasedRewards: rewards,
                FremenNodesTotal: fremenTotal,
                FremenNodesComplete: fremenComplete,
                SpiceSystemStatus: spice["SystemStatus"]?.GetValue<string>() ?? "",
                SpiceVisionStatus: spice["SpiceVisionEnabledStatus"]?.GetValue<string>() ?? "",
                SkillsAtSeven: enabledAtSeven,
                ModuleKeyCount: moduleData.Count,
                TotalSkillPoints: GetInt(level, "TotalSkillPoints"),
                UnspentSkillPoints: GetInt(level, "UnspentSkillPoints"),
                KeystoneBonusSkillPoints: GetInt(level, "KeystoneBonusSkillPoints"),
                Intel: intel);
        }
        catch
        {
            return ProgressionSummary.Empty;
        }
    }

    private static SqliteConnection OpenWritable(string path)
    {
        var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false
            }.ToString());
        connection.Open();
        ExecuteNonQuery(connection, "PRAGMA foreign_keys = ON;");
        return connection;
    }

    private static void BeginImmediate(SqliteConnection connection)
        => ExecuteNonQuery(connection, "BEGIN IMMEDIATE;");

    private static void Commit(SqliteConnection connection)
        => ExecuteNonQuery(connection, "COMMIT;");

    private static void Rollback(SqliteConnection connection)
    {
        try { ExecuteNonQuery(connection, "ROLLBACK;"); } catch { }
    }

    private static void ValidateDatabase(SqliteConnection connection)
    {
        var integrity = ScalarString(connection, "PRAGMA integrity_check;");
        var foreignKeys = ScalarLong(
            connection,
            "SELECT COUNT(*) FROM pragma_foreign_key_check;");
        if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase)
            || foreignKeys != 0)
        {
            throw new InvalidDataException(
                $"SQLite validation failed (integrity={integrity}, foreignKeys={foreignKeys}).");
        }
    }

    private static SoloIdentity ReadIdentity(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id, player_controller_id, player_pawn_id
            FROM player_state;
            """;
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            throw new InvalidDataException("No Solo character found.");
        }
        var characterId = reader.GetInt64(0);
        var controllerId = reader.GetInt64(1);
        var pawnId = reader.GetInt64(2);
        if (reader.Read())
        {
            throw new InvalidDataException("More than one Solo character found.");
        }
        var entityId = ScalarLong(
            connection,
            """
            SELECT entity_id
            FROM actor_fgl_entities
            WHERE actor_id = $pawn
              AND slot_name = 'DuneCharacter'
            LIMIT 1;
            """,
            ("$pawn", pawnId));
        if (entityId == 0)
        {
            throw new InvalidDataException(
                "DuneCharacter FGL entity was not found.");
        }
        return new SoloIdentity(characterId, controllerId, pawnId, entityId);
    }

    private static JsonObject ReadActorProperties(
        SqliteConnection connection,
        long pawnId)
        => ReadJsonObject(
            connection,
            "SELECT json(properties) FROM actors WHERE id = $id;",
            ("$id", pawnId));

    private static void WriteActorProperties(
        SqliteConnection connection,
        long pawnId,
        JsonObject properties)
    {
        var changed = ExecuteNonQuery(
            connection,
            "UPDATE actors SET properties = jsonb($json) WHERE id = $id;",
            ("$json", properties.ToJsonString()),
            ("$id", pawnId));
        if (changed != 1)
        {
            throw new InvalidDataException("Pawn property write failed.");
        }
    }

    private static JsonObject ReadFglComponents(
        SqliteConnection connection,
        long entityId)
        => ReadJsonObject(
            connection,
            "SELECT json(components) FROM fgl_entities WHERE entity_id = $id;",
            ("$id", entityId));

    private static void WriteFglComponents(
        SqliteConnection connection,
        long entityId,
        JsonObject components)
    {
        var changed = ExecuteNonQuery(
            connection,
            "UPDATE fgl_entities SET components = jsonb($json) WHERE entity_id = $id;",
            ("$json", components.ToJsonString()),
            ("$id", entityId));
        if (changed != 1)
        {
            throw new InvalidDataException("FGL component write failed.");
        }
    }

    private static JsonObject ReadJsonObject(
        SqliteConnection connection,
        string sql,
        params (string Name, object Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var parameter in parameters)
        {
            command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        }
        var raw = Convert.ToString(command.ExecuteScalar());
        return JsonNode.Parse(raw ?? "{}") as JsonObject
            ?? throw new InvalidDataException("Expected JSON object.");
    }

    private static JsonObject RequireComponentObject(
        JsonObject components,
        string name)
    {
        var array = components[name] as JsonArray
            ?? throw new InvalidDataException($"{name} is missing.");
        if (array.Count < 2 || array[1] is not JsonObject value)
        {
            throw new InvalidDataException($"{name}[1] is missing.");
        }
        return value;
    }

    private static JsonObject EnsureObject(JsonObject parent, string name)
    {
        if (parent[name] is JsonObject value) { return value; }
        value = new JsonObject();
        parent[name] = value;
        return value;
    }

    private static int GetInt(JsonObject? value, string name)
    {
        if (value?[name] is not JsonValue node) { return 0; }
        if (node.TryGetValue<int>(out var integer)) { return integer; }
        if (node.TryGetValue<long>(out var longValue)) {
            return checked((int)longValue);
        }
        if (node.TryGetValue<double>(out var doubleValue)) {
            return checked((int)Math.Round(doubleValue));
        }
        return 0;
    }

    private static int SumSkillSpend(JsonObject moduleData)
        => moduleData.Sum(pair =>
            GetInt(pair.Value as JsonObject, "SkillPointsSpent"));

    private static int ReadSpecializationBonus(
        SqliteConnection connection,
        long controllerId,
        IReadOnlyDictionary<int, KeystoneRule> keystones)
    {
        var purchased = ReadLongs(
            connection,
            """
            SELECT keystone_id
            FROM purchased_specialization_keystones
            WHERE player_id = $player;
            """,
            ("$player", controllerId));
        return purchased.Sum(id =>
            keystones.TryGetValue(checked((int)id), out var rule)
                ? SkillPointBonus(rule.Name)
                : 0);
    }

    private static int ReadCharacterKeystoneBonus(
        SqliteConnection connection,
        long pawnId)
    {
        var properties = ReadActorProperties(connection, pawnId);
        var array = properties["KeystonePlayerComponent"]?
            ["m_PurchasedKeystoneIDs"] as JsonArray;
        if (array is null) { return 0; }
        return array.Count(value =>
        {
            if (value is not JsonValue node) { return false; }
            return node.TryGetValue<int>(out var id)
                && id is 7 or 14 or 21;
        });
    }

    private static int SkillPointBonus(string name)
    {
        if (name.EndsWith("_SkillPoint_Super", StringComparison.Ordinal)) return 5;
        if (name.EndsWith("_SkillPoint_Major", StringComparison.Ordinal)) return 3;
        if (name.EndsWith("_SkillPoint", StringComparison.Ordinal)) return 1;
        return 0;
    }

    private static int CountPurchasedRecipes(
        JsonObject properties,
        IReadOnlyList<string> required)
    {
        var recipes = properties["TechKnowledgePlayerComponent"]?
            ["m_TechKnowledge"]?
            ["m_TechKnowledgeData"] as JsonArray;
        if (recipes is null) { return 0; }
        var purchased = recipes
            .OfType<JsonObject>()
            .Where(value =>
                value["UnlockedState"]?.GetValue<string>() == "Purchased")
            .Select(value => value["ItemKey"]?.GetValue<string>() ?? "")
            .ToHashSet(StringComparer.Ordinal);
        return required.Count(purchased.Contains);
    }

    private static int CountMatchingStrings(
        SqliteConnection connection,
        string table,
        string valueColumn,
        string ownerColumn,
        long ownerId,
        IReadOnlyList<string> values)
    {
        var count = 0;
        foreach (var value in values)
        {
            count += checked((int)ScalarLong(
                connection,
                $"SELECT COUNT(*) FROM {table} WHERE {ownerColumn} = $owner AND {valueColumn} = $value;",
                ("$owner", ownerId),
                ("$value", value)));
        }
        return count;
    }

    private static bool TableExists(
        SqliteConnection connection,
        string table)
        => ScalarLong(
            connection,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$name;",
            ("$name", table)) == 1;

    private static string[] ReadStrings(
        SqliteConnection connection,
        string sql,
        params (string Name, object Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var parameter in parameters) {
            command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        }
        var result = new List<string>();
        using var reader = command.ExecuteReader();
        while (reader.Read()) { result.Add(reader.GetString(0)); }
        return result.ToArray();
    }

    private static long[] ReadLongs(
        SqliteConnection connection,
        string sql,
        params (string Name, object Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var parameter in parameters) {
            command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        }
        var result = new List<long>();
        using var reader = command.ExecuteReader();
        while (reader.Read()) { result.Add(reader.GetInt64(0)); }
        return result.ToArray();
    }

    private static PtcAdapter ReadPtcAdapter(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        var specializations = root.GetProperty("specializations");
        var tracks = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in specializations.GetProperty("tracks").EnumerateObject())
        {
            tracks[property.Name] = property.Value.GetInt32();
        }
        var fremen = root.GetProperty("find_the_fremen");
        var skills = root.GetProperty("enable_all_skills");
        return new PtcAdapter(
            Id: root.GetProperty("id").GetString() ?? "",
            SchemaFingerprint: root.GetProperty("schema_fingerprint").GetString() ?? "",
            MaxLevel: specializations.GetProperty("max_level").GetInt32(),
            MaxXp: specializations.GetProperty("max_xp").GetInt32(),
            Tracks: tracks,
            FremenNodes: fremen.GetProperty("nodes")
                .EnumerateArray().Select(value => value.GetString() ?? "").ToArray(),
            FremenTags: fremen.GetProperty("tags")
                .EnumerateArray().Select(value => value.GetString() ?? "").ToArray(),
            FremenRecipes: fremen.GetProperty("recipes")
                .EnumerateArray().Select(value => value.GetString() ?? "").ToArray(),
            SpiceStatus: fremen.GetProperty("spice_status").GetString() ?? "",
            WaterCapacities: root.GetProperty("water_fillable_capacities")
                .EnumerateObject()
                .ToDictionary(
                    property => property.Name,
                    property => property.Value.GetInt32(),
                    StringComparer.OrdinalIgnoreCase),
            SkillLevel: skills.GetProperty("level_value").GetInt32(),
            SkillBuffer: skills.GetProperty("point_buffer").GetInt32(),
            IntelFloor: skills.GetProperty("intel_floor").GetInt32(),
            SkillExcludes: skills.GetProperty("exclude")
                .EnumerateArray()
                .Select(value => value.GetString() ?? "")
                .ToHashSet(StringComparer.Ordinal));
    }

    private static Dictionary<int, KeystoneRule> ReadKeystones(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var result = new Dictionary<int, KeystoneRule>();
        foreach (var property in document.RootElement.EnumerateObject())
        {
            var value = property.Value;
            result[int.Parse(property.Name)] = new KeystoneRule(
                Track: value.GetProperty("track").GetString() ?? "",
                Level: value.GetProperty("level").GetInt32(),
                Name: value.GetProperty("name").GetString() ?? "");
        }
        return result;
    }

    private static string[] ReadSkillCatalog(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.GetProperty("keys")
            .EnumerateArray()
            .Select(value => value.GetString() ?? "")
            .Where(value => value.Length > 0)
            .ToArray();
    }

    private sealed record PtcAdapter(
        string Id,
        string SchemaFingerprint,
        int MaxLevel,
        int MaxXp,
        IReadOnlyDictionary<string, int> Tracks,
        IReadOnlyList<string> FremenNodes,
        IReadOnlyList<string> FremenTags,
        IReadOnlyList<string> FremenRecipes,
        string SpiceStatus,
        IReadOnlyDictionary<string, int> WaterCapacities,
        int SkillLevel,
        int SkillBuffer,
        int IntelFloor,
        HashSet<string> SkillExcludes);

    private sealed record KeystoneRule(
        string Track,
        int Level,
        string Name);

    private sealed record SoloIdentity(
        long CharacterId,
        long ControllerId,
        long PawnId,
        long EntityId);

    private sealed record SpecializationStatus(
        int TrackType,
        double Level,
        long Xp);

    private sealed record ProgressionSummary(
        SpecializationStatus[] Specializations,
        long PurchasedRewards,
        long FremenNodesTotal,
        long FremenNodesComplete,
        string SpiceSystemStatus,
        string SpiceVisionStatus,
        int SkillsAtSeven,
        int ModuleKeyCount,
        int TotalSkillPoints,
        int UnspentSkillPoints,
        int KeystoneBonusSkillPoints,
        int Intel)
    {
        public static ProgressionSummary Empty { get; } = new(
            Array.Empty<SpecializationStatus>(),
            0,
            0,
            0,
            "",
            "",
            0,
            0,
            0,
            0,
            0,
            0);
    }
}
