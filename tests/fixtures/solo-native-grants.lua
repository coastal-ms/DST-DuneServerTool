-- Game/UE4SS fixture with in-memory files; no installed game or save access.
now=0; queue={}; notifications={}; files={}; output={}; objects={}; originals={}
mode='solo'; anti_cheat=false; controllers=true; writes=0; fail_write=false
calls=0; bag={}; refuse_grant=false; account=9007199254740993; controller_id=11
io.open=function(path, kind)
    if kind=='rb' or kind=='r' then
        if files[path]==nil then return nil end
        return {read=function(_,limit)if files[path]=='' then return nil end;if limit=='*l' then return files[path]end;return files[path]:sub(1,limit)end,close=function()return true end}
    end
    return {write=function(_,v)files[path]=v;return true end,close=function()return true end}
end
os.remove=function(path)files[path]=nil;return true end
os.rename=function(a,b)assert(files[a]~=nil);files[b]=files[a];files[a]=nil;return true end
print=function(s)output[#output+1]=s end
function ExecuteInGameThreadWithDelay(ms,cb)queue[#queue+1]={at=now+ms,cb=cb}end
function NotifyOnNewObject(name,cb)notifications[name]=cb end
function RegisterInitGameStatePreHook(cb)notifications.InitGameStatePre=cb end
function FName(s)return s end
function prop(name,kind,offset)
    return {GetFName=function()return name end,GetClass=function()return {GetFName=function()return kind end}end,GetOffset_Internal=function()return offset or 0 end}
end
function class(functions, properties, parent)
    return {IsValid=function()return true end,GetSuperStruct=function()return parent end,
        ForEachProperty=function(_,cb)for _,p in ipairs(properties or {})do cb(p)end end,
        ForEachFunction=function(_,cb)for name,fields in pairs(functions or {})do cb({GetFName=function()return name end,ForEachProperty=function(_,f)for _,p in ipairs(fields)do f(prop(p[1],p[2],p[3]))end end})end end}
end
world={IsValid=function()return true end,GetAddress=function()return 123 end}
reference_data={}
local reference_array={GetArrayNum=function()return #reference_data end,Empty=function()reference_data={}end,
    ForEach=function(_,cb)for i,obj in ipairs(reference_data)do cb(i,{get=function()return obj end})end end}
instance=setmetatable({IsValid=function()return true end,GetAddress=function()return 501 end,GetWorld=function()return world end,
    GetClass=function()return class({},missing_reference_field and {} or {prop('ReferencedObjects','ArrayProperty',0x38)})end},
    {__index=function(_,key)if key=='ReferencedObjects'then return reference_array end end,
     __newindex=function(self,key,value)if key~='ReferencedObjects'then rawset(self,key,value);return end
         reference_writes=(reference_writes or 0)+1
         if fail_reference_write and reference_writes==120 then fail_reference_write=false;error('forced reference write failure')end
         reference_data={};for i,obj in ipairs(value)do reference_data[i]=obj end
     end})
local function valid()return true end
local pcclass=class({K2_GetPawn={{'ReturnValue','ObjectProperty'}},GetAccountId={{'ReturnValue','StructProperty'}},GetPersistenceId={{'ReturnValue','StructProperty'}}})
local pawnclass=class({GetNumberOfItemsInBackpackInventory={{'InItemTemplateID','StructProperty'},{'ReturnValue','IntProperty'}}})
pawn={IsValid=valid,GetClass=function()return pawnclass end,GetNumberOfItemsInBackpackInventory=function(_,id)return bag[id.Name] or 0 end}
pc={IsValid=valid,GetClass=function()return pcclass end,GetWorld=function()return world end,GetAddress=function()return 101 end,IsLocalController=function()return true end,K2_GetPawn=function()return pawn end,
    GetAccountId=function()return {UID=account}end,GetPersistenceId=function()return {UID=controller_id}end,
    PlayerState={IsValid=valid,GetClass=function()return class({GetPlayerName={{'ReturnValue','StrProperty'}}})end,GetPlayerName=function()return 'Solo' end}}
local managerclass=class({AddItemToInventory={{'InItemName','NameProperty'},{'InQuantity','IntProperty'},{'InDurability','FloatProperty'},{'InQuality','ByteProperty'}}})
manager={IsValid=valid,GetClass=function()return managerclass end,GetOuter=function()return pc end,AddItemToInventory=function(_,id,n,d,q)
    assert(d==1.0 and q>=0 and q<=5);calls=calls+1
    assert(files['queue/'..active_id..'.result']:find('^processing|'),'claim must precede grant')
    if not refuse_grant then bag[id]=(bag[id] or 0)+n end
end}
function StaticConstructObject(kind,owner,_,flags)assert(kind==managerclass and owner==pc and flags==64);return manager end
local library={IsValid=valid,GetClass=function()return class({IsSoloPlay={{'WorldContextObject','ObjectProperty'},{'ReturnValue','BoolProperty'}}})end,IsSoloPlay=function(_,obj)assert(type(obj.GetWorld)=="function");return mode=='solo' end}
local sys={IsValid=valid,GetCommandLine=function()return anti_cheat and '-battleye' or '-nobattleye' end}
local statics={IsValid=valid,GetGameInstance=function()return instance end,GetClass=function()return class({GetGameInstance={{'WorldContextObject','ObjectProperty'},{'ReturnValue','ObjectProperty'}}})end}
local item_struct=class({}, {prop('Name','NameProperty',0)})
function StaticFindObject(path)
    if objects[path] then return objects[path] end
    if path:find('KismetSystemLibrary',1,true)then return sys end
    if path:find('GUIBlueprintLibrary',1,true)then return library end
    if path:find('Default__GameplayStatics',1,true)then return statics end
    if path=='/Script/DuneSandbox.DuneCheatManager'then return managerclass end
    if path=='/Script/DuneSandboxCore.EItemTemplateID'then return item_struct end
end
function FindAllOf(name)
    if name=='DuneGameInstance'then if mode=='ambiguous'then return {instance,{IsValid=valid,GetWorld=function()return {IsValid=valid,GetAddress=function()return 124 end}end}}else return {instance}end end
    if name=='DunePlayerController' and controllers then return {pc}end
    return {}
end
function object(path,kind,fieldname,fieldkind,offset,original)
    object_serial=(object_serial or 1000)+1;local address=object_serial
    local data={[fieldname]=original}; originals[path]={field=fieldname,value=original,data=data,kind=kind,fieldkind=fieldkind,offset=offset}
    local obj={IsValid=valid,GetAddress=function()return address end,GetFullName=function()return kind..' '..path end,GetClass=function()return class({}, {prop(fieldname,fieldkind,offset)})end}
    objects[path]=setmetatable(obj,{__index=function(_,k)return data[k]end,__newindex=function(_,k,v)
        writes=writes+1;if fail_write and writes==120 then fail_write=false;error('forced write failure')end;data[k]=v
    end})
end
function collect_unreferenced()
    local held={};for _,obj in ipairs(reference_data)do held[obj:GetAddress()]=true end
    for path,obj in pairs(objects)do if not held[obj:GetAddress()]then rawset(obj,'IsValid',function()return false end);objects[path]=nil end end
end
function LoadAsset(path)
    if path==unavailable_child then return nil end
    local row=originals[path]
    if not row then return nil end
    object(path,row.kind,row.field,row.fieldkind,row.offset,row.value);return objects[path]
end
function assert_originals()for _,row in pairs(originals)do assert(row.data[row.field]==row.value)end end
function run_until(t)
    while #queue>0 do table.sort(queue,function(a,b)return a.at<b.at end);if queue[1].at>t then break end;local e=table.remove(queue,1);now=e.at;e.cb()end
    now=t
end
function request(id, body)
    active_id=id
    files['queue/queue.txt']=id
    files['queue/'..id..'.request']='1|'..id..'|9007199254740993|11|536f6c6f\n'..body
end

menu_widget={IsValid=function()return true end,GetWorld=function()return world end}
