using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static Dictionary<(long Character, string Node), long> ReadJourneyRewardState(SqliteConnection connection)
    {
        var result = new Dictionary<(long, string), long>();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT character_id,story_node_id,has_pending_reward FROM journey_story_node;";
        using var reader = command.ExecuteReader();
        while (reader.Read()) result.Add((reader.GetInt64(0), reader.GetString(1)), reader.GetInt64(2));
        return result;
    }

    private static void AssertJourneyRewardState(SqliteConnection connection,
        IReadOnlyDictionary<(long Character, string Node), long> before)
    {
        var after = ReadJourneyRewardState(connection);
        if (before.Any(row => !after.TryGetValue(row.Key, out var pending) || pending != row.Value)
            || after.Any(row => !before.ContainsKey(row.Key) && row.Value != 0))
            throw new InvalidDataException("Journey edits must preserve existing pending rewards and cannot create pending rewards.");
    }
}
