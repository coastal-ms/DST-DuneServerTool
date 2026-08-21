using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    // These picker-only templates have names but no item rules in the shared
    // catalog. Keep the verified fallback limits aligned with PlayersRmq.ps1.
    private static readonly IReadOnlyDictionary<string, int> KnownStackLimits =
        new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["Ammo"] = 500,
            ["HeavyAmmo"] = 500,
            ["InfantryRocketAmmo"] = 500,
            ["Napalm"] = 500,
            ["RocketAmmo"] = 500,
            ["SolarisCoin"] = int.MaxValue,
            ["AntiRadiationPill"] = 20
        };

    // These templates are missing volume metadata from the extracted gameplay
    // catalog. The torch and Treadwheel hull use adjacent-item values so the
    // four vehicle kits known to fit the stock 175-volume backpack remain
    // grantable. The two unverified Sandcrawler modules stay deliberately
    // oversized so an uncertain large kit fails closed.
    private static readonly IReadOnlyDictionary<string, double> KnownVolumeFallbacks =
        new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase)
        {
            ["RepairTool5"] = 10d,
            ["TreadwheelHull_6"] = 15d,
            ["SandcrawlerSpiceContainer_Unique_Capacity_6"] = 1000d,
            ["SandcrawlerSpiceHeader_6"] = 1000d
        };

    private static readonly IReadOnlyDictionary<string, string> SoloStorageLabels =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["BasicContainer_Placeable"] = "Chest",
            ["SpiceSilo_Placeable"] = "Small Storage Container",
            ["StorageContainer_Placeable"] = "Storage Container",
            ["MediumStorageContainer_Placeable"] = "Medium Storage Container",
            ["Developer_StorageContainer_Placeable"] = "Developer Storage"
        };

    public static int Main(string[] args)
    {
        try
        {
            var options = ParseArgs(args);
            var command = RequireValue(options, "command").ToLowerInvariant();
            object result = command switch
            {
                "inspect" => InspectPath(
                    Require(options, "input"),
                    options.TryGetValue("catalog", out var inspectCatalog)
                        ? Path.GetFullPath(inspectCatalog)
                        : null,
                    options.TryGetValue("adapter", out var inspectAdapter)
                        ? Path.GetFullPath(inspectAdapter)
                        : null),
                "backup" => Backup(Require(options, "input"), Require(options, "output")),
                "restore" => Restore(
                    Require(options, "input"),
                    Require(options, "target"),
                    Require(options, "safety-backup")),
                "grant-items" => GrantItems(
                    Require(options, "input"),
                    Require(options, "safety-backup"),
                    Require(options, "plan"),
                    Require(options, "catalog")),
                "set-currencies" => SetCurrencies(
                    Require(options, "input"),
                    Require(options, "safety-backup"),
                    ParseBalance(RequireValue(options, "solari"), "Solari"),
                    ParseBalance(RequireValue(options, "scrip"), "Landsraad Scrip")),
                "fill-water" => FillWaterContainer(
                    Require(options, "input"),
                    Require(options, "safety-backup"),
                    ParseItemId(RequireValue(options, "item-id")),
                    Require(options, "adapter")),
                "max-augment-attributes" => MaxAugmentAttributes(
                    Require(options, "input"),
                    Require(options, "safety-backup")),
                "max-specializations" => MaxSpecializations(
                    Require(options, "input"),
                    Require(options, "safety-backup"),
                    Require(options, "adapter"),
                    Require(options, "keystones")),
                "complete-fremen" => CompleteFindTheFremen(
                    Require(options, "input"),
                    Require(options, "safety-backup"),
                    Require(options, "adapter")),
                "enable-skills" => EnableAllSkills(
                    Require(options, "input"),
                    Require(options, "safety-backup"),
                    Require(options, "adapter"),
                    Require(options, "skills")),
                "self-test" => SelfTest(),
                _ => throw new ArgumentException($"Unknown command: {command}")
            };
            WriteJson(result);
            return 0;
        }
        catch (Exception ex)
        {
            WriteJson(new { ok = false, error = ex.Message });
            return 1;
        }
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            var key = args[i];
            if (!key.StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length)
            {
                throw new ArgumentException($"Expected --name value, found: {key}");
            }
            result[key[2..]] = args[++i];
        }
        return result;
    }

    private static string Require(IReadOnlyDictionary<string, string> options, string key)
    {
        return Path.GetFullPath(RequireValue(options, key));
    }

    private static string RequireValue(IReadOnlyDictionary<string, string> options, string key)
    {
        if (options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
        {
            return value;
        }
        throw new ArgumentException($"Missing --{key}.");
    }

    private static object Backup(string input, string output)
    {
        var bytes = ReadStable(input);
        var inspection = InspectBytes(bytes, input);
        EnsureWritableInspection(inspection);

        var outputDirectory = Path.GetDirectoryName(output)
            ?? throw new InvalidOperationException("Backup output has no parent directory.");
        Directory.CreateDirectory(outputDirectory);
        if (File.Exists(output))
        {
            throw new IOException($"Backup already exists: {output}");
        }

        var temp = Path.Combine(outputDirectory, $".{Path.GetFileName(output)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temp, bytes);
            using (var stream = new FileStream(temp, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, output);
        }
        finally
        {
            TryDelete(temp);
        }

        return new { ok = true, path = output, inspection };
    }

    private static object Restore(string input, string target, string safetyBackup)
    {
        if (!File.Exists(target))
        {
            throw new FileNotFoundException("Target Solo save was not found.", target);
        }

        if (File.Exists(safetyBackup))
        {
            throw new IOException($"Safety backup already exists: {safetyBackup}");
        }

        var replacementBytes = ReadStable(input);
        var sourceInspection = InspectBytes(replacementBytes, input);
        EnsureWritableInspection(sourceInspection);

        var targetDirectory = Path.GetDirectoryName(target)
            ?? throw new InvalidOperationException("Target save has no parent directory.");
        Directory.CreateDirectory(Path.GetDirectoryName(safetyBackup)
            ?? throw new InvalidOperationException("Safety backup has no parent directory."));

        var temp = Path.Combine(targetDirectory, $".game.db.{Guid.NewGuid():N}.restore");
        var replaceBackup = Path.Combine(targetDirectory, $".game.db.{Guid.NewGuid():N}.previous");
        var safetyTemp = Path.Combine(
            Path.GetDirectoryName(safetyBackup)!,
            $".{Path.GetFileName(safetyBackup)}.{Guid.NewGuid():N}.tmp");
        var targetReplaced = false;
        try
        {
            File.WriteAllBytes(temp, replacementBytes);
            File.Replace(temp, target, replaceBackup, ignoreMetadataErrors: true);
            targetReplaced = true;
            File.Copy(replaceBackup, safetyTemp);
            File.Move(safetyTemp, safetyBackup);
            File.Delete(replaceBackup);

            var restoredBytes = ReadStable(target);
            if (!CryptographicOperations.FixedTimeEquals(
                    SHA256.HashData(replacementBytes),
                    SHA256.HashData(restoredBytes)))
            {
                throw new InvalidDataException("Restored save does not match the validated backup.");
            }
            var restoredInspection = InspectBytes(restoredBytes, target);
            EnsureWritableInspection(restoredInspection);
            return new
            {
                ok = true,
                path = target,
                safetyBackup,
                inspection = restoredInspection
            };
        }
        catch
        {
            if (targetReplaced)
            {
                var previous = File.Exists(replaceBackup)
                    ? replaceBackup
                    : File.Exists(safetyBackup) ? safetyBackup : null;
                if (previous is not null)
                {
                    var rollbackTemp = Path.Combine(
                        targetDirectory,
                        $".game.db.{Guid.NewGuid():N}.rollback");
                    var failedTarget = Path.Combine(
                        targetDirectory,
                        $".game.db.{Guid.NewGuid():N}.failed");
                    try
                    {
                        File.Copy(previous, rollbackTemp);
                        File.Replace(rollbackTemp, target, failedTarget, ignoreMetadataErrors: true);
                        TryDelete(failedTarget);
                    }
                    finally
                    {
                        TryDelete(rollbackTemp);
                    }
                }
            }
            throw;
        }
        finally
        {
            TryDelete(temp);
            TryDelete(safetyTemp);
            if (File.Exists(replaceBackup) && !File.Exists(safetyBackup))
            {
                File.Copy(replaceBackup, safetyTemp);
                File.Move(safetyTemp, safetyBackup);
                File.Delete(replaceBackup);
            }
        }
    }

    private static object GrantItems(
            string input,
            string safetyBackup,
            string planPath,
            string catalogPath)
        {
            var originalBytes = ReadStable(input);
            var originalInspection = InspectBytes(originalBytes, input);
            EnsureWritableInspection(originalInspection);
            var wrapped = Unwrap(originalBytes);
            var plan = ReadGrantPlan(planPath);
            var catalog = ReadCatalog(catalogPath);

            var root = Path.Combine(Path.GetTempPath(), $"dune-solo-grant-{Guid.NewGuid():N}");
            Directory.CreateDirectory(root);
            try
            {
                var sqlitePath = Path.Combine(root, "grant.sqlite");
                File.WriteAllBytes(sqlitePath, wrapped.SqliteBytes);
                var summaries = ApplyItemGrant(sqlitePath, plan, catalog);
                var mutated = Path.Combine(root, "game.db");
                WrapSqlite(sqlitePath, mutated);
                var mutatedInspection = InspectPath(mutated);
                EnsureWritableInspection(mutatedInspection);
                Restore(mutated, input, safetyBackup);
                return new
                {
                    ok = true,
                    destination = plan.Destination,
                    granted = summaries,
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
                    // A stale temp directory is safer than hiding the grant result.
                }
            }
        }

        private static long ParseBalance(string value, string label)
        {
            if (!long.TryParse(value, out var parsed) || parsed < 0 || parsed > 2_000_000_000)
            {
                throw new ArgumentException($"{label} must be between 0 and 2000000000.");
            }
            return parsed;
        }

        private static long ParseItemId(string value)
        {
            if (!long.TryParse(value, out var parsed) || parsed <= 0)
            {
                throw new ArgumentException("A valid Solo item id is required.");
            }
            return parsed;
        }

        private static object SetCurrencies(
            string input,
            string safetyBackup,
            long solari,
            long scrip)
        {
            var originalBytes = ReadStable(input);
            EnsureWritableInspection(InspectBytes(originalBytes, input));
            var wrapped = Unwrap(originalBytes);
            var root = Path.Combine(Path.GetTempPath(), $"dune-solo-currency-{Guid.NewGuid():N}");
            Directory.CreateDirectory(root);
            try
            {
                var sqlitePath = Path.Combine(root, "currency.sqlite");
                File.WriteAllBytes(sqlitePath, wrapped.SqliteBytes);
                var connectionString = new SqliteConnectionStringBuilder
                {
                    DataSource = sqlitePath,
                    Mode = SqliteOpenMode.ReadWrite,
                    Pooling = false
                }.ToString();
                using (var connection = new SqliteConnection(connectionString))
                {
                    connection.Open();
                    ExecuteNonQuery(connection, "PRAGMA foreign_keys = ON;");
                    ExecuteNonQuery(connection, "BEGIN IMMEDIATE;");
                    try
                    {
                        var controllerId = ScalarLong(
                            connection,
                            "SELECT player_controller_id FROM player_state LIMIT 1;");
                        foreach (var currency in new[] { (Id: 0, Balance: solari), (Id: 1, Balance: scrip) })
                        {
                            ExecuteNonQuery(
                                connection,
                                """
                                INSERT INTO player_virtual_currency_balances (
                                    player_controller_id,
                                    currency_id,
                                    balance
                                )
                                VALUES ($controller, $currency, $balance)
                                ON CONFLICT(player_controller_id, currency_id)
                                DO UPDATE SET balance = excluded.balance;
                                """,
                                ("$controller", controllerId),
                                ("$currency", currency.Id),
                                ("$balance", currency.Balance));
                        }
                        var verifiedSolari = ReadCurrencyBalance(connection, controllerId, 0);
                        var verifiedScrip = ReadCurrencyBalance(connection, controllerId, 1);
                        if (verifiedSolari != solari || verifiedScrip != scrip)
                        {
                            throw new InvalidDataException("Solo currency verification failed.");
                        }
                        var integrity = ScalarString(connection, "PRAGMA integrity_check;");
                        var foreignKeys = ScalarLong(
                            connection,
                            "SELECT COUNT(*) FROM pragma_foreign_key_check;");
                        if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase)
                            || foreignKeys != 0)
                        {
                            throw new InvalidDataException(
                                $"Currency write validation failed (integrity={integrity}, foreignKeys={foreignKeys}).");
                        }
                        ExecuteNonQuery(connection, "COMMIT;");
                    }
                    catch
                    {
                        try { ExecuteNonQuery(connection, "ROLLBACK;"); } catch { }
                        throw;
                    }
                }

                var mutated = Path.Combine(root, "game.db");
                WrapSqlite(sqlitePath, mutated);
                EnsureWritableInspection(InspectPath(mutated));
                Restore(mutated, input, safetyBackup);
                return new
                {
                    ok = true,
                    solari,
                    scrip,
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
                    // A stale temp directory is safer than hiding the currency result.
                }
            }
        }

    private static object FillWaterContainer(
        string input,
        string safetyBackup,
        long itemId,
        string adapterPath)
    {
        var adapter = ReadPtcAdapter(adapterPath);
        var originalBytes = ReadStable(input);
        EnsureWritableInspection(InspectBytes(originalBytes, input));
        var wrapped = Unwrap(originalBytes);
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-fill-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        var templateId = string.Empty;
        var capacity = 0d;
        try
        {
            var sqlitePath = Path.Combine(root, "fill.sqlite");
            File.WriteAllBytes(sqlitePath, wrapped.SqliteBytes);
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = sqlitePath,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false
            }.ToString();
            using (var connection = new SqliteConnection(connectionString))
            {
                connection.Open();
                ExecuteNonQuery(connection, "PRAGMA foreign_keys = ON;");
                ExecuteNonQuery(connection, "BEGIN IMMEDIATE;");
                try
                {
                    var pawnId = ScalarLong(
                        connection,
                        "SELECT player_pawn_id FROM player_state LIMIT 1;");
                    using var lookup = connection.CreateCommand();
                    lookup.CommandText = """
                        SELECT items.template_id,
                               COALESCE(
                                   json_extract(items.stats, '$.FFillableItemStats[1].MaxAmount'),
                                   0
                               )
                        FROM items
                        JOIN inventories ON inventories.id = items.inventory_id
                        WHERE items.id = $item
                          AND inventories.actor_id = $pawn
                          AND (
                              lower(items.template_id) LIKE '%literjon%'
                              OR lower(items.template_id) LIKE '%dewpack%'
                              OR lower(items.template_id) LIKE '%decajon%'
                          );
                        """;
                    lookup.Parameters.AddWithValue("$item", itemId);
                    lookup.Parameters.AddWithValue("$pawn", pawnId);
                    using var lookupReader = lookup.ExecuteReader();
                    if (!lookupReader.Read())
                    {
                        throw new InvalidDataException(
                            "The selected water container was not found on the Solo character.");
                    }
                    templateId = lookupReader.GetString(0);
                    var storedMax = lookupReader.GetDouble(1);
                    capacity = storedMax > 0
                        ? storedMax
                        : adapter.WaterCapacities.TryGetValue(
                            templateId.ToLowerInvariant(),
                            out var fallback)
                            ? fallback
                            : 0;
                    if (capacity <= 0)
                    {
                        throw new InvalidDataException(
                            $"No verified water capacity is available for {templateId}.");
                    }
                    lookupReader.Close();
                    var affected = ExecuteNonQuery(
                        connection,
                        """
                        UPDATE items
                        SET stats = json_set(
                            stats,
                            '$.FFillableItemStats[1].CurrentAmount',
                            $capacity
                        ),
                            is_new = 1
                        WHERE id = $item
                          AND inventory_id IN (
                              SELECT id
                              FROM inventories
                              WHERE actor_id = $pawn
                          );
                        """,
                        ("$capacity", capacity),
                        ("$item", itemId),
                        ("$pawn", pawnId));
                    if (affected != 1)
                    {
                        throw new InvalidDataException(
                            "The selected water container was not found on the Solo character.");
                    }
                    var verified = ScalarDouble(
                        connection,
                        """
                        SELECT COALESCE(
                            json_extract(stats, '$.FFillableItemStats[1].CurrentAmount'),
                            -1
                        )
                        FROM items
                        WHERE id = $item;
                        """,
                        ("$item", itemId));
                    if (Math.Abs(verified - capacity) > 0.0001)
                    {
                        throw new InvalidDataException("Water-container fill verification failed.");
                    }
                    var integrity = ScalarString(connection, "PRAGMA integrity_check;");
                    var foreignKeys = ScalarLong(
                        connection,
                        "SELECT COUNT(*) FROM pragma_foreign_key_check;");
                    if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase)
                        || foreignKeys != 0)
                    {
                        throw new InvalidDataException(
                            $"Fillable write validation failed (integrity={integrity}, foreignKeys={foreignKeys}).");
                    }
                    ExecuteNonQuery(connection, "COMMIT;");
                }
                catch
                {
                    try { ExecuteNonQuery(connection, "ROLLBACK;"); } catch { }
                    throw;
                }
            }

            var mutated = Path.Combine(root, "game.db");
            WrapSqlite(sqlitePath, mutated);
            EnsureWritableInspection(InspectPath(mutated));
            Restore(mutated, input, safetyBackup);
            return new
            {
                ok = true,
                itemId,
                templateId,
                amount = capacity,
                safetyBackup,
                inspection = InspectPath(input, adapterPath: adapterPath)
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
                // A stale temp directory is safer than hiding the fill result.
            }
        }
    }

    private static IReadOnlyList<object> ApplyItemGrant(
            string sqlitePath,
            GrantPlan plan,
            IReadOnlyDictionary<string, CatalogRule> catalog)
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
            var destination = ResolveDestination(connection, plan.Destination);
            var usedPositions = ReadUsedPositions(connection, destination.Id);
            var nextPosition = 0;
            var summaries = new List<object>();
            ExecuteNonQuery(connection, "BEGIN IMMEDIATE;");
            try
            {
                var currentRows = ScalarLong(
                    connection,
                    "SELECT COUNT(*) FROM items WHERE inventory_id = $id;",
                    ("$id", destination.Id));
                var currentVolume = GetUsedVolume(connection, destination.Id, catalog);
                var acquisitionTime = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

                foreach (var item in plan.Items)
                {
                    if (!catalog.TryGetValue(item.TemplateId, out var rule))
                    {
                        throw new InvalidDataException(
                            $"Item template is not in DST's catalog: {item.TemplateId}");
                    }
                    var stackMax = Math.Max(1, rule.StackMax);
                    var beforeQuantity = ScalarLong(
                        connection,
                        """
                        SELECT COALESCE(SUM(stack_size), 0)
                        FROM items
                        WHERE inventory_id = $inventory
                          AND template_id = $template
                          AND quality_level = $quality;
                        """,
                        ("$inventory", destination.Id),
                        ("$template", item.TemplateId),
                        ("$quality", item.Quality));

                    var remaining = item.Quantity;
                    var updatedRows = 0;
                    if (stackMax > 1)
                    {
                        using var existingCommand = connection.CreateCommand();
                        existingCommand.CommandText = """
                            SELECT id, stack_size
                            FROM items
                            WHERE inventory_id = $inventory
                              AND template_id = $template
                              AND quality_level = $quality
                              AND stack_size < $stackMax
                            ORDER BY position_index, id;
                            """;
                        existingCommand.Parameters.AddWithValue("$inventory", destination.Id);
                        existingCommand.Parameters.AddWithValue("$template", item.TemplateId);
                        existingCommand.Parameters.AddWithValue("$quality", item.Quality);
                        existingCommand.Parameters.AddWithValue("$stackMax", stackMax);
                        var existing = new List<(long Id, long Stack)>();
                        using (var reader = existingCommand.ExecuteReader())
                        {
                            while (reader.Read())
                            {
                                existing.Add((reader.GetInt64(0), reader.GetInt64(1)));
                            }
                        }
                        foreach (var row in existing)
                        {
                            if (remaining == 0) break;
                            var add = (int)Math.Min((long)remaining, stackMax - row.Stack);
                            ExecuteNonQuery(
                                connection,
                                "UPDATE items SET stack_size = stack_size + $add, is_new = 1 WHERE id = $id;",
                                ("$add", add),
                                ("$id", row.Id));
                            remaining -= add;
                            updatedRows++;
                        }
                    }

                    var chunks = new List<int>();
                    while (remaining > 0)
                    {
                        var chunk = Math.Min(remaining, stackMax);
                        chunks.Add(chunk);
                        remaining -= chunk;
                    }
                    if (destination.MaxItemCount > 0
                        && currentRows + chunks.Count > destination.MaxItemCount)
                    {
                        throw new InvalidDataException(
                            $"{destination.Label} needs {chunks.Count} additional slot(s), "
                            + $"but only {Math.Max(0, destination.MaxItemCount - currentRows)} remain.");
                    }
                    var addedVolume = rule.Volume * item.Quantity;
                    if (destination.MaxItemVolume > 0
                        && currentVolume + addedVolume > destination.MaxItemVolume + 0.0001)
                    {
                        throw new InvalidDataException(
                            $"{destination.Label} does not have enough item volume capacity.");
                    }

                    foreach (var chunk in chunks)
                    {
                        while (usedPositions.Contains(nextPosition)) nextPosition++;
                        usedPositions.Add(nextPosition);
                        ExecuteNonQuery(
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
                            )
                            VALUES (
                                $inventory,
                                $stack,
                                $position,
                                $template,
                                1,
                                $acquisition,
                                $stats,
                                $quality,
                                NULL
                            );
                            """,
                            ("$inventory", destination.Id),
                            ("$stack", chunk),
                            ("$position", nextPosition),
                            ("$template", item.TemplateId),
                            ("$acquisition", acquisitionTime),
                            ("$stats", ItemStatsJson(stackMax)),
                            ("$quality", item.Quality));
                        nextPosition++;
                    }
                    currentRows += chunks.Count;
                    currentVolume += addedVolume;

                    var afterQuantity = ScalarLong(
                        connection,
                        """
                        SELECT COALESCE(SUM(stack_size), 0)
                        FROM items
                        WHERE inventory_id = $inventory
                          AND template_id = $template
                          AND quality_level = $quality;
                        """,
                        ("$inventory", destination.Id),
                        ("$template", item.TemplateId),
                        ("$quality", item.Quality));
                    if (afterQuantity != beforeQuantity + item.Quantity)
                    {
                        throw new InvalidDataException(
                            $"Item grant verification failed for {item.TemplateId}.");
                    }
                    summaries.Add(new
                    {
                        templateId = item.TemplateId,
                        quantity = item.Quantity,
                        quality = item.Quality,
                        insertedRows = chunks.Count,
                        updatedRows
                    });
                }

                var integrity = ScalarString(connection, "PRAGMA integrity_check;");
                if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException($"SQLite integrity check failed: {integrity}");
                }
                var foreignKeys = ScalarLong(
                    connection,
                    "SELECT COUNT(*) FROM pragma_foreign_key_check;");
                if (foreignKeys != 0)
                {
                    throw new InvalidDataException(
                        $"SQLite foreign-key check found {foreignKeys} violation(s).");
                }
                ExecuteNonQuery(connection, "COMMIT;");
                return summaries;
            }
            catch
            {
                try { ExecuteNonQuery(connection, "ROLLBACK;"); } catch { }
                throw;
            }
        }

    private static object SelfTest()
    {
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-self-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var sqlitePath = Path.Combine(root, "fixture.sqlite");
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                   {
                       DataSource = sqlitePath,
                       Mode = SqliteOpenMode.ReadWriteCreate,
                       Pooling = false
                   }.ToString()))
            {
                connection.Open();
                using var command = connection.CreateCommand();
                command.CommandText = """
                    PRAGMA foreign_keys = ON;
                    CREATE TABLE player_state (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        player_pawn_id INTEGER NOT NULL,
                        player_controller_id INTEGER NOT NULL
                    );
                    INSERT INTO player_state (id, name, player_pawn_id, player_controller_id)
                    VALUES (1, 'Solo', 10, 11);
                    CREATE TABLE coriolis_cycle (
                        onerow_id INTEGER PRIMARY KEY,
                        start_date_seconds REAL NOT NULL,
                        end_date_seconds REAL NOT NULL,
                        cycle_index INTEGER NOT NULL
                    );
                    INSERT INTO coriolis_cycle VALUES (1, 0, 1, 14);
                    CREATE TABLE actors (
                        id INTEGER PRIMARY KEY,
                        class TEXT,
                        properties BLOB NOT NULL DEFAULT (jsonb('{}'))
                    );
                    INSERT INTO actors (id, class, properties) VALUES (
                        10,
                        'PlayerPawn',
                        jsonb('{"TechKnowledgePlayerComponent":{"m_TechKnowledgePoints":0,"m_TechKnowledge":{"m_TechKnowledgeData":[]}},"KeystonePlayerComponent":{"m_PurchasedKeystoneIDs":[]}}')
                    );
                    INSERT INTO actors (id, class, properties) VALUES (
                        20,
                        '/Game/Dune/Environment/Props/Interactables/BP_Developer_StorageContainer.BP_Developer_StorageContainer_C',
                        jsonb('{}')
                    );
                    INSERT INTO actors (id, class, properties) VALUES (
                        21,
                        '/Game/Dune/Environment/Props/Interactables/BP_Developer_StorageContainer.BP_Developer_StorageContainer_C',
                        jsonb('{}')
                    );
                    INSERT INTO actors (id, class, properties) VALUES (
                        22,
                        '/Game/Dune/Systems/Building/Pieces/BP_StorageContainer.BP_StorageContainer_C',
                        jsonb('{}')
                    );
                    INSERT INTO actors (id, class, properties) VALUES
                        (23, 'BasicContainer', jsonb('{}')),
                        (24, 'BP_SpiceSiloContainer', jsonb('{}')),
                        (25, 'MediumStorageContainer', jsonb('{}'));
                    CREATE TABLE placeables (
                        id INTEGER PRIMARY KEY,
                        owner_entity_id INTEGER,
                        building_type TEXT,
                        is_hologram INTEGER NOT NULL DEFAULT 0
                    );
                    INSERT INTO placeables VALUES (20, 1, 'Developer_StorageContainer_Placeable', 0);
                    INSERT INTO placeables VALUES (21, 1, 'Developer_StorageContainer_Placeable', 1);
                    INSERT INTO placeables VALUES (22, 1, 'StorageContainer_Placeable', 0);
                    INSERT INTO placeables VALUES (23, 1, 'BasicContainer_Placeable', 0);
                    INSERT INTO placeables VALUES (24, 1, 'SpiceSilo_Placeable', 0);
                    INSERT INTO placeables VALUES (25, 1, 'MediumStorageContainer_Placeable', 0);
                    CREATE TABLE fgl_entities (
                        entity_id INTEGER PRIMARY KEY,
                        components BLOB
                    );
                    INSERT INTO fgl_entities (entity_id, components) VALUES (
                        1000,
                        jsonb('{"FLevelComponent":[0,{"ModuleData":{"(TagName=\"Skills.Ability.VoiceStop\")":{"SkillPointsSpent":0},"(TagName=\"Skills.Ability.Hypersprint\")":{"SkillPointsSpent":0},"(TagName=\"Skills.Attribute.Explorer6\")":{"SkillPointsSpent":2}},"TotalSkillPoints":2,"UnspentSkillPoints":0,"KeystoneBonusSkillPoints":0}],"FSpiceAddictionComponent":[0,{"SystemStatus":"AddictionDisabled","SpiceVisionEnabledStatus":"Disabled"}]}')
                    );
                    CREATE TABLE actor_fgl_entities (
                        actor_id INTEGER NOT NULL,
                        entity_id INTEGER NOT NULL,
                        slot_name TEXT NOT NULL
                    );
                    INSERT INTO actor_fgl_entities VALUES (10, 1000, 'DuneCharacter');
                    CREATE TABLE specialization_tracks (
                        player_id INTEGER NOT NULL,
                        track_type INTEGER NOT NULL,
                        xp_amount INTEGER NOT NULL,
                        level REAL NOT NULL,
                        PRIMARY KEY (player_id, track_type)
                    );
                    CREATE TABLE purchased_specialization_keystones (
                        player_id INTEGER NOT NULL,
                        keystone_id INTEGER NOT NULL,
                        PRIMARY KEY (player_id, keystone_id)
                    );
                    CREATE TABLE journey_story_node (
                        character_id INTEGER NOT NULL,
                        story_node_id TEXT NOT NULL,
                        override_reward_block INTEGER NOT NULL DEFAULT 0,
                        complete_condition_state BLOB,
                        reveal_condition_state BLOB,
                        has_pending_reward INTEGER NOT NULL DEFAULT 0,
                        metadata_state BLOB,
                        reset_group INTEGER NOT NULL DEFAULT 0,
                        fail_condition_state BLOB,
                        PRIMARY KEY (character_id, story_node_id)
                    );
                    INSERT INTO journey_story_node (
                        character_id,
                        story_node_id,
                        complete_condition_state,
                        reveal_condition_state,
                        has_pending_reward,
                        metadata_state,
                        reset_group,
                        fail_condition_state
                    ) VALUES
                        (1, 'DA_MQ_FindTheFremen', jsonb('false'), jsonb('false'), 1, jsonb('{}'), 1, jsonb('{}')),
                        (1, 'DA_MQ_FindTheFremen.FirstTest', jsonb('false'), jsonb('false'), 1, jsonb('{}'), 1, jsonb('{}'));
                    CREATE TABLE player_tags (
                        character_id INTEGER NOT NULL,
                        tag TEXT NOT NULL,
                        PRIMARY KEY (character_id, tag)
                    );
                    CREATE TABLE inventories (
                        id INTEGER PRIMARY KEY,
                        actor_id INTEGER,
                        inventory_type INTEGER,
                        max_item_count INTEGER,
                        max_item_volume REAL
                    );
                    INSERT INTO inventories VALUES (1, 10, 0, 60, 175);
                    INSERT INTO inventories VALUES (2, 20, 4, 1000, 50000);
                    INSERT INTO inventories VALUES (3, 21, 4, 15, 750);
                    INSERT INTO inventories VALUES (4, 22, 4, 15, 750);
                    INSERT INTO inventories VALUES (5, 23, 4, 10, 250);
                    INSERT INTO inventories VALUES (6, 24, 4, 10, 250);
                    INSERT INTO inventories VALUES (7, 25, 4, 25, 1250);
                    CREATE TABLE items (
                        id INTEGER PRIMARY KEY,
                        inventory_id INTEGER REFERENCES inventories(id),
                        stack_size INTEGER NOT NULL,
                        position_index INTEGER NOT NULL,
                        template_id TEXT NOT NULL,
                        is_new INTEGER DEFAULT 0,
                        acquisition_time INTEGER NOT NULL DEFAULT 0,
                        stats TEXT NOT NULL,
                        quality_level INTEGER NOT NULL DEFAULT 0,
                        volume_override REAL
                    );
                    CREATE TABLE player_virtual_currency_balances (
                        player_controller_id INTEGER NOT NULL,
                        currency_id INTEGER NOT NULL,
                        balance INTEGER NOT NULL,
                        PRIMARY KEY (player_controller_id, currency_id)
                    );
                    INSERT INTO items (
                        id,
                        inventory_id,
                        stack_size,
                        position_index,
                        template_id,
                        is_new,
                        acquisition_time,
                        stats,
                        quality_level
                    )
                    VALUES (
                        100,
                        1,
                        1,
                        0,
                        'HighCapacityLiterjon_06',
                        0,
                        0,
                        '{"FItemStackAndDurabilityStats":[[],{}],"FFillableItemStats":[[],{"CurrentAmount":0.0}]}',
                        0
                    );
                    INSERT INTO items VALUES (
                        101,
                        1,
                        1,
                        1,
                        'Dewpack',
                        0,
                        0,
                        '{"FItemStackAndDurabilityStats":[[],{}],"FFillableItemStats":[[],{"CurrentAmount":0.0,"MaxAmount":250.0}]}',
                        0,
                        NULL
                    );
                    INSERT INTO items VALUES (
                        102,
                        1,
                        1,
                        2,
                        'Stillsuit_Test',
                        0,
                        0,
                        '{"FItemStackAndDurabilityStats":[[],{}],"FFillableItemStats":[[],{"CurrentAmount":0.0,"MaxAmount":1000.0}]}',
                        0,
                        NULL
                    );
                    INSERT INTO items VALUES (
                        103,
                        1,
                        1,
                        3,
                        'TestAugment_Player',
                        0,
                        0,
                        '{"FAugmentItemStats":[[],{"StatRolls":[0,0.25,"keep",1.003398]}]}',
                        0,
                        NULL
                    );
                    INSERT INTO items VALUES (
                        104,
                        2,
                        1,
                        0,
                        'TestAugment_Storage',
                        0,
                        0,
                        '{"FAugmentItemStats":[[],{"StatRolls":[0.5]}]}',
                        0,
                        NULL
                    );
                    CREATE TABLE parent (id INTEGER PRIMARY KEY);
                    CREATE TABLE child (
                        id INTEGER PRIMARY KEY,
                        parent_id INTEGER NOT NULL REFERENCES parent(id)
                    );
                    INSERT INTO parent (id) VALUES (1);
                    INSERT INTO child (id, parent_id) VALUES (1, 1);
                    """;
                command.ExecuteNonQuery();
            }

            var source = Path.Combine(root, "game.db");
            WrapSqlite(sqlitePath, source);
            var inspection = InspectPath(source);
            EnsureWritableInspection(inspection);
            if (inspection.MapSeed != 2)
            {
                throw new InvalidOperationException(
                    $"Map seed expected 2 from cycle index 14, found {inspection.MapSeed}.");
            }
            var expectedStorageLabels = new[]
            {
                "Chest #1",
                "Small Storage Container #1",
                "Storage Container #1",
                "Medium Storage Container #1",
                "Developer Storage #1"
            };
            if (inspection.Inventories.Any(value => value.Key == "inventory:3")
                || inspection.Inventories.Count(value => value.Kind == "developer-storage") != 1
                || expectedStorageLabels.Any(label =>
                    inspection.Inventories.All(value => value.Label != label)))
            {
                throw new InvalidOperationException(
                    "Built/hologram storage destination filtering is incorrect.");
            }

            var backup = Path.Combine(root, "backups", "game-test.db");
            Backup(source, backup);
            var target = Path.Combine(root, "target", "game.db");
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(source, target);
            var safety = Path.Combine(root, "safety", "game-before-restore.db");
            Restore(backup, target, safety);
            if (!File.Exists(safety))
            {
                throw new InvalidOperationException("Restore did not retain a safety backup.");
            }

            var corrupt = File.ReadAllBytes(source);
            BinaryPrimitives.WriteUInt32LittleEndian(corrupt.AsSpan(0, 4), 99);
            var rejected = false;
            try
            {
                InspectBytes(corrupt, "corrupt-wrapper");
            }
            catch (InvalidDataException)
            {
                rejected = true;
            }
            if (!rejected)
            {
                throw new InvalidOperationException("Unsupported wrapper was not rejected.");
            }

            var augmentSafety = Path.Combine(root, "safety", "before-augment.db");
            MaxAugmentAttributes(target, augmentSafety);
            if (!File.Exists(augmentSafety))
            {
                throw new InvalidOperationException("Augment write did not retain a safety backup.");
            }
            var augmentSqlite = Path.Combine(root, "augment.sqlite");
            File.WriteAllBytes(augmentSqlite, Unwrap(ReadStable(target)).SqliteBytes);
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                   {
                       DataSource = augmentSqlite,
                       Mode = SqliteOpenMode.ReadOnly,
                       Pooling = false
                   }.ToString()))
            {
                connection.Open();
                var playerStats = ScalarString(
                    connection,
                    "SELECT stats FROM items WHERE id = 103;");
                var storageStats = ScalarString(
                    connection,
                    "SELECT stats FROM items WHERE id = 104;");
                var playerRolls = GetAugmentRolls(JsonNode.Parse(playerStats));
                var storageRolls = GetAugmentRolls(JsonNode.Parse(storageStats));
                if (playerRolls is null
                    || storageRolls is null
                    || playerRolls.Count != 4
                    || storageRolls.Count != 1
                    || !TryReadJsonDecimal(playerRolls[0], out var playerZero)
                    || playerZero != 0m
                    || !TryReadJsonDecimal(playerRolls[1], out var playerChanged)
                    || playerChanged != DuneAugmentMaxRoll
                    || playerRolls[2]?.GetValue<string>() != "keep"
                    || !TryReadJsonDecimal(playerRolls[3], out var playerMax)
                    || playerMax != DuneAugmentMaxRoll
                    || !TryReadJsonDecimal(storageRolls[0], out var storageValue)
                    || storageValue != 0.5m)
                {
                    throw new InvalidOperationException(
                        "Augment max did not preserve zero/non-numeric rolls or player inventory scope.");
                }
            }

            var planPath = Path.Combine(root, "grant-plan.json");
            File.WriteAllText(
                planPath,
                """
                {"destination":"inventory:2","items":[
                  {"templateId":"TestResource","quantity":12,"quality":0},
                  {"templateId":"HeavyAmmo","quantity":501,"quality":0},
                  {"templateId":"AntiRadiationPill","quantity":21,"quality":0}
                ]}
                """);
            var catalogPath = Path.Combine(root, "catalog.json");
            File.WriteAllText(
                catalogPath,
                """
                {
                  "names":{
                    "TestResource":"Test Resource",
                    "HeavyAmmo":"Heavy Darts",
                    "AntiRadiationPill":"Iodine Pill",
                    "BuggyKnownParts":"Buggy known parts",
                    "RepairTool5":"Welding Torch Mk5",
                    "TreadwheelHull_6":"Treadwheel Hull Mk6",
                    "SandcrawlerSpiceHeader_6":"Sandcrawler Vacuum Mk6"
                  },
                  "items":{
                    "TestResource":{"stack_max":10,"volume":1.0},
                    "BuggyKnownParts":{"stack_max":1,"volume":110.0}
                  }
                }
                """);
            var catalog = ReadCatalog(catalogPath);
            if (catalog["RepairTool5"].Volume != 10d
                || catalog["TreadwheelHull_6"].Volume != 15d
                || catalog["SandcrawlerSpiceHeader_6"].Volume != 1000d)
            {
                throw new InvalidOperationException(
                    "Vehicle-kit volume fallbacks were not applied correctly.");
            }
            File.WriteAllText(
                planPath,
                """
                {"destination":"inventory:3","items":[
                  {"templateId":"TestResource","quantity":1,"quality":0}
                ]}
                """);
            var beforeHologramGrant = File.ReadAllBytes(target);
            var hologramRejected = false;
            try
            {
                GrantItems(
                    target,
                    Path.Combine(root, "safety", "before-hologram-grant.db"),
                    planPath,
                    catalogPath);
            }
            catch (InvalidDataException ex)
                when (ex.Message.Contains("no longer exists", StringComparison.OrdinalIgnoreCase))
            {
                hologramRejected = true;
            }
            if (!hologramRejected
                || !File.ReadAllBytes(target).SequenceEqual(beforeHologramGrant))
            {
                throw new InvalidOperationException(
                    "Hologram Developer Storage grant did not fail closed.");
            }
            File.WriteAllText(
                planPath,
                """
                {"destination":"inventory:2","items":[
                  {"templateId":"TestResource","quantity":12,"quality":0},
                  {"templateId":"HeavyAmmo","quantity":501,"quality":0},
                  {"templateId":"AntiRadiationPill","quantity":21,"quality":0}
                ]}
                """);
            var grantSafety = Path.Combine(root, "safety", "before-grant.db");
            GrantItems(target, grantSafety, planPath, catalogPath);
            if (!File.Exists(grantSafety))
            {
                throw new InvalidOperationException("Item grant did not retain a safety backup.");
            }
            var grantedSqlite = Path.Combine(root, "granted.sqlite");
            File.WriteAllBytes(grantedSqlite, Unwrap(ReadStable(target)).SqliteBytes);
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                   {
                       DataSource = grantedSqlite,
                       Mode = SqliteOpenMode.ReadOnly,
                       Pooling = false
                   }.ToString()))
            {
                connection.Open();
                var quantity = ScalarLong(
                    connection,
                    "SELECT COALESCE(SUM(stack_size), 0) FROM items WHERE template_id = 'TestResource';");
                if (quantity != 12)
                {
                    throw new InvalidOperationException(
                        $"Item grant expected quantity 12, found {quantity}.");
                }
                var heavyQuantity = ScalarLong(
                    connection,
                    "SELECT COALESCE(SUM(stack_size), 0) FROM items WHERE template_id = 'HeavyAmmo';");
                var heavyRows = ScalarLong(
                    connection,
                    "SELECT COUNT(*) FROM items WHERE template_id = 'HeavyAmmo';");
                var heavyMax = ScalarLong(
                    connection,
                    "SELECT COALESCE(MAX(stack_size), 0) FROM items WHERE template_id = 'HeavyAmmo';");
                var pillQuantity = ScalarLong(
                    connection,
                    "SELECT COALESCE(SUM(stack_size), 0) FROM items WHERE template_id = 'AntiRadiationPill';");
                var pillRows = ScalarLong(
                    connection,
                    "SELECT COUNT(*) FROM items WHERE template_id = 'AntiRadiationPill';");
                var pillMax = ScalarLong(
                    connection,
                    "SELECT COALESCE(MAX(stack_size), 0) FROM items WHERE template_id = 'AntiRadiationPill';");
                if (heavyQuantity != 501 || heavyRows != 2 || heavyMax != 500
                    || pillQuantity != 21 || pillRows != 2 || pillMax != 20)
                {
                    throw new InvalidOperationException(
                        "Picker-only stack-limit fallbacks were not applied correctly.");
                }
            }

            File.WriteAllText(
                planPath,
                """
                {"destination":"inventory:1","items":[
                  {"templateId":"BuggyKnownParts","quantity":1,"quality":0},
                  {"templateId":"RepairTool5","quantity":1,"quality":0}
                ]}
                """);
            var buggySafety = Path.Combine(root, "safety", "before-buggy-grant.db");
            GrantItems(target, buggySafety, planPath, catalogPath);
            if (!File.Exists(buggySafety))
            {
                throw new InvalidOperationException(
                    "Stock-volume Buggy grant did not retain a safety backup.");
            }

            var beforeOversizedGrant = File.ReadAllBytes(target);
            File.WriteAllText(
                planPath,
                """
                {"destination":"inventory:1","items":[
                  {"templateId":"SandcrawlerSpiceHeader_6","quantity":1,"quality":0}
                ]}
                """);
            var oversizedRejected = false;
            try
            {
                GrantItems(
                    target,
                    Path.Combine(root, "safety", "before-oversized-grant.db"),
                    planPath,
                    catalogPath);
            }
            catch (InvalidDataException ex)
                when (ex.Message.Contains("volume capacity", StringComparison.OrdinalIgnoreCase))
            {
                oversizedRejected = true;
            }
            if (!oversizedRejected
                || !File.ReadAllBytes(target).SequenceEqual(beforeOversizedGrant))
            {
                throw new InvalidOperationException(
                    "Oversized unknown vehicle part did not fail closed.");
            }

            var currencySafety = Path.Combine(root, "safety", "before-currency.db");
            SetCurrencies(target, currencySafety, 1_000_000, 250_000);
            if (!File.Exists(currencySafety))
            {
                throw new InvalidOperationException("Currency write did not retain a safety backup.");
            }
            var currencyInspection = InspectPath(target);
            if (currencyInspection.Currencies.Solari != 1_000_000
                || currencyInspection.Currencies.Scrip != 250_000)
            {
                throw new InvalidOperationException("Currency write did not verify expected balances.");
            }

            var adapterPath = Path.Combine(root, "solo-adapter.json");
            var selfTestFingerprint = InspectPath(target).SchemaFingerprint;
            File.WriteAllText(
                adapterPath,
                """
                {
                  "id":"self-test",
                  "schema_fingerprint":"__SCHEMA_FINGERPRINT__",
                  "specializations":{
                    "max_level":100,
                    "max_xp":44182,
                    "tracks":{"Combat":0,"Crafting":1,"Exploration":2,"Gathering":3,"Sabotage":4}
                  },
                  "find_the_fremen":{
                    "nodes":["DA_MQ_FindTheFremen","DA_MQ_FindTheFremen.FirstTest"],
                    "tags":["Journey.Act1.Completed","Journey.RewardsUnblocked"],
                    "recipes":["RCP_TestFremkitRecipe"],
                    "spice_status":"FullyEnabled"
                  },
                  "water_fillable_capacities":{
                    "highcapacityliterjon_06":3000
                  },
                  "enable_all_skills":{
                    "level_value":7,
                    "point_buffer":20,
                    "intel_floor":100,
                    "exclude":[
                      "(TagName=\"Skills.Ability.VoiceStop\")",
                      "(TagName=\"Skills.Ability.Hypersprint\")"
                    ]
                  }
                }
                """.Replace("__SCHEMA_FINGERPRINT__", selfTestFingerprint));
            var fillSafety = Path.Combine(root, "safety", "before-fill.db");
            FillWaterContainer(target, fillSafety, 100, adapterPath);
            var fillInspection = InspectPath(target, adapterPath: adapterPath);
            var literjon = fillInspection.Fillables.SingleOrDefault(value => value.ItemId == 100);
            if (!File.Exists(fillSafety)
                || literjon is null
                || Math.Abs(literjon.CurrentAmount - 3000d) > 0.0001)
            {
                throw new InvalidOperationException("Literjon fill did not verify expected capacity.");
            }
            var dewpackSafety = Path.Combine(root, "safety", "before-dewpack-fill.db");
            FillWaterContainer(target, dewpackSafety, 101, adapterPath);
            fillInspection = InspectPath(target, adapterPath: adapterPath);
            var dewpack = fillInspection.Fillables.SingleOrDefault(value => value.ItemId == 101);
            if (!File.Exists(dewpackSafety)
                || dewpack is null
                || Math.Abs(dewpack.CurrentAmount - 250d) > 0.0001
                || fillInspection.Fillables.Any(value => value.ItemId == 102))
            {
                throw new InvalidOperationException(
                    "Generic water-container detection or stillsuit exclusion failed.");
            }
            var keystonePath = Path.Combine(root, "keystones.json");
            File.WriteAllText(
                keystonePath,
                """
                {
                  "1":{"track":"Combat","level":1,"name":"DA_CombatKeystone_SkillPoint_Major"},
                  "2":{"track":"Crafting","level":1,"name":"DA_CraftingKeystone_Test"}
                }
                """);
            var skillsPath = Path.Combine(root, "skills.json");
            File.WriteAllText(
                skillsPath,
                """
                {
                  "count":4,
                  "keys":[
                    "(TagName=\"Skills.Ability.VoiceStop\")",
                    "(TagName=\"Skills.Ability.Hypersprint\")",
                    "(TagName=\"Skills.Ability.TestOne\")",
                    "(TagName=\"Skills.Attribute.TestTwo\")"
                  ]
                }
                """);
            MaxSpecializations(
                target,
                Path.Combine(root, "safety", "before-spec.db"),
                adapterPath,
                keystonePath);
            CompleteFindTheFremen(
                target,
                Path.Combine(root, "safety", "before-fremen.db"),
                adapterPath);
            EnableAllSkills(
                target,
                Path.Combine(root, "safety", "before-skills.db"),
                adapterPath,
                skillsPath);
            var progressionInspection = InspectPath(target);
            if (progressionInspection.Progression.Specializations.Length != 5
                || progressionInspection.Progression.PurchasedRewards != 2
                || progressionInspection.Progression.FremenNodesComplete != 2
                || progressionInspection.Progression.SkillsAtSeven != 2
                || progressionInspection.Progression.UnspentSkillPoints < 20
                || progressionInspection.Progression.Intel < 100)
            {
                throw new InvalidOperationException(
                    "Progression self-test did not reach verified target state.");
            }

            var badAdapterPath = Path.Combine(root, "bad-adapter.json");
            File.WriteAllText(
                badAdapterPath,
                File.ReadAllText(adapterPath).Replace(
                    selfTestFingerprint,
                    new string('0', 64)));
            var schemaTargetBefore = SHA256.HashData(File.ReadAllBytes(target));
            var schemaRejected = false;
            try
            {
                EnableAllSkills(
                    target,
                    Path.Combine(root, "safety", "bad-schema.db"),
                    badAdapterPath,
                    skillsPath);
            }
            catch (InvalidDataException)
            {
                schemaRejected = true;
            }
            if (!schemaRejected
                || !CryptographicOperations.FixedTimeEquals(
                    schemaTargetBefore,
                    SHA256.HashData(File.ReadAllBytes(target))))
            {
                throw new InvalidOperationException(
                    "Progression schema mismatch did not fail closed.");
            }

            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                   {
                       DataSource = sqlitePath,
                       Mode = SqliteOpenMode.ReadWrite,
                       Pooling = false
                   }.ToString()))
            {
                connection.Open();
                using var command = connection.CreateCommand();
                command.CommandText = """
                    INSERT INTO player_state (
                        id,
                        name,
                        player_pawn_id,
                        player_controller_id
                    )
                    VALUES (2, 'Unexpected', 10, 11);
                    """;
                command.ExecuteNonQuery();
            }
            var invalidRestore = Path.Combine(root, "invalid-two-characters.db");
            WrapSqlite(sqlitePath, invalidRestore);
            var targetBefore = SHA256.HashData(File.ReadAllBytes(target));
            var invalidRejected = false;
            try
            {
                Restore(
                    invalidRestore,
                    target,
                    Path.Combine(root, "safety", "invalid-restore-safety.db"));
            }
            catch (InvalidDataException)
            {
                invalidRejected = true;
            }
            if (!invalidRejected
                || !CryptographicOperations.FixedTimeEquals(
                    targetBefore,
                    SHA256.HashData(File.ReadAllBytes(target))))
            {
                throw new InvalidOperationException("Invalid restore did not fail closed.");
            }

            return new
            {
                ok = true,
                tests = new[]
                {
                    "wrapper-v1-roundtrip",
                    "sqlite-integrity-and-foreign-keys",
                    "exactly-one-character",
                    "map-seed-from-coriolis-cycle",
                    "retained-backup",
                    "atomic-restore-with-safety-backup",
                    "unsupported-wrapper-rejected",
                    "offline-augment-max-with-safety-backup",
                    "offline-item-grant-with-capacity-and-safety-backup",
                    "vehicle-kit-volume-fallbacks-preserve-stock-backpack-grants",
                    "offline-currency-write-with-safety-backup",
                    "offline-water-container-fills-with-safety-backups",
                    "offline-specialization-max-with-rewards",
                    "offline-find-the-fremen-completion",
                    "offline-enable-all-skills-preserves-unknowns",
                    "progression-schema-mismatch-fails-closed",
                    "invalid-restore-leaves-target-unchanged"
                }
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
                // Test result remains authoritative; OS temp cleanup can follow.
            }
        }
    }

    private static void WrapSqlite(string sqlitePath, string outputPath)
    {
        var sqlite = File.ReadAllBytes(sqlitePath);
        using var output = new MemoryStream();
        output.Write(new byte[8]);
        using (var zlib = new ZLibStream(output, CompressionLevel.Optimal, leaveOpen: true))
        {
            zlib.Write(sqlite);
        }
        var wrapped = output.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(wrapped.AsSpan(0, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(wrapped.AsSpan(4, 4), checked((uint)sqlite.Length));
        File.WriteAllBytes(outputPath, wrapped);
    }

    private static Inspection InspectPath(
        string input,
        string? catalogPath = null,
        string? adapterPath = null)
    {
        var catalog = catalogPath is null
            ? null
            : ReadCatalog(catalogPath);
        var waterCapacities = adapterPath is null
            ? null
            : ReadPtcAdapter(adapterPath).WaterCapacities;
        return InspectBytes(
            ReadStable(input),
            input,
            catalog,
            waterCapacities);
    }

    private static byte[] ReadStable(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("Solo save was not found.", path);
        }

        for (var attempt = 0; attempt < 3; attempt++)
        {
            var before = new FileInfo(path);
            var beforeLength = before.Length;
            var beforeWrite = before.LastWriteTimeUtc;
            byte[] bytes;
            using (var stream = new FileStream(
                       path,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.ReadWrite | FileShare.Delete))
            {
                using var memory = new MemoryStream();
                stream.CopyTo(memory);
                bytes = memory.ToArray();
            }

            var after = new FileInfo(path);
            if (beforeLength == after.Length
                && beforeWrite == after.LastWriteTimeUtc
                && bytes.LongLength == after.Length)
            {
                return bytes;
            }
            Thread.Sleep(150);
        }
        throw new IOException("Solo save changed while it was being copied. Try again after the game finishes saving.");
    }

    private static Inspection InspectBytes(
        byte[] wrapped,
        string sourcePath,
        IReadOnlyDictionary<string, CatalogRule>? catalog = null,
        IReadOnlyDictionary<string, int>? waterCapacities = null)
    {
        var database = Unwrap(wrapped);
        var sqliteBytes = database.SqliteBytes;
        var wrapperVersion = database.WrapperVersion;
        var declaredLength = database.DeclaredLength;

        var temp = Path.Combine(Path.GetTempPath(), $"dune-solo-{Guid.NewGuid():N}.sqlite");
        try
        {
            File.WriteAllBytes(temp, sqliteBytes);
            return InspectSqlite(
                temp,
                sourcePath,
                wrapped,
                wrapperVersion,
                declaredLength,
                catalog,
                waterCapacities);
        }
        finally
        {
            TryDelete(temp);
        }
    }

    private static WrappedDatabase Unwrap(byte[] wrapped)
    {
        if (wrapped.Length < 10)
        {
            throw new InvalidDataException("Save is too short to contain a wrapped SQLite database.");
        }

        var wrapperVersion = BinaryPrimitives.ReadUInt32LittleEndian(wrapped.AsSpan(0, 4));
        var declaredLength = BinaryPrimitives.ReadUInt32LittleEndian(wrapped.AsSpan(4, 4));
        if (wrapperVersion != 1)
        {
            throw new InvalidDataException($"Unsupported Solo save wrapper version: {wrapperVersion}.");
        }
        if (declaredLength == 0 || declaredLength > 2_147_483_647)
        {
            throw new InvalidDataException($"Invalid declared SQLite length: {declaredLength}.");
        }

        byte[] sqliteBytes;
        using (var compressed = new MemoryStream(wrapped, 8, wrapped.Length - 8, writable: false))
        using (var zlib = new ZLibStream(compressed, CompressionMode.Decompress))
        using (var sqlite = new MemoryStream((int)declaredLength))
        {
            zlib.CopyTo(sqlite);
            sqliteBytes = sqlite.ToArray();
        }
        if (sqliteBytes.LongLength != declaredLength)
        {
            throw new InvalidDataException(
                $"SQLite length mismatch: header says {declaredLength}, decompressed {sqliteBytes.LongLength}.");
        }
        if (sqliteBytes.Length < 16
            || Encoding.ASCII.GetString(sqliteBytes, 0, 16) != "SQLite format 3\0")
        {
            throw new InvalidDataException("Wrapped payload is not a SQLite 3 database.");
        }
        return new WrappedDatabase(wrapperVersion, declaredLength, sqliteBytes);
    }

    private static Inspection InspectSqlite(
        string sqlitePath,
        string sourcePath,
        byte[] wrapped,
        uint wrapperVersion,
        uint declaredLength,
        IReadOnlyDictionary<string, CatalogRule>? catalog,
        IReadOnlyDictionary<string, int>? waterCapacities)
    {
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = sqlitePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false
        }.ToString();

        using var connection = new SqliteConnection(connectionString);
        connection.Open();

        var integrity = ScalarString(connection, "PRAGMA integrity_check;");
        var foreignKeyViolations = ScalarLong(
            connection,
            "SELECT COUNT(*) FROM pragma_foreign_key_check;");
        var tableCount = ScalarLong(
            connection,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';");
        var hasPlayerState = ScalarLong(
            connection,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='player_state';") == 1;
        var characterCount = hasPlayerState
            ? ScalarLong(connection, "SELECT COUNT(*) FROM player_state;")
            : 0;
        var inventories = hasPlayerState
            ? ReadInventoryDestinations(connection, catalog)
            : Array.Empty<InventoryDestination>();
        var hasCurrencies = ScalarLong(
            connection,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='player_virtual_currency_balances';") == 1;
        var currencies = new CurrencyBalances(0, 0);
        if (hasPlayerState && hasCurrencies && characterCount == 1)
        {
            var controllerId = ScalarLong(
                connection,
                "SELECT player_controller_id FROM player_state LIMIT 1;");
            currencies = new CurrencyBalances(
                Solari: ReadCurrencyBalance(connection, controllerId, 0),
                Scrip: ReadCurrencyBalance(connection, controllerId, 1));
        }
        var fillables = hasPlayerState && characterCount == 1
            ? ReadSupportedFillables(connection, waterCapacities)
            : Array.Empty<FillableItem>();
        var progression = ReadProgressionSummary(connection);
        long? mapSeed = null;
        var hasSingleCoriolisCycle = ScalarLong(
            connection,
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table'
              AND name = 'coriolis_cycle';
            """) == 1
            && ScalarLong(connection, "SELECT COUNT(*) FROM coriolis_cycle;") == 1;
        if (hasSingleCoriolisCycle)
        {
            var cycleIndex = ScalarLong(
                connection,
                "SELECT cycle_index FROM coriolis_cycle LIMIT 1;");
            mapSeed = ((cycleIndex % 12) + 12) % 12;
        }

        using var schemaCommand = connection.CreateCommand();
        schemaCommand.CommandText = """
            SELECT m.name, p.name, COALESCE(p.type, ''), p."notnull", p.pk
            FROM sqlite_master AS m
            JOIN pragma_table_info(m.name) AS p
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, p.cid;
            """;
        var schema = new StringBuilder();
        using (var reader = schemaCommand.ExecuteReader())
        {
            while (reader.Read())
            {
                schema.Append(reader.GetString(0)).Append('|')
                    .Append(reader.GetString(1)).Append('|')
                    .Append(reader.GetString(2)).Append('|')
                    .Append(reader.GetInt64(3)).Append('|')
                    .Append(reader.GetInt64(4)).Append('\n');
            }
        }

        return new Inspection(
            Ok: true,
            SourcePath: Path.GetFullPath(sourcePath),
            WrappedBytes: wrapped.LongLength,
            WrappedSha256: Convert.ToHexString(SHA256.HashData(wrapped)).ToLowerInvariant(),
            WrapperVersion: wrapperVersion,
            DeclaredSqliteBytes: declaredLength,
            ActualSqliteBytes: new FileInfo(sqlitePath).Length,
            Integrity: integrity,
            ForeignKeyViolations: foreignKeyViolations,
            TableCount: tableCount,
            CharacterCount: characterCount,
            SchemaFingerprint: Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(schema.ToString()))).ToLowerInvariant(),
            MapSeed: mapSeed,
            Inventories: inventories,
            Currencies: currencies,
            Fillables: fillables,
            Progression: progression);
    }

    private static InventoryDestination[] ReadInventoryDestinations(
        SqliteConnection connection,
        IReadOnlyDictionary<string, CatalogRule>? catalog = null)
    {
        var results = new List<InventoryDestination>();
        var pawnId = ScalarLong(connection, "SELECT player_pawn_id FROM player_state LIMIT 1;");
        using (var backpack = connection.CreateCommand())
        {
            backpack.CommandText = """
                SELECT inv.id, inv.max_item_count, inv.max_item_volume, COUNT(items.id)
                FROM inventories AS inv
                LEFT JOIN items ON items.inventory_id = inv.id
                WHERE inv.actor_id = $pawn
                  AND inv.inventory_type = 0
                  AND COALESCE(inv.max_item_count, 0) > 0
                GROUP BY inv.id
                ORDER BY inv.id
                LIMIT 1;
                """;
            backpack.Parameters.AddWithValue("$pawn", pawnId);
            using var reader = backpack.ExecuteReader();
            if (reader.Read())
            {
                results.Add(new InventoryDestination(
                    Id: reader.GetInt64(0),
                    Key: $"inventory:{reader.GetInt64(0)}",
                    Label: "Backpack",
                    Kind: "backpack",
                    ItemRows: reader.GetInt64(3),
                    MaxItemCount: reader.IsDBNull(1) ? 0 : reader.GetInt64(1),
                    MaxItemVolume: reader.IsDBNull(2) ? 0 : reader.GetDouble(2),
                    UsedVolume: 0));
            }
        }

        using var storage = connection.CreateCommand();
        storage.CommandText = """
            SELECT inv.id,
                   inv.max_item_count,
                   inv.max_item_volume,
                   COUNT(items.id),
                   placeables.building_type
            FROM inventories AS inv
            JOIN actors ON actors.id = inv.actor_id
            JOIN placeables ON placeables.id = actors.id
            LEFT JOIN items ON items.inventory_id = inv.id
            WHERE inv.inventory_type = 4
              AND placeables.is_hologram = 0
              AND placeables.owner_entity_id IS NOT NULL
              AND placeables.owner_entity_id != 0
            GROUP BY inv.id
            ORDER BY inv.id;
            """;
        using (var reader = storage.ExecuteReader())
        {
            var labelCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            while (reader.Read())
            {
                var buildingType = reader.IsDBNull(4) ? string.Empty : reader.GetString(4);
                if (!SoloStorageLabels.TryGetValue(buildingType, out var baseLabel))
                {
                    continue;
                }
                labelCounts.TryGetValue(baseLabel, out var priorCount);
                var index = priorCount + 1;
                labelCounts[baseLabel] = index;
                results.Add(new InventoryDestination(
                    Id: reader.GetInt64(0),
                    Key: $"inventory:{reader.GetInt64(0)}",
                    Label: $"{baseLabel} #{index}",
                    Kind: string.Equals(
                        baseLabel,
                        "Developer Storage",
                        StringComparison.OrdinalIgnoreCase)
                        ? "developer-storage"
                        : "storage",
                    ItemRows: reader.GetInt64(3),
                    MaxItemCount: reader.IsDBNull(1) ? 0 : reader.GetInt64(1),
                    MaxItemVolume: reader.IsDBNull(2) ? 0 : reader.GetDouble(2),
                    UsedVolume: 0));
            }
        }
        var volumeRules = catalog
            ?? new Dictionary<string, CatalogRule>(StringComparer.OrdinalIgnoreCase);
        return results
            .Select(result => result with
            {
                UsedVolume = GetUsedVolume(connection, result.Id, volumeRules)
            })
            .ToArray();
    }

    private static GrantPlan ReadGrantPlan(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        var destination = root.GetProperty("destination").GetString()?.Trim() ?? string.Empty;
        if (!destination.StartsWith("inventory:", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Choose a valid Solo inventory destination.");
        }
        var items = new List<GrantItem>();
        foreach (var element in root.GetProperty("items").EnumerateArray())
        {
            var templateId = element.GetProperty("templateId").GetString()?.Trim() ?? string.Empty;
            var quantity = element.GetProperty("quantity").GetInt32();
            var quality = element.TryGetProperty("quality", out var qualityElement)
                ? qualityElement.GetInt32()
                : 0;
            if (string.IsNullOrWhiteSpace(templateId))
            {
                throw new InvalidDataException("Item template id is required.");
            }
            if (quantity < 1 || quantity > 100_000)
            {
                throw new InvalidDataException("Item quantity must be between 1 and 100000.");
            }
            if (quality < 0 || quality > 5)
            {
                throw new InvalidDataException("Item quality must be between 0 and 5.");
            }
            items.Add(new GrantItem(templateId, quantity, quality));
        }
        if (items.Count is < 1 or > 200)
        {
            throw new InvalidDataException("Grant between 1 and 200 item templates per operation.");
        }
        return new GrantPlan(destination, items);
    }

    private static IReadOnlyDictionary<string, CatalogRule> ReadCatalog(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var result = new Dictionary<string, CatalogRule>(StringComparer.OrdinalIgnoreCase);
        if (document.RootElement.TryGetProperty("names", out var names))
        {
            foreach (var property in names.EnumerateObject())
            {
                result[property.Name] = new CatalogRule(1, 0, false);
            }
        }
        if (document.RootElement.TryGetProperty("items", out var rules))
        {
            foreach (var property in rules.EnumerateObject())
            {
                var value = property.Value;
                var stackMax = value.TryGetProperty("stack_max", out var stackElement)
                    && stackElement.ValueKind == JsonValueKind.Number
                    ? Math.Max(1, stackElement.GetInt32())
                    : 1;
                var hasVolume = value.TryGetProperty("volume", out var volumeElement)
                    && volumeElement.ValueKind == JsonValueKind.Number;
                var volume = hasVolume ? volumeElement.GetDouble() : 0;
                result[property.Name] = new CatalogRule(stackMax, volume, hasVolume);
            }
        }
        foreach (var (templateId, stackMax) in KnownStackLimits)
        {
            if (result.TryGetValue(templateId, out var rule))
            {
                result[templateId] = rule with
                {
                    StackMax = Math.Max(rule.StackMax, stackMax)
                };
            }
        }
        foreach (var (templateId, volume) in KnownVolumeFallbacks)
        {
            if (result.ContainsKey(templateId))
            {
                result[templateId] = new CatalogRule(1, volume, true);
            }
        }
        return result;
    }

    private static InventoryDestination ResolveDestination(
        SqliteConnection connection,
        string key)
    {
        var destination = ReadInventoryDestinations(connection)
            .SingleOrDefault(value => string.Equals(
                value.Key,
                key,
                StringComparison.OrdinalIgnoreCase));
        return destination
            ?? throw new InvalidDataException(
                "The selected backpack or built storage inventory no longer exists.");
    }

    private static HashSet<int> ReadUsedPositions(
        SqliteConnection connection,
        long inventoryId)
    {
        var positions = new HashSet<int>();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT position_index FROM items WHERE inventory_id = $id;";
        command.Parameters.AddWithValue("$id", inventoryId);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            positions.Add(reader.GetInt32(0));
        }
        return positions;
    }

    private static double GetUsedVolume(
        SqliteConnection connection,
        long inventoryId,
        IReadOnlyDictionary<string, CatalogRule> catalog)
    {
        var total = 0d;
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT template_id, stack_size, volume_override
            FROM items
            WHERE inventory_id = $id;
            """;
        command.Parameters.AddWithValue("$id", inventoryId);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var templateId = reader.GetString(0);
            var quantity = reader.GetInt64(1);
            var volume = 0d;
            if (catalog.TryGetValue(templateId, out var rule) && rule.HasVolume)
            {
                volume = rule.Volume;
            }
            else if (!reader.IsDBNull(2))
            {
                var overrideVolume = reader.GetDouble(2);
                if (double.IsFinite(overrideVolume) && overrideVolume > 0)
                {
                    volume = overrideVolume;
                }
                else
                {
                    volume = 0;
                }
            }
            else
            {
                volume = 0;
            }
            total += volume * quantity;
        }
        return total;
    }

    private static long ReadCurrencyBalance(
        SqliteConnection connection,
        long controllerId,
        int currencyId)
    {
        return ScalarLong(
            connection,
            """
            SELECT COALESCE(MAX(balance), 0)
            FROM player_virtual_currency_balances
            WHERE player_controller_id = $controller
              AND currency_id = $currency;
            """,
            ("$controller", controllerId),
            ("$currency", currencyId));
    }

    private static FillableItem[] ReadSupportedFillables(
        SqliteConnection connection,
        IReadOnlyDictionary<string, int>? waterCapacities)
    {
        var pawnId = ScalarLong(connection, "SELECT player_pawn_id FROM player_state LIMIT 1;");
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT items.id,
                   items.template_id,
                   COALESCE(
                       json_extract(items.stats, '$.FFillableItemStats[1].CurrentAmount'),
                       0
                   ),
                   COALESCE(
                      json_extract(items.stats, '$.FFillableItemStats[1].MaxAmount'),
                      0
                   )
            FROM items
            JOIN inventories ON inventories.id = items.inventory_id
            WHERE inventories.actor_id = $pawn
              AND json_type(items.stats, '$.FFillableItemStats[1]') = 'object'
              AND (
                  lower(items.template_id) LIKE '%literjon%'
                  OR lower(items.template_id) LIKE '%dewpack%'
                  OR lower(items.template_id) LIKE '%decajon%'
              )
            ORDER BY items.id;
            """;
        command.Parameters.AddWithValue("$pawn", pawnId);
        var results = new List<FillableItem>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var templateId = reader.GetString(1);
            var storedMax = reader.GetDouble(3);
            var capacity = storedMax > 0
                ? storedMax
                : waterCapacities is not null
                    && waterCapacities.TryGetValue(
                        templateId.ToLowerInvariant(),
                        out var fallback)
                    ? fallback
                    : 0;
            if (capacity <= 0) { continue; }
            results.Add(new FillableItem(
                ItemId: reader.GetInt64(0),
                TemplateId: templateId,
                Label: templateId,
                CurrentAmount: reader.GetDouble(2),
                Capacity: capacity));
        }
        return results.ToArray();
    }

    private static string ItemStatsJson(int stackMax)
    {
        return stackMax > 1
            ? """{"FItemStackAndDurabilityStats":[[],{"DecayedMaxDurability":0.0}]}"""
            : """{"FCustomizationStats":[[],{}],"FItemStackAndDurabilityStats":[[],{}]}""";
    }

    private static int ExecuteNonQuery(
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
        return command.ExecuteNonQuery();
    }

    private static string ScalarString(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToString(command.ExecuteScalar()) ?? string.Empty;
    }

    private static long ScalarLong(
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
        return Convert.ToInt64(command.ExecuteScalar());
    }

    private static double ScalarDouble(
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
        return Convert.ToDouble(command.ExecuteScalar());
    }

    private static void EnsureWritableInspection(Inspection inspection)
    {
        if (!string.Equals(inspection.Integrity, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"SQLite integrity check failed: {inspection.Integrity}");
        }
        if (inspection.ForeignKeyViolations != 0)
        {
            throw new InvalidDataException(
                $"SQLite foreign-key check found {inspection.ForeignKeyViolations} violation(s).");
        }
        if (inspection.CharacterCount != 1)
        {
            throw new InvalidDataException(
                $"Expected exactly one Solo character, found {inspection.CharacterCount}.");
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // A stale temp file is safer than hiding the original operation result.
        }
    }

    private static void WriteJson(object value)
    {
        Console.Out.WriteLine(JsonSerializer.Serialize(value, JsonOptions));
    }

    private sealed record Inspection(
        bool Ok,
        string SourcePath,
        long WrappedBytes,
        string WrappedSha256,
        uint WrapperVersion,
        uint DeclaredSqliteBytes,
        long ActualSqliteBytes,
        string Integrity,
        long ForeignKeyViolations,
        long TableCount,
        long CharacterCount,
        string SchemaFingerprint,
        long? MapSeed,
        InventoryDestination[] Inventories,
        CurrencyBalances Currencies,
        FillableItem[] Fillables,
        ProgressionSummary Progression);

    private sealed record WrappedDatabase(
        uint WrapperVersion,
        uint DeclaredLength,
        byte[] SqliteBytes);

    private sealed record InventoryDestination(
        long Id,
        string Key,
        string Label,
        string Kind,
        long ItemRows,
        long MaxItemCount,
        double MaxItemVolume,
        double UsedVolume);

    private sealed record CatalogRule(
        int StackMax,
        double Volume,
        bool HasVolume);

    private sealed record CurrencyBalances(
        long Solari,
        long Scrip);


    private sealed record FillableItem(
        long ItemId,
        string TemplateId,
        string Label,
        double CurrentAmount,
        double Capacity);

    private sealed record GrantItem(
        string TemplateId,
        int Quantity,
        int Quality);

    private sealed record GrantPlan(
        string Destination,
        IReadOnlyList<GrantItem> Items);
}
