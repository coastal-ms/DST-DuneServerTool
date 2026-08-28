using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace DunePlatformStore;

internal static partial class PlatformStore
{
    private const int MaxMaps = 500;
    private const int MaxLayers = 64;
    private const int MaxActiveSpice = 5_000;
    private const int MaxHistoryPerRequest = 100_000;
    private const int MaxPublicPoisStored = 10_000;
    private const int MaxPublicPoisHydrated = 2_000;
    private const string AppVersion = "1";
    private static readonly HashSet<string> FreshnessStates =
        new(["fresh", "refreshing", "stale", "unavailable", "partial"], StringComparer.Ordinal);
    private static readonly HashSet<string> CoordinateSpaces =
        new(["none", "sector-v1", "normalized-v1"], StringComparer.Ordinal);
    private static readonly HashSet<string> PoiCoordinateSpaces =
        new(["sector-v1", "normalized-v1"], StringComparer.Ordinal);
    private static readonly HashSet<string> PublicPoiCategories =
        new(["testing-station", "tradepost", "global-resource"], StringComparer.Ordinal);

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$", RegexOptions.CultureInvariant)]
    private static partial Regex KeyPattern();

    internal static object Migrate(string databasePath)
    {
        StorageSecurity.EnsureProtectedDirectory(databasePath);
        var existed = File.Exists(databasePath) && new FileInfo(databasePath).Length > 0;
        using var securedConnection = Schema.Open(databasePath, readOnly: false);
        var connection = securedConnection.Connection;
        var current = Schema.ReadVersion(connection);
        if (current > Schema.Version)
        {
            throw new UnsupportedSchemaException(current, Schema.Version);
        }
        var quickCheck = Schema.QuickCheck(connection);
        if (!string.Equals(quickCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Cache quick check failed: {quickCheck}");
        }
        if (current == Schema.Version)
        {
            ValidateMigrationIdentity(connection);
            return new
            {
                ok = true,
                schemaVersion = current,
                migrated = false,
                backupCreated = false,
                quickCheck
            };
        }

        Schema.Execute(connection, null, "PRAGMA wal_checkpoint(TRUNCATE);");
        var backupPath = existed && HasUserTables(connection)
            ? CreateMigrationBackup(connection, databasePath)
            : null;
        Schema.CreateV1(connection, AppVersion);
        quickCheck = Schema.QuickCheck(connection);
        if (!string.Equals(quickCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Cache quick check after migration failed: {quickCheck}");
        }
        PruneMigrationBackups(databasePath, 1);
        return new
        {
            ok = true,
            schemaVersion = Schema.Version,
            migrated = true,
            backupCreated = backupPath is not null,
            quickCheck
        };
    }

    internal static object Hydrate(string databasePath)
    {
        var stopwatch = Stopwatch.StartNew();
        if (!File.Exists(databasePath))
        {
            return new
            {
                ok = true,
                available = false,
                schemaVersion = Schema.Version,
                errorCode = "cache-missing",
                snapshot = (object?)null,
                hydrateMs = stopwatch.Elapsed.TotalMilliseconds,
                workingSetBytes = Environment.WorkingSet
            };
        }

        using var securedConnection = Schema.Open(databasePath, readOnly: true);
        var connection = securedConnection.Connection;
        Schema.EnsureSupported(connection);
        ValidateMigrationIdentity(connection);
        var generation = ReadMetadata(connection, "active_generation");
        if (string.IsNullOrWhiteSpace(generation))
        {
            return new
            {
                ok = true,
                available = false,
                schemaVersion = Schema.Version,
                errorCode = "snapshot-missing",
                snapshot = (object?)null,
                hydrateMs = stopwatch.Elapsed.TotalMilliseconds,
                workingSetBytes = Environment.WorkingSet
            };
        }

        var sources = ReadSourceHealth(connection);
        var maps = ReadMaps(connection, generation);
        var layers = ReadLayers(connection, generation);
        var activeSpice = ReadActiveSpice(connection, generation);
        var activeSpiceHistory = ReadActiveSpiceHistory(connection);
        var publicPois = ReadPublicPois(connection, generation);
        var snapshot = new MapSnapshot(
            generation,
            DateTimeOffset.UtcNow,
            sources,
            maps,
            layers,
            activeSpice,
            activeSpiceHistory,
            publicPois);
        stopwatch.Stop();
        return new
        {
            ok = true,
            available = true,
            schemaVersion = Schema.Version,
            snapshot,
            hydrateMs = stopwatch.Elapsed.TotalMilliseconds,
            workingSetBytes = Environment.WorkingSet
        };
    }

    internal static object ReplaceGeneration(string databasePath, ReplaceGenerationRequest request)
    {
        ValidateRequest(request);
        var stopwatch = Stopwatch.StartNew();
        using var securedConnection = Schema.Open(databasePath, readOnly: false);
        var connection = securedConnection.Connection;
        Schema.EnsureSupported(connection);
        ValidateMigrationIdentity(connection);
        using var transaction = connection.BeginTransaction();
        var now = DateTimeOffset.UtcNow;

        Schema.Execute(connection, transaction,
            """
            DELETE FROM map_catalog;
            DELETE FROM active_spice_current;
            DELETE FROM public_poi_layer;
            DELETE FROM layer_snapshots WHERE generation=$generation;
            DELETE FROM active_spice_history WHERE generation=$generation;
            """,
            ("$generation", request.Generation));
        UpsertSources(connection, transaction, request.Sources);
        InsertMaps(connection, transaction, request.Generation, request.Maps);
        InsertLayers(connection, transaction, request.Generation, request.Layers);
        InsertActiveSpiceCurrent(connection, transaction, request.Generation, request.ActiveSpiceCurrent);
        InsertActiveSpiceHistory(connection, transaction, request.Generation, request.ActiveSpiceHistory);
        InsertPublicPois(connection, transaction, request.Generation, request.PublicPois);
        Schema.Execute(connection, transaction,
            """
            INSERT INTO cache_metadata(key, value, updated_at_utc)
            VALUES ('active_generation', $generation, $now)
            ON CONFLICT(key) DO UPDATE SET
              value=excluded.value,
              updated_at_utc=excluded.updated_at_utc;
            """,
            ("$generation", request.Generation),
            ("$now", FormatTimestamp(now)));
        transaction.Commit();
        stopwatch.Stop();
        return new
        {
            ok = true,
            schemaVersion = Schema.Version,
            generation = request.Generation,
            counts = new
            {
                sources = request.Sources.Count,
                maps = request.Maps.Count,
                layers = request.Layers.Count,
                activeSpice = request.ActiveSpiceCurrent.Count,
                historyAdded = request.ActiveSpiceHistory.Count,
                publicPois = request.PublicPois.Count
            },
            replaceMs = stopwatch.Elapsed.TotalMilliseconds,
            workingSetBytes = Environment.WorkingSet
        };
    }

    internal static object Integrity(string databasePath)
    {
        if (!File.Exists(databasePath))
        {
            return new
            {
                ok = true,
                available = false,
                schemaVersion = Schema.Version,
                quickCheck = "not-run",
                errorCode = "cache-missing"
            };
        }
        using var securedConnection = Schema.Open(databasePath, readOnly: true);
        var connection = securedConnection.Connection;
        Schema.EnsureSupported(connection);
        ValidateMigrationIdentity(connection);
        var quickCheck = Schema.QuickCheck(connection);
        if (!string.Equals(quickCheck, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Cache quick check failed: {quickCheck}");
        }
        var generation = ReadMetadata(connection, "active_generation");
        var sources = ReadSourceHealth(connection);
        var layers = ReadLayerHealth(connection, generation);
        return new
        {
            ok = true,
            available = true,
            helperVersion = AppVersion,
            schemaVersion = Schema.Version,
            schemaChecksum = Schema.Checksum,
            quickCheck,
            fileBytes = new FileInfo(databasePath).Length,
            generationPresent = !string.IsNullOrWhiteSpace(generation),
            counts = new
            {
                maps = ScalarLong(connection, "SELECT COUNT(*) FROM map_catalog;"),
                layerSnapshots = ScalarLong(connection, "SELECT COUNT(*) FROM layer_snapshots;"),
                activeSpiceCurrent = ScalarLong(connection, "SELECT COUNT(*) FROM active_spice_current;"),
                activeSpiceHistory = ScalarLong(connection, "SELECT COUNT(*) FROM active_spice_history;"),
                publicPois = ScalarLong(connection, "SELECT COUNT(*) FROM public_poi_layer;")
            },
            sources,
            layers
        };
    }

    internal static object Prune(
        string databasePath,
        int historyDays,
        int historyRows,
        int snapshotGenerations,
        long maxBytes)
    {
        using var securedConnection = Schema.Open(databasePath, readOnly: false);
        var connection = securedConnection.Connection;
        Schema.EnsureSupported(connection);
        ValidateMigrationIdentity(connection);
        using var transaction = connection.BeginTransaction();
        var historyBefore = ScalarLong(connection, "SELECT COUNT(*) FROM active_spice_history;", transaction);
        var snapshotsBefore = ScalarLong(connection, "SELECT COUNT(*) FROM layer_snapshots;", transaction);
        var cutoff = FormatTimestamp(DateTimeOffset.UtcNow.AddDays(-historyDays));
        Schema.Execute(connection, transaction,
            "DELETE FROM active_spice_history WHERE observed_at_utc < $cutoff;",
            ("$cutoff", cutoff));
        Schema.Execute(connection, transaction,
            """
            DELETE FROM active_spice_history
            WHERE observation_id IN (
              SELECT observation_id
              FROM (
                SELECT observation_id,
                       ROW_NUMBER() OVER (
                         PARTITION BY farm_id, map_id, partition_id
                         ORDER BY observed_at_utc DESC, observation_id DESC
                       ) AS row_number
                FROM active_spice_history
              )
              WHERE row_number > $historyRows
            );
            """,
            ("$historyRows", historyRows));
        Schema.Execute(connection, transaction,
            """
            DELETE FROM layer_snapshots
            WHERE generation NOT IN (
              SELECT generation
              FROM layer_snapshots
              GROUP BY generation
              ORDER BY MAX(snapshot_id) DESC
              LIMIT $generations
            );
            """,
            ("$generations", snapshotGenerations));
        transaction.Commit();
        Schema.Execute(connection, null, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(2000);");
        PruneMigrationBackups(databasePath, 1);
        var sizePressureRowsRemoved = 0L;
        var historyAfter = ScalarLong(connection, "SELECT COUNT(*) FROM active_spice_history;");
        var fileBytes = new FileInfo(databasePath).Length;
        for (var pass = 0; pass < 20 && fileBytes > maxBytes && historyAfter > 1_000; pass++)
        {
            using var sizeTransaction = connection.BeginTransaction();
            Schema.Execute(connection, sizeTransaction,
                """
                DELETE FROM active_spice_history
                WHERE observation_id IN (
                  SELECT observation_id
                  FROM active_spice_history
                  ORDER BY observed_at_utc, observation_id
                  LIMIT 5000
                );
                """);
            sizeTransaction.Commit();
            sizePressureRowsRemoved += Math.Min(5_000, historyAfter);
            Schema.Execute(connection, null, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(5000);");
            historyAfter = ScalarLong(connection, "SELECT COUNT(*) FROM active_spice_history;");
            fileBytes = new FileInfo(databasePath).Length;
        }
        var snapshotsAfter = ScalarLong(connection, "SELECT COUNT(*) FROM layer_snapshots;");
        return new
        {
            ok = true,
            historyRemoved = historyBefore - historyAfter,
            snapshotsRemoved = snapshotsBefore - snapshotsAfter,
            historyRows = historyAfter,
            sizePressureRowsRemoved,
            snapshotRows = snapshotsAfter,
            fileBytes,
            sizePressure = fileBytes > maxBytes,
            maxBytes
        };
    }

    internal static object CreateTestFixture(string databasePath, int historyRows, int poiRows)
    {
        foreach (var suffix in new[] { "", "-wal", "-shm" })
        {
            var path = databasePath + suffix;
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        Migrate(databasePath);
        var request = BuildFixture("fixture-1", historyRows, poiRows);
        var result = ReplaceGeneration(databasePath, request);
        using var securedConnection = Schema.Open(databasePath, readOnly: false);
        var connection = securedConnection.Connection;
        Schema.Execute(connection, null, "PRAGMA wal_checkpoint(TRUNCATE);");
        return new
        {
            ok = true,
            historyRows,
            poiRows,
            fileBytes = new FileInfo(databasePath).Length,
            replace = result
        };
    }

    internal static object SelfTest()
    {
        var priorSelfTest = Environment.GetEnvironmentVariable("DST_PLATFORM_SELF_TEST");
        Environment.SetEnvironmentVariable("DST_PLATFORM_SELF_TEST", "1");
        var root = Path.Combine(Path.GetTempPath(), $"dune-platform-store-self-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            Require(!PrivilegeDrop.IsElevated(), "The cache helper self-test retained an elevated token.");
            Require(
                PrivilegeDrop.SelfTestInheritableStandardHandles(),
                "The cache helper could not create inheritable standard handles.");
            var shellParentAvailable = PrivilegeDrop.HasInteractiveShell();
            var shellParentTested = !shellParentAvailable || PrivilegeDrop.SelfTestShellParentLaunch();
            Require(shellParentTested, "The Explorer parent-process launch self-test failed.");
            var killOnParentExit = !shellParentAvailable || PrivilegeDrop.SelfTestShellParentKillOnExit();
            Require(killOnParentExit, "The shell-parented child survived its wrapper process.");
            var database = Path.Combine(root, "platform-cache-v1.sqlite");
            CreateTestFixture(database, 100_000, 2_000);
            var hydrateJson = System.Text.Json.JsonSerializer.Serialize(
                Hydrate(database),
                Program.SerializerOptions);
            using (var hydrate = System.Text.Json.JsonDocument.Parse(hydrateJson))
            {
                var rootElement = hydrate.RootElement;
                Require(rootElement.GetProperty("available").GetBoolean(), "Fixture did not hydrate.");
                var snapshot = rootElement.GetProperty("snapshot");
                Require(snapshot.GetProperty("publicPois").GetArrayLength() == 2_000, "POI hydrate count is invalid.");
            }

            var concurrentRequest = BuildFixture("fixture-2", 1, 2_000);
            VerifyConcurrentProcesses(database, concurrentRequest);
            ReplaceGeneration(database, concurrentRequest);
            using (var securedRetryCheck = Schema.Open(database, readOnly: true))
            {
                var retryCheck = securedRetryCheck.Connection;
                Require(
                    ScalarLong(retryCheck,
                        "SELECT COUNT(*) FROM active_spice_history WHERE generation='fixture-2';") == 1,
                    "Retrying a generation duplicated its history rows.");
            }

            VerifyInterruptedWriteRecovery(database);
            var integrity = Integrity(database);
            var prune = Prune(database, 90, 100_000, 20, 250L * 1024 * 1024);
            VerifyMigrationBackup(root);
            VerifyInterruptedMigrationRecovery(root);
            VerifyNewerSchemaFailure(root);
            VerifyCorruptionFailure(root);
            VerifyOffsetTimestampPruning(root);
            Require(
                StorageSecurity.SelfTestHeldHandleRace(root),
                "Held no-follow handles did not block a path replacement race.");
            return new
            {
                ok = true,
                schemaVersion = Schema.Version,
                historyScale = 100_000,
                publicPoiScale = 2_000,
                concurrentReaders = 8,
                concurrentWriters = 1,
                processConcurrency = true,
                oneShotExit = true,
                interruptedWriteRecovery = true,
                interruptedMigrationRecovery = true,
                idempotentGenerationReplace = true,
                offsetTimestampPruning = true,
                pathRaceResistance = true,
                inheritableStandardHandles = true,
                shellParentAvailable,
                shellParentTested,
                killOnParentExit,
                runningElevated = PrivilegeDrop.IsElevated(),
                migrationBackup = true,
                newerSchemaFailure = true,
                corruptionFailure = true,
                integrity,
                prune,
                processId = Environment.ProcessId,
                workingSetBytes = Environment.WorkingSet
            };
        }
        finally
        {
            TryDeleteDirectory(root);
            Environment.SetEnvironmentVariable("DST_PLATFORM_SELF_TEST", priorSelfTest);
        }
    }

    private static void ValidateRequest(ReplaceGenerationRequest request)
    {
        ValidateKey(request.Generation, nameof(request.Generation));
        ValidateCount(request.Sources.Count, 0, 32, nameof(request.Sources));
        ValidateCount(request.Maps.Count, 0, MaxMaps, nameof(request.Maps));
        ValidateCount(request.Layers.Count, 0, MaxLayers, nameof(request.Layers));
        ValidateCount(request.ActiveSpiceCurrent.Count, 0, MaxActiveSpice, nameof(request.ActiveSpiceCurrent));
        ValidateCount(request.ActiveSpiceHistory.Count, 0, MaxHistoryPerRequest, nameof(request.ActiveSpiceHistory));
        ValidateCount(request.PublicPois.Count, 0, MaxPublicPoisStored, nameof(request.PublicPois));
        RequireUnique(request.Sources.Select(value => value.SourceKey), "source key");
        RequireUnique(
            request.Maps.Select(value => $"{value.FarmId}\0{value.MapId}\0{value.PartitionId}"),
            "map identity");
        RequireUnique(
            request.Layers.Select(value =>
                $"{value.FarmId}\0{value.MapId}\0{value.PartitionId}\0{value.LayerId}"),
            "layer identity");
        RequireUnique(
            request.ActiveSpiceCurrent.Select(value =>
                $"{value.FarmId}\0{value.MapId}\0{value.PartitionId}\0{value.FieldId}"),
            "active spice identity");
        RequireUnique(
            request.PublicPois.Select(value =>
                $"{value.FarmId}\0{value.MapId}\0{value.PartitionId}\0{value.Id}"),
            "public POI identity");

        foreach (var source in request.Sources)
        {
            ValidateKey(source.SourceKey, nameof(source.SourceKey));
            ValidateText(source.SchemaFingerprint, 256, nameof(source.SchemaFingerprint));
            ValidateOptionalErrorCode(source.LastErrorCode);
        }
        foreach (var map in request.Maps)
        {
            ValidateMapIdentity(map.FarmId, map.MapId, map.PartitionId);
            ValidateText(map.Label, 256, nameof(map.Label));
            ValidateKey(map.Kind, nameof(map.Kind));
            RequireTimestamp(map.LastSeenAt, nameof(map.LastSeenAt));
        }
        foreach (var layer in request.Layers)
        {
            ValidateMapIdentity(layer.FarmId, layer.MapId, layer.PartitionId);
            ValidateKey(layer.LayerId, nameof(layer.LayerId));
            ValidateKey(layer.SourceKey, nameof(layer.SourceKey));
            if (!FreshnessStates.Contains(layer.FreshnessState))
            {
                throw new InvalidDataException($"Unsupported freshness state '{layer.FreshnessState}'.");
            }
            ValidateOptionalErrorCode(layer.LastErrorCode);
            if (layer.RowCount < 0 || layer.RowCount > MaxPublicPoisStored)
            {
                throw new InvalidDataException("Layer row count is outside the Maps v1 budget.");
            }
            if (!IsSha256(layer.PayloadSha256))
            {
                throw new InvalidDataException("Layer payloadSha256 must contain 64 hexadecimal characters.");
            }
            RequireTimestamp(layer.CachedAt, nameof(layer.CachedAt));
        }
        foreach (var value in request.ActiveSpiceCurrent.Concat(request.ActiveSpiceHistory))
        {
            ValidateActiveSpice(value);
        }
        foreach (var poi in request.PublicPois)
        {
            ValidateMapIdentity(poi.FarmId, poi.MapId, poi.PartitionId);
            ValidateKey(poi.Id, nameof(poi.Id));
            if (!PublicPoiCategories.Contains(poi.Category))
            {
                throw new InvalidDataException($"Public POI category '{poi.Category}' is not allow-listed.");
            }
            ValidateText(poi.Label, 256, nameof(poi.Label));
            if (!PoiCoordinateSpaces.Contains(poi.CoordinateSpace))
            {
                throw new InvalidDataException($"Unsupported public POI coordinate space '{poi.CoordinateSpace}'.");
            }
            ValidateCoordinate(poi.X, poi.CoordinateSpace, nameof(poi.X));
            ValidateCoordinate(poi.Y, poi.CoordinateSpace, nameof(poi.Y));
            ValidateText(poi.SourceFingerprint, 256, nameof(poi.SourceFingerprint));
            RequireTimestamp(poi.ObservedAt, nameof(poi.ObservedAt));
            RequireTimestamp(poi.ExpiresAt, nameof(poi.ExpiresAt));
        }
    }

    private static void ValidateActiveSpice(ActiveSpiceInput value)
    {
        ValidateMapIdentity(value.FarmId, value.MapId, value.PartitionId);
        ValidateKey(value.FieldId, nameof(value.FieldId));
        ValidateKey(value.State, nameof(value.State));
        if (!CoordinateSpaces.Contains(value.CoordinateSpace))
        {
            throw new InvalidDataException($"Unsupported active spice coordinate space '{value.CoordinateSpace}'.");
        }
        if (value.CoordinateSpace == "none")
        {
            if (value.X is not null || value.Y is not null)
            {
                throw new InvalidDataException("Coordinate space 'none' cannot include coordinates.");
            }
        }
        else
        {
            if (value.X is null || value.Y is null)
            {
                throw new InvalidDataException("Spatial active spice rows require both coordinates.");
            }
            ValidateCoordinate(value.X.Value, value.CoordinateSpace, nameof(value.X));
            ValidateCoordinate(value.Y.Value, value.CoordinateSpace, nameof(value.Y));
        }
        ValidateText(value.SourceFingerprint, 256, nameof(value.SourceFingerprint));
        RequireTimestamp(value.ObservedAt, nameof(value.ObservedAt));
        RequireTimestamp(value.ExpiresAt, nameof(value.ExpiresAt));
    }

    private static void ValidateMapIdentity(string farmId, string mapId, string partitionId)
    {
        ValidateKey(farmId, nameof(farmId));
        ValidateKey(mapId, nameof(mapId));
        ValidateKey(partitionId, nameof(partitionId));
    }

    private static void ValidateKey(string value, string name)
    {
        if (!KeyPattern().IsMatch(value))
        {
            throw new InvalidDataException($"{name} is empty, too long, or contains unsupported characters.");
        }
    }

    private static void ValidateText(string value, int maxLength, string name)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maxLength || value.Any(char.IsControl))
        {
            throw new InvalidDataException($"{name} is empty, too long, or contains control characters.");
        }
    }

    private static void ValidateOptionalErrorCode(string? value)
    {
        if (value is not null)
        {
            ValidateKey(value, "lastErrorCode");
        }
    }

    private static void ValidateCoordinate(double value, string coordinateSpace, string name)
    {
        if (!double.IsFinite(value) || Math.Abs(value) > 10_000_000 ||
            (coordinateSpace == "normalized-v1" && (value < 0 || value > 1)))
        {
            throw new InvalidDataException($"{name} is outside the '{coordinateSpace}' coordinate budget.");
        }
    }

    private static void RequireTimestamp(DateTimeOffset value, string name)
    {
        if (value == default)
        {
            throw new InvalidDataException($"{name} is required.");
        }
    }

    private static void ValidateCount(int count, int minimum, int maximum, string name)
    {
        if (count < minimum || count > maximum)
        {
            throw new InvalidDataException($"{name} count must be between {minimum} and {maximum}.");
        }
    }

    private static void RequireUnique(IEnumerable<string> values, string name)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        if (values.Any(value => !seen.Add(value)))
        {
            throw new InvalidDataException($"The request contains a duplicate {name}.");
        }
    }

    private static bool IsSha256(string value) =>
        value.Length == 64 && value.All(Uri.IsHexDigit);

    private static IReadOnlyList<MapCatalogInput> ReadMaps(SqliteConnection connection, string generation)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT farm_id, map_id, partition_id, label, kind, last_seen_at_utc, active
            FROM map_catalog
            WHERE generation=$generation AND active=1
            ORDER BY farm_id, map_id, partition_id
            LIMIT 500;
            """;
        command.Parameters.AddWithValue("$generation", generation);
        using var reader = command.ExecuteReader();
        var values = new List<MapCatalogInput>();
        while (reader.Read())
        {
            values.Add(new MapCatalogInput
            {
                FarmId = reader.GetString(0),
                MapId = reader.GetString(1),
                PartitionId = reader.GetString(2),
                Label = reader.GetString(3),
                Kind = reader.GetString(4),
                LastSeenAt = ParseTimestamp(reader.GetString(5)),
                Active = reader.GetInt64(6) == 1
            });
        }
        return values.AsReadOnly();
    }

    private static IReadOnlyList<LayerSnapshotInput> ReadLayers(SqliteConnection connection, string generation)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT farm_id, map_id, partition_id, layer_id, source_key, observed_at_utc,
                   cached_at_utc, expires_at_utc, freshness_state, last_error_code,
                   row_count, truncated, payload_sha256
            FROM layer_snapshots
            WHERE generation=$generation
            ORDER BY farm_id, map_id, partition_id, layer_id
            LIMIT 64;
            """;
        command.Parameters.AddWithValue("$generation", generation);
        using var reader = command.ExecuteReader();
        var now = DateTimeOffset.UtcNow;
        var values = new List<LayerSnapshotInput>();
        while (reader.Read())
        {
            var expiresAt = reader.IsDBNull(7) ? (DateTimeOffset?)null : ParseTimestamp(reader.GetString(7));
            var state = reader.GetString(8);
            if (state == "fresh" && expiresAt is not null && expiresAt <= now)
            {
                state = "stale";
            }
            values.Add(new LayerSnapshotInput
            {
                FarmId = reader.GetString(0),
                MapId = reader.GetString(1),
                PartitionId = reader.GetString(2),
                LayerId = reader.GetString(3),
                SourceKey = reader.GetString(4),
                ObservedAt = reader.IsDBNull(5) ? null : ParseTimestamp(reader.GetString(5)),
                CachedAt = ParseTimestamp(reader.GetString(6)),
                ExpiresAt = expiresAt,
                FreshnessState = state,
                LastErrorCode = reader.IsDBNull(9) ? null : reader.GetString(9),
                RowCount = reader.GetInt32(10),
                Truncated = reader.GetInt64(11) == 1,
                PayloadSha256 = reader.GetString(12)
            });
        }
        return values.AsReadOnly();
    }

    private static IReadOnlyList<ActiveSpiceInput> ReadActiveSpice(SqliteConnection connection, string generation)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT farm_id, map_id, partition_id, field_id, state, coordinate_space,
                   projected_x, projected_y, source_fingerprint, observed_at_utc, expires_at_utc
            FROM active_spice_current
            WHERE generation=$generation
            ORDER BY farm_id, map_id, partition_id, field_id
            LIMIT 5000;
            """;
        command.Parameters.AddWithValue("$generation", generation);
        using var reader = command.ExecuteReader();
        var values = new List<ActiveSpiceInput>();
        while (reader.Read())
        {
            values.Add(ReadActiveSpice(reader));
        }
        return values.AsReadOnly();
    }

    private static IReadOnlyList<ActiveSpiceInput> ReadActiveSpiceHistory(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT farm_id, map_id, partition_id, field_id, state, coordinate_space,
                   projected_x, projected_y, source_fingerprint, observed_at_utc, observed_at_utc
            FROM active_spice_history
            ORDER BY observed_at_utc DESC, farm_id, map_id, partition_id, field_id
            LIMIT 1000;
            """;
        using var reader = command.ExecuteReader();
        var values = new List<ActiveSpiceInput>();
        while (reader.Read())
        {
            values.Add(ReadActiveSpice(reader));
        }
        return values.AsReadOnly();
    }

    private static IReadOnlyList<PublicPoiInput> ReadPublicPois(SqliteConnection connection, string generation)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT farm_id, map_id, partition_id, poi_id, category, label, coordinate_space,
                   projected_x, projected_y, source_fingerprint, observed_at_utc, expires_at_utc
            FROM public_poi_layer
            WHERE generation=$generation
            ORDER BY farm_id, map_id, partition_id, poi_id
            LIMIT 2000;
            """;
        command.Parameters.AddWithValue("$generation", generation);
        using var reader = command.ExecuteReader();
        var values = new List<PublicPoiInput>();
        while (reader.Read())
        {
            values.Add(new PublicPoiInput
            {
                FarmId = reader.GetString(0),
                MapId = reader.GetString(1),
                PartitionId = reader.GetString(2),
                Id = reader.GetString(3),
                Category = reader.GetString(4),
                Label = reader.GetString(5),
                CoordinateSpace = reader.GetString(6),
                X = reader.GetDouble(7),
                Y = reader.GetDouble(8),
                SourceFingerprint = reader.GetString(9),
                ObservedAt = ParseTimestamp(reader.GetString(10)),
                ExpiresAt = ParseTimestamp(reader.GetString(11))
            });
        }
        return values.AsReadOnly();
    }

    private static ActiveSpiceInput ReadActiveSpice(SqliteDataReader reader) => new()
    {
        FarmId = reader.GetString(0),
        MapId = reader.GetString(1),
        PartitionId = reader.GetString(2),
        FieldId = reader.GetString(3),
        State = reader.GetString(4),
        CoordinateSpace = reader.GetString(5),
        X = reader.IsDBNull(6) ? null : reader.GetDouble(6),
        Y = reader.IsDBNull(7) ? null : reader.GetDouble(7),
        SourceFingerprint = reader.GetString(8),
        ObservedAt = ParseTimestamp(reader.GetString(9)),
        ExpiresAt = ParseTimestamp(reader.GetString(10))
    };

    private static void UpsertSources(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IReadOnlyList<SourceStateInput> values)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO source_state(
              source_key, schema_fingerprint, last_attempt_utc, last_success_utc,
              expires_at_utc, last_error_code)
            VALUES ($sourceKey, $fingerprint, $attempt, $success, $expires, $error)
            ON CONFLICT(source_key) DO UPDATE SET
              schema_fingerprint=excluded.schema_fingerprint,
              last_attempt_utc=excluded.last_attempt_utc,
              last_success_utc=excluded.last_success_utc,
              expires_at_utc=excluded.expires_at_utc,
              last_error_code=excluded.last_error_code;
            """;
        var sourceKey = command.Parameters.Add("$sourceKey", SqliteType.Text);
        var fingerprint = command.Parameters.Add("$fingerprint", SqliteType.Text);
        var attempt = command.Parameters.Add("$attempt", SqliteType.Text);
        var success = command.Parameters.Add("$success", SqliteType.Text);
        var expires = command.Parameters.Add("$expires", SqliteType.Text);
        var error = command.Parameters.Add("$error", SqliteType.Text);
        foreach (var value in values)
        {
            sourceKey.Value = value.SourceKey;
            fingerprint.Value = value.SchemaFingerprint;
            attempt.Value = DbTimestamp(value.LastAttemptAt);
            success.Value = DbTimestamp(value.LastSuccessAt);
            expires.Value = DbTimestamp(value.ExpiresAt);
            error.Value = value.LastErrorCode ?? (object)DBNull.Value;
            command.ExecuteNonQuery();
        }
    }

    private static void InsertMaps(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string generation,
        IReadOnlyList<MapCatalogInput> values)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO map_catalog(
              generation, farm_id, map_id, partition_id, label, kind, last_seen_at_utc, active)
            VALUES ($generation, $farm, $map, $partition, $label, $kind, $seen, $active);
            """;
        var parameters = AddParameters(command,
            "$generation", "$farm", "$map", "$partition", "$label", "$kind", "$seen", "$active");
        foreach (var value in values)
        {
            Set(parameters, generation, value.FarmId, value.MapId, value.PartitionId, value.Label,
                value.Kind, FormatTimestamp(value.LastSeenAt), value.Active ? 1 : 0);
            command.ExecuteNonQuery();
        }
    }

    private static void InsertLayers(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string generation,
        IReadOnlyList<LayerSnapshotInput> values)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO layer_snapshots(
              generation, farm_id, map_id, partition_id, layer_id, source_key, observed_at_utc,
              cached_at_utc, expires_at_utc, freshness_state, last_error_code, row_count,
              truncated, payload_sha256)
            VALUES ($generation, $farm, $map, $partition, $layer, $source, $observed,
              $cached, $expires, $freshness, $error, $rows, $truncated, $sha);
            """;
        var parameters = AddParameters(command,
            "$generation", "$farm", "$map", "$partition", "$layer", "$source", "$observed",
            "$cached", "$expires", "$freshness", "$error", "$rows", "$truncated", "$sha");
        foreach (var value in values)
        {
            Set(parameters, generation, value.FarmId, value.MapId, value.PartitionId, value.LayerId,
                value.SourceKey, DbTimestamp(value.ObservedAt), FormatTimestamp(value.CachedAt),
                DbTimestamp(value.ExpiresAt), value.FreshnessState, value.LastErrorCode ?? (object)DBNull.Value,
                value.RowCount, value.Truncated ? 1 : 0, value.PayloadSha256);
            command.ExecuteNonQuery();
        }
    }

    private static void InsertActiveSpiceCurrent(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string generation,
        IReadOnlyList<ActiveSpiceInput> values)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO active_spice_current(
              generation, farm_id, map_id, partition_id, field_id, state, coordinate_space,
              projected_x, projected_y, source_fingerprint, observed_at_utc, expires_at_utc)
            VALUES ($generation, $farm, $map, $partition, $field, $state, $space,
              $x, $y, $fingerprint, $observed, $expires);
            """;
        var parameters = AddParameters(command,
            "$generation", "$farm", "$map", "$partition", "$field", "$state", "$space",
            "$x", "$y", "$fingerprint", "$observed", "$expires");
        foreach (var value in values)
        {
            Set(parameters, generation, value.FarmId, value.MapId, value.PartitionId, value.FieldId,
                value.State, value.CoordinateSpace, value.X ?? (object)DBNull.Value,
                value.Y ?? (object)DBNull.Value, value.SourceFingerprint,
                FormatTimestamp(value.ObservedAt), FormatTimestamp(value.ExpiresAt));
            command.ExecuteNonQuery();
        }
    }

    private static void InsertActiveSpiceHistory(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string generation,
        IReadOnlyList<ActiveSpiceInput> values)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO active_spice_history(
              generation, farm_id, map_id, partition_id, field_id, state, coordinate_space,
              projected_x, projected_y, source_fingerprint, observed_at_utc)
            VALUES ($generation, $farm, $map, $partition, $field, $state, $space,
              $x, $y, $fingerprint, $observed);
            """;
        var parameters = AddParameters(command,
            "$generation", "$farm", "$map", "$partition", "$field", "$state", "$space",
            "$x", "$y", "$fingerprint", "$observed");
        foreach (var value in values)
        {
            Set(parameters, generation, value.FarmId, value.MapId, value.PartitionId, value.FieldId,
                value.State, value.CoordinateSpace, value.X ?? (object)DBNull.Value,
                value.Y ?? (object)DBNull.Value, value.SourceFingerprint, FormatTimestamp(value.ObservedAt));
            command.ExecuteNonQuery();
        }
    }

    private static void InsertPublicPois(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string generation,
        IReadOnlyList<PublicPoiInput> values)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO public_poi_layer(
              generation, farm_id, map_id, partition_id, poi_id, category, label, coordinate_space,
              projected_x, projected_y, source_fingerprint, observed_at_utc, expires_at_utc)
            VALUES ($generation, $farm, $map, $partition, $id, $category, $label, $space,
              $x, $y, $fingerprint, $observed, $expires);
            """;
        var parameters = AddParameters(command,
            "$generation", "$farm", "$map", "$partition", "$id", "$category", "$label", "$space",
            "$x", "$y", "$fingerprint", "$observed", "$expires");
        foreach (var value in values)
        {
            Set(parameters, generation, value.FarmId, value.MapId, value.PartitionId, value.Id,
                value.Category, value.Label, value.CoordinateSpace, value.X, value.Y,
                value.SourceFingerprint, FormatTimestamp(value.ObservedAt), FormatTimestamp(value.ExpiresAt));
            command.ExecuteNonQuery();
        }
    }

    private static SqliteParameter[] AddParameters(SqliteCommand command, params string[] names) =>
        names.Select(name => command.Parameters.Add(name, SqliteType.Text)).ToArray();

    private static void Set(SqliteParameter[] parameters, params object[] values)
    {
        for (var i = 0; i < parameters.Length; i++)
        {
            parameters[i].Value = values[i];
        }
    }

    private static IReadOnlyList<object> ReadSourceHealth(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT source_key, schema_fingerprint, last_attempt_utc, last_success_utc,
                   expires_at_utc, last_error_code
            FROM source_state
            ORDER BY source_key
            LIMIT 32;
            """;
        using var reader = command.ExecuteReader();
        var values = new List<object>();
        while (reader.Read())
        {
            values.Add(new
            {
                sourceKey = reader.GetString(0),
                schemaFingerprint = reader.GetString(1),
                lastAttemptAt = reader.IsDBNull(2) ? null : reader.GetString(2),
                lastSuccessAt = reader.IsDBNull(3) ? null : reader.GetString(3),
                expiresAt = reader.IsDBNull(4) ? null : reader.GetString(4),
                lastErrorCode = reader.IsDBNull(5) ? null : reader.GetString(5)
            });
        }
        return values.AsReadOnly();
    }

    private static IReadOnlyList<object> ReadLayerHealth(SqliteConnection connection, string generation)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT layer_id, source_key, observed_at_utc, cached_at_utc, expires_at_utc,
                   freshness_state, last_error_code, row_count, truncated
            FROM layer_snapshots
            WHERE generation=$generation
            ORDER BY layer_id
            LIMIT 64;
            """;
        command.Parameters.AddWithValue("$generation", generation);
        using var reader = command.ExecuteReader();
        var values = new List<object>();
        while (reader.Read())
        {
            values.Add(new
            {
                layerId = reader.GetString(0),
                sourceKey = reader.GetString(1),
                observedAt = reader.IsDBNull(2) ? null : reader.GetString(2),
                cachedAt = reader.GetString(3),
                expiresAt = reader.IsDBNull(4) ? null : reader.GetString(4),
                freshnessState = reader.GetString(5),
                lastErrorCode = reader.IsDBNull(6) ? null : reader.GetString(6),
                rowCount = reader.GetInt64(7),
                truncated = reader.GetInt64(8) == 1
            });
        }
        return values.AsReadOnly();
    }

    private static void ValidateMigrationIdentity(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT checksum FROM schema_migrations WHERE version=1;";
        var checksum = Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        if (!string.Equals(checksum, Schema.Checksum, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Cache schema migration identity is missing or invalid.");
        }
    }

    private static bool HasUserTables(SqliteConnection connection) =>
        ScalarLong(connection,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';") > 0;

    private static string CreateMigrationBackup(SqliteConnection source, string databasePath)
    {
        var backupPath = databasePath + $".migration-{DateTimeOffset.UtcNow:yyyyMMddHHmmssfff}.bak";
        string quickCheck;
        using (var securedDestination = Schema.Open(backupPath, readOnly: false))
        {
            var destination = securedDestination.Connection;
            source.BackupDatabase(destination);
            Schema.Execute(destination, null, "PRAGMA wal_checkpoint(TRUNCATE);");
            quickCheck = Schema.QuickCheck(destination);
            if (!string.Equals(quickCheck, "ok", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException($"Migration backup quick check failed: {quickCheck}");
            }
        }
        DeleteSqliteSidecars(backupPath);
        return backupPath;
    }

    private static void PruneMigrationBackups(string databasePath, int keep)
    {
        var directory = Path.GetDirectoryName(databasePath)!;
        var pattern = Path.GetFileName(databasePath) + ".migration-*.bak";
        var backups = new DirectoryInfo(directory)
            .GetFiles(pattern)
            .OrderByDescending(value => value.LastWriteTimeUtc)
            .ToArray();
        var retained = new HashSet<string>(
            backups.Take(keep).Select(value => value.FullName),
            StringComparer.OrdinalIgnoreCase);
        foreach (var file in backups.Where(value => !retained.Contains(value.FullName)))
        {
            file.Delete();
            DeleteSqliteSidecars(file.FullName);
        }
        foreach (var sidecar in new DirectoryInfo(directory)
                     .GetFiles(Path.GetFileName(databasePath) + ".migration-*.bak-*"))
        {
            var backupPath = sidecar.FullName.EndsWith("-wal", StringComparison.OrdinalIgnoreCase) ||
                sidecar.FullName.EndsWith("-shm", StringComparison.OrdinalIgnoreCase)
                ? sidecar.FullName[..^4]
                : "";
            if (!retained.Contains(backupPath))
            {
                sidecar.Delete();
            }
        }
    }

    private static void DeleteSqliteSidecars(string databasePath)
    {
        foreach (var suffix in new[] { "-wal", "-shm" })
        {
            var path = databasePath + suffix;
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private static ReplaceGenerationRequest BuildFixture(string generation, int historyRows, int poiRows)
    {
        var now = DateTimeOffset.UtcNow;
        var history = new List<ActiveSpiceInput>(historyRows);
        for (var index = 0; index < historyRows; index++)
        {
            history.Add(new ActiveSpiceInput
            {
                FarmId = "farm-1",
                MapId = "deep-desert",
                PartitionId = "partition-1",
                FieldId = $"spice-{index % 128:D3}",
                State = index % 3 == 0 ? "active" : "inactive",
                CoordinateSpace = "none",
                SourceFingerprint = "fixture-v1",
                ObservedAt = now.AddSeconds(-index),
                ExpiresAt = now.AddMinutes(1)
            });
        }
        var pois = new List<PublicPoiInput>(poiRows);
        for (var index = 0; index < poiRows; index++)
        {
            pois.Add(new PublicPoiInput
            {
                FarmId = "farm-1",
                MapId = "deep-desert",
                PartitionId = "partition-1",
                Id = $"poi-{index:D4}",
                Category = index % 2 == 0 ? "testing-station" : "tradepost",
                Label = $"Public POI {index:D4}",
                CoordinateSpace = "normalized-v1",
                X = (index % 100) / 100.0,
                Y = (index / 100) / 20.0,
                SourceFingerprint = "fixture-v1",
                ObservedAt = now,
                ExpiresAt = now.AddMinutes(30)
            });
        }
        var active = Enumerable.Range(0, 12).Select(index => new ActiveSpiceInput
        {
            FarmId = "farm-1",
            MapId = "deep-desert",
            PartitionId = "partition-1",
            FieldId = $"spice-{index:D3}",
            State = index % 3 == 0 ? "active" : "inactive",
            CoordinateSpace = "none",
            SourceFingerprint = "fixture-v1",
            ObservedAt = now,
            ExpiresAt = now.AddMinutes(1)
        }).ToArray();
        var sha = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(generation))).ToLowerInvariant();
        return new ReplaceGenerationRequest
        {
            Generation = generation,
            Sources =
            [
                new SourceStateInput
                {
                    SourceKey = "maps.catalog",
                    SchemaFingerprint = "fixture-v1",
                    LastAttemptAt = now,
                    LastSuccessAt = now,
                    ExpiresAt = now.AddMinutes(1)
                },
                new SourceStateInput
                {
                    SourceKey = "maps.active-spice",
                    SchemaFingerprint = "fixture-v1",
                    LastAttemptAt = now,
                    LastSuccessAt = now,
                    ExpiresAt = now.AddMinutes(1)
                },
                new SourceStateInput
                {
                    SourceKey = "maps.public-poi",
                    SchemaFingerprint = "fixture-v1",
                    LastAttemptAt = now,
                    LastSuccessAt = now,
                    ExpiresAt = now.AddMinutes(30)
                }
            ],
            Maps =
            [
                new MapCatalogInput
                {
                    FarmId = "farm-1",
                    MapId = "deep-desert",
                    PartitionId = "partition-1",
                    Label = "Deep Desert 1",
                    Kind = "deep-desert",
                    LastSeenAt = now,
                    Active = true
                }
            ],
            Layers =
            [
                new LayerSnapshotInput
                {
                    FarmId = "farm-1",
                    MapId = "deep-desert",
                    PartitionId = "partition-1",
                    LayerId = "active-spice",
                    SourceKey = "maps.active-spice",
                    ObservedAt = now,
                    CachedAt = now,
                    ExpiresAt = now.AddMinutes(1),
                    FreshnessState = "fresh",
                    RowCount = active.Length,
                    PayloadSha256 = sha
                },
                new LayerSnapshotInput
                {
                    FarmId = "farm-1",
                    MapId = "deep-desert",
                    PartitionId = "partition-1",
                    LayerId = "public-poi",
                    SourceKey = "maps.public-poi",
                    ObservedAt = now,
                    CachedAt = now,
                    ExpiresAt = now.AddMinutes(30),
                    FreshnessState = "fresh",
                    RowCount = poiRows,
                    Truncated = poiRows > MaxPublicPoisHydrated,
                    PayloadSha256 = sha
                }
            ],
            ActiveSpiceCurrent = active,
            ActiveSpiceHistory = history,
            PublicPois = pois
        };
    }

    internal static object CrashWrite(string databasePath)
    {
        using var securedConnection = Schema.Open(databasePath, readOnly: false);
        var connection = securedConnection.Connection;
        Schema.EnsureSupported(connection);
        using var transaction = connection.BeginTransaction();
        Schema.Execute(connection, transaction,
            """
            INSERT INTO active_spice_history(
              generation, farm_id, map_id, partition_id, field_id, state, coordinate_space,
              projected_x, projected_y, source_fingerprint, observed_at_utc)
            VALUES ('crash-probe','farm-1','deep-desert','partition-1','crash-probe',
              'active','none',NULL,NULL,'probe',$now);
            """,
            ("$now", FormatTimestamp(DateTimeOffset.UtcNow)));
        Environment.FailFast("Intentional cache write crash probe before commit.");
        return new { ok = false };
    }

    internal static object CrashMigration(string databasePath)
    {
        using var securedConnection = Schema.Open(databasePath, readOnly: false);
        var connection = securedConnection.Connection;
        using var transaction = connection.BeginTransaction();
        Schema.Execute(connection, transaction,
            """
            CREATE TABLE interrupted_migration(value TEXT NOT NULL) STRICT;
            INSERT INTO interrupted_migration VALUES ('uncommitted');
            PRAGMA user_version=1;
            """);
        Environment.FailFast("Intentional cache migration crash probe before commit.");
        return new { ok = false };
    }

    private static void VerifyInterruptedWriteRecovery(string databasePath)
    {
        RunExpectedCrash(databasePath, "self-test-crash-write");
        using var securedRecovered = Schema.Open(databasePath, readOnly: true);
        var recovered = securedRecovered.Connection;
        Require(
            ScalarLong(recovered,
                "SELECT COUNT(*) FROM active_spice_history WHERE field_id='crash-probe';") == 0,
            "An interrupted transaction was not rolled back.");
        Require(
            string.Equals(Schema.QuickCheck(recovered), "ok", StringComparison.OrdinalIgnoreCase),
            "The recovered database failed quick_check.");
    }

    private static void VerifyInterruptedMigrationRecovery(string root)
    {
        var databasePath = Path.Combine(root, "interrupted-migration.sqlite");
        RunExpectedCrash(databasePath, "self-test-crash-migration");
        using var securedRecovered = Schema.Open(databasePath, readOnly: true);
        var recovered = securedRecovered.Connection;
        Require(Schema.ReadVersion(recovered) == 0, "An interrupted migration changed the schema version.");
        Require(
            ScalarLong(recovered,
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='interrupted_migration';") == 0,
            "An interrupted migration retained uncommitted DDL.");
        Require(
            string.Equals(Schema.QuickCheck(recovered), "ok", StringComparison.OrdinalIgnoreCase),
            "The interrupted migration database failed quick_check.");
    }

    private static void RunExpectedCrash(string databasePath, string command)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The helper executable path is unavailable.");
        var child = StartChild(executable, databasePath, command, null, enableCrashProbe: true);
        try
        {
            if (!child.Process.WaitForExit(30_000))
            {
                child.Process.Kill(entireProcessTree: true);
                throw new TimeoutException("A helper crash probe did not exit.");
            }
            child.Output.GetAwaiter().GetResult();
            child.Error.GetAwaiter().GetResult();
            Require(child.Process.ExitCode != 0, "A helper crash probe exited successfully.");
        }
        finally
        {
            child.Process.Dispose();
        }
    }

    private static void VerifyConcurrentProcesses(
        string databasePath,
        ReplaceGenerationRequest request)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The helper executable path is unavailable.");
        var children = new List<(Process Process, Task<string> Output, Task<string> Error)>();
        try
        {
            for (var index = 0; index < 8; index++)
            {
                children.Add(StartChild(executable, databasePath, "hydrate", null));
            }
            var requestJson = System.Text.Json.JsonSerializer.Serialize(request, Program.SerializerOptions);
            children.Add(StartChild(executable, databasePath, "replace-generation", requestJson));
            foreach (var child in children)
            {
                if (!child.Process.WaitForExit(30_000))
                {
                    child.Process.Kill(entireProcessTree: true);
                    throw new TimeoutException("A concurrent one-shot helper process did not exit.");
                }
                var output = child.Output.GetAwaiter().GetResult();
                var error = child.Error.GetAwaiter().GetResult();
                if (child.Process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        $"Concurrent helper process failed: {error}{output}");
                }
            }
        }
        finally
        {
            foreach (var child in children)
            {
                if (!child.Process.HasExited)
                {
                    child.Process.Kill(entireProcessTree: true);
                    child.Process.WaitForExit();
                }
                child.Process.Dispose();
            }
        }
    }

    private static (Process Process, Task<string> Output, Task<string> Error) StartChild(
        string executable,
        string databasePath,
        string command,
        string? request,
        bool enableCrashProbe = false)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add("--command");
        start.ArgumentList.Add(command);
        start.ArgumentList.Add("--database");
        start.ArgumentList.Add(databasePath);
        if (enableCrashProbe)
        {
            start.Environment["DST_PLATFORM_SELF_TEST"] = "1";
        }
        var process = Process.Start(start)
            ?? throw new InvalidOperationException("A concurrent helper process did not start.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (request is not null)
        {
            process.StandardInput.Write(request);
        }
        process.StandardInput.Close();
        return (process, output, error);
    }

    private static void VerifyMigrationBackup(string root)
    {
        var database = Path.Combine(root, "migration.sqlite");
        using (var securedConnection = Schema.Open(database, readOnly: false))
        {
            var connection = securedConnection.Connection;
            Schema.Execute(connection, null, "CREATE TABLE legacy_probe(value TEXT NOT NULL); INSERT INTO legacy_probe VALUES ('preserved');");
        }
        Migrate(database);
        Require(
            Directory.GetFiles(root, "migration.sqlite.migration-*.bak").Length == 1,
            "Migration did not retain exactly one backup.");
        Require(
            Directory.GetFiles(root, "migration.sqlite.migration-*.bak-*").Length == 0,
            "Migration retained WAL/SHM files outside the backup retention set.");
    }

    private static void VerifyNewerSchemaFailure(string root)
    {
        var database = Path.Combine(root, "newer.sqlite");
        CreateTestFixture(database, 1, 1);
        using (var securedConnection = Schema.Open(database, readOnly: false))
        {
            var connection = securedConnection.Connection;
            Schema.Execute(connection, null, "PRAGMA user_version=2;");
        }
        try
        {
            Hydrate(database);
            throw new InvalidOperationException("A newer schema was accepted.");
        }
        catch (UnsupportedSchemaException)
        {
        }
    }

    private static void VerifyCorruptionFailure(string root)
    {
        var database = Path.Combine(root, "corrupt.sqlite");
        File.WriteAllBytes(database, [1, 2, 3, 4, 5, 6, 7, 8]);
        try
        {
            Integrity(database);
            throw new InvalidOperationException("A corrupt cache was accepted.");
        }
        catch (SqliteException)
        {
        }
    }

    private static void VerifyOffsetTimestampPruning(string root)
    {
        var database = Path.Combine(root, "offset-pruning.sqlite");
        Migrate(database);
        var request = BuildFixture("offset-generation", 1, 0);
        var offsetObservation = request.ActiveSpiceHistory[0] with
        {
            FieldId = "offset-probe",
            ObservedAt = DateTimeOffset.UtcNow.AddHours(-18).ToOffset(TimeSpan.FromHours(-12))
        };
        ReplaceGeneration(database, request with { ActiveSpiceHistory = [offsetObservation] });
        Prune(database, 1, 100_000, 20, 250L * 1024 * 1024);
        using var securedConnection = Schema.Open(database, readOnly: true);
        var connection = securedConnection.Connection;
        Require(
            ScalarLong(connection,
                "SELECT COUNT(*) FROM active_spice_history WHERE field_id='offset-probe';") == 1,
            "History pruning did not compare offset timestamps chronologically.");
    }

    private static string ReadMetadata(SqliteConnection connection, string key)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM cache_metadata WHERE key=$key;";
        command.Parameters.AddWithValue("$key", key);
        return Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
    }

    private static long ScalarLong(
        SqliteConnection connection,
        string sql,
        SqliteTransaction? transaction = null)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);

    private static string FormatTimestamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("O");

    private static object DbTimestamp(DateTimeOffset? value) =>
        value is null ? DBNull.Value : FormatTimestamp(value.Value);

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
        }
    }
}
