using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;

namespace DunePlatformStore;

internal static class Schema
{
    internal const int Version = 1;
    internal const string Checksum = "maps-v1-20260828";
    private const int SqliteOk = 0;
    private const int SqliteFcntlPersistWal = 10;
    private static readonly byte[] MainDatabaseName = "main\0"u8.ToArray();

    internal static ProtectedSqliteConnection Open(string databasePath, bool readOnly)
    {
        var lease = StorageSecurity.AcquireDatabase(databasePath, readOnly);
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
            DefaultTimeout = 5
        };
        var connection = new SqliteConnection(builder.ToString());
        try
        {
            connection.Open();
            EnablePersistentWal(connection);
            using var command = connection.CreateCommand();
            command.CommandText = readOnly
                ? "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;"
                : "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;";
            command.ExecuteNonQuery();
            lease.RevalidateAll();
            return new ProtectedSqliteConnection(connection, lease);
        }

        catch
        {
            connection.Dispose();
            lease.Dispose();
            throw;
        }
    }

    internal sealed class ProtectedSqliteConnection(
        SqliteConnection connection,
        StorageSecurity.StorageLease storageLease) : IDisposable
    {
        internal SqliteConnection Connection { get; } = connection;

        public void Dispose()
        {
            try
            {
                if (Connection.State == System.Data.ConnectionState.Open)
                {
                    using var command = Connection.CreateCommand();
                    command.CommandText = "PRAGMA busy_timeout=0;";
                    command.ExecuteNonQuery();
                }

                Connection.Dispose();
            }
            finally
            {
                storageLease.Dispose();
            }
        }
    }

    private static void EnablePersistentWal(SqliteConnection connection)
    {
        var persist = 1;
        var handle = connection.Handle
            ?? throw new InvalidOperationException("The SQLite native handle is unavailable.");
        var result = sqlite3_file_control(
            handle.DangerousGetHandle(),
            MainDatabaseName,
            SqliteFcntlPersistWal,
            ref persist);
        if (result != SqliteOk)
        {
            throw new InvalidOperationException(
                $"SQLite could not enable persistent WAL mode (result {result}).");
        }
    }

    [DllImport("e_sqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_file_control(
        IntPtr database,
        byte[] databaseName,
        int operation,
        ref int value);

    internal static int ReadVersion(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA user_version;";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    internal static void EnsureSupported(SqliteConnection connection)
    {
        var current = ReadVersion(connection);
        if (current > Version)
        {
            throw new UnsupportedSchemaException(current, Version);
        }
        if (current != Version)
        {
            throw new InvalidOperationException(
                $"Cache schema {current} is not initialized; run the migrate command.");
        }
    }

    internal static string QuickCheck(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA quick_check;";
        return Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
    }

    internal static void CreateV1(SqliteConnection connection, string appVersion)
    {
        Execute(connection, null, "PRAGMA auto_vacuum=INCREMENTAL;");
        using var transaction = connection.BeginTransaction();
        Execute(connection, transaction,
            """
            CREATE TABLE cache_metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL
            ) STRICT;
            CREATE TABLE schema_migrations (
              version INTEGER PRIMARY KEY,
              checksum TEXT NOT NULL,
              app_version TEXT NOT NULL,
              applied_at_utc TEXT NOT NULL
            ) STRICT;
            CREATE TABLE source_state (
              source_key TEXT PRIMARY KEY,
              schema_fingerprint TEXT NOT NULL,
              last_attempt_utc TEXT,
              last_success_utc TEXT,
              expires_at_utc TEXT,
              last_error_code TEXT
            ) STRICT;
            CREATE TABLE map_catalog (
              generation TEXT NOT NULL,
              farm_id TEXT NOT NULL,
              map_id TEXT NOT NULL,
              partition_id TEXT NOT NULL,
              label TEXT NOT NULL,
              kind TEXT NOT NULL,
              last_seen_at_utc TEXT NOT NULL,
              active INTEGER NOT NULL CHECK (active IN (0, 1)),
              PRIMARY KEY (farm_id, map_id, partition_id)
            ) STRICT;
            CREATE TABLE layer_snapshots (
              snapshot_id INTEGER PRIMARY KEY,
              generation TEXT NOT NULL,
              farm_id TEXT NOT NULL,
              map_id TEXT NOT NULL,
              partition_id TEXT NOT NULL,
              layer_id TEXT NOT NULL,
              source_key TEXT NOT NULL,
              observed_at_utc TEXT,
              cached_at_utc TEXT NOT NULL,
              expires_at_utc TEXT,
              freshness_state TEXT NOT NULL
                CHECK (freshness_state IN ('fresh','refreshing','stale','unavailable','partial')),
              last_error_code TEXT,
              row_count INTEGER NOT NULL CHECK (row_count >= 0),
              truncated INTEGER NOT NULL CHECK (truncated IN (0, 1)),
              payload_sha256 TEXT NOT NULL,
              UNIQUE (generation, farm_id, map_id, partition_id, layer_id)
            ) STRICT;
            CREATE INDEX layer_snapshots_active
              ON layer_snapshots (generation, farm_id, map_id, partition_id, layer_id);
            CREATE TABLE active_spice_current (
              generation TEXT NOT NULL,
              farm_id TEXT NOT NULL,
              map_id TEXT NOT NULL,
              partition_id TEXT NOT NULL,
              field_id TEXT NOT NULL,
              state TEXT NOT NULL,
              coordinate_space TEXT NOT NULL
                CHECK (coordinate_space IN ('none','sector-v1','normalized-v1')),
              projected_x REAL,
              projected_y REAL,
              source_fingerprint TEXT NOT NULL,
              observed_at_utc TEXT NOT NULL,
              expires_at_utc TEXT NOT NULL,
              PRIMARY KEY (farm_id, map_id, partition_id, field_id)
            ) STRICT;
            CREATE TABLE active_spice_history (
              observation_id INTEGER PRIMARY KEY,
              generation TEXT NOT NULL,
              farm_id TEXT NOT NULL,
              map_id TEXT NOT NULL,
              partition_id TEXT NOT NULL,
              field_id TEXT NOT NULL,
              state TEXT NOT NULL,
              coordinate_space TEXT NOT NULL
                CHECK (coordinate_space IN ('none','sector-v1','normalized-v1')),
              projected_x REAL,
              projected_y REAL,
              source_fingerprint TEXT NOT NULL,
              observed_at_utc TEXT NOT NULL
            ) STRICT;
            CREATE INDEX active_spice_history_lookup
              ON active_spice_history (
                farm_id, map_id, partition_id, observed_at_utc DESC, observation_id DESC
              );
            CREATE TABLE public_poi_layer (
              generation TEXT NOT NULL,
              farm_id TEXT NOT NULL,
              map_id TEXT NOT NULL,
              partition_id TEXT NOT NULL,
              poi_id TEXT NOT NULL,
              category TEXT NOT NULL
                CHECK (category IN ('testing-station','tradepost','global-resource')),
              label TEXT NOT NULL,
              coordinate_space TEXT NOT NULL
                CHECK (coordinate_space IN ('sector-v1','normalized-v1')),
              projected_x REAL NOT NULL,
              projected_y REAL NOT NULL,
              source_fingerprint TEXT NOT NULL,
              observed_at_utc TEXT NOT NULL,
              expires_at_utc TEXT NOT NULL,
              PRIMARY KEY (farm_id, map_id, partition_id, poi_id)
            ) STRICT;
            PRAGMA user_version=1;
            """);
        var now = DateTimeOffset.UtcNow.ToUniversalTime().ToString("O");
        Execute(connection, transaction,
            """
            INSERT INTO schema_migrations(version, checksum, app_version, applied_at_utc)
            VALUES (1, $checksum, $appVersion, $now);
            INSERT INTO cache_metadata(key, value, updated_at_utc)
            VALUES
              ('derived_only', 'true', $now),
              ('schema_name', 'maps-v1', $now),
              ('active_generation', '', $now);
            """,
            ("$checksum", Checksum),
            ("$appVersion", appVersion),
            ("$now", now));
        transaction.Commit();
    }

    internal static void Execute(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string sql,
        params (string Name, object? Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        foreach (var parameter in parameters)
        {
            command.Parameters.AddWithValue(parameter.Name, parameter.Value ?? DBNull.Value);
        }
        command.ExecuteNonQuery();
    }
}
