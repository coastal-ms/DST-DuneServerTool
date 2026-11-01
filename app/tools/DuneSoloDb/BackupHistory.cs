using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text.Json;

namespace DuneSoloDb;
internal static partial class Program
{
    // Display metadata only. Never use a name or reused numeric ID to approve
    // recovery reuse, mutation ownership, or a whole-save restore.
    private static void WriteBackupCharacter(string backup)
    {
        var root = Path.Combine(Path.GetTempPath(), "dune-backup-character-" + Guid.NewGuid().ToString("N"));
        var metadataTemp = backup + ".character.json." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = ReadStable(backup);
            Directory.CreateDirectory(root);
            var sqlite = Path.Combine(root, "snapshot.sqlite");
            long count = -1;
            string? name = null;
            try
            {
                File.WriteAllBytes(sqlite, Unwrap(bytes).SqliteBytes);
                using var db = new SqliteConnection(new SqliteConnectionStringBuilder
                    { DataSource = sqlite, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
                db.Open();
                if (TableExists(db, "player_state"))
                {
                    var column = ScalarLong(db, "SELECT COUNT(*) FROM pragma_table_info('player_state') WHERE name='character_name';") == 1
                        ? "character_name" : ScalarLong(db, "SELECT COUNT(*) FROM pragma_table_info('player_state') WHERE name='name';") == 1 ? "name" : null;
                    count = ScalarLong(db, "SELECT COUNT(*) FROM player_state;");
                    name = count == 1 && column != null ? ScalarString(db, $"SELECT {column} FROM player_state LIMIT 1;") : null;
                }
            }
            catch { /* Cache an unavailable label without changing the backup. */ }
            var info = new FileInfo(backup);
            File.WriteAllText(metadataTemp, JsonSerializer.Serialize(new
            {
                schema = 2, characterName = name, characterCount = count,
                bytes = info.Length, modifiedTicks = info.LastWriteTimeUtc.Ticks,
                sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()
            }));
            File.Move(metadataTemp, backup + ".character.json", overwrite: true);
        }
        catch
        {
            // A missing label must not discard or invalidate a verified backup.
            // Legacy or unreadable metadata is shown as not recorded.
        }
        finally
        {
            TryDelete(metadataTemp);
            try { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static object BackupCharacter(string backup)
    {
        WriteBackupCharacter(backup);
        return new { ok = true };
    }

    private static object BackupCharacters(string manifest)
    {
        if (new FileInfo(manifest).Length > 16 * 1024 * 1024)
            throw new InvalidDataException("Backup label manifest is too large.");
        var paths = JsonSerializer.Deserialize<string[]>(File.ReadAllText(manifest)) ?? [];
        if (paths.Length > 8192) throw new InvalidDataException("Too many backup labels in one request.");
        foreach (var path in paths) WriteBackupCharacter(path);
        return new { ok = true, count = paths.Length };
    }

    private static void SelfTestBackupLifecycle(string root, string current, string older)
    {
        var target = Path.Combine(root, "lifecycle-target.db");
        var existing = Path.Combine(root, "lifecycle-old-recovery.db");
        File.Copy(current, target);
        File.Copy(older, existing);
        var before = File.ReadAllBytes(target);
        try { Restore(older, target, existing); throw new InvalidOperationException("Existing recovery was reused."); }
        catch (IOException) { }
        if (!File.ReadAllBytes(target).SequenceEqual(before) || !File.ReadAllBytes(existing).SequenceEqual(File.ReadAllBytes(older)))
            throw new InvalidOperationException("Existing recovery rejection changed a file.");
        var safety = Path.Combine(root, "lifecycle-exact-recovery.db");
        Restore(older, target, safety);
        if (!File.ReadAllBytes(safety).SequenceEqual(before)) throw new InvalidOperationException("Exact recovery missing.");
        using (var metadata = JsonDocument.Parse(File.ReadAllText(safety + ".character.json")))
        {
            if (metadata.RootElement.GetProperty("characterName").GetString() != "Solo" ||
                metadata.RootElement.GetProperty("characterCount").GetInt64() != 1 ||
                metadata.RootElement.GetProperty("sha256").GetString() != Convert.ToHexString(SHA256.HashData(before)).ToLowerInvariant())
                throw new InvalidOperationException("Backup character metadata does not describe its exact snapshot.");
        }
        // The retail schema uses character_name. Keep coverage independent of
        // the older synthetic fixture's name column, and never rewrite backup bytes.
        var retailSqlite = Path.Combine(root, "retail-label.sqlite");
        File.WriteAllBytes(retailSqlite, Unwrap(before).SqliteBytes);
        using (var db = OpenWritable(retailSqlite))
            ExecuteNonQuery(db, "ALTER TABLE player_state RENAME COLUMN name TO character_name; UPDATE player_state SET character_name='Earlier character';");
        var retail = Path.Combine(root, "retail-label.db");
        WrapSqlite(retailSqlite, retail);
        var retailBefore = File.ReadAllBytes(retail);
        BackupCharacter(retail);
        using (var metadata = JsonDocument.Parse(File.ReadAllText(retail + ".character.json")))
            if (metadata.RootElement.GetProperty("characterName").GetString() != "Earlier character")
                throw new InvalidOperationException("Retail backup character name was not recovered.");
        if (!retailBefore.SequenceEqual(File.ReadAllBytes(retail)))
            throw new InvalidOperationException("Reading a backup label changed its save bytes.");
        var prior = File.ReadAllBytes(target);
        try
        {
            RestoreVerificationProbe = () => throw new InvalidDataException("Lifecycle verification failure");
            try { Restore(current, target, Path.Combine(root, "lifecycle-rollback.db")); throw new InvalidOperationException("Probe did not fail."); }
            catch (InvalidDataException ex) when (ex.Message == "Lifecycle verification failure") { }
            if (!File.ReadAllBytes(target).SequenceEqual(prior)) throw new InvalidOperationException("Immediate rollback failed.");
        }
        finally { RestoreVerificationProbe = null; }
    }
}
