using System.Globalization;
using System.Text;
using System.Text.Json;

namespace DunePlatformStore;

internal static class Program
{
    private const int MaxRequestBytes = 5 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public static int Main(string[] args)
    {
        try
        {
            var parentLaunched = PrivilegeDrop.TryConsumeShellParentLaunch(ref args);
            if (parentLaunched && PrivilegeDrop.IsElevated())
            {
                throw new UnauthorizedAccessException("The shell-parented cache helper is still elevated.");
            }
            if (!parentLaunched)
            {
                var unelevatedExitCode = PrivilegeDrop.EnsureUnelevated(args);
                if (unelevatedExitCode.HasValue)
                {
                    return unelevatedExitCode.Value;
                }
            }
            var options = ParseArgs(args);
            var command = RequireValue(options, "command").ToLowerInvariant();
            if (command is not ("migrate" or "hydrate" or "replace-generation" or "integrity" or
                "prune" or "self-test" or "create-test-fixture" or "self-test-crash-write" or
                "self-test-crash-migration" or "self-test-delayed-replace" or
                "self-test-parent-probe" or "self-test-parent-sleep-probe"))
            {
                throw new ArgumentException($"Unknown command '{command}'.");
            }
            ValidateOptions(command, options.Keys);
            if (options.ContainsKey("timeout-ms") && options.ContainsKey("deadline-utc-ticks"))
            {
                throw new ArgumentException("Specify either --timeout-ms or --deadline-utc-ticks, not both.");
            }
            var timeoutMs = GetOperationTimeoutMilliseconds(options);
            using var deadline = new Timer(
                _ => Environment.FailFast("DunePlatformStore exceeded its bounded operation deadline."),
                null,
                timeoutMs,
                Timeout.Infinite);
            object result = command switch
            {
                "migrate" => PlatformStore.Migrate(GetDatabasePath(options)),
                "hydrate" => PlatformStore.Hydrate(GetDatabasePath(options)),
                "replace-generation" => PlatformStore.ReplaceGeneration(
                    GetDatabasePath(options),
                    ReadRequest<ReplaceGenerationRequest>()),
                "integrity" => PlatformStore.Integrity(GetDatabasePath(options)),
                "prune" => PlatformStore.Prune(
                    GetDatabasePath(options),
                    GetInt(options, "history-days", 90, 1, 365),
                    GetInt(options, "history-rows", 100_000, 1_000, 250_000),
                    GetInt(options, "snapshot-generations", 20, 1, 100),
                    GetLong(options, "max-bytes", 250L * 1024 * 1024, 16L * 1024 * 1024, 1024L * 1024 * 1024)),
                "self-test" => PlatformStore.SelfTest(),
                "create-test-fixture" => RunSelfTestOnly(() => PlatformStore.CreateTestFixture(
                    GetDatabasePath(options),
                    GetInt(options, "history-rows", 100_000, 0, 100_000),
                    GetInt(options, "poi-rows", 2_000, 0, 2_000))),
                "self-test-crash-write" => RunSelfTestOnly(
                    () => PlatformStore.CrashWrite(GetDatabasePath(options))),
                "self-test-crash-migration" => RunSelfTestOnly(
                    () => PlatformStore.CrashMigration(GetDatabasePath(options))),
                "self-test-delayed-replace" => RunSelfTestOnly(() =>
                {
                    Thread.Sleep(GetInt(options, "delay-ms", 1_000, 1, 120_000));
                    return PlatformStore.ReplaceGeneration(
                        GetDatabasePath(options),
                        ReadRequest<ReplaceGenerationRequest>());
                }),
                "self-test-parent-probe" => RunSelfTestOnly(() => new
                {
                    ok = true,
                    elevated = PrivilegeDrop.IsElevated(),
                    userSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value,
                    nonce = ReadRequest<Dictionary<string, string>>()["nonce"]
                }),
                "self-test-parent-sleep-probe" => RunSelfTestOnly(() =>
                {
                    File.WriteAllText(
                        RequireValue(options, "probe-file"),
                        Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
                    Thread.Sleep(30_000);
                    return new { ok = true };
                }),
                _ => throw new ArgumentException($"Unknown command '{command}'.")
            };
            WriteJson(result, Console.Out);
            return 0;
        }
        catch (Exception ex)
        {
            WriteJson(new
            {
                ok = false,
                errorCode = ErrorCode(ex),
                error = ex.Message,
                type = ex.GetType().Name
            }, Console.Error);
            return 1;
        }
    }

    internal static JsonSerializerOptions SerializerOptions => JsonOptions;

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            var key = args[i];
            if (!key.StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length)
            {
                throw new ArgumentException($"Expected --name value, found '{key}'.");
            }
            key = key[2..];
            if (!result.TryAdd(key, args[++i]))
            {
                throw new ArgumentException($"Duplicate option '--{key}'.");
            }
        }
        return result;
    }

    private static void ValidateOptions(string command, IEnumerable<string> supplied)
    {
        var common = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "command",
            "timeout-ms",
            "deadline-utc-ticks"
        };
        var allowed = command switch
        {
            "migrate" or "hydrate" or "replace-generation" or "integrity" =>
                common.Concat(["database"]),
            "prune" => common.Concat(["database", "history-days", "history-rows", "snapshot-generations", "max-bytes"]),
            "self-test" or "self-test-parent-probe" => common,
            "self-test-parent-sleep-probe" => common.Concat(["probe-file"]),
            "create-test-fixture" => common.Concat(["database", "history-rows", "poi-rows"]),
            "self-test-crash-write" or "self-test-crash-migration" => common.Concat(["database"]),
            "self-test-delayed-replace" => common.Concat(["database", "delay-ms"]),
            _ => common
        };
        var allowedSet = new HashSet<string>(allowed, StringComparer.OrdinalIgnoreCase);
        var unexpected = supplied.FirstOrDefault(key => !allowedSet.Contains(key));
        if (unexpected is not null)
        {
            throw new ArgumentException($"Option '--{unexpected}' is not valid for command '{command}'.");
        }
    }

    private static string GetDatabasePath(IReadOnlyDictionary<string, string> options)
    {
        if (options.TryGetValue("database", out var path) && !string.IsNullOrWhiteSpace(path))
        {
            if (!string.Equals(
                    Environment.GetEnvironmentVariable("DST_PLATFORM_SELF_TEST"),
                    "1",
                    StringComparison.Ordinal))
            {
                throw new ArgumentException("--database is available only to the helper self-test.");
            }
            return Path.GetFullPath(path);
        }
        return StorageSecurity.GetDefaultDatabasePath();
    }

    private static T ReadRequest<T>()
    {
        using var input = Console.OpenStandardInput();
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        while (true)
        {
            var read = input.Read(chunk, 0, chunk.Length);
            if (read == 0)
            {
                break;
            }
            buffer.Write(chunk, 0, read);
            if (buffer.Length > MaxRequestBytes)
            {
                throw new InvalidDataException("Request exceeds the 5 MiB input limit.");
            }
        }
        if (buffer.Length == 0)
        {
            throw new InvalidDataException("A JSON request is required on standard input.");
        }
        buffer.Position = 0;
        return JsonSerializer.Deserialize<T>(buffer, JsonOptions)
            ?? throw new InvalidDataException("The JSON request is empty.");
    }

    private static string RequireValue(IReadOnlyDictionary<string, string> options, string key) =>
        options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing --{key}.");

    private static int GetInt(
        IReadOnlyDictionary<string, string> options,
        string key,
        int fallback,
        int minimum,
        int maximum)
    {
        if (!options.TryGetValue(key, out var text))
        {
            return fallback;
        }
        if (!int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ||
            value < minimum || value > maximum)
        {
            throw new ArgumentOutOfRangeException(key, $"--{key} must be between {minimum} and {maximum}.");
        }
        return value;
    }

    private static long GetLong(
        IReadOnlyDictionary<string, string> options,
        string key,
        long fallback,
        long minimum,
        long maximum)
    {
        if (!options.TryGetValue(key, out var text))
        {
            return fallback;
        }
        if (!long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ||
            value < minimum || value > maximum)
        {
            throw new ArgumentOutOfRangeException(key, $"--{key} must be between {minimum} and {maximum}.");
        }
        return value;
    }

    private static int GetOperationTimeoutMilliseconds(IReadOnlyDictionary<string, string> options)
    {
        if (!options.ContainsKey("deadline-utc-ticks"))
        {
            return GetInt(options, "timeout-ms", 30_000, 100, 120_000);
        }
        var deadlineTicks = GetLong(
            options,
            "deadline-utc-ticks",
            0,
            1,
            DateTime.MaxValue.Ticks);
        var remainingTicks = deadlineTicks - DateTime.UtcNow.Ticks;
        if (remainingTicks <= 0)
        {
            throw new TimeoutException("DunePlatformStore received an expired operation deadline.");
        }
        return (int)Math.Clamp(
            TimeSpan.FromTicks(remainingTicks).TotalMilliseconds,
            1,
            120_000);
    }

    private static string ErrorCode(Exception ex) => ex switch
    {
        UnsupportedSchemaException => "unsupported-schema",
        Microsoft.Data.Sqlite.SqliteException => "cache-corrupt-or-unreadable",
        InvalidDataException => "invalid-request",
        ArgumentException => "invalid-argument",
        UnauthorizedAccessException => "cache-access-denied",
        _ => "cache-operation-failed"
    };

    private static void WriteJson(object value, TextWriter writer) =>
        writer.WriteLine(JsonSerializer.Serialize(value, JsonOptions));

    private static object RunSelfTestOnly(Func<object> operation)
    {
        if (!string.Equals(
                Environment.GetEnvironmentVariable("DST_PLATFORM_SELF_TEST"),
                "1",
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The test operation is available only to the helper self-test.");
        }
        return operation();
    }
}

internal sealed class UnsupportedSchemaException(int found, int supported)
    : InvalidOperationException($"Cache schema {found} is newer than supported schema {supported}.")
{
}
