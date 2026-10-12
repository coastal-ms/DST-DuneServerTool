namespace DuneSoloDb;

internal static partial class Program
{
    // Current retail station assets and the faction-to-difficulty curve's upper endpoint.
    private static readonly string[] TestingStations = [
        "DA_Dgn_024_Darkness", "DA_Dgn_089_Radiation", "DA_Dgn_136_Fire",
        "DA_Dgn_152_Electric", "DA_Dgn_195_Poison", "DA_Dgn_Pit"
    ];
    private const int TestingStationDifficulty = 1000;

    private static object UnlockTestingStations(string input, string backup, string adapterPath, string station)
    {
        var selected = station == "all" ? TestingStations : TestingStations.Contains(station, StringComparer.Ordinal)
            ? new[] { station } : throw new ArgumentException("Choose a supported Testing Station or all six.");
        AssertProgressionAdapter(input, ReadSoloAdapter(adapterPath));
        return RunProgressionMutation(input, backup, "unlock-testing-stations", path =>
        {
            using var db = OpenWritable(path);
            var player = ReadIdentity(db);
            BeginImmediate(db);
            try
            {
                var added = 0;
                foreach (var id in selected)
                {
                    if (ScalarLong(db, """
                        SELECT COUNT(*) FROM dungeon_completion d
                        JOIN dungeon_completion_players p ON p.completion_id=d.completion_id
                        WHERE p.player_id=$player AND d.dungeon_id=$station AND d.difficulty >= $difficulty;
                        """, ("$player",player.ControllerId), ("$station",id), ("$difficulty",TestingStationDifficulty)) > 0) continue;
                    ExecuteNonQuery(db, """
                        INSERT INTO dungeon_completion(dungeon_id,difficulty,duration_ms,players_num)
                        VALUES($station,$difficulty,2147483647,1);
                        """, ("$station",id), ("$difficulty",TestingStationDifficulty));
                    var completion = ScalarLong(db,"SELECT last_insert_rowid();");
                    ExecuteNonQuery(db,"INSERT INTO dungeon_completion_players(player_id,completion_id) VALUES($player,$completion);",
                        ("$player",player.ControllerId),("$completion",completion));
                    added++;
                }
                ValidateDatabase(db);
                Commit(db);
                return new { stations=selected, added, completionDifficulty=TestingStationDifficulty };
            }
            catch { Rollback(db); throw; }
        }, requireGameClosed:true);
    }

    private static void SelfTestTestingStations(string root, string target, string adapterPath)
    {
        var sqlite=Path.Combine(root,"stations-seed.sqlite");
        File.WriteAllBytes(sqlite,Unwrap(File.ReadAllBytes(target)).SqliteBytes);
        long player;
        using(var db=OpenWritable(sqlite))
        {
            player=ReadIdentity(db).ControllerId;
            ExecuteNonQuery(db,"""
                CREATE TABLE dungeon_completion(completion_id INTEGER PRIMARY KEY AUTOINCREMENT,dungeon_id TEXT NOT NULL,difficulty INTEGER NOT NULL,duration_ms INTEGER NOT NULL,players_num INTEGER NOT NULL);
                CREATE TABLE dungeon_completion_players(player_id INTEGER NOT NULL,completion_id INTEGER NOT NULL REFERENCES dungeon_completion(completion_id),PRIMARY KEY(player_id,completion_id));
                INSERT INTO dungeon_completion VALUES(1,'DA_Dgn_024_Darkness',1200,1234,1);
                INSERT INTO dungeon_completion_players VALUES($player,1);
                INSERT INTO dungeon_completion VALUES(2,'UnrelatedDungeon',3,5678,2);
                INSERT INTO dungeon_completion_players VALUES($player,2);
                """,("$player",player));
        }
        var stage=Path.Combine(root,"stations-game.db");
        WrapSqlite(sqlite,stage);
        var original=File.ReadAllBytes(stage);
        var backup=Path.Combine(root,"stations-backup.db");
        UnlockTestingStations(stage,backup,adapterPath,"all");
        if(!File.ReadAllBytes(backup).SequenceEqual(original)) throw new InvalidOperationException("Station backup is not exact.");
        UnlockTestingStations(stage,Path.Combine(root,"stations-repeat.db"),adapterPath,"all");
        var stable=File.ReadAllBytes(stage);
        try { UnlockTestingStations(stage,Path.Combine(root,"stations-invalid.db"),adapterPath,"unknown"); throw new InvalidOperationException("Invalid station accepted."); }
        catch(ArgumentException) { }
        if(!File.ReadAllBytes(stage).SequenceEqual(stable)) throw new InvalidOperationException("Invalid station changed save.");
        File.WriteAllBytes(sqlite,Unwrap(stable).SqliteBytes);
        using(var db=OpenWritable(sqlite))
        {
            if(ScalarLong(db,"SELECT COUNT(*) FROM dungeon_completion;")!=7
                || ScalarLong(db,"SELECT difficulty FROM dungeon_completion WHERE completion_id=1;")!=1200
                || ScalarLong(db,"SELECT duration_ms FROM dungeon_completion WHERE completion_id=2;")!=5678
                || ScalarLong(db,"SELECT COUNT(*) FROM dungeon_completion_players WHERE player_id=$player;",("$player",player))!=7)
                throw new InvalidOperationException("Station targeting, preservation or repeat failed.");
        }
        Restore(backup,stage,Path.Combine(root,"stations-before-rollback.db"),requireGameClosed:true);
        if(!File.ReadAllBytes(stage).SequenceEqual(original)) throw new InvalidOperationException("Station backup restore failed.");
    }
}
