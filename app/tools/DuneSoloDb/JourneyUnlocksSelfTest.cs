using Microsoft.Data.Sqlite;
using System.Text.Json;

namespace DuneSoloDb;

internal static partial class Program
{
    private static void SelfTestJourneyUnlocks(string root, string original, string adapterPath)
    {
        SelfTestSoloCompletionPlans(root, original, adapterPath);
        foreach (var quest in new[] { "DA_MQ_TheGreatConventionPt2", "DA_MQ_TheGreatConventionPt3", "DA_DLC_LostHarvest" })
        {
            var target = Path.Combine(root, quest + "-unlock.db");
            var sqlite = Path.Combine(root, quest + "-unlock.sqlite");
            File.WriteAllBytes(sqlite, Unwrap(File.ReadAllBytes(original)).SqliteBytes);
            long character;
            using (var connection = OpenWritable(sqlite))
            {
                character = ReadIdentity(connection).CharacterId;
                foreach (var node in new[] { quest, quest + ".Child", quest + "Other.Child" })
                    ExecuteNonQuery(connection, """
                        INSERT OR REPLACE INTO journey_story_node
                        (character_id,story_node_id,has_pending_reward,complete_condition_state,reveal_condition_state,
                         fail_condition_state,metadata_state,reset_group)
                        VALUES($character,$node,1,jsonb('false'),jsonb('false'),jsonb('{}'),jsonb('{}'),'Default');
                        """, ("$character", character), ("$node", node));
            }
            WrapSqlite(sqlite, target);
            var before = File.ReadAllBytes(target);
            var tags = Path.Combine(root, quest + "-tags.json");
            File.WriteAllText(tags, JsonSerializer.Serialize(new { journey_node_tags = new Dictionary<string,string[]> {
                [quest] = new[] { "Journey.ScopeTest.Completed" }
            } }));
            var backup = Path.Combine(root, quest + "-before.db");
            UnlockMainQuest(target, backup, adapterPath, tags, quest);
            if (!File.ReadAllBytes(backup).SequenceEqual(before))
                throw new InvalidOperationException("Whole journey unlock backup differs from original.");
            File.WriteAllBytes(sqlite, Unwrap(File.ReadAllBytes(target)).SqliteBytes);
            using var check = OpenWritable(sqlite);
            if (ScalarLong(check, """
                SELECT COUNT(*) FROM journey_story_node WHERE character_id=$character
                AND story_node_id IN ($quest,$child)
                AND json(complete_condition_state)='true' AND json(reveal_condition_state)='true'
                AND has_pending_reward=1;
                """, ("$character",character),("$quest",quest),("$child",quest+".Child")) != 2
                || ScalarLong(check, """
                SELECT COUNT(*) FROM journey_story_node WHERE character_id=$character AND story_node_id=$other
                AND json(complete_condition_state)='false' AND has_pending_reward=1;
                """, ("$character",character),("$other",quest+"Other.Child")) != 1)
                throw new InvalidOperationException("Whole journey unlock changed the wrong subtree or pending rewards.");
        }
    }
}
