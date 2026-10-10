using System.Text.Json;
using System.Text.Json.Nodes;
namespace DuneSoloDb;
internal static partial class Program
{
    private static object SetFactionProgression(string input, string backup, string adapterPath,
        string catalogPath, string faction, string action, long amount)
    {
        var name = faction.ToLowerInvariant() switch { "atreides" => "Atreides", "harkonnen" => "Harkonnen", _ => throw new ArgumentException("Choose Atreides or Harkonnen.") };
        if (action is not ("ch3_start" or "rank19_eligible" or "add-reputation" or "set-reputation")) throw new ArgumentException("Choose a valid faction action.");
        if (amount < 0 || amount > 12474) throw new ArgumentException("Reputation must be between 0 and 12474.");
        var unlock = action is "ch3_start" or "rank19_eligible";
        AssertProgressionSchema(input, ReadSoloAdapter(adapterPath));
        using var catalog = JsonDocument.Parse(File.ReadAllText(catalogPath));
        var nodes = new List<string>();
        if (unlock) {
            foreach (var key in new[] { "climb_the_ranks_nodes", "climb_the_ranks_story_nodes", "climb_the_ranks_story_nodes_" + name.ToLowerInvariant() })
                nodes.AddRange(catalog.RootElement.GetProperty(key).EnumerateArray().Select(v => v.GetString()!));
            if (action == "rank19_eligible") nodes.AddRange(catalog.RootElement.GetProperty("landsraad_mission_nodes_" + name.ToLowerInvariant()).EnumerateArray().Select(v => v.GetString()!));
            nodes = nodes.Distinct(StringComparer.Ordinal).ToList();
            if (nodes.Count == 0 || nodes.Any(string.IsNullOrWhiteSpace)) throw new InvalidDataException("Faction journey catalog is invalid.");
        }
        return RunProgressionMutation(input, backup, "faction-progression", path => {
            using var db = OpenWritable(path);
            var player = ReadIdentity(db);
            var id = name == "Atreides" ? 1 : 2;
            if (ScalarString(db, "SELECT name FROM factions WHERE id=$id;", ("$id", id)) != name) throw new InvalidDataException("Unsupported Solo faction mapping.");
            BeginImmediate(db);
            try {
                var current = ScalarLong(db, "SELECT COALESCE((SELECT reputation_amount FROM player_faction_reputation WHERE actor_id=$p AND faction_id=$f),0);", ("$p", player.ControllerId), ("$f", id));
                if (current < 0 || current > 12474) throw new InvalidDataException("Existing reputation is outside the supported range.");
                var rep = action switch { "ch3_start" => Math.Max(current,2000), "rank19_eligible" => Math.Max(current,11975), "add-reputation" => Math.Min(12474,current+amount), _ => amount };
                ExecuteNonQuery(db, "INSERT INTO player_faction_reputation(actor_id,faction_id,reputation_amount) VALUES($p,$f,$r) ON CONFLICT(actor_id,faction_id) DO UPDATE SET reputation_amount=excluded.reputation_amount;", ("$p", player.ControllerId), ("$f", id), ("$r", rep));
                var properties = ReadActorProperties(db, player.ControllerId);
                if (properties["FactionPlayerComponent"] is not null and not JsonObject)
                    throw new InvalidDataException("Unsupported faction component shape.");
                var component = EnsureObject(properties,"FactionPlayerComponent");
                if (component["m_FactionDataArray"] is not null and not JsonArray) throw new InvalidDataException("Unsupported faction component shape.");
                var entries = component["m_FactionDataArray"] as JsonArray ?? new JsonArray();
                if (entries.Any(e => e is not JsonObject || e["Faction"] is not JsonObject || e["Faction"]?["Name"] is not JsonValue))
                    throw new InvalidDataException("Unsupported faction entry shape.");
                component["m_FactionDataArray"] = entries;
                var matches = entries.OfType<JsonObject>().Where(e => e["Faction"]?["Name"]?.GetValue<string>() == name).ToArray();
                if (matches.Length > 1) throw new InvalidDataException("Duplicate faction entries.");
                var entry = matches.FirstOrDefault();
                if (entry is null) { entry = new JsonObject { ["Faction"] = new JsonObject { ["Name"] = name }, ["timestamp"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() }; entries.Add(entry); }
                entry["ReputationAmount"] = rep;
                WriteActorProperties(db, player.ControllerId, properties);
                if (unlock) {
                    ExecuteNonQuery(db, "INSERT INTO player_faction(actor_id,faction_id,utc_time_faction_change) VALUES($p,$f,$t) ON CONFLICT(actor_id) DO UPDATE SET faction_id=excluded.faction_id,utc_time_faction_change=CASE WHEN player_faction.faction_id=excluded.faction_id THEN player_faction.utc_time_faction_change ELSE excluded.utc_time_faction_change END;", ("$p", player.ControllerId), ("$f", id), ("$t", DateTimeOffset.UtcNow.ToUnixTimeSeconds()));
                    foreach (var node in nodes) ExecuteNonQuery(db, "INSERT INTO journey_story_node(character_id,story_node_id,complete_condition_state,reveal_condition_state,has_pending_reward,metadata_state,reset_group,fail_condition_state) VALUES($c,$n,jsonb('true'),jsonb('true'),0,jsonb('{}'),0,jsonb('{}')) ON CONFLICT(character_id,story_node_id) DO UPDATE SET complete_condition_state=jsonb('true'),reveal_condition_state=jsonb('true'),has_pending_reward=0;", ("$c", player.CharacterId), ("$n", node));
                    var tags = new List<string> { "DialogueFlags.Factions." + (id==1 ? "SentToMeetHawat" : "SentToPiterDeVries"), "DialogueFlags.Factions.Aligned"+name, "DialogueFlags.Factions.Met"+(id==1 ? "Hawat" : "PiterDeVries"), "Contract.Tracking."+name+"FactionUnlocked", "Contract.Tracking."+name+"RecruitmentCompleted", "DialogueFlags.Factions.FactionIntro", "DialogueFlags.Factions.FactionRank1", "DialogueFlags.Factions.FactionRank3", "DialogueFlags.Factions.MetARecruiter", "DialogueFlags.Factions.PlayedAllegianceCinematic", "DialogueFlags.Factions.SeenAnvilCinematic" };
                    tags.AddRange(Enumerable.Range(0,6).Select(t => $"Faction.{name}.Tier{t}"));
                    if (action=="rank19_eligible") tags.Add("Journey.LandsraadContractsUnlocked");
                    foreach (var tag in tags) ExecuteNonQuery(db,"INSERT INTO player_tags(character_id,tag) VALUES($c,$t) ON CONFLICT DO NOTHING;",("$c",player.CharacterId),("$t",tag));
                    foreach (var node in nodes) if (ScalarLong(db,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=$c AND story_node_id=$n AND json(complete_condition_state)='true' AND json(reveal_condition_state)='true';",("$c",player.CharacterId),("$n",node)) != 1) throw new InvalidDataException("Faction journey verification failed.");
                    if (ScalarLong(db,"SELECT faction_id FROM player_faction WHERE actor_id=$p;",("$p",player.ControllerId)) != id) throw new InvalidDataException("Faction alignment verification failed.");
                }
                if (ScalarLong(db,"SELECT reputation_amount FROM player_faction_reputation WHERE actor_id=$p AND faction_id=$f;",("$p",player.ControllerId),("$f",id)) != rep) throw new InvalidDataException("Reputation verification failed.");
                var verified = ReadActorProperties(db,player.ControllerId);
                if ((verified["FactionPlayerComponent"]?["m_FactionDataArray"] as JsonArray)?.OfType<JsonObject>().Single(e => e["Faction"]?["Name"]?.GetValue<string>()==name)["ReputationAmount"]?.GetValue<long>() != rep) throw new InvalidDataException("Faction component verification failed.");
                ValidateDatabase(db); Commit(db);
                return new { faction=name,reputation=rep,action,journeyNodes=nodes.Count };
            } catch { Rollback(db); throw; }
        },requireGameClosed:true);
    }
}
