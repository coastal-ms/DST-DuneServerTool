# Dune: Awakening — CheatScript Reference

Cheat scripts are named sequences of in-game **console commands**. The server
runs one by name when it receives a `CheatScript` `ServerCommand` over RabbitMQ
(see `Invoke-DuneRmqCheatScript` in `app/server/lib/Rmq.ps1`, exposed by DST as
the **Gameplay Admin → Live → Cheat Script** action). Each `+Cmd=` line is a
single console command executed in order against the target player.

These definitions are transcribed from the game's INI
(`docs/Dune_Server_INI_Field_Sheet.md`, sections `[CheatScript.*]`). They reflect
what the game server itself ships — DST cannot invent new scripts, it can only
invoke ones the server already defines (or send the individual underlying
`ServerCommand`s it wraps).

> **Note on "Intel" / Tech Knowledge:** none of the documented cheat scripts or
> console verbs grant Intel (`m_TechKnowledgePoints`). The only documented
> progression verbs are `AwardXP`, `SkillsSetModuleLevel`,
> `SkillsSetUnspentSkillPoints`, and `ResetProgression`. There is no
> `AwardIntel`/`GiveTechKnowledge` console command in this reference.

---

## CheatScript catalog

### LeaveMeAlone
Clears nearby threats and disables environmental hazards.

```ini
+Cmd=EncountersDestroyAndDisableAll
+Cmd=DestroyAllNpcs
+Cmd=SetAutoSandstormSpawnEnabled 0
+Cmd=DestroyAllSandStorms
+Cmd=ServerExec sandworm.dune.Enabled 0
```

### StartHitchVehicleTest
Performance/hitch test harness — forces frame hitches and unsteady FPS.

```ini
+Cmd=ServerExec t.maxfps 20
+Cmd=ServerExec CauseHitchesPeriod 10
+Cmd=ServerExec CauseHitchesHitchMS 1000
+Cmd=ServerExec CauseHitches 1
+Cmd=ServerExec t.UnsteadyFps 1
+Cmd=CauseHitchesPeriod 20
+Cmd=CauseHitchesHitchMS 200
+Cmd=CauseHitches 1
+Cmd=t.UnsteadyFps 1
```

### StopHitchVehicleTest
Reverts `StartHitchVehicleTest`.

```ini
+Cmd=ServerExec t.maxfps 0
+Cmd=ServerExec CauseHitches 0
+Cmd=ServerExec t.UnsteadyFps 0
+Cmd=CauseHitches 0
+Cmd=t.UnsteadyFps 0
```

### PlaytestSetup
Full playtest loadout — resets progression, refills the player, grants a large
weapon/armor/consumable kit, awards XP, unlocks all skills, sets skill points,
and completes the intro quest. Items are referenced by **display name** with the
class string in parentheses.

```ini
+Cmd=ResetProgression
+Cmd=CleanPlayerInventory
+Cmd=AddItemToInventory HouseLMG(AtreLMG3) 1 1
+Cmd=AddItemToInventory HouseKarpov38BattleRifle(HarkAr5) 1 1
+Cmd=AddItemToInventory HouseJABALSpitdartRifle(SmugDmr4) 1 1
+Cmd=AddItemToInventory AlumniumGRDA44Scattergun(Scattergun_Prototype1) 1 1
+Cmd=AddItemToInventory HouseCHOAMSword(CHOAMSword_1) 1 1
+Cmd=AddItemToInventory HealthPack_Channeled_3 20
+Cmd=AddItemToInventory IndustrialHighCapacityWaterTank(HighCapacityLiterjon_04) 1 1
+Cmd=UpdateAllWaterFillables 2500
+Cmd=AddItemToInventory RespawnBeacon(RespawnBeacon) 2 1
+Cmd=AddItemToInventory AdeptArhunK-28Lasgun(ChoamLg1) 1 1
+Cmd=AddItemToInventory IndustrialCutteray(MiningTool_2h_Heavy) 1 1
+Cmd=AddItemToInventory AlumiteHeavyHelmet(Combat_Choam_Heavy01_Helmet) 1 1
+Cmd=AddItemToInventory AlumiteHeavyTop(Combat_Choam_Heavy01_Top) 1 1
+Cmd=AddItemToInventory AlumiteHeavyBottom(Combat_Choam_Heavy01_Bottom) 1 1
+Cmd=AddItemToInventory AlumiteHeavyGloves(Combat_Choam_Heavy01_Gloves) 1 1
+Cmd=AddItemToInventory AlumiteHeavyBoots(Combat_Choam_Heavy01_Boots) 1 1
+Cmd=AddItemToInventory AdvancedHoltzmanShield(HoltzmanShieldActiveDrain2) 1 1
+Cmd=AddItemToInventory FullReductionBelt(FullSuspensorBelt) 1 1
+Cmd=AddItemToInventory IndustrialPowerPack(PowerPack3) 1 1
+Cmd=AddItemToInventory Ammo 1000
+Cmd=AddItemToInventory HeavyAmmo 1000
+Cmd=AddItemToInventory ConstructionTool(BasicBuildingTool) 1 1
+Cmd=AddItemToInventory HouseRafiqSnubnosePistol(HarkHeavyPistol3) 1 1
+Cmd=AddItemToInventory HouseSavoy&MirtM11SMG(AtreSmg4) 1 1
+Cmd=AddItemToInventory HouseElephantGun(SmugShot3) 1 1
+Cmd=CheatScript AwardPlayerXP
+Cmd=CheatScript UnlockAllSkills
+Cmd=SkillsSetUnspentSkillPoints 104
+Cmd=JourneyCompleteTaskByName DA_MQ_ANewBeginning
```

### PlaytestSetupAdmin
Same as `PlaytestSetup` but items are referenced by **class string only** (no
display-name wrapper).

```ini
+Cmd=ResetProgression
+Cmd=CleanPlayerInventory
+Cmd=AddItemToInventory AtreLMG3 1 1
+Cmd=AddItemToInventory HarkAr5 1 1
+Cmd=AddItemToInventory SmugDmr4 1 1
+Cmd=AddItemToInventory Scattergun_Prototype1 1 1
+Cmd=AddItemToInventory CHOAMSword_1 1 1
+Cmd=AddItemToInventory HealthPack_Channeled_3 20
+Cmd=AddItemToInventory HighCapacityLiterjon_04 1 1
+Cmd=UpdateAllWaterFillables 2500
+Cmd=AddItemToInventory RespawnBeacon 2 1
+Cmd=AddItemToInventory ChoamLg1 1 1
+Cmd=AddItemToInventory MiningTool_2h_Heavy 1 1
+Cmd=AddItemToInventory Combat_Choam_Heavy01_Helmet 1 1
+Cmd=AddItemToInventory Combat_Choam_Heavy01_Top 1 1
+Cmd=AddItemToInventory Combat_Choam_Heavy01_Bottom 1 1
+Cmd=AddItemToInventory Combat_Choam_Heavy01_Gloves 1 1
+Cmd=AddItemToInventory Combat_Choam_Heavy01_Boots 1 1
+Cmd=AddItemToInventory HoltzmanShieldActiveDrain2 1 1
+Cmd=AddItemToInventory FullSuspensorBelt 1 1
+Cmd=AddItemToInventory PowerPack3 1 1
+Cmd=AddItemToInventory Ammo 1000
+Cmd=AddItemToInventory HeavyAmmo 1000
+Cmd=AddItemToInventory BasicBuildingTool 1 1
+Cmd=AddItemToInventory HarkHeavyPistol3 1 1
+Cmd=AddItemToInventory AtreSmg4 1 1
+Cmd=AddItemToInventory SmugShot3 1 1
+Cmd=CheatScript AwardPlayerXP
+Cmd=CheatScript UnlockAllSkills
+Cmd=SkillsSetUnspentSkillPoints 104
+Cmd=JourneyCompleteTaskByName DA_MQ_ANewBeginning
```

### AwardPlayerXP
Grants 10,000 XP in each of the three categories.

```ini
+Cmd=AwardXP Combat 10000
+Cmd=AwardXP Exploration 10000
+Cmd=AwardXP Science 10000
```

### UnlockAllSkills
Sets every key skill module and capstone to level 1.

```ini
+Cmd=SkillsSetModuleLevel Skills.Key.Trooper1 1
+Cmd=SkillsSetModuleLevel Skills.Key.Trooper2 1
+Cmd=SkillsSetModuleLevel Skills.Key.Trooper3 1
+Cmd=SkillsSetModuleLevel Skills.Key.Swordmaster1 1
+Cmd=SkillsSetModuleLevel Skills.Key.Swordmaster2 1
+Cmd=SkillsSetModuleLevel Skills.Key.Swordmaster3 1
+Cmd=SkillsSetModuleLevel Skills.Key.Planetologist1 1
+Cmd=SkillsSetModuleLevel Skills.Key.Planetologist2 1
+Cmd=SkillsSetModuleLevel Skills.Key.Planetologist3 1
+Cmd=SkillsSetModuleLevel Skills.Key.Mentat1 1
+Cmd=SkillsSetModuleLevel Skills.Key.Mentat2 1
+Cmd=SkillsSetModuleLevel Skills.Key.Mentat3 1
+Cmd=SkillsSetModuleLevel Skills.Key.BeneGesserit1 1
+Cmd=SkillsSetModuleLevel Skills.Key.BeneGesserit2 1
+Cmd=SkillsSetModuleLevel Skills.Key.BeneGesserit3 1
+Cmd=SkillsSetModuleLevel Skills.Key.Dev1 1
+Cmd=SkillsSetModuleLevel Skills.Key.Dev2 1
+Cmd=SkillsSetModuleLevel Skills.Key.Dev3 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneWeirdingWay 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneWeaponry 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneTactician 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneSuspensorTech 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneSelfControl 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneScientist 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneResolve 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneMentalCalculus 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneManipulation 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneGadgets 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneExplorer 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneDriver 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneBlade 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneAssassination 1
+Cmd=SkillsSetModuleLevel Skills.Key.CapstoneAggression 1
```

### UnlockAllAbilities
Sets every ability module to level 1.

```ini
+Cmd=SkillsSetModuleLevel Skills.Ability.Blindspot 1
+Cmd=SkillsSetModuleLevel Skills.Ability.DeflectionSlow 1
+Cmd=SkillsSetModuleLevel Skills.Ability.ExplosiveMine 1
+Cmd=SkillsSetModuleLevel Skills.Ability.FragGrenade 1
+Cmd=SkillsSetModuleLevel Skills.Ability.HealingCapsule 1
+Cmd=SkillsSetModuleLevel Skills.Ability.HunterSeeker 1
+Cmd=SkillsSetModuleLevel Skills.Ability.Hypersprint 1
+Cmd=SkillsSetModuleLevel Skills.Ability.KneeCharge 1
+Cmd=SkillsSetModuleLevel Skills.Ability.MagneticAttractor 1
+Cmd=SkillsSetModuleLevel Skills.Ability.PoisonCapsuleLauncher 1
+Cmd=SkillsSetModuleLevel Skills.Ability.RiposteBreak 1
+Cmd=SkillsSetModuleLevel Skills.Ability.RiposteInjure 1
+Cmd=SkillsSetModuleLevel Skills.Ability.SolidoDecoy.Moving 1
+Cmd=SkillsSetModuleLevel Skills.Ability.SuspensorGrenade_Amplification 1
+Cmd=SkillsSetModuleLevel Skills.Ability.SuspensorGrenade_Reduction 1
+Cmd=SkillsSetModuleLevel Skills.Ability.SuspensorMine_Amplification 1
+Cmd=SkillsSetModuleLevel Skills.Ability.SuspensorMine_Reduction 1
+Cmd=SkillsSetModuleLevel Skills.Ability.SuspensorWall 1
+Cmd=SkillsSetModuleLevel Skills.Ability.VoiceCompel 1
+Cmd=SkillsSetModuleLevel Skills.Ability.WeirdingStep 1
```

---

## Console-command verbs used

Every distinct `+Cmd=` verb across the cheat scripts above:

| Verb | Purpose |
| --- | --- |
| `AddItemToInventory <class> <qty> [quality]` | Give an item (class string) to the player. |
| `AwardXP <Category> <amount>` | Grant category XP (Combat / Exploration / Science). |
| `CheatScript <Name>` | Run another named cheat script. |
| `CleanPlayerInventory` | Wipe the player's inventory. |
| `ResetProgression` | Reset character progression. |
| `SkillsSetModuleLevel <Skill> <level>` | Set a skill/ability module level. |
| `SkillsSetUnspentSkillPoints <n>` | Set unspent skill points. |
| `UpdateAllWaterFillables <amount>` | Refill all water containers. |
| `JourneyCompleteTaskByName <Task>` | Force-complete a journey/quest task. |
| `SetAutoSandstormSpawnEnabled <0\|1>` | Toggle automatic sandstorm spawning. |
| `DestroyAllSandStorms` | Clear active sandstorms. |
| `DestroyAllNpcs` | Despawn all NPCs. |
| `EncountersDestroyAndDisableAll` | Destroy + disable all encounters. |
| `CauseHitches[Period\|HitchMS] <n>` | Performance-test hitch injection. |
| `t.UnsteadyFps <0\|1>` | Performance-test unsteady FPS. |
| `ServerExec <command>` | Run an arbitrary server console command/cvar. |

Source: `docs/Dune_Server_INI_Field_Sheet.md`, sections `[CheatScript.*]` (lines 1632–1807).
