using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static void TestInventoryGroupDeletion(string fixture, string catalogPath, string root)
    {
        var sqlite = Path.Combine(root, "group-fixture.sqlite");
        File.WriteAllBytes(sqlite, Unwrap(ReadStable(fixture)).SqliteBytes);
        using (var connection = new SqliteConnection($"Data Source={sqlite};Pooling=False"))
        {
            connection.Open();
            ExecuteNonQuery(connection, """
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<19991)
                INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats)
                SELECT 100000+x,1,1,100000+x,'BulkTest','{}' FROM n;
                INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats)
                VALUES(90001,35,7,1,'BulkTest','{}'),(90002,8,1,2,'BulkTest','{}'),
                      (90003,383,9,3,'BulkTest','{}');
                """);
        }
        var target = Path.Combine(root, "group-game.db");
        WrapSqlite(sqlite, target);
        var before = File.ReadAllBytes(target);
        var backup = Path.Combine(root, "safety", "before-group.db");
        try
        {
            DeleteInventoryGroup(target, backup, "BulkTest", "inventory:1", 19990, 19991,
                catalogPath, requireGameClosed: false);
            throw new InvalidOperationException("Stale group count was accepted.");
        }
        catch (InvalidDataException) { }
        if (!File.ReadAllBytes(target).SequenceEqual(before) || File.Exists(backup))
            throw new InvalidOperationException("Rejected bulk deletion changed the save or wrote a backup.");
        DeleteInventoryGroup(target, backup, "BulkTest", "inventory:1", 19991, 19991,
            catalogPath, requireGameClosed: false);
        if (!File.ReadAllBytes(backup).SequenceEqual(before))
            throw new InvalidOperationException("Bulk deletion did not retain the exact original save.");
        var result = InspectPath(target, catalogPath);
        if (result.InventoryItems.Any(g => g.TemplateId == "BulkTest" && g.DestinationKey == "inventory:1")
            || !result.InventoryItems.Any(g => g.TemplateId == "TestResource" && g.TotalQuantity == 10)
            || !result.InventoryItems.Any(g => g.TemplateId == "BulkTest" && g.DestinationKey == "inventory:35" && g.TotalQuantity == 7))
            throw new InvalidOperationException("Bulk deletion crossed inventory or item boundaries.");
        DeleteInventoryGroup(target, Path.Combine(root, "safety", "before-all-group.db"),
            "BulkTest", "all", 1, 7, catalogPath, requireGameClosed: false);
        File.WriteAllBytes(sqlite, Unwrap(ReadStable(target)).SqliteBytes);
        using var final = new SqliteConnection($"Data Source={sqlite};Pooling=False");
        final.Open();
        if (ScalarLong(final, "SELECT COUNT(*) FROM items WHERE id IN (90002,90003);") != 2)
            throw new InvalidOperationException("All locations deleted equipped or another character's items.");
    }

    private static object DeleteInventoryGroup(string input, string safetyBackup,
        string templateId, string destination, long expectedCount, long expectedTotal,
        string catalogPath, bool requireGameClosed = true)
    {
        if (string.IsNullOrWhiteSpace(templateId) || expectedCount <= 0 || expectedTotal < 0)
            throw new InvalidDataException("Choose an item group and refresh its total before deleting.");
        var catalog = ReadCatalog(catalogPath);
        var original = ReadStable(input);
        var inspection = InspectBytes(original, input, catalog);
        EnsureWritableInspection(inspection);
        var groups = inspection.InventoryItems.Where(g =>
            string.Equals(g.TemplateId, templateId, StringComparison.OrdinalIgnoreCase)
            && g.DestinationKind != "equipment"
            && (destination == "all" || g.DestinationKey == destination)).ToArray();
        var targets = groups.SelectMany(g => g.Occurrences).ToArray();
        var total = targets.Sum(i => i.StackSize);
        if (targets.LongLength != expectedCount || total != expectedTotal)
            throw new InvalidDataException("The selected item group changed. Refresh and review the total again.");
        var root = Path.Combine(Path.GetTempPath(), $"dune-solo-delete-group-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var sqlite = Path.Combine(root, "items.sqlite");
            File.WriteAllBytes(sqlite, Unwrap(original).SqliteBytes);
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder {
                DataSource = sqlite, Mode = SqliteOpenMode.ReadWrite, Pooling = false }.ToString()))
            {
                connection.Open();
                ExecuteNonQuery(connection, "PRAGMA foreign_keys = ON;");
                using var transaction = connection.BeginTransaction();
                using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = "DELETE FROM items WHERE id = $id AND stack_size = $size;";
                var id = command.Parameters.Add("$id", SqliteType.Integer);
                var size = command.Parameters.Add("$size", SqliteType.Integer);
                command.Prepare();
                foreach (var target in targets)
                {
                    id.Value = target.ItemId; size.Value = target.StackSize;
                    if (command.ExecuteNonQuery() != 1)
                        throw new InvalidDataException("The selected item group changed. Refresh and try again.");
                }
                transaction.Commit();
                if (ScalarString(connection, "PRAGMA integrity_check;") != "ok"
                    || ScalarLong(connection, "SELECT COUNT(*) FROM pragma_foreign_key_check;") != 0)
                    throw new InvalidDataException("Solo group deletion failed save integrity checks.");
            }
            var mutated = Path.Combine(root, "game.db");
            WrapSqlite(sqlite, mutated);
            var verified = InspectPath(mutated, catalogPath);
            EnsureWritableInspection(verified);
            var ids = targets.Select(i => i.ItemId).ToHashSet();
            if (verified.InventoryItems.SelectMany(g => g.Occurrences).Any(i => ids.Contains(i.ItemId)))
                throw new InvalidDataException("Solo group deletion verification failed.");
            Restore(mutated, input, safetyBackup, expectedTargetBytes: original, requireGameClosed);
            return new { ok = true, templateId, removed = total, deletedStacks = targets.Length,
                safetyBackup, inspection = InspectPath(input, catalogPath) };
        }
        finally { try { Directory.Delete(root, recursive: true); } catch { } }
    }
}
