using System.Security.Cryptography;
using System.Text.Json.Nodes;
namespace DuneSoloDb;
internal static partial class Program
{
    private static object SelfTestPostNpeReset(string root, string source)
    {
        var sqlite = Path.Combine(root,"post-npe-fixture.sqlite");
        File.WriteAllBytes(sqlite,Unwrap(ReadStable(source)).SqliteBytes);
        using(var db=OpenWritable(sqlite)) {
            ExecuteNonQuery(db,"""
                ALTER TABLE actors ADD COLUMN map TEXT;
                ALTER TABLE actors ADD COLUMN dimension_index INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE actors ADD COLUMN location_x REAL;
                ALTER TABLE actors ADD COLUMN location_y REAL;
                ALTER TABLE actors ADD COLUMN location_z REAL;
                CREATE TABLE factions(id INTEGER PRIMARY KEY,name TEXT);
                INSERT INTO factions VALUES(1,'Atreides'),(2,'Harkonnen'),(3,'None');
                CREATE TABLE player_faction(actor_id INTEGER PRIMARY KEY,faction_id INTEGER,utc_time_faction_change INTEGER);
                INSERT INTO player_faction VALUES(11,1,123);
                CREATE TABLE player_faction_reputation(actor_id INTEGER,faction_id INTEGER,reputation_amount INTEGER,PRIMARY KEY(actor_id,faction_id));
                INSERT INTO player_faction_reputation VALUES(11,1,11975),(999,1,700);
                CREATE TABLE mnemonic_recall(character_id INTEGER,lesson TEXT,PRIMARY KEY(character_id,lesson));
                INSERT INTO mnemonic_recall VALUES(1,'TestLore'),(999,'OtherLore');
                INSERT OR IGNORE INTO actors(id,class,properties) VALUES(11,'Controller',jsonb('{}'));
                INSERT INTO inventories VALUES(500,10,29,20,1000);
                INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats) VALUES(501,500,1,0,'ContractItem','{}');
                INSERT INTO player_tags VALUES(1,'Character.Keystone.Exploration.BonusLoot'),(1,'Exploration.POI.SocialHubs.HarkoTerminusNorth'),(1,'DialogueFlags.Mentor.Swordmaster'),(1,'Journey.RewardsUnblocked'),(1,'Faction.Tier19'),(1,'DialogueFlags.Factions.SeenAnvilCinematic'),(1,'DialogueFlags.AoK.ThraxStanding');
                INSERT INTO journey_story_node(character_id,story_node_id,complete_condition_state,reveal_condition_state,metadata_state,fail_condition_state) VALUES
                    (1,'DA_SQ_VermiliusGap.Relocate',jsonb('true'),jsonb('true'),jsonb('{}'),jsonb('{}')),
                    (1,'DA_Dunipedia_Test.Fragment',jsonb('true'),jsonb('true'),jsonb('{}'),jsonb('{}')),
                    (1,'DA_ACH_Test',jsonb('true'),jsonb('true'),jsonb('{}'),jsonb('{}')),
                    (999,'OtherCharacterQuest',jsonb('true'),jsonb('true'),jsonb('{}'),jsonb('{}'));
                """);
            var p=ReadIdentity(db);
            var pawn=ReadActorProperties(db,p.PawnId);
            var tech=EnsureObject(pawn,"TechKnowledgePlayerComponent");tech["m_TechKnowledgePoints"]=2077;
            EnsureObject(tech,"m_TechKnowledge")["m_TechKnowledgeData"]=new JsonArray(
                new JsonObject{["ItemKey"]="RCP_TestFremkitRecipe",["UnlockedState"]="Purchased"},
                new JsonObject{["ItemKey"]="RCP_BaseBackupTool_Recipe",["UnlockedState"]="Purchased"},
                new JsonObject{["ItemKey"]="DA_GRP_CrudeStillsuit",["UnlockedState"]="Purchased"},
                new JsonObject{["ItemKey"]="RCP_LeakyStillsuit_Boots_Recipe",["UnlockedState"]="Purchased"},
                new JsonObject{["ItemKey"]="RCP_LeakyStillsuit_Gloves_Recipe",["UnlockedState"]="Purchased"},
                new JsonObject{["ItemKey"]="RCP_LeakyStillsuit_Mask_Recipe",["UnlockedState"]="Purchased"},
                new JsonObject{["ItemKey"]="UnrelatedResearch",["UnlockedState"]="Purchased"});
            pawn["ContractsCoordinatorComponent"]=new JsonObject{["m_TrackedContractItemUid"]="!!itm#501"};
            WriteActorProperties(db,p.PawnId,pawn);
            var controller=ReadActorProperties(db,p.ControllerId);
            controller["FactionPlayerComponent"]=JsonNode.Parse("""{"m_FactionDataArray":[{"Faction":{"Name":"Atreides"},"ReputationAmount":11975}]}""");
            WriteActorProperties(db,p.ControllerId,controller);
            var components=ReadFglComponents(db,p.EntityId);
            var level=RequireComponentObject(components,"FLevelComponent");level["UnspentSkillPoints"]=93;level["TotalSkillPoints"]=95;
            var spice=RequireComponentObject(components,"FSpiceAddictionComponent");spice["SystemStatus"]="FullyEnabled";spice["SpiceVisionEnabledStatus"]="FullyEnabled";
            WriteFglComponents(db,p.EntityId,components);
        }
        var input=Path.Combine(root,"post-npe-game.db");WrapSqlite(sqlite,input);
        var adapterPath=Path.Combine(root,"post-npe-adapter.json");
        var selfTestFingerprint=InspectPath(input).SchemaFingerprint;
        File.WriteAllText(adapterPath,"""
                {
                  "id":"self-test",
                  "schema_fingerprint":"__SCHEMA_FINGERPRINT__",
                  "specializations":{
                    "max_level":100,
                    "max_xp":44182,
                    "tracks":{"Combat":4,"Crafting":1,"Exploration":3,"Gathering":2,"Sabotage":5}
                  },
                  "find_the_fremen":{
                    "nodes":["DA_MQ_FindTheFremen","DA_MQ_FindTheFremen.FirstTest"],
                    "tags":["Journey.Act1.Completed","Journey.RewardsUnblocked"],
                    "recipes":["RCP_TestFremkitRecipe"],
                    "spice_status":"FullyEnabled"
                  },
                  "complete_npe":{
                    "tag":"NPE.SelfTestCompletedNPE",
                    "node_count":2,
                    "nodes":["DA_MQ_ANewBeginning","DA_MQ_NPEAutocompleted"]
                  },
                  "water_fillable_capacities":{
                    "highcapacityliterjon_06":3000
                  },
                  "enable_all_skills":{
                    "level_value":7,
                    "point_buffer":20,
                    "intel_floor":100,
                    "exclude":[
                      "(TagName=\"Skills.Ability.VoiceStop\")",
                      "(TagName=\"Skills.Ability.Hypersprint\")"
                    ]
                  }
                }
                """.Replace("__SCHEMA_FINGERPRINT__",selfTestFingerprint));
        var resetPath=Path.Combine(root,"post-npe-reset.json");
        File.WriteAllText(resetPath,"""{"returnLocation":{"map":"HaggaBasin","dimensionIndex":0,"x":10,"y":20,"z":30},"resetResearchItemKeys":["RCP_TestFremkitRecipe","RCP_BaseBackupTool_Recipe","DA_GRP_CrudeStillsuit","RCP_LeakyStillsuit_Boots_Recipe","RCP_LeakyStillsuit_Gloves_Recipe","RCP_LeakyStillsuit_Mask_Recipe"]}""");
        string levelBefore;
        using(var db=OpenWritable(sqlite))levelBefore=RequireComponentObject(ReadFglComponents(db,ReadIdentity(db).EntityId),"FLevelComponent").ToJsonString();
        var before=File.ReadAllBytes(input);
        var backup=Path.Combine(root,"post-npe-safety.db");
        ResetPostNpe(input,backup,adapterPath,resetPath,requireGameClosed:false);
        if(!File.Exists(backup)||!before.SequenceEqual(File.ReadAllBytes(backup)))throw new InvalidOperationException("Post-NPE reset did not retain the exact original save.");
        var after=Path.Combine(root,"post-npe-after.sqlite");File.WriteAllBytes(after,Unwrap(ReadStable(input)).SqliteBytes);
        using(var db=OpenWritable(after)) {
            var p=ReadIdentity(db);var pawn=ReadActorProperties(db,p.PawnId);
            var c=ReadFglComponents(db,p.EntityId);
            if(RequireComponentObject(c,"FLevelComponent").ToJsonString()!=levelBefore
                ||GetInt(EnsureObject(pawn,"TechKnowledgePlayerComponent"),"m_TechKnowledgePoints")!=2077
                ||ScalarLong(db,"SELECT COUNT(*) FROM player_tags WHERE character_id=1 AND tag IN ('Character.Keystone.Exploration.BonusLoot','Exploration.POI.SocialHubs.HarkoTerminusNorth','DialogueFlags.Mentor.Swordmaster');")!=3
                ||ScalarLong(db,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=1 AND story_node_id='DA_SQ_VermiliusGap.Relocate' AND json(complete_condition_state)='false';")!=1
                ||ScalarLong(db,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=1 AND story_node_id='DA_Dunipedia_Test.Fragment' AND json(complete_condition_state)='false';")!=1
                ||ScalarLong(db,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=1 AND story_node_id='DA_ACH_Test' AND json(complete_condition_state)='true';")!=1
                ||ScalarLong(db,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=999 AND json(complete_condition_state)='true';")!=1
                ||ScalarLong(db,"SELECT COUNT(*) FROM mnemonic_recall WHERE character_id=999;")!=1
                ||ScalarLong(db,"SELECT COUNT(*) FROM mnemonic_recall WHERE character_id=1;")!=0
                ||ScalarLong(db,"SELECT COUNT(*) FROM items WHERE id=501;")!=0
                ||CountPurchasedRecipes(pawn,new[]{"UnrelatedResearch"})!=1
                ||CountPurchasedRecipes(pawn,new[]{"RCP_BaseBackupTool_Recipe"})!=0
                ||ScalarLong(db,"SELECT COUNT(*) FROM actors WHERE id=10 AND map='HaggaBasin' AND location_x=10 AND location_y=20 AND location_z=30;")!=1
                ||RequireComponentObject(c,"FSpiceAddictionComponent")["SpiceVisionEnabledStatus"]?.GetValue<string>()!="Disabled")
                throw new InvalidOperationException("Post-NPE fixture preservation check failed.");
        }
        // A shared recovery point is older than the immediate edit rollback.
        var recovery=Path.Combine(root,"session-recovery.db");File.Copy(backup,recovery);
        var edited=Path.Combine(root,"session-edited.db");File.Copy(input,edited);
        var recoveryHash=SHA256.HashData(File.ReadAllBytes(recovery));
        var editHash=SHA256.HashData(File.ReadAllBytes(edited));
        try {
            ReuseRecoverySnapshot=true;
            Restore(input,edited,recovery);
            if(!recoveryHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(recovery))))throw new InvalidOperationException("Session recovery snapshot was overwritten.");
            RestoreVerificationProbe=()=>throw new InvalidDataException("Self-test verification failure");
            try { Restore(backup,edited,recovery); throw new InvalidOperationException("Injected verification failure was not rejected."); }
            catch(InvalidDataException ex) when(ex.Message=="Self-test verification failure") { }
            finally { RestoreVerificationProbe=null; }
            if(!editHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(edited))))throw new InvalidOperationException("Immediate edit rollback used the older recovery point.");
            File.SetLastWriteTimeUtc(recovery,DateTime.UtcNow.AddMinutes(-16));
            try { Restore(input,edited,recovery); throw new InvalidOperationException("Expired session snapshot was reused."); }
            catch(IOException) { }
        } finally { ReuseRecoverySnapshot=false;RestoreVerificationProbe=null; }
        // Force a failure inside the private transaction; original must stay byte-identical.
        using(var db=OpenWritable(sqlite))ExecuteNonQuery(db,"ALTER TABLE journey_story_node DROP COLUMN metadata_state;");
        var bad=Path.Combine(root,"post-npe-invalid.db");WrapSqlite(sqlite,bad);
        var badBefore=SHA256.HashData(File.ReadAllBytes(bad));var rejected=false;
        try{ResetPostNpe(bad,Path.Combine(root,"rejected-post-npe.db"),adapterPath,resetPath,requireGameClosed:false);}
        catch(Exception ex) when(ex is Microsoft.Data.Sqlite.SqliteException or InvalidDataException){rejected=true;}
        if(!rejected||!badBefore.SequenceEqual(SHA256.HashData(File.ReadAllBytes(bad))))throw new InvalidOperationException("Post-NPE failure changed the original fixture.");
        return new{ok=true,tests=new[]{"post-npe-skills-and-point-balances-preserved","post-npe-story-faction-codex-and-fremen-rewards-reset","post-npe-npe-restored-and-crossing-incomplete","post-npe-discoveries-bonuses-and-other-character-preserved","post-npe-exact-safety-backup","post-npe-failure-leaves-original-unchanged","routine-edits-reuse-recovery-snapshot","verification-failure-restores-immediate-previous-save","expired-recovery-snapshot-rejected"}};
    }
}
