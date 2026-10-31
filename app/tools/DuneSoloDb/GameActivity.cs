using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace DuneSoloDb;
internal static partial class Program
{
    private static void SelfTestGameActivity(string root,string original)
    {
        var sqlite=Path.Combine(root,"activity-test.sqlite");var target=Path.Combine(root,"activity-test.db");
        File.WriteAllBytes(sqlite,Unwrap(File.ReadAllBytes(original)).SqliteBytes);
        using(var db=OpenWritable(sqlite)) {
            var identity=ReadIdentity(db);
            ExecuteNonQuery(db,"CREATE TABLE IF NOT EXISTS game_events(actor_id INTEGER,universe_time TEXT,map TEXT,event_type INTEGER,custom_data BLOB,player_facing_event INTEGER);");
            ExecuteNonQuery(db,"DELETE FROM game_events;");
            ExecuteNonQuery(db,"INSERT INTO game_events VALUES($controller,'2026-10-30 18:00:00','Survival_1',19,jsonb('{\"m_StateChange\":\"On\"}'),1),($pawn,'2026-10-30 18:01:00','Survival_1',13,jsonb('{\"m_TotemShieldState\":\"Restored\"}'),1),(999999,'2026-10-30 18:02:00','Survival_1',98,jsonb('{}'),1),($controller,'2026-10-30 18:03:00','Survival_1',97,jsonb('{}'),0);",("$controller",identity.ControllerId),("$pawn",identity.PawnId));
        }
        WrapSqlite(sqlite,target);var before=File.ReadAllBytes(target);
        using var result=JsonDocument.Parse(JsonSerializer.Serialize(ReadGameActivity(target)));
        var events=result.RootElement.GetProperty("events");
        if(events.GetArrayLength()!=2||events[0].GetProperty("event_type").GetString()!="communinet_13"||events[1].GetProperty("event_type").GetString()!="communinet_19"||!before.SequenceEqual(File.ReadAllBytes(target)))
            throw new InvalidOperationException("Activity reader changed the save or included another actor/non-player-facing event.");
    }
    private static object ReadGameActivity(string input)
    {
        var bytes=ReadStable(input);
        if(InspectBytes(bytes,input).CharacterCount!=1) throw new InvalidDataException("Activity requires exactly one Solo character.");
        var root=Path.Combine(Path.GetTempPath(),"dune-solo-activity-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            var path=Path.Combine(root,"snapshot.sqlite"); File.WriteAllBytes(path,Unwrap(bytes).SqliteBytes);
            using var db=new SqliteConnection(new SqliteConnectionStringBuilder {DataSource=path,Mode=SqliteOpenMode.ReadOnly,Pooling=false}.ToString());
            db.Open(); ExecuteNonQuery(db,"PRAGMA query_only=ON;");
            var events=new List<object>();
            var unsupported=!TableExists(db,"game_events");
            if(!unsupported) {
                var columns=new HashSet<string>(StringComparer.Ordinal);
                using(var schema=db.CreateCommand()) { schema.CommandText="PRAGMA table_info(game_events);";using var fields=schema.ExecuteReader();while(fields.Read())columns.Add(fields.GetString(1)); }
                unsupported=new[]{"actor_id","universe_time","event_type","custom_data","map","player_facing_event"}.Any(c=>!columns.Contains(c));
            }
            if(!unsupported) {
                var identity=ReadIdentity(db);
                using var command=db.CreateCommand();
                command.CommandText="SELECT universe_time,event_type,json(custom_data),map FROM game_events WHERE player_facing_event=1 AND actor_id IN ($controller,$pawn) ORDER BY universe_time DESC,event_type,custom_data LIMIT 100;";
                command.Parameters.AddWithValue("$controller",identity.ControllerId);command.Parameters.AddWithValue("$pawn",identity.PawnId);
                using var reader=command.ExecuteReader();
                while(reader.Read()) {
                    var raw=reader.IsDBNull(0)?"":Convert.ToString(reader.GetValue(0),System.Globalization.CultureInfo.InvariantCulture)??"";
                    var ts=DateTimeOffset.TryParse(raw,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AssumeUniversal,out var parsed)?parsed.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"):raw;
                    var meta=JsonSerializer.Deserialize<Dictionary<string,object?>>(reader.IsDBNull(2)?"{}":reader.GetString(2))??new();
                    meta["map"]=reader.IsDBNull(3)?"":reader.GetString(3);
                    events.Add(new {id=-(events.Count+1),ts,event_type="communinet_"+reader.GetInt64(1),meta=JsonSerializer.Serialize(meta)});
                }
            }
            if(!SHA256.HashData(bytes).SequenceEqual(SHA256.HashData(ReadStable(input))))throw new IOException("Solo save changed while reading activity. Refresh and try again.");
            return new {ok=true,events,unsupported};
        } finally {try {Directory.Delete(root,true);}catch(IOException){}catch(UnauthorizedAccessException){} }
    }
}
