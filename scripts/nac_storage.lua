-- Server-side ingredient transactions and preservation-aware output routing.
local M = {}
local EXCLUDE = { "INLIMBO", "NOCLICK", "FX", "DECOR", "burnt" }

-- Arcadiea's verified freezer refreshes food periodically. This is a routing
-- preference, not a change to that mod's actual perishable component.
local PRESERVATION = { mega_freezer = 0 }

local function IsValid(inst)
    return inst ~= nil and inst:IsValid()
end

local function IsAvailable(inst)
    return IsValid(inst) and not inst:HasTag("INLIMBO")
        and not inst:HasTag("NOCLICK") and not inst:HasTag("burnt")
        and not inst:HasTag("FX") and not inst:HasTag("DECOR")
        and not (inst.components.burnable ~= nil and inst.components.burnable:IsBurning())
end

function M.IsStorage(inst)
    if not IsAvailable(inst) then
        return false
    end
    local c = inst.components
    local container = c.container
    return container ~= nil and c.inventoryitem == nil and c.inventory == nil
        and c.health == nil and c.locomotor == nil
        and c.stewer == nil and c.brewer == nil and c.melter == nil
        and c.container_proxy == nil and c.pocketdimensioncontainer == nil
        and inst.prefab ~= "shadow_container"
        and inst.entity:GetParent() == nil
        and (inst:HasTag("structure") or inst:HasTag("fridge")
            or inst:HasTag("foodpreserver") or c.preserver ~= nil)
        and (container.type == "chest" or container.type == nil)
        -- Open storage remains usable. Source references and quantities are
        -- revalidated immediately before withdrawal, including between callbacks.
        -- Deliberately ignore the retired skip_open option from older callers.
        and container.canbeopened ~= false and not container.readonlycontainer
end

local function IsUsableItem(item)
    local inventoryitem = IsValid(item) and item.components.inventoryitem or nil
    return inventoryitem ~= nil and not inventoryitem.islockedinslot
        and item.components.itemmimic == nil
        and not item:HasTag("burnt")
        and not (item.components.burnable ~= nil and item.components.burnable:IsBurning())
end

function M.IsGroundItem(item)
    return IsAvailable(item) and IsUsableItem(item)
        and item.components.inventoryitem.owner == nil
        and item.components.inventoryitem.canbepickedup ~= false
        and item.entity:GetParent() == nil
end

local function StackSize(item)
    return item.components.stackable ~= nil and item.components.stackable:StackSize() or 1
end

local function SortByDistance(inst, entities)
    table.sort(entities, function(a, b)
        local da, db = inst:GetDistanceSqToInst(a), inst:GetDistanceSqToInst(b)
        return da == db and a.GUID < b.GUID or da < db
    end)
end

function M.FindSources(inst, config)
    config = config or {}
    local sources = { containers = {}, ground = {} }
    if not IsValid(inst) then
        return sources
    end
    local x, y, z = inst.Transform:GetWorldPosition()
    -- No required tag: custom cellars need not advertise the vanilla chest tag.
    for _, entity in ipairs(TheSim:FindEntities(x, y, z, config.radius or 12, nil, EXCLUDE)) do
        if entity ~= inst then
            if M.IsStorage(entity, config) then
                sources.containers[#sources.containers + 1] = entity
            elseif config.ground ~= false and M.IsGroundItem(entity) then
                sources.ground[#sources.ground + 1] = entity
            end
        end
    end
    SortByDistance(inst, sources.containers)
    SortByDistance(inst, sources.ground)
    return sources
end

local function NormalizeRecipe(recipe)
    if type(recipe) ~= "table" then
        return nil
    end
    local ordered = {}
    if #recipe > 0 then
        for _, entry in ipairs(recipe) do
            if type(entry) ~= "table" then
                return nil
            end
            ordered[#ordered + 1] = { prefab = entry.prefab, count = entry.count }
        end
    else
        for prefab, count in pairs(recipe) do
            ordered[#ordered + 1] = { prefab = prefab, count = count }
        end
        table.sort(ordered, function(a, b) return tostring(a.prefab) < tostring(b.prefab) end)
    end
    for _, entry in ipairs(ordered) do
        if type(entry.prefab) ~= "string" or entry.prefab == ""
            or type(entry.count) ~= "number" or entry.count < 1
            or entry.count == math.huge or entry.count ~= math.floor(entry.count) then
            return nil
        end
    end
    return ordered
end

-- A plan only reserves references in Lua. Nothing moves until TakeIngredients.
-- Every entry represents exactly one item, in the supplied recipe order.
function M.PlanIngredients(inst, recipe, config)
    local ordered = NormalizeRecipe(recipe)
    if ordered == nil or not IsValid(inst) then
        return nil, "invalid_recipe"
    end
    local sources = M.FindSources(inst, config)
    local wanted, pools = {}, {}
    for _, entry in ipairs(ordered) do
        wanted[entry.prefab] = true
    end
    local function AddCandidate(item, container, slot, pos)
        if IsUsableItem(item) and wanted[item.prefab] then
            local pool = pools[item.prefab]
            if pool == nil then
                pool = {}
                pools[item.prefab] = pool
            end
            pool[#pool + 1] = {
                item = item, container = container, slot = slot, pos = pos,
                available = StackSize(item),
            }
        end
    end
    for _, chest in ipairs(sources.containers) do
        local container = chest.components.container
        for slot = 1, container:GetNumSlots() do
            AddCandidate(container:GetItemInSlot(slot), container, slot, chest:GetPosition())
        end
    end
    for _, item in ipairs(sources.ground) do
        AddCandidate(item, nil, nil, item:GetPosition())
    end
    local plan = { entries = {}, inst = inst, config = config or {}, pos = inst:GetPosition() }
    for _, required in ipairs(ordered) do
        local needed = required.count
        for _, candidate in ipairs(pools[required.prefab] or {}) do
            local take = math.min(needed, candidate.available)
            for _ = 1, take do
                plan.entries[#plan.entries + 1] = {
                    item = candidate.item, container = candidate.container,
                    slot = candidate.slot, pos = candidate.pos, prefab = required.prefab,
                }
            end
            needed = needed - take
            candidate.available = candidate.available - take
            if needed == 0 then
                break
            end
        end
        if needed > 0 then
            return nil, "missing_ingredients"
        end
    end
    return plan
end

local function CandidateIsAvailable(entry, config)
    if not IsUsableItem(entry.item) or entry.item.prefab ~= entry.prefab then
        return false
    end
    if entry.container ~= nil then
        return M.IsStorage(entry.container.inst, config)
            and entry.container.inst.components.container == entry.container
            and entry.container:GetItemInSlot(entry.slot) == entry.item
            and entry.item.components.inventoryitem.owner == entry.container.inst
    end
    return M.IsGroundItem(entry.item)
end

local function IsDetached(item)
    return IsValid(item) and item.components.inventoryitem ~= nil
        and item.components.inventoryitem.owner == nil
end

local function DropAt(item, pos)
    if IsDetached(item) then
        item.Transform:SetPosition(pos:Get())
        item.components.inventoryitem:OnDropped(true)
    end
end

-- GiveItem may partially merge a stack and return false. Inspect the surviving
-- object and its owner; neither the boolean nor the old stack count is enough.
local function Give(container, item, slot, pos)
    local before = StackSize(item)
    container:GiveItem(item, slot, pos, false)
    if not IsValid(item) then
        return before, true
    end
    if item.components.inventoryitem.owner ~= nil then
        return before, true
    end
    return math.max(0, before - StackSize(item)), false
end

function M.ReturnIngredients(records, fallback_pos)
    for _, record in ipairs(records or {}) do
        local item, origin = record.item, record.origin
        if IsDetached(item) then
            local pos = origin ~= nil and origin.pos or fallback_pos or item:GetPosition()
            local container = origin ~= nil and origin.container or nil
            if container ~= nil and M.IsStorage(container.inst, record.config)
                and container.inst.components.container == container then
                Give(container, item, origin.slot, pos)
            elseif origin ~= nil and origin.item ~= item and M.IsGroundItem(origin.item)
                and origin.item.components.stackable ~= nil
                and item.components.stackable ~= nil
                and origin.item.components.stackable:CanStackWith(item) then
                origin.item.components.stackable:Put(item, pos)
            end
            DropAt(item, pos)
        end
    end
end

function M.TakeIngredients(plan)
    if type(plan) ~= "table" or type(plan.entries) ~= "table" or plan.taken then
        return nil, "invalid_plan"
    end
    local counts = {}
    -- Check the entire plan before moving even its first item.
    for _, entry in ipairs(plan.entries) do
        if not CandidateIsAvailable(entry, plan.config) then
            return nil, "ingredients_changed"
        end
        counts[entry.item] = (counts[entry.item] or 0) + 1
        if counts[entry.item] > StackSize(entry.item) then
            return nil, "ingredients_changed"
        end
    end
    plan.taken = true
    local records = {}
    for _, entry in ipairs(plan.entries) do
        if not CandidateIsAvailable(entry, plan.config) then
            M.ReturnIngredients(records, plan.pos)
            return nil, "ingredients_changed"
        end
        local item
        if entry.container ~= nil then
            item = entry.container:RemoveItem(entry.item, false)
        elseif entry.item.components.stackable ~= nil then
            item = entry.item.components.stackable:Get(1)
        else
            item = entry.item
        end
        if IsDetached(item) then
            item.Transform:SetPosition(entry.pos:Get())
            records[#records + 1] = { item = item, origin = entry, config = plan.config }
        end
        -- Split/remove callbacks can change the source or the returned object.
        if not IsDetached(item) or item.prefab ~= entry.prefab or StackSize(item) ~= 1 then
            M.ReturnIngredients(records, plan.pos)
            return nil, "ingredient_transfer_failed"
        end
    end
    return records
end

function M.RegisterPreservation(prefab, rate_or_fn)
    assert(type(prefab) == "string", "prefab must be a string")
    assert(rate_or_fn == nil or type(rate_or_fn) == "number" or type(rate_or_fn) == "function",
        "preservation preference must be a number, function, or nil")
    PRESERVATION[prefab] = rate_or_fn
end

local function NumericRate(value)
    return type(value) == "number" and value == value and value or nil
end

function M.PreservationRate(inst, item)
    local override = PRESERVATION[inst.prefab]
    if type(override) == "function" then
        local ok, value = pcall(override, inst, item)
        override = ok and value or nil
    end
    local rate = NumericRate(override)
    if rate ~= nil then
        return rate
    end
    local preserver = inst.components.preserver
    if preserver ~= nil then
        local ok, value = pcall(preserver.GetPerishRateMultiplier, preserver, item)
        rate = ok and NumericRate(value) or nil
    end
    if rate == nil then
        if inst:HasTag("fridge") then
            rate = item ~= nil and item:HasTag("frozen")
                and not inst:HasTag("nocool") and not inst:HasTag("lowcool")
                and TUNING.PERISH_COLD_FROZEN_MULT or TUNING.PERISH_FRIDGE_MULT
        elseif inst:HasTag("foodpreserver") then
            rate = TUNING.PERISH_FOOD_PRESERVER_MULT
        else
            rate = 1
        end
    end
    if inst:HasTag("spoiler") then
        rate = rate * TUNING.PERISH_GROUND_MULT
    end
    return rate
end

local function AcceptingSlot(container, item)
    local empty
    for slot = 1, container:GetNumSlots() do
        if container:CanTakeItemInSlot(item, slot) then
            local existing = container:GetItemInSlot(slot)
            if existing == nil then
                empty = empty or slot
            elseif container.acceptsstacks ~= false and existing.components.stackable ~= nil
                and item.components.stackable ~= nil
                and existing.components.stackable:CanStackWith(item)
                and not existing.components.stackable:IsFull() then
                return slot
            end
        end
    end
    return empty
end

local function AddRoute(routes, target, count, pos)
    if count <= 0 then
        return
    end
    local previous = routes[#routes]
    if previous ~= nil and previous.target == target then
        previous.count = previous.count + count
    else
        routes[#routes + 1] = { target = target, count = count, pos = pos }
    end
end

-- Returns the last destination (nil for a ground remainder) and exact routes.
-- The item must already be detached from its cooking building/inventory.
function M.StoreProduct(inst, item, config)
    local routes = {}
    if not IsDetached(item) then
        return nil, routes
    end
    local pos = IsValid(inst) and inst:GetPosition() or item:GetPosition()
    local candidates = M.FindSources(inst, config).containers
    local rates = {}
    for _, chest in ipairs(candidates) do
        rates[chest] = M.PreservationRate(chest, item)
    end
    table.sort(candidates, function(a, b)
        if rates[a] ~= rates[b] then
            return rates[a] < rates[b]
        end
        local da, db = inst:GetDistanceSqToInst(a), inst:GetDistanceSqToInst(b)
        return da == db and a.GUID < b.GUID or da < db
    end)
    for _, chest in ipairs(candidates) do
        if M.IsStorage(chest, config) then
            local container = chest.components.container
            -- A non-stacking container may accept only one item per GiveItem.
            for _ = 1, container:GetNumSlots() + 1 do
                if not M.IsStorage(chest, config) or chest.components.container ~= container then
                    break
                end
                local slot = AcceptingSlot(container, item)
                if slot == nil then
                    break
                end
                local destination_pos = chest:GetPosition()
                local accepted, finished = Give(container, item, slot, pos)
                AddRoute(routes, chest, accepted, destination_pos)
                if finished then
                    return chest, routes
                elseif accepted == 0 then
                    break
                end
            end
        end
    end
    if IsDetached(item) then
        AddRoute(routes, nil, StackSize(item), pos)
        DropAt(item, pos)
    end
    return nil, routes
end

return M
