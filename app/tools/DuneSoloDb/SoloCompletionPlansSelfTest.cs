using System.Text.Json;
using System.Text.Json.Nodes;
namespace DuneSoloDb;
internal static partial class Program
{
    private static void SelfTestSoloCompletionPlans(string root, string original, string adapter)
    {
        var path = Path.Combine(root,"completion-plan.db"); var seed = Path.Combine(root,"completion-plan.sqlite");
        File.WriteAllBytes(seed,Unwrap(File.ReadAllBytes(original)).SqliteBytes);
        var contracts = new[] { "Week1_01","Week1_02","Week1_03","Week2_01","Week2_01_Funnel","Week2_02","Week3_01","Week3_01_Funnel","Week3_02" }.Select(s=>"DA_CT_Halloween_"+s).ToArray();
        using(var db=OpenWritable(seed)) {
            var id=ReadIdentity(db);
            foreach(var node in new[]{"DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides","DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides.Child","DA_FQ_ClimbTheRanks.Rank20_Mission_Harkonnen","DA_FQ_ClimbTheRanks.BetrayTheAtreides"})
                ExecuteNonQuery(db,"INSERT OR REPLACE INTO journey_story_node(character_id,story_node_id,has_pending_reward,complete_condition_state,reveal_condition_state,fail_condition_state,metadata_state,reset_group) VALUES($id,$node,1,jsonb('false'),jsonb('false'),jsonb('{}'),jsonb('{}'),'Default');",("$id",id.CharacterId),("$node",node));
            foreach(var node in new[]{"DA_MQ_AssassinsHandbook","DA_MQ_AssassinsHandbook.Child","DA_MQ_TheGreatConvention","DA_MQ_TheGreatConvention.Child","DA_MQ_TheGreatConventionOther.Child"})
                ExecuteNonQuery(db,"INSERT OR REPLACE INTO journey_story_node(character_id,story_node_id,has_pending_reward,complete_condition_state,reveal_condition_state,fail_condition_state,metadata_state,reset_group) VALUES($id,$node,1,jsonb('false'),jsonb('false'),jsonb('{}'),jsonb('{}'),'Default');",("$id",id.CharacterId),("$node",node));
            ExecuteNonQuery(db,"INSERT INTO inventories(id,actor_id,inventory_type) VALUES(998201,$pawn,29),(998202,20,29);",("$pawn",id.PawnId));
            ExecuteNonQuery(db,"INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats) VALUES(998001,998201,1,0,'ContractItem',jsonb('{\"FContractItemStats\":[0,{\"ContractName\":{\"Name\":\"Halloween_Week3_02\"}}]}')),(998002,998202,1,0,'ContractItem',jsonb('{\"FContractItemStats\":[0,{\"ContractName\":{\"Name\":\"Halloween_Week3_02\"}}]}')); ");
            var props=ReadActorProperties(db,id.PawnId);props["ContractsCoordinatorComponent"]=new JsonObject{["m_TrackedContractItemUid"]="!!itm#998001",["OtherKey"]="kept"};WriteActorProperties(db,id.PawnId,props);
            ExecuteNonQuery(db,"INSERT INTO player_tags(character_id,tag) VALUES($id,'Event.Active'),($id,'Unrelated.Kept');",("$id",id.CharacterId));
        }
        WrapSqlite(seed,path);
        var catalog=Path.Combine(root,"completion-plan-tags.json");File.WriteAllText(catalog,JsonSerializer.Serialize(new {
            completion_plans=new Dictionary<string,string[]>{{"faction_atreides_complete",new[]{"DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides","DA_FQ_ClimbTheRanks.Absent"}}},
            journey_node_tags=new Dictionary<string,string[]>{{"DA_MQ_TheGreatConvention",new[]{"Act2.Completed"}}},
            contract_tags=contracts.ToDictionary(c=>c,c=>new[]{"Completed."+c}),
            contract_remove_tags=new Dictionary<string,string[]>{{contracts[0],new[]{"Event.Active"}}}
        }));
        foreach(var plan in new[]{"act2_complete","scourge_complete","faction_atreides_complete"}) {
            var before=File.ReadAllBytes(path);var backup=Path.Combine(root,plan+"-plan-before.db");UnlockMainQuest(path,backup,adapter,catalog,plan);
            if(!File.ReadAllBytes(backup).SequenceEqual(before))throw new InvalidOperationException("Completion plan backup changed.");
        }
        File.WriteAllBytes(seed,Unwrap(File.ReadAllBytes(path)).SqliteBytes);
        using var check=OpenWritable(seed);var identity=ReadIdentity(check);
        if(ScalarLong(check,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=$id AND story_node_id IN ('DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides','DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides.Child') AND json(complete_condition_state)='true' AND has_pending_reward=1;",("$id",identity.CharacterId))!=2
            || ScalarLong(check,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=$id AND story_node_id IN ('DA_FQ_ClimbTheRanks.Rank20_Mission_Harkonnen','DA_FQ_ClimbTheRanks.BetrayTheAtreides') AND json(complete_condition_state)='false';",("$id",identity.CharacterId))!=2)
            throw new InvalidOperationException("Faction completion changed the wrong faction or pending rewards.");
        if(ScalarLong(check,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=$id AND story_node_id IN ('DA_MQ_AssassinsHandbook','DA_MQ_AssassinsHandbook.Child','DA_MQ_TheGreatConvention','DA_MQ_TheGreatConvention.Child') AND json(complete_condition_state)='true' AND has_pending_reward=1;",("$id",identity.CharacterId))!=4
            || ScalarLong(check,"SELECT COUNT(*) FROM journey_story_node WHERE character_id=$id AND story_node_id='DA_MQ_TheGreatConventionOther.Child' AND json(complete_condition_state)='false';",("$id",identity.CharacterId))!=1
            || ScalarLong(check,"SELECT COUNT(*) FROM items WHERE id=998001;")!=0 || ScalarLong(check,"SELECT COUNT(*) FROM items WHERE id=998002;")!=1
            || ScalarLong(check,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag LIKE 'Completed.DA_CT_Halloween_%';",("$id",identity.CharacterId))!=9
            || ScalarLong(check,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag='Event.Active';",("$id",identity.CharacterId))!=0
            || ScalarLong(check,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag='Unrelated.Kept';",("$id",identity.CharacterId))!=1
            || ReadActorProperties(check,identity.PawnId)["ContractsCoordinatorComponent"]?["m_TrackedContractItemUid"]?.GetValue<string>()!="!!itm#0")
            throw new InvalidOperationException("Completion plans failed scope/reward/contract preservation.");
    }
}
