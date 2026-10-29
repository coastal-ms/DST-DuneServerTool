"""Executable bridge/state-machine checks. Requires the Lua 5.4 lupa wheel."""
import re
import unittest
from pathlib import Path
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'app/resources/solo-mods/dst-solo-grants/Scripts'
REWARDS = (SCRIPTS / 'rewards.lua').read_text()
MAIN = (SCRIPTS / 'main.lua').read_text()
FIXTURE = (ROOT / 'tests/fixtures/solo-native-grants.lua').read_text()


def setup(extra=''):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FIXTURE)
    for i, row in enumerate(re.findall(r'\{path="([^"]+)", actions=\{(.*?)\}\},', REWARDS)):
        path, actions = row
        lua.execute('object(..., "DunePlayerRewardsActionsDataAsset", "m_bIsExclusiveToPlayerRewards", "BoolProperty", 0xa8, true)', path)
        for j, (name, kind) in enumerate(re.findall(r'name="([^"]+)", class="([^"]+)"', actions)):
            lua.execute('local path,kind,value=...;object(path,kind,"m_ActionType","IntProperty",0x28,value)', path+':'+name, kind, (i+j) % 4)
    lua.execute('initial_writes=0;for _,row in pairs(originals)do local wanted;if row.field=="m_ActionType"then wanted=1 else wanted=false end;if row.value~=wanted then initial_writes=initial_writes+1 end end')
    lua.execute(extra)
    lua.globals().rewards_source = REWARDS
    lua.execute('dofile=function()return assert(load(rewards_source,"@bundled/rewards.lua"))()end;files["bundled/dst-command-root.txt"]="queue|abcdef"')
    lua.execute('assert(load(...,"@bundled/main.lua"))()', MAIN)
    return lua


class SoloNativeGrants(unittest.TestCase):
    def test_gc_and_build_menu_roundtrip_keep_assets_alive(self):
        setup().execute("""
            run_until(100)
            unavailable_child='/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_GunnerSet.DA_PlayerRewards_GunnerSet:DunePlayerRewardsActionBuildingSet_0'
            local before=writes
            for i=1,5 do collect_unreferenced();run_until(100+i*1000)end
            assert(writes==before and calls==0 and not files['queue/bridge-error.txt'])
            local n=0;for _ in pairs(objects)do n=n+1 end;assert(n==369)
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(6000)
            assert(calls==1 and files['queue/'..active_id..'.result']:find('^delivered|1|'))
            mode='online';run_until(6500);assert_originals();assert(#reference_data==0)
        """)

    def test_engine_and_other_mod_references_survive_cleanup(self):
        setup().execute("""
            local _,engine=next(objects)
            local other={GetAddress=function()return 777777 end}
            reference_data={engine,other};run_until(100)
            local added={GetAddress=function()return 888888 end};reference_data[#reference_data+1]=added
            collect_unreferenced();run_until(1000);assert(not files['queue/bridge-error.txt'])
            mode='online';run_until(2000);assert_originals()
            assert(#reference_data==3 and reference_data[1]==engine and reference_data[2]==other and reference_data[3]==added)
        """)

    def test_reference_write_failure_rolls_back_before_reward_mutation(self):
        setup('fail_reference_write=true;other={GetAddress=function()return 777777 end};reference_data={other}').execute("run_until(1000);assert(writes==0 and calls==0);assert_originals();assert(#reference_data==1 and reference_data[1]==other)")

    def test_unsupported_reference_property_rejects_before_reward_mutation(self):
        setup('missing_reference_field=true').execute("run_until(1000);assert(writes==0 and calls==0);assert_originals();assert(#reference_data==0)")

    def test_repeated_same_startup_hook_does_not_interrupt_delivery(self):
        setup().execute("""
            notifications.InitGameStatePre({get=function()return instance end})
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(100)
            for _=1,200 do notifications.InitGameStatePre({get=function()return instance end})end
            run_until(1600);assert(calls==1 and files['queue/'..active_id..'.result']:find('^delivered|1|'))
        """)

    def test_world_startup_applies_without_waiting_for_scheduled_tick(self):
        lua = setup('controllers=false')
        lua.execute("assert(writes==0);notifications.InitGameStatePre({get=function()return instance end});assert(writes==initial_writes and calls==0)")

    def test_same_startup_object_can_reenter_after_leaving_solo(self):
        setup().execute("""
            notifications.InitGameStatePre({get=function()return instance end});run_until(100)
            mode='online';notifications['/Script/DuneSandbox.MainMenuHomeWidget'](menu_widget);run_until(1000);assert_originals()
            mode='solo';notifications.InitGameStatePre({get=function()return instance end});run_until(2000)
            assert(#reference_data==369 and not files['queue/bridge-error.txt'])
        """)

    def test_world_startup_denies_online_and_anticheat_context(self):
        for extra in ["mode='online'", 'anti_cheat=true']:
            with self.subTest(extra=extra):
                setup(extra).execute('notifications.InitGameStatePre({get=function()return instance end});assert(writes==0 and calls==0)')

    def test_reset_reward_settings_are_revalidated_before_native_delivery(self):
        lua = setup()
        lua.execute("run_until(100);for _,row in pairs(originals)do if row.data[row.field]~=row.value then row.data[row.field]=row.value;break end end;request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600);assert(calls==1);assert(not files['queue/bridge-error.txt']);mode='online';run_until(2500);assert_originals()")

    def test_reloaded_asset_and_action_recover_without_automatic_grants(self):
        setup().execute("""
            run_until(100)
            local asset='/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_BetaReward_MemorialPlaque.DA_PlayerRewards_BetaReward_MemorialPlaque'
            local action=asset..':DunePlayerRewardsActionBuildingSet_0'
            for _,path in ipairs({asset,action})do rawset(objects[path],'IsValid',function()return false end)end
            object(asset,'DunePlayerRewardsActionsDataAsset','m_bIsExclusiveToPlayerRewards','BoolProperty',0xa8,true)
            object(action,'DunePlayerRewardsActionBuildingSet','m_ActionType','IntProperty',0x28,3)
            run_until(1600)
            assert(objects[asset].m_bIsExclusiveToPlayerRewards==false and objects[action].m_ActionType==1)
            assert(calls==0 and not files['queue/bridge-error.txt'])
            mode='online';run_until(2500);assert_originals()
        """)

    def test_reloaded_asset_schema_change_stops_before_new_writes(self):
        setup().execute("""
            run_until(100)
            local asset='/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_BetaReward_MemorialPlaque.DA_PlayerRewards_BetaReward_MemorialPlaque'
            rawset(objects[asset],'IsValid',function()return false end)
            object(asset,'DunePlayerRewardsActionsDataAsset','m_bIsExclusiveToPlayerRewards','BoolProperty',0xa9,true)
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600)
            assert(calls==0 and files['queue/bridge-error.txt']);assert_originals()
        """)

    def test_repair_failure_restores_the_pre_application_values(self):
        setup().execute("""
            run_until(100)
            for _,row in pairs(originals)do if row.data[row.field]~=row.value then row.data[row.field]=row.value end end
            fail_write=true;writes=119
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600)
            assert(calls==0 and files['queue/bridge-error.txt']);assert_originals()
        """)

    def test_repair_preserves_an_original_false_flag(self):
        setup().execute("""
            local target
            for _,row in pairs(originals)do
                if row.field=='m_bIsExclusiveToPlayerRewards' then target=row;row.value=false;row.data[row.field]=false;break end
            end
            run_until(100);target.data[target.field]=true;run_until(1600)
            assert(target.data[target.field]==false and not files['queue/bridge-error.txt'])
            mode='online';run_until(2500);assert_originals()
        """)

    def test_stale_controller_waits_without_restoring_verified_solo_flags(self):
        setup().execute("""
            run_until(100);local previous=world;local current={IsValid=function()return true end,GetAddress=function()return 124 end}
            instance.GetWorld=function()return current end
            notifications.InitGameStatePre({get=function()return instance end})
            local before=writes
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600)
            assert(writes==before and calls==0 and not files['queue/bridge-error.txt'])
            pc.GetWorld=function()return current end;run_until(3000);assert(calls==1)
            mode='online';run_until(4000);assert_originals()
        """)

    def test_same_world_non_solo_controller_still_rejects_and_restores(self):
        setup().execute("""
            run_until(100)
            local library=StaticFindObject('/Script/DuneSandbox.Default__GUIBlueprintLibrary')
            library.IsSoloPlay=function(_,obj)return obj~=pc end
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600)
            assert(calls==0);assert_originals()
        """)

    def test_unknown_controller_world_cannot_inherit_departing_world_exception(self):
        setup().execute("""
            notifications.InitGameStatePre({get=function()return instance end});run_until(100)
            pc.GetWorld=function()return {IsValid=function()return true end,GetAddress=function()return 999 end}end
            request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600)
            assert(calls==0);assert_originals()
        """)

    def test_missing_startup_context_does_not_fall_back_to_late_polling(self):
        setup().execute('notifications.InitGameStatePre({get=function()return nil end});run_until(1000);assert(writes==0 and calls==0)')

    def test_invalid_transition_context_restores_existing_settings(self):
        setup().execute('run_until(100);assert(writes==initial_writes);notifications.InitGameStatePre({get=function()return nil end});run_until(1000);assert_originals();assert(calls==0)')

    def test_solo_settings_before_controller_and_restore_online(self):
        lua = setup('controllers=false')
        lua.execute("run_until(100);assert(writes==initial_writes);mode='online';run_until(600);assert_originals()")

    def test_no_changes_online_ambiguous_or_anticheat(self):
        for extra in ["mode='online'", "mode='ambiguous'", 'anti_cheat=true']:
            with self.subTest(extra=extra):
                setup(extra).execute('run_until(1000);assert(writes==0 and calls==0)')

    def test_partial_write_rollback(self):
        setup('fail_write=true').execute('run_until(1000);assert_originals();assert(calls==0)')

    def test_schema_change_rejects_before_mutation(self):
        lua = setup('local _,o=next(objects);o.GetClass=function()return class({}, {prop("m_bIsExclusiveToPlayerRewards","BoolProperty",0xa9)})end')
        lua.execute('run_until(1000);assert(writes==0);assert_originals()')

    def test_menu_restores_without_reapplying_stale_world(self):
        setup().execute('run_until(500);mode="online";notifications["/Script/DuneSandbox.MainMenuHomeWidget"](menu_widget);run_until(1500);assert_originals()')

    def test_queued_menu_callback_cannot_undo_synchronous_solo_startup(self):
        setup().execute('notifications["/Script/DuneSandbox.MainMenuHomeWidget"](menu_widget);notifications.InitGameStatePre({get=function()return instance end});run_until(500);assert(writes==initial_writes and calls==0)')

    def test_menu_widget_constructed_inside_solo_is_not_a_menu_transition(self):
        setup().execute('run_until(100);notifications["/Script/DuneSandbox.MainMenuHomeWidget"](menu_widget);run_until(1000);assert(writes==initial_writes and calls==0)')

    def test_stale_menu_widget_world_does_not_restore_current_solo_assets(self):
        setup().execute('run_until(100);local old={IsValid=function()return true end,GetWorld=function()return {IsValid=function()return true end,GetAddress=function()return 999 end}end};notifications["/Script/DuneSandbox.MainMenuHomeWidget"](old);run_until(1000);assert(writes==initial_writes and calls==0)')

    def test_new_solo_lifecycle_can_reuse_the_previous_world_address(self):
        setup().execute('run_until(100);mode="online";notifications["/Script/DuneSandbox.MainMenuHomeWidget"](menu_widget);run_until(200);assert_originals();mode="solo";notifications.InitGameStatePre({get=function()return instance end});run_until(1000);assert(writes==initial_writes*3 and calls==0)')

    def test_new_lifecycle_during_a_delivery_is_uncertain_not_replayed(self):
        setup().execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(100);notifications.InitGameStatePre({get=function()return instance end});run_until(2000);assert(calls==1);assert(files['queue/'..active_id..'.result']:find('^uncertain|0|'))")

    def test_native_grant_claim_readback_and_no_replay(self):
        lua = setup()
        lua.execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1600);assert(calls==1 and bag.Beta_Plaque_Patent==1);assert(files['queue/'..active_id..'.result']:find('^delivered|1|'));run_until(5000);assert(calls==1)")

    def test_wrong_character_waits(self):
        setup('account=42').execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(1500);assert(calls==0);account=9007199254740993;run_until(3000);assert(calls==1)")

    def test_interrupted_claim_is_never_replayed(self):
        setup().execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');files['queue/'..active_id..'.result']='processing|0|Delivering';run_until(1500);assert(calls==0);assert(files['queue/'..active_id..'.result']:find('^uncertain|0|'))")

    def test_native_noop_or_full_backpack_is_uncertain(self):
        setup('refuse_grant=true').execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');run_until(2000);assert(calls==1);assert(files['queue/'..active_id..'.result']:find('^uncertain|0|'))")

    def test_missing_receipt_after_claim_is_never_replayed(self):
        setup().execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');files['queue/'..active_id..'.claim']='old-session';run_until(2000);assert(calls==0);assert(files['queue/'..active_id..'.result']:find('^uncertain|0|'))")

    def test_empty_existing_claim_is_not_treated_as_missing(self):
        setup().execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0');files['queue/'..active_id..'.claim']='';run_until(2000);assert(calls==0);assert(files['queue/'..active_id..'.result']:find('^uncertain|0|'))")

    def test_batch_partial_failure_does_not_repeat_completed_item(self):
        lua = setup()
        lua.execute("request(string.rep('b',32),'Beta_Plaque_Patent|1|0\\nScrap|2|3');run_until(100);refuse_grant=true;run_until(2000);assert(calls==2);assert(files['queue/'..active_id..'.result']:find('^uncertain|1|'))")


if __name__ == '__main__':
    unittest.main()
