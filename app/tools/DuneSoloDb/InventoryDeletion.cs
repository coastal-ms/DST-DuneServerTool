using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static object DeleteInventoryItem(
        string input,
        string safetyBackup,
        long itemId,
        long expectedStackSize,
        long quantity,
        string catalogPath,
        bool requireGameClosed = true)
    {
        if (quantity > expectedStackSize
            || (expectedStackSize > 0 && quantity == 0))
        {
            throw new InvalidDataException(
                "Delete quantity cannot exceed the expected stack size.");
        }

        var catalog = ReadCatalog(catalogPath);
        var originalBytes = ReadStable(input);
        EnsureWritableInspection(InspectBytes(originalBytes, input, catalog));
        var wrapped = Unwrap(originalBytes);
        var root = Path.Combine(
            Path.GetTempPath(),
            $"dune-solo-delete-item-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        var templateId = string.Empty;
        var remaining = expectedStackSize - quantity;
        try
        {
            var sqlitePath = Path.Combine(root, "delete-item.sqlite");
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
                    var supportedInventories = ReadInventoryDestinations(connection, catalog)
                        .Select(value => value.Id)
                        .ToHashSet();
                    using var lookup = connection.CreateCommand();
                    lookup.CommandText = """
                        SELECT template_id, inventory_id, stack_size
                        FROM items
                        WHERE id = $item;
                        """;
                    lookup.Parameters.AddWithValue("$item", itemId);
                    using var reader = lookup.ExecuteReader();
                    if (!reader.Read())
                    {
                        throw new InvalidDataException(
                            "The selected Solo item no longer exists. Refresh and try again.");
                    }
                    templateId = reader.GetString(0);
                    var inventoryId = reader.GetInt64(1);
                    var currentStackSize = reader.GetInt64(2);
                    reader.Close();
                    if (!supportedInventories.Contains(inventoryId))
                    {
                        throw new InvalidDataException(
                            "The selected item is not in a supported Solo inventory.");
                    }
                    if (currentStackSize != expectedStackSize)
                    {
                        throw new InvalidDataException(
                            "Item quantity changed or the item no longer exists. Refresh and try again.");
                    }

                    var affected = remaining == 0
                        ? ExecuteNonQuery(
                            connection,
                            "DELETE FROM items WHERE id = $item AND stack_size = $expected;",
                            ("$item", itemId),
                            ("$expected", expectedStackSize))
                        : ExecuteNonQuery(
                            connection,
                            """
                            UPDATE items
                            SET stack_size = $remaining,
                                is_new = 1
                            WHERE id = $item
                              AND stack_size = $expected;
                            """,
                            ("$remaining", remaining),
                            ("$item", itemId),
                            ("$expected", expectedStackSize));
                    if (affected != 1)
                    {
                        throw new InvalidDataException(
                            "Item quantity changed or the item no longer exists. Refresh and try again.");
                    }

                    var verifiedCount = ScalarLong(
                        connection,
                        "SELECT COUNT(*) FROM items WHERE id = $item;",
                        ("$item", itemId));
                    if ((remaining == 0 && verifiedCount != 0)
                        || (remaining > 0 && (verifiedCount != 1
                            || ScalarLong(
                                connection,
                                "SELECT stack_size FROM items WHERE id = $item;",
                                ("$item", itemId)) != remaining)))
                    {
                        throw new InvalidDataException("Solo item deletion verification failed.");
                    }

                    var integrity = ScalarString(connection, "PRAGMA integrity_check;");
                    var foreignKeys = ScalarLong(
                        connection,
                        "SELECT COUNT(*) FROM pragma_foreign_key_check;");
                    if (!string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase)
                        || foreignKeys != 0)
                    {
                        throw new InvalidDataException(
                            $"Item deletion validation failed (integrity={integrity}, foreignKeys={foreignKeys}).");
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
            EnsureWritableInspection(InspectPath(mutated, catalogPath));
            Restore(
                mutated,
                input,
                safetyBackup,
                expectedTargetBytes: originalBytes,
                requireGameClosed);
            return new
            {
                ok = true,
                itemId,
                templateId,
                removed = quantity,
                remaining,
                safetyBackup,
                inspection = InspectPath(input, catalogPath)
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
                // A stale temp directory is safer than hiding the delete result.
            }
        }
    }
}
