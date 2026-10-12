using System.Text.Json;
using System.Text.Json.Nodes;

namespace DuneSoloDb;

internal static partial class Program
{
    private static object EnableAllSkills(string input, string safetyBackup, string adapterPath, string skillsPath, string? tagsPath = null)
    {
        // Fixture callers exercise skills independently; the product command requires the trainer catalog.
        if (tagsPath is null) return EnableAllSkillsCore(input, safetyBackup, adapterPath, skillsPath);
        var original = ReadStable(input);
        var root = Path.Combine(Path.GetTempPath(), "dune-solo-trainer-skills-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var stage = Path.Combine(root,"game.db");
            File.WriteAllBytes(stage,original);
            foreach (var job in new[] { "Swordmaster", "Trooper", "Mentat", "BeneGesserit", "Planetologist" })
                UnlockTrainer(stage,Path.Combine(root,job+"-before.db"),adapterPath,tagsPath,job);
            EnableAllSkillsCore(stage,Path.Combine(root,"skills-before.db"),adapterPath,skillsPath);
            if (!ReadStable(input).SequenceEqual(original)) throw new IOException("Solo save changed while preparing trainer and skill unlocks.");
            Restore(stage,input,safetyBackup,requireGameClosed:true);
            return new { ok=true, action="enable-all-skills", safetyBackup, trainers=5, inspection=InspectPath(input) };
        }
        finally { Directory.Delete(root,true); }
    }

    private static void SelfTestTrainers(string root, string target, string adapterPath, string skillsPath)
    {
        var catalog = Path.Combine(root, "trainer-tags.json");
        File.WriteAllText(catalog, """
            {"contract_tags":{"DA_CT_Trainer_Mentat1_01":["Trainer.Mentat.Complete"]},
             "contract_remove_tags":{"DA_CT_Trainer_Mentat1_01":["Trainer.Mentat.Active"]},
             "contract_skill_grants":{"DA_CT_Trainer_Mentat1_01":["Skills.Attribute.TrainerTest"]},
             "job_skill_blocks":{"Mentat":["Skills.Key.Mentat1"]}}
            """);
        var original = File.ReadAllBytes(target);
        var seed = Path.Combine(root,"trainer-seed.sqlite");
        File.WriteAllBytes(seed,Unwrap(original).SqliteBytes);
        using (var db = OpenWritable(seed))
        {
            var identity=ReadIdentity(db);
            ExecuteNonQuery(db,"INSERT INTO player_tags(character_id,tag) VALUES($id,'Trainer.Mentat.Active'),($id,'Trainer.Unrelated');",("$id",identity.CharacterId));
            ExecuteNonQuery(db,"INSERT INTO inventories(id,actor_id,inventory_type) VALUES(999201,$pawn,29),(999202,20,29);",("$pawn",identity.PawnId));
            ExecuteNonQuery(db,"""
                INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats)
                VALUES(999001,999201,1,0,'ContractItem',jsonb('{"FContractItemStats":[0,{"ContractName":{"Name":"Trainer_Mentat1_01"}}]}')),
                      (999002,999202,1,0,'ContractItem',jsonb('{"FContractItemStats":[0,{"ContractName":{"Name":"Trainer_Mentat1_01"}}]}'));
                """);
            var components=ReadFglComponents(db,identity.EntityId);
            var level=RequireComponentObject(components,"FLevelComponent");
            var modules=level["ModuleData"] as JsonObject ?? new JsonObject();
            level["ModuleData"]=modules;
            modules["(TagName=\"Skills.Key.Mentat1\")"]=new JsonObject { ["SkillPointsSpent"]=5,["UnrelatedMetadata"]="kept" };
            WriteFglComponents(db,identity.EntityId,components);
            var properties=ReadActorProperties(db,identity.PawnId);
            properties["ContractsCoordinatorComponent"]=new JsonObject { ["m_TrackedContractItemUid"]="!!itm#999001",["OtherKey"]="kept" };
            WriteActorProperties(db,identity.PawnId,properties);
        }
        WrapSqlite(seed,target);
        var before = File.ReadAllBytes(target);
        var backup = Path.Combine(root, "safety", "before-trainer.db");
        UnlockTrainer(target, backup, adapterPath, catalog, "Mentat");
        if (!File.ReadAllBytes(backup).SequenceEqual(before)) throw new InvalidOperationException("Trainer backup was not exact.");
        var stable = File.ReadAllBytes(target);
        try { UnlockTrainer(target, Path.Combine(root,"bad-trainer.db"), adapterPath, catalog, "Unknown"); throw new InvalidOperationException("Unknown trainer accepted."); }
        catch (ArgumentException) { }
        if (!File.ReadAllBytes(target).SequenceEqual(stable)) throw new InvalidOperationException("Rejected trainer changed the save.");
        UnlockTrainer(target, Path.Combine(root,"repeat-trainer.db"), adapterPath, catalog, "Mentat");
        var wrapped = Unwrap(File.ReadAllBytes(target));
        var sqlite = Path.Combine(root,"trainer-verify.sqlite");
        File.WriteAllBytes(sqlite,wrapped.SqliteBytes);
        using (var db = OpenWritable(sqlite))
        {
            var identity=ReadIdentity(db);
            if (ScalarLong(db,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag='Trainer.Mentat.Complete';",("$id",identity.CharacterId))!=1)
                throw new InvalidOperationException("Trainer tags were missing or duplicated.");
            if (ScalarLong(db,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag='Trainer.Mentat.Active';",("$id",identity.CharacterId))!=0
                || ScalarLong(db,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag='Trainer.Unrelated';",("$id",identity.CharacterId))!=1
                || ScalarLong(db,"SELECT COUNT(*) FROM items WHERE id=999001;")!=0
                || ScalarLong(db,"SELECT COUNT(*) FROM items WHERE id=999002;")!=1)
                throw new InvalidOperationException("Trainer mutation did not preserve unrelated data or dismiss only its own contract.");
            var modules=RequireComponentObject(ReadFglComponents(db,identity.EntityId),"FLevelComponent")["ModuleData"] as JsonObject;
            if (GetInt(modules?["(TagName=\"Skills.Key.Mentat1\")"] as JsonObject,"SkillPointsSpent")!=5
                || modules?["(TagName=\"Skills.Key.Mentat1\")"]?["UnrelatedMetadata"]?.GetValue<string>()!="kept")
                throw new InvalidOperationException("Trainer unlock lowered skills or dropped metadata.");
            var coordinator=ReadActorProperties(db,identity.PawnId)["ContractsCoordinatorComponent"];
            if(coordinator?["m_TrackedContractItemUid"]?.GetValue<string>()!="!!itm#0" || coordinator?["OtherKey"]?.GetValue<string>()!="kept")
                throw new InvalidOperationException("Trainer tracked contract cleanup failed.");
        }
        var jobs = new[] { "Swordmaster", "Trooper", "Mentat", "BeneGesserit", "Planetologist" };
        var allTags = jobs.ToDictionary(j=>"DA_CT_Trainer_"+j+"1_01",j=>new[]{"Trainer."+j+".Complete"});
        var allBlocks = jobs.ToDictionary(j=>j,j=>new[]{"Skills.Key."+j+"1"});
        var combinedBefore=File.ReadAllBytes(target);
        var combinedBackup=Path.Combine(root,"safety","combined-trainers.db");
        allTags.Remove("DA_CT_Trainer_Planetologist1_01");
        File.WriteAllText(catalog,JsonSerializer.Serialize(new { contract_tags=allTags,job_skill_blocks=allBlocks }));
        try { EnableAllSkills(target,combinedBackup,adapterPath,skillsPath,catalog); throw new InvalidOperationException("Incomplete trainer catalog accepted."); }
        catch(InvalidDataException) { }
        if(!File.ReadAllBytes(target).SequenceEqual(combinedBefore) || File.Exists(combinedBackup))
            throw new InvalidOperationException("Failed combined unlock changed the live target or created a misleading backup.");
        allTags["DA_CT_Trainer_Planetologist1_01"]=["Trainer.Planetologist.Complete"];
        File.WriteAllText(catalog,JsonSerializer.Serialize(new { contract_tags=allTags,job_skill_blocks=allBlocks }));
        EnableAllSkills(target,combinedBackup,adapterPath,skillsPath,catalog);
        if(!File.ReadAllBytes(combinedBackup).SequenceEqual(combinedBefore)) throw new InvalidOperationException("Combined unlock backup was not exact.");
        File.WriteAllBytes(sqlite,Unwrap(File.ReadAllBytes(target)).SqliteBytes);
        using(var db=OpenWritable(sqlite))
        {
            var identity=ReadIdentity(db);
            if(jobs.Any(j=>ScalarLong(db,"SELECT COUNT(*) FROM player_tags WHERE character_id=$id AND tag=$tag;",("$id",identity.CharacterId),("$tag","Trainer."+j+".Complete"))!=1))
                throw new InvalidOperationException("Enable all skills did not unlock all five trainers.");
        }
        File.WriteAllBytes(target,original);
    }

    private static object UnlockTrainer(string input, string safetyBackup, string adapterPath, string tagsPath, string job)
    {
        if (job is not ("Swordmaster" or "Trooper" or "Mentat" or "BeneGesserit" or "Planetologist"))
            throw new ArgumentException("Choose a supported trainer.");
        var adapter = ReadSoloAdapter(adapterPath);
        AssertProgressionAdapter(input, adapter);
        using var document = JsonDocument.Parse(File.ReadAllText(tagsPath));
        var catalog = document.RootElement;
        var contracts = catalog.GetProperty("contract_tags").EnumerateObject()
            .Where(p => p.Name.StartsWith("DA_CT_Trainer_" + job, StringComparison.Ordinal)
                && p.Name.Length > ("DA_CT_Trainer_" + job).Length
                && char.IsDigit(p.Name[("DA_CT_Trainer_" + job).Length]))
            .Select(p => p.Name).ToArray();
        if (contracts.Length == 0) throw new InvalidDataException("Trainer contracts are missing from the catalog.");
        string[] Values(string group, string key) => catalog.TryGetProperty(group, out var section)
            && section.TryGetProperty(key, out var values)
                ? values.EnumerateArray().Select(v => v.GetString() ?? throw new InvalidDataException("Invalid trainer catalog tag.")).ToArray()
                : [];
        var tags = contracts.SelectMany(c => Values("contract_tags", c)).Distinct(StringComparer.Ordinal).ToArray();
        var remove = contracts.SelectMany(c => Values("contract_remove_tags", c)).Distinct(StringComparer.Ordinal).ToArray();
        var skills = Values("job_skill_blocks", job).Concat(contracts.SelectMany(c => Values("contract_skill_grants", c)))
            .Distinct(StringComparer.Ordinal).ToArray();
        if (skills.Length == 0 || tags.Length == 0 || tags.Any(t => t.StartsWith("Faction.", StringComparison.Ordinal)))
            throw new InvalidDataException("Trainer catalog is incomplete or requires unsupported faction changes.");
        return RunProgressionMutation(input, safetyBackup, "unlock-trainer", sqlitePath =>
        {
            using var db = OpenWritable(sqlitePath);
            var identity = ReadIdentity(db);
            BeginImmediate(db);
            try
            {
                foreach (var tag in remove)
                    ExecuteNonQuery(db, "DELETE FROM player_tags WHERE character_id=$character AND tag=$tag;", ("$character", identity.CharacterId), ("$tag", tag));
                foreach (var tag in tags)
                    ExecuteNonQuery(db, "INSERT INTO player_tags(character_id,tag) VALUES($character,$tag) ON CONFLICT(character_id,tag) DO NOTHING;", ("$character", identity.CharacterId), ("$tag", tag));
                var components = ReadFglComponents(db, identity.EntityId);
                var level = RequireComponentObject(components, "FLevelComponent");
                var modules = level["ModuleData"] as JsonObject ?? new JsonObject();
                level["ModuleData"] = modules;
                foreach (var skill in skills)
                {
                    var key = "(TagName=\"" + skill + "\")";
                    var module = modules[key] as JsonObject ?? new JsonObject();
                    module["SkillPointsSpent"] = Math.Max(GetInt(module, "SkillPointsSpent"), 1);
                    modules[key] = module;
                }
                WriteFglComponents(db, identity.EntityId, components);
                var dismissed = 0;
                foreach (var contract in contracts)
                    dismissed += ExecuteNonQuery(db, """
                        DELETE FROM items WHERE template_id='ContractItem'
                        AND inventory_id IN (SELECT id FROM inventories WHERE actor_id=$pawn AND inventory_type=29)
                        AND json_extract(stats,'$.FContractItemStats[1].ContractName.Name')=$name;
                        """, ("$pawn", identity.PawnId), ("$name", contract[6..]));
                var properties = ReadActorProperties(db, identity.PawnId);
                if (properties["ContractsCoordinatorComponent"] is JsonObject coordinator
                    && coordinator["m_TrackedContractItemUid"] is JsonValue tracked
                    && tracked.TryGetValue<string>(out var uid) && uid != "!!itm#0")
                {
                    if (!uid.StartsWith("!!itm#", StringComparison.Ordinal) || !long.TryParse(uid[6..], out var item))
                        throw new InvalidDataException("Unsupported tracked contract identity; no changes saved.");
                    if (ScalarLong(db, "SELECT COUNT(*) FROM items WHERE id=$id;", ("$id", item)) == 0)
                    {
                        coordinator["m_TrackedContractItemUid"] = "!!itm#0";
                        WriteActorProperties(db, identity.PawnId, properties);
                    }
                }
                var verified = RequireComponentObject(ReadFglComponents(db, identity.EntityId), "FLevelComponent")["ModuleData"] as JsonObject;
                if (skills.Any(s => GetInt(verified?["(TagName=\"" + s + "\")"] as JsonObject, "SkillPointsSpent") < 1)
                    || tags.Any(t => ScalarLong(db, "SELECT COUNT(*) FROM player_tags WHERE character_id=$character AND tag=$tag;", ("$character", identity.CharacterId), ("$tag", t)) != 1)
                    || remove.Except(tags).Any(t => ScalarLong(db, "SELECT COUNT(*) FROM player_tags WHERE character_id=$character AND tag=$tag;", ("$character", identity.CharacterId), ("$tag", t)) != 0))
                    throw new InvalidDataException("Trainer unlock verification failed.");
                ValidateDatabase(db);
                Commit(db);
                return new { job, contracts = contracts.Length, tags = tags.Length, skills = skills.Length, dismissed };
            }
            catch { Rollback(db); throw; }
        }, requireGameClosed: true);
    }
}
