using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;

internal static partial class Program
{
    private static readonly HashSet<string> SoloMainQuestRoots = new(StringComparer.Ordinal)
    {
        "DA_MQ_ANewBeginning", "DA_MQ_FindTheFremen", "DA_MQ_AssassinsHandbook",
        "DA_MQ_TheGreatConvention", "DA_MQ_TheGreatConventionPt2", "DA_MQ_TheGreatConventionPt3", "DA_DLC_LostHarvest"
    };

    private static object UnlockMainQuest(string input, string safetyBackup,
        string adapterPath, string tagsPath, string quest)
    {
        if (quest is "act2_complete" or "scourge_complete" or "faction_atreides_complete" or "faction_harkonnen_complete")
            return CompleteSoloPlan(input, safetyBackup, adapterPath, tagsPath, quest);
        if (!SoloMainQuestRoots.Contains(quest))
            throw new ArgumentException("Choose a supported main quest.");
        // Reuse the reviewed recipe and prescience handling; pending rewards remain unchanged.
        if (quest == "DA_MQ_FindTheFremen")
            return CompleteFindTheFremen(input, safetyBackup, adapterPath);
        var adapter = ReadSoloAdapter(adapterPath);
        AssertProgressionAdapter(input, adapter);
        using var catalog = JsonDocument.Parse(File.ReadAllText(tagsPath));
        var tags = catalog.RootElement.GetProperty("journey_node_tags").EnumerateObject()
            .Where(p => p.Name == quest || p.Name.StartsWith(quest + ".", StringComparison.Ordinal))
            .SelectMany(p => p.Value.EnumerateArray().Select(v => v.GetString()!))
            .Distinct(StringComparer.Ordinal).ToArray();
        return RunProgressionMutation(input, safetyBackup, "unlock-main-quest", sqlitePath =>
        {
            using var connection = OpenWritable(sqlitePath);
            var identity = ReadIdentity(connection);
            BeginImmediate(connection);
            try
            {
                var rewardState = ReadJourneyRewardState(connection);
                var nodes = ReadStrings(connection,
                    "SELECT story_node_id FROM journey_story_node WHERE character_id=$character AND (story_node_id=$quest OR substr(story_node_id,1,length($quest)+1)=$quest||'.') ORDER BY story_node_id;",
                    ("$character", identity.CharacterId), ("$quest", quest));
                if (nodes.Length == 0)
                    throw new InvalidDataException("This main quest is not present in the selected Solo save. No data was changed.");
                ExecuteNonQuery(connection,
                    "UPDATE journey_story_node SET complete_condition_state=jsonb('true'), reveal_condition_state=jsonb('true') WHERE character_id=$character AND (story_node_id=$quest OR substr(story_node_id,1,length($quest)+1)=$quest||'.');",
                    ("$character", identity.CharacterId), ("$quest", quest));
                foreach (var tag in tags)
                    ExecuteNonQuery(connection,
                        "INSERT INTO player_tags(character_id,tag) VALUES($character,$tag) ON CONFLICT(character_id,tag) DO NOTHING;",
                        ("$character", identity.CharacterId), ("$tag", tag));
                var completed = ScalarLong(connection,
                    "SELECT COUNT(*) FROM journey_story_node WHERE character_id=$character AND (story_node_id=$quest OR substr(story_node_id,1,length($quest)+1)=$quest||'.') AND json(complete_condition_state)='true' AND json(reveal_condition_state)='true';",
                    ("$character", identity.CharacterId), ("$quest", quest));
                if (completed != nodes.Length || tags.Any(tag => ScalarLong(connection,
                    "SELECT COUNT(*) FROM player_tags WHERE character_id=$character AND tag=$tag;",
                    ("$character", identity.CharacterId), ("$tag", tag)) != 1))
                    throw new InvalidDataException("Main quest verification failed.");
                AssertJourneyRewardState(connection, rewardState);
                ValidateDatabase(connection);
                Commit(connection);
                return new { quest, nodes = completed, tags = tags.Length };
            }
            catch { Rollback(connection); throw; }
        }, requireGameClosed: true);
    }
}
