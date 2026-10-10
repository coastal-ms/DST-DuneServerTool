using System.Text.Json;
using System.Text.Json.Nodes;

namespace DuneSoloDb;

internal static partial class Program
{
    private static object ChangeCharacterXp(string input, string backup, string adapterPath,
        string levelsPath, string action, long amount)
    {
        if (action is not ("add" or "set")) throw new ArgumentException("Choose Add or Set character XP.");
        if (amount < 0 || amount > 344440) throw new ArgumentException("Character XP must be between 0 and 344440.");
        AssertProgressionAdapter(input, ReadSoloAdapter(adapterPath));
        var thresholds = JsonSerializer.Deserialize<long[]>(File.ReadAllText(levelsPath))
            ?? throw new InvalidDataException("Character XP catalog is missing.");
        if (thresholds.Length != 201 || thresholds[0] != 0 || thresholds[^1] != 344440
            || thresholds.Zip(thresholds.Skip(1)).Any(pair => pair.First >= pair.Second))
            throw new InvalidDataException("Character XP catalog is invalid.");
        int Level(long xp) => Math.Max(0, Array.FindLastIndex(thresholds, threshold => threshold <= xp));
        return RunProgressionMutation(input, backup, "character-xp", path =>
        {
            using var db = OpenWritable(path);
            var identity = ReadIdentity(db);
            BeginImmediate(db);
            try
            {
                var components = ReadFglComponents(db, identity.EntityId);
                var level = RequireComponentObject(components, "FLevelComponent");
                if (level["TotalXPEarned"] is not JsonValue xpNode || !xpNode.TryGetValue<long>(out var current)
                    || current < 0 || current > 344440)
                    throw new InvalidDataException("Saved character XP is missing or outside the supported range.");
                var xp = action == "add" ? Math.Min(344440, current + amount) : amount;
                var oldLevel = Level(current);
                var newLevel = Level(xp);
                int RequirePoints(JsonObject component, string key)
                {
                    if (component[key] is not JsonValue value || !value.TryGetValue<int>(out var points) || points < 0)
                        throw new InvalidDataException($"Saved {key} is missing or invalid.");
                    return points;
                }
                var total = RequirePoints(level, "TotalSkillPoints");
                var unspent = RequirePoints(level, "UnspentSkillPoints");
                var bonus = RequirePoints(level, "KeystoneBonusSkillPoints");
                var modules = level["ModuleData"] as JsonObject
                    ?? throw new InvalidDataException("Saved skill allocations are missing.");
                var spent = SumSkillSpend(modules);
                if (total < 0 || unspent < 0 || bonus < 0 || unspent > total || spent > total - unspent)
                    throw new InvalidDataException("Saved skill-point accounting is inconsistent.");
                // Preserve specialization bonuses, admin-granted points and current allocations.
                var newTotal = checked(total + newLevel - oldLevel);
                var newUnspent = checked(unspent + newLevel - oldLevel);
                if (newUnspent < 0 || newTotal < spent)
                    throw new InvalidDataException("Respec before lowering character XP below allocated skill points.");
                var properties = ReadActorProperties(db, identity.PawnId);
                var tech = properties["TechKnowledgePlayerComponent"] as JsonObject
                    ?? throw new InvalidDataException("Saved Intel component is missing.");
                var intel = RequirePoints(tech, "m_TechKnowledgePoints");
                // Award only newly earned level Intel; never restore already spent research Intel.
                var newIntel = checked(intel + Math.Max(0, CharacterIntelAtLevel(newLevel) - CharacterIntelAtLevel(oldLevel)));
                var moduleBefore = modules.ToJsonString();
                level["TotalXPEarned"] = xp;
                level["TotalSkillPoints"] = newTotal;
                level["UnspentSkillPoints"] = newUnspent;
                tech["m_TechKnowledgePoints"] = newIntel;
                WriteFglComponents(db, identity.EntityId, components);
                WriteActorProperties(db, identity.PawnId, properties);
                var verifiedLevel = RequireComponentObject(ReadFglComponents(db, identity.EntityId), "FLevelComponent");
                var verifiedTech = ReadActorProperties(db, identity.PawnId)["TechKnowledgePlayerComponent"] as JsonObject;
                if (verifiedLevel["TotalXPEarned"]?.GetValue<long>() != xp
                    || GetInt(verifiedLevel, "TotalSkillPoints") != newTotal
                    || GetInt(verifiedLevel, "UnspentSkillPoints") != newUnspent
                    || GetInt(verifiedLevel, "KeystoneBonusSkillPoints") != bonus
                    || verifiedLevel["ModuleData"]?.ToJsonString() != moduleBefore
                    || GetInt(verifiedTech, "m_TechKnowledgePoints") != newIntel)
                    throw new InvalidDataException("Character XP verification failed.");
                ValidateDatabase(db);
                Commit(db);
                return new { previousXp = current, xp, level = newLevel, totalSkillPoints = newTotal,
                    unspentSkillPoints = newUnspent, intel = newIntel };
            }
            catch { Rollback(db); throw; }
        }, requireGameClosed: true);
    }

    private static int CharacterIntelAtLevel(int level) => level switch
    {
        <= 0 => 0,
        1 => 4,
        <= 3 => 4 + (level - 1) * 2,
        <= 15 => 8 + (level - 3) * 3,
        <= 30 => 44 + (level - 15) * 5,
        <= 50 => 119 + (level - 30) * 10,
        <= 69 => 319 + (level - 50) * 20,
        <= 85 => 699 + (level - 69) * 30,
        <= 125 => 1179 + (level - 85) * 40,
        _ => 2779
    };

    private static void SelfTestCharacterXp(string root, string fixture, string adapter)
    {
        var levelsPath = Path.Combine(root, "xp-levels.json");
        var thresholds = Enumerable.Range(0, 201).Select(index => (long)index * 344440 / 200).ToArray();
        File.WriteAllText(levelsPath, JsonSerializer.Serialize(thresholds));
        var raw = Path.Combine(root, "xp-fixture.sqlite");
        File.WriteAllBytes(raw, Unwrap(ReadStable(fixture)).SqliteBytes);
        using (var db = OpenWritable(raw))
        {
            var identity = ReadIdentity(db);
            var components = ReadFglComponents(db, identity.EntityId);
            var level = RequireComponentObject(components, "FLevelComponent");
            level["TotalXPEarned"] = thresholds[100];
            level["TotalSkillPoints"] = 110;
            level["UnspentSkillPoints"] = 108;
            level["KeystoneBonusSkillPoints"] = 10;
            WriteFglComponents(db, identity.EntityId, components);
        }
        var target = Path.Combine(root, "xp-fixture.db");
        WrapSqlite(raw, target);
        var baseline = File.ReadAllBytes(target);
        var backup = Path.Combine(root, "safety", "xp-before.db");
        ChangeCharacterXp(target, backup, adapter, levelsPath, "add", 344440);
        if (!File.ReadAllBytes(backup).SequenceEqual(baseline)) throw new InvalidOperationException("XP backup differs from original.");
        var report = InspectPath(target).Progression;
        if (report.CharacterXp != 344440 || report.TotalSkillPoints != 210
            || report.UnspentSkillPoints != 208 || report.KeystoneBonusSkillPoints != 10
            || report.Intel != CharacterIntelAtLevel(200) - CharacterIntelAtLevel(100))
            throw new InvalidOperationException("XP grant did not preserve point bonuses or award only new Intel.");
        ChangeCharacterXp(target, Path.Combine(root, "safety", "xp-lower.db"), adapter, levelsPath, "set", 0);
        report = InspectPath(target).Progression;
        if (report.CharacterXp != 0 || report.TotalSkillPoints != 10 || report.UnspentSkillPoints != 8)
            throw new InvalidOperationException("XP reduction did not preserve allocations and bonus points.");
        // Remove the bonus buffer on a separate copy, leaving two allocated points.
        File.WriteAllBytes(raw, Unwrap(baseline).SqliteBytes);
        using (var db = OpenWritable(raw))
        {
            var identity = ReadIdentity(db);
            var components = ReadFglComponents(db, identity.EntityId);
            var level = RequireComponentObject(components, "FLevelComponent");
            level["TotalSkillPoints"] = 100;
            level["UnspentSkillPoints"] = 98;
            level["KeystoneBonusSkillPoints"] = 0;
            WriteFglComponents(db, identity.EntityId, components);
        }
        WrapSqlite(raw, target);
        var before = File.ReadAllBytes(target);
        var rejectedBackup = Path.Combine(root, "safety", "xp-rejected.db");
        var rejected = false;
        try { ChangeCharacterXp(target, rejectedBackup, adapter, levelsPath, "set", 0); }
        catch (InvalidDataException) { rejected = true; }
        if (!rejected || !File.ReadAllBytes(target).SequenceEqual(before) || File.Exists(rejectedBackup))
            throw new InvalidOperationException("XP reduction failed to protect spent skills and original save.");
    }
}
