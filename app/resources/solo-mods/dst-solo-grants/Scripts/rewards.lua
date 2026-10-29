-- Bundled Solo reward settings. Funcom asset identities; no account or save writes.
local PREFIX = "[DSTSoloGrants] "
local source = debug.getinfo(1, "S").source:match("^@(.+[/\\])")
local journal, world_address = {}, nil
local stopped, applied = false, false
local failure
local generation = 0
local departing_controllers = {}
local references = {}
local release_references
local startup_seen
local REWARDS = {
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Anniversary2026_TeaHouse_Week1.DA_PlayerRewards_Anniversary2026_TeaHouse_Week1", actions={{name="DunePlayerRewardsActionBuildingSet_3", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_4", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Anniversary2026_TeaHouse_Week2.DA_PlayerRewards_Anniversary2026_TeaHouse_Week2", actions={{name="DunePlayerRewardsActionBuildingSet_3", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Anniversary2026_TeaHouse_Week3.DA_PlayerRewards_Anniversary2026_TeaHouse_Week3", actions={{name="DunePlayerRewardsActionBuildingSet_3", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Anniversary2026_TeaHouse_Week4.DA_PlayerRewards_Anniversary2026_TeaHouse_Week4", actions={{name="DunePlayerRewardsActionBuildingSet_3", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Atreides_TeaHouse_Relief_01.DA_PlayerRewards_Atreides_TeaHouse_Relief_01", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_B1C3_CodeGiveaway_RoofToppers_01.DA_PlayerRewards_B1C3_CodeGiveaway_RoofToppers_01", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_B1C3_CodeGiveaway_RoofToppers_02.DA_PlayerRewards_B1C3_CodeGiveaway_RoofToppers_02", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_BenchmarkBonus_FramebladeKnife.DA_PlayerRewards_BenchmarkBonus_FramebladeKnife", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_BetaReward_AwooEmote.DA_PlayerRewards_BetaReward_AwooEmote", actions={{name="DunePlayerRewardsActionEmote_0", class="DunePlayerRewardsActionEmote"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_BetaReward_BETASwordSkin.DA_PlayerRewards_BetaReward_BETASwordSkin", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_BetaReward_MemorialPlaque.DA_PlayerRewards_BetaReward_MemorialPlaque", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Ch4Event_Dirk.DA_PlayerRewards_Ch4Event_Dirk", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Ch4Event_HeavyPistol.DA_PlayerRewards_Ch4Event_HeavyPistol", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Ch4Event_MaulaPistol.DA_PlayerRewards_Ch4Event_MaulaPistol", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_CommunityChallenge_1510_Milestone1.DA_PlayerRewards_CommunityChallenge_1510_Milestone1", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_CommunityChallenge_1510_Milestone2.DA_PlayerRewards_CommunityChallenge_1510_Milestone2", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_CommunityChallenge_1510_Milestone3.DA_PlayerRewards_CommunityChallenge_1510_Milestone3", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_CommunityChallenge_1510_Milestone4.DA_PlayerRewards_CommunityChallenge_1510_Milestone4", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DigitalArtbook.DA_PlayerRewards_DigitalArtbook", actions={}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DigitalSoundtrack.DA_PlayerRewards_DigitalSoundtrack", actions={}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_BlueDasherOrnithopterSwatch.DA_PlayerRewards_DLC_BlueDasherOrnithopterSwatch", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_CaladanPalaceBuildingSet.DA_PlayerRewards_DLC_CaladanPalaceBuildingSet", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_10", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_12", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_14", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_16", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_18", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_2", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_20", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_22", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_24", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_26", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_28", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_30", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_32", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_34", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_36", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_38", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_4", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_40", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_42", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_44", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_6", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_8", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_Chapter3_Cosmetics.DA_PlayerRewards_DLC_Chapter3_Cosmetics", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_2", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_10", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_11", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_12", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_13", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_14", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_15", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_16", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_17", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_4", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_5", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_6", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_7", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_8", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_9", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionEmote_0", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_2", class="DunePlayerRewardsActionEmote"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_Dune2021FilmStillsuit.DA_PlayerRewards_DLC_Dune2021FilmStillsuit", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_DuskRiderSandbikeSwatch.DA_PlayerRewards_DLC_DuskRiderSandbikeSwatch", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_LostHarvest.DA_PlayerRewards_DLC_LostHarvest", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_10", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_12", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_14", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_2", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_4", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_6", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_10", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_11", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_12", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_13", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_14", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_4", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_5", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_6", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_7", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_8", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_9", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionEmote_0", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_2", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_4", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_6", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_8", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionGameplayTag_1", class="DunePlayerRewardsActionGameplayTag"},{name="DunePlayerRewardsActionTechTreeEntry_3", class="DunePlayerRewardsActionTechTreeEntry"},{name="DunePlayerRewardsActionTechTreeEntry_5", class="DunePlayerRewardsActionTechTreeEntry"},{name="DunePlayerRewardsActionTechTreeEntry_7", class="DunePlayerRewardsActionTechTreeEntry"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_OutsideTheLaw.DA_PlayerRewards_DLC_OutsideTheLaw", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionGameplayTag_1", class="DunePlayerRewardsActionGameplayTag"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_SardaukarBatorArmor.DA_PlayerRewards_DLC_SardaukarBatorArmor", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_DLC_WildlifeOfArrakis.DA_PlayerRewards_DLC_WildlifeOfArrakis", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_2", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_4", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_6", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_AtreidesFlagshipWallArt.DA_PlayerRewards_Giveaway_AtreidesFlagshipWallArt", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_Atreides_BattleRifle.DA_PlayerRewards_Giveaway_Atreides_BattleRifle", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_Christmas_2025.DA_PlayerRewards_Giveaway_Christmas_2025", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_10", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_11", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_12", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_2", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_3", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_4", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_5", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_6", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_7", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_8", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_9", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_FlyersFriendMaulaPistol.DA_PlayerRewards_Giveaway_FlyersFriendMaulaPistol", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_MakeshiftPlazKnife.DA_PlayerRewards_Giveaway_MakeshiftPlazKnife", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_Mural_AMemoryOfPain.DA_PlayerRewards_Giveaway_Mural_AMemoryOfPain", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_Mural_ArrakisRising.DA_PlayerRewards_Giveaway_Mural_ArrakisRising", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_Giveaway_Mural_CallToAdventure.DA_PlayerRewards_Giveaway_Mural_CallToAdventure", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_GunnerSet.DA_PlayerRewards_GunnerSet", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_GunnerSet_Battlerifle.DA_PlayerRewards_GunnerSet_Battlerifle", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_GunnerSet_BuildingSet_01.DA_PlayerRewards_GunnerSet_BuildingSet_01", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_GunnerSet_BuildingSet_02.DA_PlayerRewards_GunnerSet_BuildingSet_02", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_GunnerSet_Sniper.DA_PlayerRewards_GunnerSet_Sniper", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_PreOrderBonus_SunsetDyeGlobalSwatch.DA_PlayerRewards_PreOrderBonus_SunsetDyeGlobalSwatch", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_PreOrderBonus_TerrariumofMuadDib.DA_PlayerRewards_PreOrderBonus_TerrariumofMuadDib", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_ReverendMother_GiveawayPackage.DA_PlayerRewards_ReverendMother_GiveawayPackage", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_2", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_3", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_4", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_6", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_RicheseMaulaPistol.DA_PlayerRewards_RicheseMaulaPistol", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_SardaukarSet.DA_PlayerRewards_SardaukarSet", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_10", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_11", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_12", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_13", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_14", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_15", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_16", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_17", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_18", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_19", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_20", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_21", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_22", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_23", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_24", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_25", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_26", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_27", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_28", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_29", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_30", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_31", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_33", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_34", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_35", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_36", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_37", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_38", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_39", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_4", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_40", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_5", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_6", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_7", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_8", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_9", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionEmote_0", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_1", class="DunePlayerRewardsActionEmote"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_ThorvaldLMG.DA_PlayerRewards_ThorvaldLMG", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TMobile_SocialOutfit.DA_PlayerRewards_TMobile_SocialOutfit", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_AtreidesWarshipCarving.DA_PlayerRewards_TwitchDrop_AtreidesWarshipCarving", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_CHOAMSpiceMask.DA_PlayerRewards_TwitchDrop_CHOAMSpiceMask", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_LetoOutfitBottom.DA_PlayerRewards_TwitchDrop_LetoOutfitBottom", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_LetoOutfitFeet.DA_PlayerRewards_TwitchDrop_LetoOutfitFeet", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_LetoOutfitGloves.DA_PlayerRewards_TwitchDrop_LetoOutfitGloves", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_LetoOutfitTop.DA_PlayerRewards_TwitchDrop_LetoOutfitTop", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverColumn.DA_PlayerRewards_TwitchDrop_ObserverColumn", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverColumn2.DA_PlayerRewards_TwitchDrop_ObserverColumn2", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverDoor.DA_PlayerRewards_TwitchDrop_ObserverDoor", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverFloor.DA_PlayerRewards_TwitchDrop_ObserverFloor", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverFloorRound.DA_PlayerRewards_TwitchDrop_ObserverFloorRound", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverFoundation.DA_PlayerRewards_TwitchDrop_ObserverFoundation", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverFoundationRound.DA_PlayerRewards_TwitchDrop_ObserverFoundationRound", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleBottomLeft.DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleBottomLeft", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleBottomRight.DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleBottomRight", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleTopLeft.DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleTopLeft", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleTopRight.DA_PlayerRewards_TwitchDrop_ObserverHalfTriangleTopRight", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverHatchDoor.DA_PlayerRewards_TwitchDrop_ObserverHatchDoor", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverLadder.DA_PlayerRewards_TwitchDrop_ObserverLadder", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverPassageway.DA_PlayerRewards_TwitchDrop_ObserverPassageway", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverPillarBottom.DA_PlayerRewards_TwitchDrop_ObserverPillarBottom", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverPillarMiddle.DA_PlayerRewards_TwitchDrop_ObserverPillarMiddle", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverPillarTop.DA_PlayerRewards_TwitchDrop_ObserverPillarTop", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRailing1.DA_PlayerRewards_TwitchDrop_ObserverRailing1", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRailingCornerRound.DA_PlayerRewards_TwitchDrop_ObserverRailingCornerRound", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRailingGate.DA_PlayerRewards_TwitchDrop_ObserverRailingGate", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRailingInclined.DA_PlayerRewards_TwitchDrop_ObserverRailingInclined", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRoofCorner.DA_PlayerRewards_TwitchDrop_ObserverRoofCorner", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRoofCornerInverted.DA_PlayerRewards_TwitchDrop_ObserverRoofCornerInverted", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRoofCornerRound.DA_PlayerRewards_TwitchDrop_ObserverRoofCornerRound", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRoofHalf.DA_PlayerRewards_TwitchDrop_ObserverRoofHalf", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverRoofTop.DA_PlayerRewards_TwitchDrop_ObserverRoofTop", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverStairs.DA_PlayerRewards_TwitchDrop_ObserverStairs", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverStairsCorner.DA_PlayerRewards_TwitchDrop_ObserverStairsCorner", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverStairsCornerInverted.DA_PlayerRewards_TwitchDrop_ObserverStairsCornerInverted", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverTriangleBottomLeft.DA_PlayerRewards_TwitchDrop_ObserverTriangleBottomLeft", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverTriangleBottomRight.DA_PlayerRewards_TwitchDrop_ObserverTriangleBottomRight", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverTriangleTopLeft.DA_PlayerRewards_TwitchDrop_ObserverTriangleTopLeft", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverTriangleTopRight.DA_PlayerRewards_TwitchDrop_ObserverTriangleTopRight", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverWallHalf.DA_PlayerRewards_TwitchDrop_ObserverWallHalf", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverWallRound.DA_PlayerRewards_TwitchDrop_ObserverWallRound", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverWall_01.DA_PlayerRewards_TwitchDrop_ObserverWall_01", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverWall_02.DA_PlayerRewards_TwitchDrop_ObserverWall_02", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverWindowRound.DA_PlayerRewards_TwitchDrop_ObserverWindowRound", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_TwitchDrop_ObserverWindow_01.DA_PlayerRewards_TwitchDrop_ObserverWindow_01", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_WatershippersSet.DA_PlayerRewards_WatershippersSet", actions={{name="DunePlayerRewardsActionBuildingSet_0", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionBuildingSet_1", class="DunePlayerRewardsActionBuildingSet"},{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_1", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_10", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_11", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_12", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_13", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_14", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_15", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_16", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_17", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_18", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_2", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_3", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_4", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_5", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_6", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_8", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionCustomization_9", class="DunePlayerRewardsActionCustomization"},{name="DunePlayerRewardsActionEmote_0", class="DunePlayerRewardsActionEmote"},{name="DunePlayerRewardsActionEmote_1", class="DunePlayerRewardsActionEmote"}}},
    {path="/Game/Dune/Systems/Monetization/Data/DA_PlayerRewards_WikiContributorSwatch.DA_PlayerRewards_WikiContributorSwatch", actions={{name="DunePlayerRewardsActionCustomization_0", class="DunePlayerRewardsActionCustomization"}}},
}
local function log(message)
    local line = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(message)
    print(PREFIX .. line .. "\n")
    if source then
        local file = io.open(source .. "rewards.log", "a")
        if file then file:write(line .. "\n"); file:close() end
    end
end
local function valid(object)
    if not object then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end
local function text(value)
    if type(value) == "string" then return value end
    return value:ToString()
end
local function find(path)
    local value = StaticFindObject(path)
    if not valid(value) and type(LoadAsset) == "function" then
        local ok, result = pcall(LoadAsset, path)
        if ok and valid(result) then value = result end
    end
    assert(valid(value), "Required object unavailable: " .. path)
    return value
end
local function params(class, name)
    for _ = 1, 12 do
        if not valid(class) then break end
        local result
        class:ForEachFunction(function(fn)
            if text(fn:GetFName()) == name then
                assert(not result, "Ambiguous function: " .. name)
                local fields = {}
                fn:ForEachProperty(function(property)
                    assert(property:GetOffset_Internal() < 0x200, "Unsupported argument extent")
                    fields[#fields + 1] = text(property:GetFName()) .. ":" .. text(property:GetClass():GetFName())
                end)
                result = table.concat(fields, ",")
            end
        end)
        if result then return result end
        class = class:GetSuperStruct()
    end
    error("Function unavailable: " .. name)
end

local function restore(reason)
    local errors = {}
    for i = #journal, 1, -1 do
        local row = journal[i]
        if row.dirty and valid(row.object) then
            local ok, why = pcall(function()
                row.object[row.field] = row.original
                assert(row.object[row.field] == row.original, "Restoration readback failed")
            end)
            if not ok then errors[#errors + 1] = row.name .. ": " .. tostring(why) end
        end
    end
    if #errors > 0 then error(table.concat(errors, "; ")) end
    if #journal > 0 then log("RESTORED properties=" .. #journal .. " reason=" .. reason) end
    journal, applied = {}, false
    if release_references then release_references() end
end
local function context(startup, entering)
    local sys = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not valid(sys) then return nil end
    local flags = {}; for flag in text(sys:GetCommandLine()):lower():gmatch("%S+") do flags[flag] = true end
    if not flags["-nobattleye"] or flags["-battleye"] then return nil end
    local library = StaticFindObject("/Script/DuneSandbox.Default__GUIBlueprintLibrary")
    if not valid(library) then return nil end
    local contract = params(library:GetClass(), "IsSoloPlay")
    assert(contract == "WorldContextObject:ObjectProperty,ReturnValue:BoolProperty" or contract == "ReturnValue:BoolProperty", "Solo contract changed")
    -- The game thread can load the world and restore persisted actors before a
    -- delayed callback gets another turn. InitGameState supplies the new world
    -- synchronously, before that restoration. Do not grant from this context.
    if valid(startup) and valid(startup:GetWorld()) then
        local solo
        if contract:find("WorldContextObject", 1, true) then solo = library:IsSoloPlay(startup) else solo = library:IsSoloPlay() end
        if solo == true then
            local world = startup:GetWorld():GetAddress()
            if entering then
                -- Only controllers already present when this verified Solo
                -- lifecycle starts can be treated as the departing world.
                departing_controllers = {}
                for _, pc in ipairs(FindAllOf("DunePlayerController") or {}) do
                    if valid(pc) and pc:IsLocalController() and valid(pc:GetWorld()) then
                        local previous = pc:GetWorld():GetAddress()
                        if previous ~= world then departing_controllers[pc:GetAddress()] = previous end
                    end
                end
            end
            local statics = find("/Script/Engine.Default__GameplayStatics")
            assert(params(statics:GetClass(), "GetGameInstance") == "WorldContextObject:ObjectProperty,ReturnValue:ObjectProperty", "GameInstance getter contract changed")
            local instance = statics:GetGameInstance(startup)
            assert(valid(instance), "Solo GameInstance unavailable")
            return {world=world, generation=generation, instance=instance}
        end
        return nil
    end
    local matches, worlds = {}, {}
    -- IsSoloPlay takes a WorldContextObject. The GameInstance is available before
    -- inventory/reward restoration; waiting for a controller can be too late.
    for _, instance in ipairs(FindAllOf("DuneGameInstance") or {}) do
        if valid(instance) and valid(instance:GetWorld()) then
            local solo
            if contract:find("WorldContextObject", 1, true) then solo = library:IsSoloPlay(instance) else solo = library:IsSoloPlay() end
            if solo == true then
                local world = instance:GetWorld():GetAddress()
                if not worlds[world] then worlds[world] = true; matches[#matches + 1] = {world=world, generation=generation, instance=instance} end
            end
        end
    end
    if #matches ~= 1 then return nil, "Solo instance worlds=" .. #matches end
    local session, locals = matches[1], 0
    for _, pc in ipairs(FindAllOf("DunePlayerController") or {}) do
        if valid(pc) and pc:IsLocalController() then
            -- A controller from the departing world can survive new-world
            -- initialization. It cannot receive a grant, but does not invalidate
            -- the independently verified Solo GameInstance's new world.
            if valid(pc:GetWorld()) and pc:GetWorld():GetAddress() == session.world then
                locals = locals + 1
                local solo
                if contract:find("WorldContextObject", 1, true) then solo = library:IsSoloPlay(pc) else solo = library:IsSoloPlay() end
                if solo ~= true then return nil, "current controller outside Solo" end
                assert(params(pc:GetClass(), "K2_GetPawn") == "ReturnValue:ObjectProperty", "Pawn getter contract changed")
                session.pc, session.pawn = pc, pc:K2_GetPawn()
            elseif not valid(pc:GetWorld()) or departing_controllers[pc:GetAddress()] ~= pc:GetWorld():GetAddress() then
                return nil, "unverified controller world"
            end
        end
    end
    if locals > 1 then return nil end
    return session
end

local function field(object, name, offset, types)
    local count, class = 0, object:GetClass()
    for _ = 1, 12 do
        if not valid(class) then break end
        class:ForEachProperty(function(property)
            if text(property:GetFName()) == name then
                local kind = text(property:GetClass():GetFName())
                assert(types[kind] and property:GetOffset_Internal() == offset, "Field layout changed: " .. name)
                count = count + 1
            end
        end)
        class = class:GetSuperStruct()
    end
    assert(count == 1, "Field not uniquely reflected: " .. name)
end
-- Lua UObject handles do not keep Unreal assets alive. Hold references through
-- the reflected GameInstance GC list for the verified Solo session, preserving
-- references owned by the engine and other mods. No root flags or raw offsets.
local function reference_list(owner)
    local count, class = 0, owner:GetClass()
    for _ = 1, 12 do
        if not valid(class) then break end
        class:ForEachProperty(function(property)
            if text(property:GetFName()) == "ReferencedObjects" then
                assert(text(property:GetClass():GetFName()) == "ArrayProperty", "Reference list layout changed")
                count = count + 1
            end
        end)
        class = class:GetSuperStruct()
    end
    assert(count == 1, "GameInstance reference list unavailable")
    local array, result = owner.ReferencedObjects, {}
    local length = array:GetArrayNum()
    assert(length >= 0 and length <= 4096, "Unsupported reference list length")
    array:ForEach(function(_, entry)
        local object = entry:get()
        assert(object ~= nil, "Unsupported reference list entry")
        result[#result + 1] = object
    end)
    assert(#result == length, "Reference list changed while reading")
    return result
end
local function write_references(owner, previous, desired)
    local ok, why = pcall(function()
        -- The pinned runtime reconstructs arrays when assigning a Lua table.
        -- Empty first to release its previous allocation, then verify each entry.
        owner.ReferencedObjects:Empty()
        owner.ReferencedObjects = desired
        local actual = reference_list(owner)
        assert(#actual == #desired, "Reference list count differs")
        for i, object in ipairs(desired) do
            assert(actual[i]:GetAddress() == object:GetAddress(), "Reference list readback differs")
        end
    end)
    if not ok then
        local restored, err = pcall(function()
            owner.ReferencedObjects:Empty()
            owner.ReferencedObjects = previous
        end)
        error(tostring(why) .. (restored and "" or " REFERENCE RESTORE ERROR " .. tostring(err)))
    end
end
local function retain(owner, object)
    assert(valid(owner) and valid(object), "Invalid Solo lifetime reference")
    local address, key = object:GetAddress(), owner:GetAddress()
    local owned = references[key]
    if not owned or not valid(owned.owner) then owned = {owner=owner, objects={}}; references[key] = owned end
    local previous = reference_list(owner)
    for _, existing in ipairs(previous) do if existing:GetAddress() == address then return end end
    local desired = {}; for _, existing in ipairs(previous) do desired[#desired + 1] = existing end
    desired[#desired + 1] = object
    owned.objects[address] = object -- record intent before changing engine memory
    write_references(owner, previous, desired)
end
release_references = function()
    for _, owned in pairs(references) do
        if valid(owned.owner) then
            local previous, desired = reference_list(owned.owner), {}
            for _, object in ipairs(previous) do
                local ours = owned.objects[object:GetAddress()]
                if not ours or not valid(ours) then desired[#desired + 1] = object end
            end
            if #desired ~= #previous then write_references(owned.owner, previous, desired) end
        end
    end
    references = {}
end
local function stage(plan, previous, object, name, desired)
    local original = object[name]
    if name == "m_ActionType" then
        assert(type(original) == "number" and original % 1 == 0 and original >= 0 and original <= 3, "Unsupported action mask")
    else assert(type(original) == "boolean", "Unsupported exclusive flag") end
    local fullname = object:GetFullName()
    local prior = previous[fullname .. ":" .. name]
    local retained = prior and valid(prior.object) and prior.object:GetAddress() == object:GetAddress()
    if retained then original = prior.original; prior.retained = true end
    plan[#plan + 1] = {object=object, field=name, original=original,
        desired=desired, name=fullname, dirty=retained and prior.dirty or false}
end
local function apply(session)
    local previous, plan = {}, {}
    for _, row in ipairs(journal) do
        row.retained = false
        previous[row.name .. ":" .. row.field] = row
    end
    local actions = 0
    for _, reward in ipairs(REWARDS) do
        local asset = find(reward.path)
        assert(asset:GetFullName() == "DunePlayerRewardsActionsDataAsset " .. reward.path, "Unexpected reward asset")
        field(asset, "m_bIsExclusiveToPlayerRewards", 0xa8, {BoolProperty=true})
        retain(session.instance, asset)
        stage(plan, previous, asset, "m_bIsExclusiveToPlayerRewards", false)
        for _, spec in ipairs(reward.actions) do
            local path = reward.path .. ":" .. spec.name
            local action = find(path)
            assert(action:GetFullName() == spec.class .. " " .. path, "Unexpected reward action")
            field(action, "m_ActionType", 0x28, {IntProperty=true, EnumProperty=true, ByteProperty=true})
            retain(session.instance, action)
            stage(plan, previous, action, "m_ActionType", 1)
            actions = actions + 1
        end
    end
    -- Reacquire engine-owned objects after reloads. Preserve restoration values
    -- for surviving objects, and cover both generations if a write fails.
    local retired = {}
    for _, row in ipairs(journal) do if not row.retained then retired[#retired + 1] = row end end
    journal = {}
    for _, row in ipairs(retired) do journal[#journal + 1] = row end
    for _, row in ipairs(plan) do journal[#journal + 1] = row end
    -- All target identities, layouts and values verified before any write.
    local changed = 0
    for _, row in ipairs(plan) do
        if row.object[row.field] ~= row.desired then
            row.dirty = true -- journal write intent before mutation
            row.object[row.field] = row.desired
            changed = changed + 1
        end
        assert(row.object[row.field] == row.desired, "Blanket readback failed: " .. row.name)
    end
    for _, row in ipairs(retired) do
        if row.dirty and valid(row.object) then
            row.object[row.field] = row.original
            assert(row.object[row.field] == row.original, "Retired object restoration failed: " .. row.name)
        end
    end
    journal = plan
    applied = true
    log("ACTIVE Solo assets=" .. #REWARDS .. " actions=" .. actions .. " exclusive=false action=1 writes=" .. changed .. "; manual grants only")
end
local blocked_world
local function step(startup)
    if stopped then return nil end
    local ok, session = pcall(function()
        local current, reason = context(startup, startup ~= nil)
        if not current or current.world == blocked_world then
            restore("outside verified Solo" .. (reason and ": " .. reason or ""))
            world_address = nil
            return nil
        end
        -- Reward definitions are global assets. A verified Solo-to-Solo world
        -- transition must not briefly restore restrictions during actor loading.
        world_address = current.world
        if not applied then apply(current) end
        -- An ACTIVE log is historical evidence, not proof that the same asset
        -- objects and values still exist after loading or another mod's work.
        for _, row in ipairs(journal) do
            local alive = valid(row.object)
            local value = alive and row.object[row.field]
            if not alive or value ~= row.desired then
                log("REFRESH " .. (alive and "value=" .. tostring(value) or "object invalid") ..
                    " field=" .. row.field .. " target=" .. row.name)
                apply(current)
                break
            end
        end
        return current
    end)
    if not ok then
        local restored, err = pcall(restore, "reward settings error")
        stopped = true
        failure = "Solo grant support could not initialize. Check the Solo runtime log and update DST before granting."
        log("DISABLED " .. tostring(session) .. (restored and "" or " RESTORE ERROR " .. tostring(err)))
        return nil
    end
    return session
end
if type(RegisterInitGameStatePreHook) == "function" then
    RegisterInitGameStatePreHook(function(context_parameter)
        if stopped then return end
        local ok, startup, address = pcall(function()
            local object = context_parameter:get()
            if not valid(object) then return nil end
            local world = object:GetWorld()
            return object, valid(world) and world:GetAddress() or nil
        end)
        if not ok or not valid(startup) or not address then
            local restored, why = pcall(restore, "invalid game-state startup context")
            stopped = true
            failure = "Solo reward startup could not be verified. Close Dune and check the Solo runtime log."
            log("DISABLED invalid game-state startup context" .. (restored and "" or " RESTORE ERROR " .. tostring(why)))
            return
        end
        if startup_seen and valid(startup_seen.object) and startup_seen.object:GetAddress() == startup:GetAddress() and startup_seen.world == address and startup_seen.active == applied then return end
        startup_seen = {object=startup, world=address}
        generation = generation + 1
        blocked_world = nil -- a new lifecycle can reuse a previous UWorld address
        local session = step(startup)
        startup_seen.active = applied
        log("GAMESTATE PRE " .. (session and "verified Solo settings applied" or "outside verified Solo"))
    end)
else
    stopped = true
    failure = "The selected Solo runtime does not support early reward initialization. Update DST before granting."
    log("DISABLED game-state startup hook unavailable")
end
NotifyOnNewObject("/Script/DuneSandbox.MainMenuHomeWidget", function(widget)
    -- Object construction is not proof that the menu is active. Loading Solo
    -- can hold up this callback until after synchronous GameMode initialization.
    -- Bind it to the lifecycle that scheduled it, never the world it finds later.
    local observed_generation, observed_world = generation, world_address
    ExecuteInGameThreadWithDelay(0, function()
        if observed_generation ~= generation or observed_world ~= world_address then return end
        if not valid(widget) then return end
        local ok, menu_world, solo = pcall(function()
            local world = widget:GetWorld()
            if not valid(world) then return nil end
            local current = context(widget)
            return world:GetAddress(), current ~= nil
        end)
        if not ok then
            -- Do not treat an unreadable constructor notification as a menu
            -- transition. The normal verified-context check remains authoritative.
            log("MENU context unavailable; retaining lifecycle verification")
            return
        end
        if not menu_world or (world_address and menu_world ~= world_address) or solo then return end
        blocked_world = world_address
        local restored, why = pcall(restore, "verified menu transition")
        world_address = nil
        if not restored then stopped = true; failure = "Solo reward settings could not be restored. Close Dune before changing sessions."; log("DISABLED " .. tostring(why)) end
    end)
end)
return {step=step, valid=valid, text=text, find=find, params=params, field=field, failure=function()return failure end}
