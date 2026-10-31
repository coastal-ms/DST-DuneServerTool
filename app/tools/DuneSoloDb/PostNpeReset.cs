using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;
internal static partial class Program
{
    private static bool IsPostNpeStoryTag(string tag)
    {
        // Do not let faction-name wildcards remove Harko discoveries or bonuses.
        if (new[] { "Character.", "Skills.", "Exploration.", "DialogueFlags.Caste.", "DialogueFlags.Mentor." }
            .Any(p => tag.StartsWith(p, StringComparison.OrdinalIgnoreCase))) return false;
        return new[] { "Journey.", "JourneySets.", "Contract.", "BigMoments.", "NPE.",
            "DialogueFlags.Contracts.", "DialogueFlags.Faction.", "DialogueFlags.Factions.",
            "DialogueFlags.AoK.", "Faction.", "FactionStoryline" }
            .Any(p => tag.StartsWith(p, StringComparison.OrdinalIgnoreCase))
            || new[] { "Atreides", "Harkonnen", "Atre", "Hark" }.Any(p => tag.Contains(p, StringComparison.Ordinal))
            || new[] { "DialogueFlags.IntroductionDone.ThufirHawat", "DialogueFlags.IntroductionDone.PiterDeVries", "DialogueFlags.IntroductionDone.MaasKharet" }.Contains(tag, StringComparer.Ordinal);
    }

    private static object ResetPostNpe(string input, string backup, string adapterPath, string resetCatalogPath, bool requireGameClosed = true)
    {
        var adapter = ReadSoloAdapter(adapterPath);
        AssertProgressionAdapter(input, adapter);
        if (adapter.NpeNodes.Count == 0 || adapter.FremenRecipes.Count == 0)
            throw new InvalidDataException("Post-NPE reset requires a complete tutorial and Fremen reward catalog.");
        using var resetCatalog = JsonDocument.Parse(File.ReadAllText(resetCatalogPath));
        var resetRecipes = resetCatalog.RootElement.GetProperty("resetResearchItemKeys").EnumerateArray().Select(v => v.GetString() ?? throw new InvalidDataException("Invalid replay research catalog.")).Distinct(StringComparer.Ordinal).ToArray();
        var destination = resetCatalog.RootElement.GetProperty("returnLocation");
        var map = destination.GetProperty("map").GetString();
        var dimension = destination.GetProperty("dimensionIndex").GetInt32();
        var x = destination.GetProperty("x").GetDouble();
        var y = destination.GetProperty("y").GetDouble();
        var z = destination.GetProperty("z").GetDouble();
        if (map != "HaggaBasin" || dimension != 0 || new[] {x,y,z}.Any(v => !double.IsFinite(v) || Math.Abs(v)>10000000) || resetRecipes.Length==0 || resetRecipes.Any(string.IsNullOrWhiteSpace))
            throw new InvalidDataException("Unsupported post-NPE return destination or research catalog.");
        return RunProgressionMutation(input, backup, "reset-post-npe", path => {
            using var db = OpenWritable(path);
            var player = ReadIdentity(db);
            foreach (var table in new[] { "player_faction", "player_faction_reputation", "factions", "journey_story_node", "player_tags", "items", "inventories" })
                if (!TableExists(db, table)) throw new InvalidDataException($"Post-NPE reset requires the supported {table} schema.");
            if (ScalarString(db, "SELECT name FROM factions WHERE id=1;") != "Atreides"
                || ScalarString(db, "SELECT name FROM factions WHERE id=2;") != "Harkonnen")
                throw new InvalidDataException("Unsupported faction identity mapping.");
            var observedNpe = ReadStrings(db, "SELECT story_node_id FROM journey_story_node WHERE character_id=$c AND (story_node_id='DA_MQ_ANewBeginning' OR story_node_id LIKE 'DA_MQ_ANewBeginning.%' OR story_node_id='DA_MQ_NPEAutocompleted' OR story_node_id LIKE 'DA_MQ_NPEAutocompleted.%');", ("$c", player.CharacterId));
            if (observedNpe.Except(adapter.NpeNodes, StringComparer.Ordinal).Any())
                throw new InvalidDataException("Unknown tutorial nodes; the Solo save was not changed.");
            var components = ReadFglComponents(db, player.EntityId);
            var levelBefore = RequireComponentObject(components, "FLevelComponent").DeepClone();
            var spice = RequireComponentObject(components, "FSpiceAddictionComponent");
            var pawn = ReadActorProperties(db, player.PawnId);
            var controller = ReadActorProperties(db, player.ControllerId);
            var pawnPointsBefore = pawn["TechKnowledgePlayerComponent"]?["m_TechKnowledgePoints"]?.DeepClone();
            var controllerPointsBefore = controller["TechKnowledgePlayerComponent"]?["m_TechKnowledgePoints"]?.DeepClone();
            var protectedTags = ReadStrings(db, "SELECT tag FROM player_tags WHERE character_id=$c ORDER BY tag;", ("$c", player.CharacterId)).Where(t => !IsPostNpeStoryTag(t)).ToArray();
            BeginImmediate(db);
            try {
                // Retain row scaffolds so Solo can re-offer quests and Codex entries.
                ExecuteNonQuery(db, "UPDATE journey_story_node SET complete_condition_state=jsonb('false'),reveal_condition_state=jsonb('false'),has_pending_reward=0,metadata_state=jsonb('{}'),fail_condition_state=jsonb('{}') WHERE character_id=$c AND story_node_id NOT GLOB 'DA_ACH_*';", ("$c", player.CharacterId));
                foreach (var tag in ReadStrings(db, "SELECT tag FROM player_tags WHERE character_id=$c;", ("$c", player.CharacterId)).Where(IsPostNpeStoryTag))
                    ExecuteNonQuery(db, "DELETE FROM player_tags WHERE character_id=$c AND tag=$tag;", ("$c", player.CharacterId), ("$tag", tag));
                foreach (var node in adapter.NpeNodes)
                    ExecuteNonQuery(db, "INSERT INTO journey_story_node(character_id,story_node_id,complete_condition_state,reveal_condition_state,has_pending_reward,metadata_state,reset_group,fail_condition_state) VALUES($c,$n,jsonb('true'),jsonb('true'),0,jsonb('{}'),0,jsonb('{}')) ON CONFLICT(character_id,story_node_id) DO UPDATE SET complete_condition_state=jsonb('true'),reveal_condition_state=jsonb('true'),has_pending_reward=0;", ("$c", player.CharacterId), ("$n", node));
                ExecuteNonQuery(db, "INSERT INTO player_tags(character_id,tag) VALUES($c,$tag);", ("$c", player.CharacterId), ("$tag", adapter.NpeTag));
                if (TableExists(db, "mnemonic_recall")) ExecuteNonQuery(db, "DELETE FROM mnemonic_recall WHERE character_id=$c;", ("$c", player.CharacterId));
                ExecuteNonQuery(db, "DELETE FROM items WHERE template_id='ContractItem' AND inventory_id IN (SELECT id FROM inventories WHERE actor_id=$p AND inventory_type=29);", ("$p", player.PawnId));
                if (pawn["ContractsCoordinatorComponent"] is JsonObject coordinator) coordinator["m_TrackedContractItemUid"] = "!!itm#0";
                var recipesNode = pawn["TechKnowledgePlayerComponent"]?["m_TechKnowledge"]?["m_TechKnowledgeData"];
                if (recipesNode is not null and not JsonArray) throw new InvalidDataException("Unsupported recipe knowledge shape.");
                if (recipesNode is JsonArray recipes)
                    for (var i = recipes.Count - 1; i >= 0; i--)
                        if (resetRecipes.Contains(recipes[i]?["ItemKey"]?.GetValue<string>() ?? "", StringComparer.Ordinal)) recipes.RemoveAt(i);
                spice["SystemStatus"] = "AddictionDisabled";
                spice["SpiceVisionEnabledStatus"] = "Disabled";
                foreach (var faction in new[] { 1, 2 })
                    ExecuteNonQuery(db, "INSERT INTO player_faction_reputation(actor_id,faction_id,reputation_amount) VALUES($p,$f,0) ON CONFLICT(actor_id,faction_id) DO UPDATE SET reputation_amount=0;", ("$p", player.ControllerId), ("$f", faction));
                ExecuteNonQuery(db, "DELETE FROM player_faction WHERE actor_id=$p;", ("$p", player.ControllerId));
                if (controller["FactionPlayerComponent"] is JsonObject factionComponent) {
                    if (factionComponent["m_FactionDataArray"] is not null and not JsonArray) throw new InvalidDataException("Unsupported faction reputation component shape.");
                    if (factionComponent["m_FactionDataArray"] is JsonArray entries)
                        foreach (var entry in entries) {
                            if (entry is not JsonObject || entry["Faction"] is not JsonObject) throw new InvalidDataException("Unsupported faction reputation entry.");
                            if (entry["Faction"]?["Name"]?.GetValue<string>() is "Atreides" or "Harkonnen") entry["ReputationAmount"] = 0;
                        }
                } else if (controller["FactionPlayerComponent"] is not null) throw new InvalidDataException("Unsupported faction component.");
                WriteActorProperties(db, player.PawnId, pawn);
                WriteActorProperties(db, player.ControllerId, controller);
                WriteFglComponents(db, player.EntityId, components);
                var verifyComponents = ReadFglComponents(db, player.EntityId);
                var verifyPawn = ReadActorProperties(db, player.PawnId);
                var verifyController = ReadActorProperties(db, player.ControllerId);
                var complete = ReadStrings(db, "SELECT story_node_id FROM journey_story_node WHERE character_id=$c AND json(complete_condition_state)='true' AND story_node_id NOT GLOB 'DA_ACH_*' ORDER BY story_node_id;", ("$c", player.CharacterId));
                var remainingTags = ReadStrings(db, "SELECT tag FROM player_tags WHERE character_id=$c ORDER BY tag;", ("$c", player.CharacterId));
                if (!complete.SequenceEqual(adapter.NpeNodes.OrderBy(n => n, StringComparer.Ordinal), StringComparer.Ordinal)
                    || !remainingTags.Where(t => t != adapter.NpeTag).SequenceEqual(protectedTags, StringComparer.Ordinal)
                    || !remainingTags.Contains(adapter.NpeTag, StringComparer.Ordinal)
                    || !JsonNode.DeepEquals(levelBefore, RequireComponentObject(verifyComponents, "FLevelComponent"))
                    || !JsonNode.DeepEquals(pawnPointsBefore, verifyPawn["TechKnowledgePlayerComponent"]?["m_TechKnowledgePoints"])
                    || !JsonNode.DeepEquals(controllerPointsBefore, verifyController["TechKnowledgePlayerComponent"]?["m_TechKnowledgePoints"])
                    || !JsonNode.DeepEquals(pawn, verifyPawn) || !JsonNode.DeepEquals(controller, verifyController)
                    || CountPurchasedRecipes(verifyPawn, resetRecipes) != 0
                    || ScalarLong(db, "SELECT COUNT(*) FROM player_faction WHERE actor_id=$p;", ("$p", player.ControllerId)) != 0
                    || ScalarLong(db, "SELECT COUNT(*) FROM player_faction_reputation WHERE actor_id=$p AND faction_id IN (1,2) AND reputation_amount<>0;", ("$p", player.ControllerId)) != 0)
                    throw new InvalidDataException("Post-NPE reset verification failed; original save remains unchanged.");
                ExecuteNonQuery(db, "UPDATE actors SET map=$map,dimension_index=0,location_x=$x,location_y=$y,location_z=$z WHERE id=$p;", ("$map",map),("$x",x),("$y",y),("$z",z),("$p",player.PawnId));
                if (ScalarLong(db,"SELECT COUNT(*) FROM actors WHERE id=$p AND map=$map AND dimension_index=0 AND location_x=$x AND location_y=$y AND location_z=$z;",("$p",player.PawnId),("$map",map),("$x",x),("$y",y),("$z",z))!=1)
                    throw new InvalidDataException("Griffin's Reach return-location verification failed.");
                ValidateDatabase(db);
                Commit(db);
                return new { npeNodes = adapter.NpeNodes.Count, skillsPreserved = true, pointBalancesPreserved = true, factionReset = true, codexReset = true, fremenRewardsReset = true, returnedTo = "Griffin's Reach" };
            } catch { Rollback(db); throw; }
        }, requireGameClosed: requireGameClosed);
    }
}
