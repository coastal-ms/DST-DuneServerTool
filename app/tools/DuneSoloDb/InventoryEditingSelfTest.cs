using Microsoft.Data.Sqlite;
namespace DuneSoloDb;
internal static partial class Program {
    private static void SelfTestInventoryEditing(string source, string catalogPath, string root) {
        var sqlite=Path.Combine(root,"inventory-edit-fixture.sqlite");
        File.WriteAllBytes(sqlite,Unwrap(File.ReadAllBytes(source)).SqliteBytes);
        var stats="""{"UnknownFutureStats":{"keep":17},"FFillableItemStats":["FillableItemStats",{"CurrentAmount":250,"MaxAmount":1000}],"FItemStackAndDurabilityStats":["ItemStackAndDurabilityStats",{"MaxDurability":100,"CurrentDurability":45,"DecayedMaxDurability":80,"Custom":9}]}""";
        using(var db=new SqliteConnection($"Data Source={sqlite};Pooling=False")) {
            db.Open();
            // Retail saves enforce TEXT for stats. Exercise the actual STRICT
            // constraint; permissive fixture tables would accept JSONB by mistake.
            var schema=ScalarString(db,"SELECT sql FROM sqlite_master WHERE type='table' AND name='items';");
            ExecuteNonQuery(db,"PRAGMA foreign_keys=OFF;");
            ExecuteNonQuery(db,schema.Replace("CREATE TABLE items", "CREATE TABLE strict_items")+" STRICT;");
            ExecuteNonQuery(db,"INSERT INTO strict_items SELECT id,inventory_id,stack_size,position_index,template_id,is_new,acquisition_time,json(stats),quality_level,volume_override FROM items; DROP TABLE items; ALTER TABLE strict_items RENAME TO items; PRAGMA foreign_keys=ON;");
            ExecuteNonQuery(db,"INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats,quality_level) VALUES(60000,1,2,99,'HighCapacityLiterjon_06',$stats,3);",("$stats",stats));
            ExecuteNonQuery(db,"INSERT INTO items(id,inventory_id,stack_size,position_index,template_id,stats,quality_level) VALUES(60001,3,1,99,'ForeignItem','{}',0);");
        }
        var target=Path.Combine(root,"inventory-edit-target.db");WrapSqlite(sqlite,target);
        InventoryItemOccurrence Item() => InspectPath(target,catalogPath).InventoryItems.SelectMany(g=>g.Occurrences).Single(i=>i.ItemId==60000);
        void Check(bool condition,string message) {if(!condition)throw new InvalidOperationException(message);}
        void Apply(string field,string values) {
            var before=File.ReadAllBytes(target);var backup=Path.Combine(root,"edit-"+Guid.NewGuid().ToString("N")+".db");
            EditInventoryItem(target,backup,catalogPath,60000,Item().Revision!,field,values,false);
            Check(File.ReadAllBytes(backup).SequenceEqual(before),"Inventory edit must keep exact prior save.");
        }
        var revision=Item().Revision!;Apply("stack","""{"quantity":123}""");Check(Item().StackSize==123,"Stack edit failed.");
        Apply("water","""{"amount":1234.5}""");Check(Item().WaterStats!["CurrentAmount"]!.GetValue<double>()==1234.5,"Water edit must permit explicit overfill.");
        Apply("durability","""{"maximum":300,"current":275.5,"decayed":290}""");Check(Item().DurabilityStats!["CurrentDurability"]!.GetValue<double>()==275.5,"Durability edit failed.");
        Check(Item().DurabilityStats!["Custom"]!.GetValue<int>()==9,"Unknown durability fields changed.");
        Apply("water","""{"amount":0}""");Check(Item().WaterStats!["CurrentAmount"]!.GetValue<double>()==0,"Zero water must be supported.");
        void Reject(string field,string values,long id,string expected) {
            var before=File.ReadAllBytes(target);var backup=Path.Combine(root,"rejected-"+Guid.NewGuid().ToString("N")+".db");bool rejected=false;
            try {EditInventoryItem(target,backup,catalogPath,id,expected,field,values,false);} catch(InvalidDataException){rejected=true;}
            Check(rejected && before.SequenceEqual(File.ReadAllBytes(target)) && !File.Exists(backup),"Rejected edit changed save/backup or was accepted.");
        }
        Reject("stack","""{"quantity":2}""",60000,revision);
        foreach(var value in new[]{"0","-1","1.5","2147483648"})Reject("stack","{\"quantity\":"+value+"}",60000,Item().Revision!);
        Reject("water","""{"amount":-1}""",60000,Item().Revision!);
        Reject("durability","""{"maximum":100,"current":null,"decayed":100}""",60000,Item().Revision!);
        Reject("stack","""{"quantity":2}""",60001,new string('a',64));
        var unwrapped=Path.Combine(root,"inventory-edit-readback.sqlite");File.WriteAllBytes(unwrapped,Unwrap(File.ReadAllBytes(target)).SqliteBytes);
        using(var db=new SqliteConnection($"Data Source={unwrapped};Pooling=False")) {db.Open();Check(ScalarLong(db,"SELECT strict FROM pragma_table_list WHERE name='items';")==1,"Retail STRICT fixture was not enabled.");Check(ScalarString(db,"SELECT typeof(stats) FROM items WHERE id=60000;")=="text","Item stats must remain TEXT.");Check(ScalarLong(db,"SELECT json_extract(stats,'$.UnknownFutureStats.keep') FROM items WHERE id=60000;")==17,"Unrelated item stats changed.");Check(ScalarLong(db,"SELECT quality_level FROM items WHERE id=60000;")==3,"Quality changed.");}
    }
}
