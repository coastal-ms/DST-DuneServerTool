-- Solo Regis Tanks. Reflected contracts only; no executable/file patches.
local PREFIX = "[DSTRegisTanks] "
local script_path = debug.getinfo(1, "S").source:match("^@(.+[/\\])")
local PLATFORM
if script_path then
    local context = io.open(script_path .. "dst-launch-platform.txt", "r")
    if context then PLATFORM = context:read("*l"); context:close() end
end
local TANK = "/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C"
local MODULES = "/Game/Dune/Systems/Vehicles/Modules/DT_Tank_Modules.DT_Tank_Modules"
local TEMPLATES = "/Game/Dune/Systems/Vehicles/DT_VehicleTemplates.DT_VehicleTemplates"
local lines, journal = {}, {}
local used, enabled, pending = {}, false, false
local preparing = false
local tank_class, tank_cdo, prior_deprecated
local private_manager
local item_journal = {}
local function log(text)
    lines[#lines + 1] = text
    print(PREFIX .. text .. "\n")

end
local function valid(object)
    return object and object:IsValid()
end
local function find(path)
    local object = StaticFindObject(path)
    if not valid(object) and type(LoadAsset) == "function" then
        local ok, asset = pcall(function() return LoadAsset(path) end)
        if ok and valid(asset) then object = asset end
        if not valid(object) and path == TANK then
            pcall(function() LoadAsset("/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM") end)
            object = StaticFindObject(path)
        end
    end
    if not valid(object) then error("Required object unavailable: " .. path) end
    return object
end
local function text(value)
    if type(value) == "string" then return value end
    return value:ToString()
end
local function params(class, wanted)
    local found
    for depth = 1, 12 do
        if not valid(class) then break end
        class:ForEachFunction(function(fn)
            if text(fn:GetFName()) == wanted then
                local names = {}
                fn:ForEachProperty(function(property)
                    local offset = property:GetOffset_Internal()
                    if type(offset) ~= "number" or offset < 0 or offset >= 0x200 then error("Reflected function exceeds this Lua bridge's argument buffer: " .. wanted) end
                    names[#names + 1] = text(property:GetFName()) .. ":" .. text(property:GetClass():GetFName())
                end)
                if found then error("Ambiguous function contract: " .. wanted) end
                found = table.concat(names, ",")
            end
        end)
        if found then return found end
        class = class:GetSuperStruct()
    end
    error("Required function unavailable: " .. wanted)
end
local function verify_launch_context()
    if PLATFORM ~= "steam" and PLATFORM ~= "xbox" then error("Launch Regis Tanks through DST Solo.") end
end
local function standalone(pawn)
    -- Dune's Solo session is not necessarily Unreal NM_Standalone.
    -- Require the game's own explicit Solo flag, not server authority alone.
    local library = find("/Script/DuneSandbox.Default__GUIBlueprintLibrary")
    local contract = params(library:GetClass(), "IsSoloPlay")
    log("SOLO_PLAY_CONTRACT " .. contract)
    local result
    if contract == "WorldContextObject:ObjectProperty,ReturnValue:BoolProperty" then
        result = library:IsSoloPlay(pawn)
    elseif contract == "ReturnValue:BoolProperty" then
        result = library:IsSoloPlay()
    else
        error("Unrecognized IsSoloPlay contract: " .. contract .. "; no spawn attempted.")
    end
    log("SOLO_PLAY_RESULT " .. tostring(result))
    return result == true
end
local function controller()
    local matches = {}
    for _, pc in ipairs(FindAllOf("DunePlayerController") or {}) do
        if valid(pc) then
            local contract = params(pc:GetClass(), "K2_GetPawn")
            log("PAWN_GETTER_CONTRACT " .. contract)
            if contract ~= "ReturnValue:ObjectProperty" then error("Pawn getter signature changed; no spawn attempted.") end
            local pawn = pc:K2_GetPawn()
            if valid(pawn) and standalone(pawn) then matches[#matches + 1] = pc end
        end
    end
    if #matches ~= 1 then error("Load your Solo world on foot. Exactly one player in a verified Dune Solo session is required.") end
    return matches[1]
end
local function cheat_manager(pc)
    local manager = pc.CheatManager
    if not valid(manager) then
        if type(StaticConstructObject) ~= "function" then error("Native object construction unavailable.") end
        local class = find("/Script/DuneSandbox.DuneCheatManager")
        local expected = "VehicleClassName:StrProperty,VehicleTemplateName:StrProperty,FactionId:StrProperty,Distance:FloatProperty,HeightOffset:FloatProperty,bAllowPersistence:FloatProperty"
        if params(class, "SpawnVehicle") ~= expected then error("SpawnVehicle signature changed before construction.") end
        -- Same owner/flags as the existing Solo inventory native-setter path.
        -- Do not enable general controller cheats or replace pc.CheatManager.
        private_manager = StaticConstructObject(class, pc, 0, 64)
        manager = private_manager
        log("PRIVATE_MANAGER_CONSTRUCTED " .. tostring(valid(manager)))
    end
    if not valid(manager) then error("Solo native spawn owner unavailable.") end
    local outer = manager:GetOuter()
    if not valid(outer) or outer:GetAddress() ~= pc:GetAddress() then error("Native spawn owner is not the verified Solo controller.") end
    local expected = "VehicleClassName:StrProperty,VehicleTemplateName:StrProperty,FactionId:StrProperty,Distance:FloatProperty,HeightOffset:FloatProperty,bAllowPersistence:FloatProperty"
    if params(manager:GetClass(), "SpawnVehicle") ~= expected then error("SpawnVehicle signature changed; no spawn attempted.") end
    return manager
end
local function inspect_item_field(table_object)
    local identity = table_object:GetRowStruct()
    local row_path = "/Script/DuneSandbox.BaseVehicleModuleTableRow"
    if not valid(identity) or identity:GetFullName() ~= "ScriptStruct " .. row_path then error("Tank module row structure changed.") end
    -- The pinned runtime exposes an identity wrapper here; enumerate the metadata separately.
    local structure = find(row_path)
    local item_structure
    structure:ForEachProperty(function(property)
        if text(property:GetFName()) == "m_ItemTemplate" then item_structure = property:GetStruct() end
    end)
    local item_path = "/Script/DuneSandboxCore.EItemTemplateID"
    if not valid(item_structure) or item_structure:GetFullName() ~= "ScriptStruct " .. item_path then error("Item-template struct reflection changed.") end
    item_structure = find(item_path)
    local fields, seen, finished = {}, {}, false
    for depth = 1, 16 do
        if not valid(item_structure) then finished = true; break end
        local identity = item_structure:GetFullName()
        if seen[identity] then error("Cyclic item-template inheritance.") end
        seen[identity] = true
        log("ITEM_ID_STRUCT " .. identity)
        item_structure:ForEachProperty(function(property)
            local name = text(property:GetFName())
            local kind = text(property:GetClass():GetFName())
            log("ITEM_ID_FIELD " .. name .. ":" .. kind)
            if #fields >= 16 then error("Unexpected item-template field count.") end
            fields[#fields + 1] = {name = name, kind = kind, offset = property:GetOffset_Internal()}
        end)
        item_structure = item_structure:GetSuperStruct()
    end
    if not finished and valid(item_structure) then error("Item-template inheritance exceeds its bound.") end
    if #fields ~= 1 or fields[1].name ~= "Name" or fields[1].kind ~= "NameProperty" or fields[1].offset ~= 0 then
        error("Item-template ID does not match the single Name FName at offset zero; reflected fields=" .. #fields)
    end
    return fields[1].name
end
local function prepare_rows()
    local dt = find(MODULES)
    local field = inspect_item_field(dt)
    local replacements = {
        TankGenerator_6 = {old = "TankGenerator_6", new = "TreadwheelGenerator_6"},
        TankLocomotionFrontLeft_6 = {old = "TankLocomotion_6", new = "TreadwheelLocomotion_6"},
        TankLocomotionFrontRight_6 = {old = "TankLocomotion_6", new = "TreadwheelLocomotion_6"},
        TankLocomotionBackLeft_6 = {old = "TankLocomotion_6", new = "TreadwheelLocomotion_6"},
        TankLocomotionBackRight_6 = {old = "TankLocomotion_6", new = "TreadwheelLocomotion_6"},
    }
    local changes = {}
    dt:ForEachRow(function(row_name, row)
        local name = text(row_name)
        local expected = replacements[name]
        if expected then
            local item = row.m_ItemTemplate
            local old = text(item[field])
            log("ITEM_ID " .. name .. "=" .. old)
            if old ~= expected.old then error("Tank item identity differs: " .. name .. "=" .. old) end
            changes[#changes + 1] = {dt = dt, row = row, item = item, field = field, old = old, new = expected.new, name = name}
        end
    end)
    if #changes ~= 5 then error("Expected five exact Tank-only item bindings; found " .. #changes) end
    return changes
end
local function verify_preset()
    local found = false
    find(TEMPLATES):ForEachRow(function(row_name, row)
        if text(row_name) == "Tank" then found = row.m_Templates:Contains(FName("T6_CombatFire")) and row.m_Templates:Contains(FName("T6_CombatDart")) end
    end)
    if not found then error("Stock Tank presets unavailable.") end
end
local function prepare_tank_item_flags()
    local items = find("/Game/Dune/Systems/Items/CDT_BaseItems.CDT_BaseItems")
    local meta = find("/Script/DuneSandbox.BaseItemTableRow")
    local flag
    for depth = 1, 16 do
        if not valid(meta) then break end
        meta:ForEachProperty(function(property)
            if text(property:GetFName()) == "bIsDeprecated" then
                if flag then error("Ambiguous item deprecation field.") end
                if text(property:GetClass():GetFName()) ~= "BoolProperty" or property:GetOffset_Internal() ~= 0x2c0 then error("Native item-deprecation field does not match inspected Windows spawner.") end
                flag = true
            end
        end)
        meta = meta:GetSuperStruct()
    end
    if not flag then error("Native item-deprecation metadata unavailable.") end
    local wanted = {"TankChassis_6", "TankEngine_6", "TankHull_6", "TankHullFront_6", "TankInventory_6", "TankDart_6", "TankBoost_6", "TankFire_6"}
    local candidates = {}
    items:ForEachRow(function(name, row)
        name = text(name)
        for _, wanted_name in ipairs(wanted) do
            if name == wanted_name then
                if type(row.bIsDeprecated) ~= "boolean" then error("Tank item-deprecation value unavailable: " .. name) end
                -- Do not change disabled item content or entitlement settings.
                if row.StaticData.bIsEnabled ~= true then error("Stock Tank item is disabled: " .. name .. "; enabled/entitlement gates retained.") end
                log("TANK_ITEM_FLAG " .. name .. " deprecated=" .. tostring(row.bIsDeprecated) .. "; enabled=true")
                candidates[#candidates + 1] = {name=name, row=row, old=row.bIsDeprecated}
            end
        end
    end)
    if #candidates ~= #wanted then error("Expected eight exact stock Tank item rows; found " .. #candidates) end
    return candidates
end
local function restore()
    for i = #item_journal, 1, -1 do
        local entry = item_journal[i]
        local ok, err = pcall(function() entry.row.bIsDeprecated = entry.old end)
        if not ok then log("ITEM_FLAG_RESTORE_ERROR " .. tostring(err)) end
    end
    item_journal = {}
    for i = #journal, 1, -1 do
        local change = journal[i]
        local ok, err = pcall(function()
            change.item[change.field] = FName(change.old)
        end)
        if not ok then log("RESTORE_ERROR " .. tostring(err)) end
    end
    journal = {}
    if valid(tank_cdo) and type(prior_deprecated) == "boolean" then
        local ok, err = pcall(function() tank_cdo.m_bIsDeprecated = prior_deprecated end)
        if not ok then log("RESTORE_ERROR " .. tostring(err)) end
    end
    enabled = false
end
local function inspect_spawn()
    local tanks = FindAllOf("BP_Tank_CHOAM_C") or {}
    if #tanks < 1 then error("No loaded Tank observed.") end
    local count = 0
    for _, tank in ipairs(FindAllOf("BP_Tank_CHOAM_C") or {}) do
        if valid(tank) and standalone(tank) then
            count = count + 1
            local before = #tank:GetVehicleModules()
            log("TANK_MODULES_BEFORE " .. before)

            local module_count = #tank:GetVehicleModules()
            local mandatory = tank:HasAllMandatoryModules()
            log("TANK_OBSERVED modules=" .. tostring(module_count) .. "; mandatory=" .. tostring(mandatory) .. "; deprecated=" .. tostring(tank.m_bIsDeprecated))
            log("Persistence requested via native SpawnVehicle; save and cold-reload acceptance required.")
        end
    end
    log("TANK_COUNT " .. count)
    log("PERSISTENCE_OBSERVATION; native save and cold-reload survival remain to be verified.")
end
local function audit_remaining_contracts()
    local problems = 0
    local checks = {
        {"Tank preset", verify_preset},
        {"Stock Tank item-deprecation flags", prepare_tank_item_flags},
        {"Tank item schema and identities", prepare_rows},
        {"Tank class default", function()
            local cdo = find(TANK):GetCDO()
            if not valid(cdo) or type(cdo.m_bIsDeprecated) ~= "boolean" then error("Tank default unavailable.") end
        end},
    }
    for _, check in ipairs(checks) do
        local ok, err = pcall(check[2])
        if ok then log("PREFLIGHT_OK " .. check[1])
        else problems = problems + 1; log("PREFLIGHT_ERROR " .. check[1] .. ": " .. tostring(err)) end
    end
    if problems > 0 then error("Remaining preflight checks failed; all failures recorded, no spawn attempted.") end
end
local function prepare_compatibility(context)
    verify_launch_context()
    if not standalone(context) then error("Tank load is outside verified Solo; no changes made.") end
    if enabled then return end
    if preparing then error("Tank compatibility initialization is already in progress.") end
    preparing = true
    local ok, problem = pcall(function()
        audit_remaining_contracts()
        tank_class = find(TANK)
        tank_cdo = tank_class:GetCDO()
    local changes = prepare_rows()
    local item_changes = prepare_tank_item_flags()
    prior_deprecated = tank_cdo.m_bIsDeprecated
    for _, entry in ipairs(item_changes) do
        item_journal[#item_journal+1] = entry
        entry.row.bIsDeprecated = false
        if entry.row.bIsDeprecated ~= false then error("Tank item-deprecation readback failed: " .. entry.name) end
        log("TANK_ITEM_FLAG_APPLIED " .. entry.name)
    end
    for _, change in ipairs(changes) do
        journal[#journal + 1] = change
        change.item[change.field] = FName(change.new)
    end
    local readback = 0
    find(MODULES):ForEachRow(function(row_name, row)
        local key = text(row_name)
        for _, change in ipairs(changes) do
            if key == change.name then
                if text(row.m_ItemTemplate[change.field]) ~= change.new then error("Tank item table readback failed: " .. key) end
                readback = readback + 1
            end
        end
    end)
    if readback ~= 5 then error("Tank item table readback incomplete.") end
    for _, change in ipairs(changes) do
        log("ITEM_ID_APPLIED " .. change.name .. "=" .. change.new)
    end
    tank_cdo.m_bIsDeprecated = false
    if tank_cdo.m_bIsDeprecated ~= false then error("Tank deprecation readback failed.") end
    enabled = true
    end)
    preparing = false
    if not ok then restore(); error(problem) end
    log("PERSISTENCE_COMPATIBILITY_READY")
end
local function spawn(preset)
    if used[preset] or pending then return false, "One grant per variant per launch. Reload Solo to grant another." end
    pending = true
    local previously_enabled = enabled
    local ok, err = pcall(function()
        verify_launch_context()
        local pc = controller()
        local manager = cheat_manager(pc)
        verify_preset()
        tank_class = find(TANK)
        tank_cdo = tank_class:GetCDO()
        if not valid(tank_cdo) or type(tank_cdo.m_bIsDeprecated) ~= "boolean" then error("Tank deprecation property unavailable.") end
        prepare_compatibility(pc)
        used[preset] = true
        log("SPAWN_REQUEST row=Tank preset=" .. preset .. "; persistence=1.")
        manager:SpawnVehicle("Tank", preset, "", 1000.0, 100.0, 1.0)
        ExecuteWithDelay(3000, function() ExecuteInGameThread(function()
            local success, problem = pcall(inspect_spawn)
            if not success then log("INSPECT_ERROR " .. tostring(problem)) end
        end) end)
    end)
    if not ok then if not previously_enabled then restore() end; log("GRANT_ERROR " .. tostring(err)) end
    pending = false
    return ok, err
end
log("LOADED: Solo-only; grant Dart or Flamethrower using DST buttons. Saved Tanks require this support on reload.")
log("No server operations, executable patches, cooked-asset installs or direct save writes.")
NotifyOnNewObject("/Script/DuneSandbox.DuneTankVehicle", function(object)
    if preparing then return end
    local ok, err = pcall(function()
        if valid(object) and valid(object:GetClass()) and object:GetClass():GetFullName() == "BlueprintGeneratedClass " .. TANK then
            -- Reapply compatibility before native BeginPlay for a saved actor.
            -- Game-declared Solo and reflected contract checks precede preparation.
            prepare_compatibility(object)
            object.m_bIsDeprecated = false
            if object.m_bIsDeprecated ~= false then error("Loaded Tank deprecation readback failed.") end
            log("PERSISTENCE_TANK_CONSTRUCTION_READY")
        end
    end)
    if not ok then log("TANK_CONSTRUCTION_ERROR " .. tostring(err)) end
end)
local command_root
if script_path then
    local context = io.open(script_path .. "dst-command-root.txt", "r")
    if context then command_root = context:read("*l"); context:close() end
end
local function poll_grants()
    if command_root then
        local request_path = command_root .. "\\tank-request.txt"
        local request = io.open(request_path, "r")
        if request then
            local text = request:read("*a"); request:close()
            local id, preset = text:match("^([0-9a-f]+)|([%w_]+)$")
            if id and #id == 32 and (preset == "T6_CombatDart" or preset == "T6_CombatFire") then
                os.remove(request_path)
                ExecuteInGameThread(function()
                    local ok, err = spawn(preset)
                    local temp = command_root .. "\\tank-response.tmp"
                    local response = io.open(temp, "w")
                    if response then
                        response:write(id .. "|" .. (ok and "ok" or "error") .. "|" .. tostring(err or "Grant requested"):gsub("[|\r\n]", " "))
                        response:close()
                        os.remove(command_root .. "\\tank-response.txt")
                        os.rename(temp, command_root .. "\\tank-response.txt")
                    end
                end)
            end
        end
    end
    ExecuteWithDelay(500, poll_grants)
end
ExecuteWithDelay(500, poll_grants)
