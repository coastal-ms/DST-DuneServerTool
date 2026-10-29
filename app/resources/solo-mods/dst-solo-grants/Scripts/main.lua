-- DST-owned bridge. Native calls only in verified Solo; never edits a save.
local source = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local rewards = dofile(source .. "rewards.lua")
local valid, text, find, params = rewards.valid, rewards.text, rewards.find, rewards.params
local function read(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil end
    local value = f:read((limit or 65536) + 1); f:close()
    assert(not value or #value <= (limit or 65536), "Grant file exceeds its limit")
    return value or "" -- distinguish an existing empty claim from a missing file
end
local function write(path, value)
    local f = assert(io.open(path .. ".tmp", "wb"), "Cannot write grant receipt")
    assert(f:write(value)); assert(f:close())
    -- Windows rename cannot replace an existing file. A failed replacement is
    -- visible as processing/uncertain; it must never trigger automatic replay.
    os.remove(path)
    assert(os.rename(path .. ".tmp", path), "Cannot publish grant receipt")
end
local config = read(source .. "dst-command-root.txt", 4096)
local root, nonce
if config then root, nonce = config:match("^([^|\r\n]+)|([a-f0-9]+)$") end
local function receipt(id, status, completed, message)
    message = tostring(message):gsub("[|\r\n]", " "):sub(1, 400)
    write(root .. "/" .. id .. ".result", status .. "|" .. completed .. "|" .. message)
end
local function hex(value)
    return (value:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function uid(pc, getter)
    assert(params(pc:GetClass(), getter) == "ReturnValue:StructProperty", "Character identity contract changed")
    local result = pc[getter](pc)
    local value = result.UID
    -- The pinned bridge preserves int64 as a Lua integer. A floating-point UID
    -- cannot safely bind a request to a character.
    assert(math.type(value) == "integer", "Character identity is not an exact integer")
    return tostring(value)
end
local manager, manager_owner
local function native_manager(pc)
    local expected = "InItemName:NameProperty,InQuantity:IntProperty,InDurability:FloatProperty,InQuality:ByteProperty"
    local class = find("/Script/DuneSandbox.DuneCheatManager")
    assert(params(class, "AddItemToInventory") == expected, "Inventory grant contract changed")
    if not valid(manager) or manager_owner ~= pc:GetAddress() then
        manager = pc.CheatManager
        if not valid(manager) then manager = StaticConstructObject(class, pc, 0, 64) end
        manager_owner = pc:GetAddress()
    end
    assert(valid(manager) and valid(manager:GetOuter()) and manager:GetOuter():GetAddress() == pc:GetAddress(), "Inventory grant owner differs")
    assert(params(manager:GetClass(), "AddItemToInventory") == expected, "Inventory grant contract changed")
    return manager
end
local function item_count(pawn, template)
    assert(params(pawn:GetClass(), "GetNumberOfItemsInBackpackInventory") == "InItemTemplateID:StructProperty,ReturnValue:IntProperty", "Inventory readback contract changed")
    local structure = find("/Script/DuneSandboxCore.EItemTemplateID")
    local fields = {}
    for _ = 1, 16 do
        if not valid(structure) then break end
        structure:ForEachProperty(function(p)
            fields[#fields + 1] = text(p:GetFName()) .. ":" .. text(p:GetClass():GetFName()) .. ":" .. p:GetOffset_Internal()
        end)
        structure = structure:GetSuperStruct()
    end
    assert(#fields == 1 and fields[1] == "Name:NameProperty:0", "Item identity layout changed")
    local count = pawn:GetNumberOfItemsInBackpackInventory({Name=FName(template)})
    assert(math.type(count) == "integer" and count >= 0, "Invalid inventory readback")
    return count
end
local function parse(id, data)
    local lines = {}; for line in data:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    local version, request, account, controller, name = (lines[1] or ""):match("^(%d+)|([a-f0-9]+)|(-?%d+)|(-?%d+)|([a-f0-9]+)$")
    assert(version == "1" and request == id and #id == 32 and #name <= 1024, "Invalid grant identity")
    local items = {}
    for i = 2, #lines do
        local template, quantity, quality = lines[i]:match("^([%w_()/%-]+)|(%d+)|(%d+)$")
        quantity, quality = tonumber(quantity), tonumber(quality)
        assert(template and #template <= 180 and quantity and quantity >= 1 and quantity <= 100000 and quality and quality <= 5, "Invalid grant item")
        items[#items + 1] = {template=template, quantity=quantity, quality=quality}
    end
    assert(#items >= 1 and #items <= 200, "Invalid grant batch")
    return {id=id, account=account, controller=controller, name=name, items=items, completed=0}
end
local active, last_ready
local function deliver(session)
    if not root or not nonce then return end
    if not session or not valid(session.pc) or not valid(session.pawn) then
        os.remove(root .. "/ready.txt"); last_ready = nil
        return
    end
    local pc, pawn = session.pc, session.pawn
    local id = active and active.id
    if not id then
        for candidate in (read(root .. "/queue.txt", 4096) or ""):gmatch("[^\r\n]+") do
            assert(#candidate == 32 and candidate:match("^[a-f0-9]+$"), "Invalid request identifier")
            local prior = read(root .. "/" .. candidate .. ".result", 512)
            if (prior and prior:match("^processing|")) or (not prior and read(root .. "/" .. candidate .. ".claim", 64)) then
                receipt(candidate, "uncertain", (prior and tonumber(prior:match("^[^|]+|(%d+)|"))) or 0, "Interrupted delivery. Check your backpack before creating another grant.")
            elseif not prior then id = candidate; break end
        end
    end
    if not id then return end
    assert(#id == 32 and id:match("^[a-f0-9]+$"), "Invalid request identifier")
    if active and active.id ~= id then active = nil end
    if not active then
        local prior = read(root .. "/" .. id .. ".result", 512)
        if prior or read(root .. "/" .. id .. ".claim", 64) then
            if not prior or prior:match("^processing|") then receipt(id, "uncertain", prior and tonumber(prior:match("^[^|]+|(%d+)|")) or 0, "Interrupted delivery. Check your backpack before creating another grant.") end
            return -- durable claim: never replay even after a bridge/game restart
        end
        active = parse(id, assert(read(root .. "/" .. id .. ".request"), "Missing grant request"))
    end
    local job = active
    local account, controller = uid(pc, "GetAccountId"), uid(pc, "GetPersistenceId")
    local state = pc.PlayerState
    assert(valid(state) and params(state:GetClass(), "GetPlayerName") == "ReturnValue:StrProperty", "Character name contract changed")
    local name = hex(text(state:GetPlayerName()))
    local ready = nonce .. "|" .. account .. "|" .. controller .. "|" .. name
    if ready ~= last_ready then write(root .. "/ready.txt", ready); last_ready = ready end
    if job.account ~= account or job.controller ~= controller or job.name ~= name then return end
    assert(not job.world or job.world == session.world, "Solo world changed during delivery")
    assert(not job.generation or job.generation == session.generation, "Solo session changed during delivery")
    job.world, job.generation = session.world, session.generation
    local item = job.items[job.completed + 1]
    if job.before then
        local after = item_count(pawn, item.template)
        print("[DSTSoloGrants] GRANT CHECK template=" .. item.template .. " before=" .. job.before .. " after=" .. after .. " requested=" .. item.quantity .. "\n")
        assert(after == job.before + item.quantity, "Delivery could not be confirmed. Check your backpack and unlocks before retrying.")
        job.completed = job.completed + 1
        job.before = nil
        receipt(id, job.completed == #job.items and "delivered" or "processing", job.completed, "Backpack delivery verified in game.")
        if job.completed == #job.items then active = nil; return end
        item = job.items[job.completed + 1]
    end
    local owner = native_manager(pc)
    job.before = item_count(pawn, item.template)
    -- Immutable separate claim survives a crash during receipt replacement on
    -- Windows. Updating a status file must never erase the replay barrier.
    if job.completed == 0 then
        assert(not read(root .. "/" .. id .. ".claim", 64), "Grant was already claimed")
        write(root .. "/" .. id .. ".claim", nonce)
    end
    -- Claim before the call. A crash after this point is uncertain, never retried.
    receipt(id, "processing", job.completed, "Delivering selected items.")
    owner:AddItemToInventory(FName(item.template), item.quantity, 1.0, item.quality)
end
local scheduled = false
local startup_ticks = 0
local function tick()
    scheduled = false
    local session = rewards.step()
    if root and rewards.failure() then pcall(write, root .. "/bridge-error.txt", rewards.failure()) end
    local ok, why = pcall(deliver, session)
    if not ok then
        local message = (tostring(why):match(":%d+: (.+)") or tostring(why)):gsub("[\r\n]", " "):sub(1, 400)
        if root then
            os.remove(root .. "/ready.txt")
            if active then pcall(receipt, active.id, "uncertain", active.completed, message); active = nil end
        end
        print("[DSTSoloGrants] " .. tostring(why) .. "\n")
        if root then pcall(write, root .. "/bridge-error.txt", message) end
    end
    -- Fast startup observation before a controller/pawn exists; modest cadence
    -- once Solo settings are active. No catalog grants run on startup.
    startup_ticks = startup_ticks + 1
    if not scheduled then scheduled = true; ExecuteInGameThreadWithDelay((session or startup_ticks > 400) and 500 or 50, tick) end
end
ExecuteInGameThreadWithDelay(0, tick)
