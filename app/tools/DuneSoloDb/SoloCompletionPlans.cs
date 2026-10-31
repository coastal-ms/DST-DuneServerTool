using System.Text.Json;
using System.Text.Json.Nodes;
namespace DuneSoloDb;
internal static partial class Program
{
    private static object CompleteSoloPlan(string input, string backup, string adapterPath, string tagsPath, string plan)
    {
        var roots = plan == "act2_complete" ? new[] { "DA_MQ_AssassinsHandbook", "DA_MQ_TheGreatConvention" } : Array.Empty<string>();
        var contracts = plan == "scourge_complete" ? new[] {
            "DA_CT_Halloween_Week1_01", "DA_CT_Halloween_Week1_02", "DA_CT_Halloween_Week1_03",
            "DA_CT_Halloween_Week2_01", "DA_CT_Halloween_Week2_01_Funnel", "DA_CT_Halloween_Week2_02",
            "DA_CT_Halloween_Week3_01", "DA_CT_Halloween_Week3_01_Funnel", "DA_CT_Halloween_Week3_02" } : Array.Empty<string>();
        AssertProgressionAdapter(input, ReadSoloAdapter(adapterPath));
        using var document = JsonDocument.Parse(File.ReadAllText(tagsPath));
        var catalog = document.RootElement;
        if (plan is "faction_atreides_complete" or "faction_harkonnen_complete")
            roots = catalog.GetProperty("completion_plans").GetProperty(plan).EnumerateArray().Select(v => v.GetString()!).ToArray();
        string[] Values(string group, string key) => catalog.TryGetProperty(group, out var section) && section.TryGetProperty(key, out var values)
            ? values.EnumerateArray().Select(v => v.GetString() ?? throw new InvalidDataException("Invalid completion catalog.")).ToArray() : [];
        if (contracts.Any(c => Values("contract_tags", c).Length == 0)) throw new InvalidDataException("Event completion catalog is incomplete.");
        var tags = catalog.GetProperty("journey_node_tags").EnumerateObject()
            .Where(p => roots.Any(root => p.Name == root || p.Name.StartsWith(root + ".", StringComparison.Ordinal)))
            .SelectMany(p => p.Value.EnumerateArray().Select(v => v.GetString()!))
            .Concat(contracts.SelectMany(c => Values("contract_tags", c))).Distinct(StringComparer.Ordinal).ToArray();
        var remove = contracts.SelectMany(c => Values("contract_remove_tags", c)).Except(tags).Distinct(StringComparer.Ordinal).ToArray();
        return RunProgressionMutation(input, backup, "complete-story", sqlitePath => {
            using var db = OpenWritable(sqlitePath); var identity = ReadIdentity(db); BeginImmediate(db);
            try {
                var rewards = ReadJourneyRewardState(db); long completed = 0;
                foreach (var root in roots) {
                    var count = ScalarLong(db, "SELECT COUNT(*) FROM journey_story_node WHERE character_id=$character AND (story_node_id=$root OR substr(story_node_id,1,length($root)+1)=$root||'.');", ("$character", identity.CharacterId), ("$root", root));
                    if (count == 0 && plan.StartsWith("faction_", StringComparison.Ordinal)) continue;
                    if (count == 0) throw new InvalidDataException("A selected story is not present in this save. No changes were saved.");
                    ExecuteNonQuery(db, "UPDATE journey_story_node SET complete_condition_state=jsonb('true'),reveal_condition_state=jsonb('true') WHERE character_id=$character AND (story_node_id=$root OR substr(story_node_id,1,length($root)+1)=$root||'.');", ("$character", identity.CharacterId), ("$root", root));
                    var verified = ScalarLong(db, "SELECT COUNT(*) FROM journey_story_node WHERE character_id=$character AND (story_node_id=$root OR substr(story_node_id,1,length($root)+1)=$root||'.') AND json(complete_condition_state)='true' AND json(reveal_condition_state)='true';", ("$character", identity.CharacterId), ("$root", root));
                    if (verified != count) throw new InvalidDataException("Story completion verification failed."); completed += count;
                }
                if (roots.Length > 0 && completed == 0) throw new InvalidDataException("No selected journeys are present in this save. No changes were saved.");
                foreach (var tag in remove) ExecuteNonQuery(db, "DELETE FROM player_tags WHERE character_id=$character AND tag=$tag;", ("$character", identity.CharacterId), ("$tag", tag));
                foreach (var tag in tags) ExecuteNonQuery(db, "INSERT INTO player_tags(character_id,tag) VALUES($character,$tag) ON CONFLICT(character_id,tag) DO NOTHING;", ("$character", identity.CharacterId), ("$tag", tag));
                foreach (var contract in contracts) ExecuteNonQuery(db, "DELETE FROM items WHERE template_id='ContractItem' AND inventory_id IN (SELECT id FROM inventories WHERE actor_id=$pawn AND inventory_type=29) AND json_extract(stats,'$.FContractItemStats[1].ContractName.Name')=$name;", ("$pawn", identity.PawnId), ("$name", contract[6..]));
                if (contracts.Length > 0) {
                    var properties = ReadActorProperties(db, identity.PawnId);
                    if (properties["ContractsCoordinatorComponent"] is JsonObject coordinator && coordinator["m_TrackedContractItemUid"] is JsonValue tracked && tracked.TryGetValue<string>(out var uid) && uid != "!!itm#0") {
                        if (!uid.StartsWith("!!itm#", StringComparison.Ordinal) || !long.TryParse(uid[6..], out var item)) throw new InvalidDataException("Unsupported tracked contract identity.");
                        if (ScalarLong(db, "SELECT COUNT(*) FROM items WHERE id=$id;", ("$id", item)) == 0) { coordinator["m_TrackedContractItemUid"] = "!!itm#0"; WriteActorProperties(db, identity.PawnId, properties); }
                    }
                }
                if (tags.Any(t => ScalarLong(db, "SELECT COUNT(*) FROM player_tags WHERE character_id=$character AND tag=$tag;", ("$character", identity.CharacterId), ("$tag", t)) != 1) || remove.Any(t => ScalarLong(db, "SELECT COUNT(*) FROM player_tags WHERE character_id=$character AND tag=$tag;", ("$character", identity.CharacterId), ("$tag", t)) != 0)) throw new InvalidDataException("Completion tag verification failed.");
                AssertJourneyRewardState(db, rewards); ValidateDatabase(db); Commit(db);
                return new { plan, nodes = completed, contracts = contracts.Length, tags = tags.Length };
            } catch { Rollback(db); throw; }
        }, requireGameClosed: true);
    }
}
