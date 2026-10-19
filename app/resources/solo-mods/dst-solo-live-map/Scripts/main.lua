-- Solo map: read-only game observation; output belongs to the local companion.
local busy = false
local last_message = ""
local function report(message)
    if message ~= last_message then print("[DSTSoloLiveMap] " .. message .. "\n");last_message=message end
end
local metadata, seen = {}, {}
local classes = {
    {"ResourceField", "spice"}, {"ResourceNodeSpawner", "ore"},
    {"HarvestableInstancedMeshActor", "ore"}, {"CrashSite", "crash-probe"},
    {"SandStormBase", "storm"},
    {"DuneVehicle", "vehicle"}, {"SandStormManager", "storm-manager"},
    {"SandwormPawn", "worm"},
    {"DynamicEncounter", "crash-probe"},
    {"MTXContentSpawnController_ChoamWreckage", "crash-probe"},
}
local function safe(fn) local ok,v=pcall(fn); if ok then return v end end
local function valid(o) return o and safe(function() return o:IsValid() end)==true end
local function name(o) return safe(function() return o:GetFName():ToString() end) or "" end
local function full(o) return safe(function() return o:GetFullName() end) or "" end
local function json(v)
    local t=type(v)
    if t=="string" then return '"'..v:gsub('[%z\1-\31\\"]',function(c) return string.format('\\u%04x',string.byte(c)) end)..'"' end
    if t=="boolean" then return tostring(v) end
    if t=="number" then if v==v and math.abs(v)<math.huge then return tostring(v) end; return "null" end
    if t=="table" then
        local out={}
        if v[1]~=nil then for _,x in ipairs(v) do out[#out+1]=json(x) end; return '['..table.concat(out,',')..']' end
        for k,x in pairs(v) do out[#out+1]=json(tostring(k))..':'..json(x) end
        return '{'..table.concat(out,',')..'}'
    end
    return "null"
end
local script_path = debug.getinfo(1, "S").source:match("^@(.+[/\\])")
local output_root, launch_id, native_build
if script_path then
    local context = io.open(script_path .. "dst-live-map-context.txt", "r")
    if context then output_root=context:read("*l"); launch_id=context:read("*l"); context:close() end
    local build=io.open(script_path .. "dst-native-build.txt","r")
    if build then native_build=build:read("*l");build:close() end
end
local native_encounter_ready=false
local function prepare_native_encounter()
    if native_encounter_ready then return true end
    -- Verified Steam executable + native FName contract. Unknown builds never
    -- read this offset. Registration adds a Lua getter; no game field is set.
    if native_build~="B9A77E7A178CFA8D88D65743BCBB04EF9D45E13539DB0BBD148E172BDA86A9E9" then return false end
    if type(RegisterCustomProperty)~="function" or not PropertyTypes or not PropertyTypes.NameProperty then return false end
    local class=StaticFindObject("/Script/DuneSandbox.DynamicEncounter")
    if not valid(class) then return false end
    local ok=pcall(function() RegisterCustomProperty({
        Name="DSTSoloLiveEncounterAsset",Type=PropertyTypes.NameProperty,
        BelongsToClass="/Script/DuneSandbox.DynamicEncounter",OffsetInternal=0x450
    }) end)
    native_encounter_ready=ok
    return ok
end
local function write(file,value)
    if not output_root or not launch_id then return end
    value.launchId=launch_id
    local target=output_root .. "/" .. file
    local temporary=target .. ".tmp"
    local handle=io.open(temporary,"wb")
    if not handle then report("Map output unavailable");return end
    handle:write(json(value));handle:close()
    -- The companion tolerates the brief replace interval and holds its last frame.
    os.remove(target)
    local ok=os.rename(temporary,target)
    if not ok then report("Map output unavailable") end
end
local metadata_version=0
local exported_metadata_version=-1
local function describe(c)
    local depth=0
    while valid(c) and depth<8 do
        local key=full(c)
        if seen[key] then break end
        seen[key]=true
        local row={class=key,properties={},functions={}}
        safe(function() c:ForEachProperty(function(p)
            row.properties[#row.properties+1]={name=name(p),type=name(p:GetClass())}
        end) end)
        safe(function() c:ForEachFunction(function(fn)
            local n=name(fn)
            if n:find("Location") or n:find("Transform") or n:find("Instance") or n:find("Solo") or n:find("Encounter") or n:find("Marker") or n:find("Fuel") or n:find("Health") then
                local params={}
                fn:ForEachProperty(function(p) params[#params+1]={name=name(p),type=name(p:GetClass())} end)
                row.functions[#row.functions+1]={name=n,params=params}
            end
        end) end)
        metadata[#metadata+1]=row
        metadata_version=metadata_version+1
        c=safe(function() return c:GetSuperStruct() end);depth=depth+1
    end
end
local function solo_world()
    local lib=StaticFindObject("/Script/DuneSandbox.Default__GUIBlueprintLibrary")
    if not valid(lib) then return nil,"Solo library unavailable" end
    -- Resolve only the known read-only Solo getter, including its two known signatures.
    local contract
    safe(function() lib:GetClass():ForEachFunction(function(fn)
        if name(fn)=="IsSoloPlay" then
            local p={};fn:ForEachProperty(function(x) p[#p+1]=name(x)..":"..name(x:GetClass()) end)
            contract=table.concat(p,",")
        end
    end) end)
    local matches={}
    for _,pc in ipairs(FindAllOf("DunePlayerController") or {}) do
        if valid(pc) then
            local pawn=safe(function() return pc:K2_GetPawn() end)
            if valid(pawn) then
                local isSolo=false
                if contract=="WorldContextObject:ObjectProperty,ReturnValue:BoolProperty" then isSolo=safe(function() return lib:IsSoloPlay(pawn) end)
                elseif contract=="ReturnValue:BoolProperty" then isSolo=safe(function() return lib:IsSoloPlay() end) end
                if isSolo==true then
                    local outer=pawn
                    for _=1,8 do
                        outer=safe(function() return outer:GetOuter() end)
                        if not valid(outer) then break end
                        if name(outer:GetClass())=="World" then matches[#matches+1]=name(outer);break end
                    end
                end
            end
        end
    end
    if #matches~=1 then return nil,"Waiting for one Solo world" end
    return matches[1]
end
local contract_cache={}
local function function_contract(object,wanted)
    local c=object:GetClass()
    local key=full(c)..":"..wanted
    if contract_cache[key]~=nil then return contract_cache[key] or nil end
    for _=1,12 do
        if not valid(c) then break end
        local result
        c:ForEachFunction(function(fn)
            if name(fn)==wanted then
                local p={};fn:ForEachProperty(function(x) p[#p+1]=name(x)..":"..name(x:GetClass()) end)
                result=table.concat(p,",")
            end
        end)
        if result then contract_cache[key]=result;return result end
        c=c:GetSuperStruct()
    end
    contract_cache[key]=false
end
local function ore_kind(text)
    text=text:lower()
    for _,v in ipairs({"titanium","stravidium","bauxite","erythrite","magnetite","azurite","jasmium","dolomite","rhyolite","basalt"}) do
        if text:find(v,1,true) then return v end
    end
end
local function actor_world(object,expected)
    local outer=object
    local world_name
    for _=1,12 do
        outer=safe(function() return outer:GetOuter() end)
        if not valid(outer) then break end
        local kind=name(outer:GetClass())
        if kind=="World" then
            world_name=name(outer)
            if world_name==expected then return world_name end
        elseif kind=="Package" and expected then
            -- DD streaming bundles use their own World names. The runtime
            -- package records the parent world, e.g. /Temp/Cb/DeepDesert_1_CB_.
            local prefix="/Temp/Cb/"..expected.."_CB_"
            if name(outer):sub(1,#prefix)==prefix then return expected end
        end
    end
    return world_name
end
local function inherits(class,wanted)
    for _=1,12 do
        if not valid(class) then return false end
        if name(class)==wanted then return true end
        class=class:GetSuperStruct()
    end
    return false
end
local function identity_fields(object,fields,prefix,depth)
    if not valid(object) or depth>1 then return end
    local ancestor=object:GetClass()
    describe(ancestor)
    for _=1,12 do
        if not valid(ancestor) then break end
        ancestor:ForEachProperty(function(property)
            local key=name(property)
            local lower=key:lower()
            if lower:find("marker") or lower:find("definition") or lower:find("encounter") or lower:find("asset") or lower:find("displayname") or lower:find("descriptor") then
                local value=safe(function() return object[key] end)
                local text_value
                if type(value)=="string" then text_value=value
                elseif valid(value) then
                    text_value=full(value)
                    if lower:find("encounter") and lower:find("component") then
                        identity_fields(value,fields,prefix..key..".",depth+1)
                    end
                else text_value=safe(function() return value:ToString() end) end
                if text_value then fields[prefix..key]=text_value end
            end
        end)
        ancestor=ancestor:GetSuperStruct()
    end
end
local function mesh_points(component,row,out)
    if not valid(component) then return end
    local source_id=row.id..":"..tostring(component:GetAddress())
    out.oreSources[source_id]="excluded"
    -- Reject hidden, destroyed or vehicle-attached instances. This observer
    -- must not expose packed/stored objects as world deposits.
    if safe(function() return component.bVisible end)==false or safe(function() return component.bHiddenInGame end)==true then return end
    local parent=component
    for _=1,16 do
        if not valid(parent) then break end
        local owner=safe(function() return parent:GetOwner() end)
        if valid(owner) then
            if safe(function() return owner.bHidden end)==true or safe(function() return owner.bActorIsBeingDestroyed end)==true then return end
            local c=owner:GetClass()
            for _=1,12 do
                if not valid(c) then break end
                if name(c)=="DuneVehicle" then return end
                c=c:GetSuperStruct()
            end
        end
        if function_contract(parent,"GetAttachParent")~="ReturnValue:ObjectProperty" then break end
        parent=parent:GetAttachParent()
    end
    describe(component:GetClass())
    if function_contract(component,"GetInstanceCount")~="ReturnValue:IntProperty" then return end
    if function_contract(component,"GetInstanceTransform")~="InstanceIndex:IntProperty,OutInstanceTransform:StructProperty,bWorldSpace:BoolProperty,ReturnValue:BoolProperty" then return end
    local count=component:GetInstanceCount()
    if type(count)~="number" or count<0 or count>20000 then return end
    out.oreSources[source_id]="partial"
    if count<=2000 and #out.items+count<30000 then out.oreSources[source_id]="complete" end
    for i=0,math.min(count,2000)-1 do
        if #out.items>=30000 then out.limits.ore=true;break end
        local transform={}
        local ok=component:GetInstanceTransform(i,transform,true)
        if ok then
            local t=transform.Translation
            local scale=transform.Scale3D
            if t and scale and math.abs(scale.X*scale.Y*scale.Z)>0.000001 then
                out.items[#out.items+1]={id=source_id..":"..i,oreSource=source_id,kind="ore",oreType=row.oreType,name=row.name,location={x=t.X,y=t.Y,z=t.Z},source="instance"}
            end
        end
    end
end
local function capture()
    local world,reason=solo_world()
    local out={schema=1,capturedAt=os.time(),world=world or "",status=reason or "",items={},oreSources={},counts={},limits={},readOnly=true}
    if not world or not world:lower():find("deepdesert",1,true) then
        out.status=reason or "Waiting for Deep Desert"
        write("runtime.json",out);report(out.status .. " (world=" .. out.world .. ")");return
    end
    out.status="observing"
    for _,spec in ipairs(classes) do
        local list=safe(function() return FindAllOf(spec[1]) end) or {}
        out.counts[spec[1]]=#list
        local kept=0
        out.limits[spec[1]]=false
        for i,o in ipairs(list) do
            if valid(o) and actor_world(o,world)==world and safe(function() return o.bActorIsBeingDestroyed end)~=true then
                local c=o:GetClass();describe(c)
                local row={id=tostring(o:GetAddress()),class=full(c),name=name(o),kind=spec[2]}
                local include=true
                if row.kind=="spice" then
                    include=row.class:lower():find("spice",1,true)~=nil and not row.class:lower():find("flour",1,true)
                    if include then include=safe(function() return o.m_bIsActiveOnServer end)==true end
                end
                if row.kind=="ore" then row.oreType=ore_kind(row.class.." "..row.name);include=row.oreType~=nil end
                if row.kind=="crash-probe" then
                    -- Inspect the current world's declared marker/encounter identity.
                    -- Do not label a generic encounter or scrap pile as a shipwreck.
                    row.definitionFields={}
                    identity_fields(o,row.definitionFields,"",0)
                    if inherits(c,"DynamicEncounter") and prepare_native_encounter() then
                        row.definitionFields.nativeAsset=safe(function() return o.DSTSoloLiveEncounterAsset:ToString() end)
                    end
                    local identity=json(row.definitionFields):lower()
                    if identity:find("shipwreck",1,true) or identity:find("ship_wreck",1,true) then
                        row.kind="crash";row.name="Crashed ship event"
                    end
                end
                if include then
                kept=kept+1
                if kept>300 then out.limits[spec[1]]=true;break end
                local loc=safe(function() return o:K2_GetActorLocation() end)
                if loc then row.location=safe(function() return {x=loc.X,y=loc.Y,z=loc.Z} end) end
                -- Names and values of selected reflected data are research evidence,
                -- not assumed spawn/activity state. Never call gameplay setters.
                row.fields={}
                if row.kind=="crash" then
                    -- Content registration is not event activity: live spawned
                    -- encounters legitimately have this persistence flag false.
                    row.fields.contentRegistered=safe(function() return o.m_EncounterActorComponent.m_bIsRegisteredAsContent end)
                end
                if row.kind=="vehicle" then
                    row.customName=safe(function() return o.m_VehicleDisplayCustomName:ToString() end)
                    row.templateName=safe(function() return o.m_VehicleTemplateName:ToString() end)
                    row.fields.hidden=safe(function() return o.bHidden end)
                    row.fields.destroying=safe(function() return o.bActorIsBeingDestroyed end)
                    row.fields.waitingForPersistence=safe(function() return o.bActorIsWaitingForPersistence end)
                    local root=safe(function() return o.RootComponent end)
                    row.worldPlaced=valid(root) and row.fields.hidden~=true and row.fields.destroying~=true and row.fields.waitingForPersistence~=true
                end
                for _,key in ipairs({"m_AgePercent","m_bIsActiveOnServer","m_TotalValue","m_AllocatedTotalValue","m_UniverseSpawnTime","m_RemainingTime","m_TotalTime","m_ResourceNodeComponent","m_ResourceFieldTypeConfig","m_Root"}) do
                    local v=safe(function() return o[key] end)
                    if type(v)=="number" or type(v)=="boolean" or type(v)=="string" then row.fields[key]=v
                    elseif valid(v) then row.fields[key]=full(v) end
                end
                if row.kind=="ore" then
                    -- Never publish the spawner origin as an individual deposit.
                    row.location=nil;row.source="spawner"
                    if spec[1]=="ResourceNodeSpawner" then safe(function() mesh_points(o.m_StaticMeshComponent,row,out) end)
                    else safe(function() o.m_HarvestableComponents:ForEach(function(_,elem) mesh_points(elem:get(),row,out) end) end) end
                end
                if row.kind=="storm-manager" then
                    safe(function() row.stormDataCount=#o.m_SpawnedSandstormData end)
                end
                if row.kind=="storm" then
                    row.zones={}
                    for zone_index=1,6 do
                        safe(function()
                            local zone=o["m_StormZoneComponent"..zone_index]
                            if not valid(zone) then return end
                            describe(zone:GetClass())
                            local data=zone.m_ZoneData
                            if not valid(data) then return end
                            describe(data:GetClass())
                            local width,length=data.m_ElipseWidth,data.m_ElipseLength
                            if type(width)~="number" or type(length)~="number" or width<=0 or length<=0 or width>=100000 or length>=100000 then return end
                            if function_contract(zone,"K2_GetComponentLocation")~="ReturnValue:StructProperty" or function_contract(zone,"K2_GetComponentRotation")~="ReturnValue:StructProperty" or function_contract(zone,"K2_GetComponentScale")~="ReturnValue:StructProperty" then return end
                            local pos,rot,scale=zone:K2_GetComponentLocation(),zone:K2_GetComponentRotation(),zone:K2_GetComponentScale()
                            row.zones[#row.zones+1]={location={x=pos.X,y=pos.Y,z=pos.Z},rotation={pitch=rot.Pitch,yaw=rot.Yaw,roll=rot.Roll},scale={x=scale.X,y=scale.Y,z=scale.Z},widthMeters=width,lengthMeters=length,damaging=data.m_bDoesDamage==true,warning=data.m_bWarningBuildup==true}
                        end)
                    end
                    for _,key in ipairs({"m_StartLocation","m_EndLocation","m_MoveSpeed","m_LifeTimeRemaining","m_LifeTimeTotal"}) do
                        local v=safe(function() return o[key] end)
                        if type(v)=="number" then row.fields[key]=v
                        else
                            local vector=safe(function() return {x=v.X,y=v.Y,z=v.Z} end)
                            if vector and type(vector.x)=="number" and type(vector.y)=="number" then row.fields[key]=vector end
                        end
                    end
                end
                if include then out.items[#out.items+1]=row end
                end
            end
        end
    end
    if exported_metadata_version~=metadata_version then write("reflection.json",metadata);exported_metadata_version=metadata_version end
    write("runtime.json",out)
    report("Captured " .. tostring(#out.items) .. " selected DD objects")
end
if type(LoopAsync)~="function" or type(ExecuteInGameThread)~="function" then print("[DSTSoloLiveMap] Required callbacks unavailable\n");return end
print("[DSTSoloLiveMap] Read-only DD observation ready\n")
LoopAsync(3000,function()
    if busy then return false end
    busy=true
    ExecuteInGameThread(function()
        local ok,err=pcall(capture)
        if not ok then
            report("CAPTURE_ERROR " .. tostring(err))
            safe(function() write("error.json",{at=os.time(),error=tostring(err)}) end)
        end
        busy=false
    end)
    return false
end)
