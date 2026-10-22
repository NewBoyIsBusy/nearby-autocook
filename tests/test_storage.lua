-- Native game components, minimal entity/network/physics harness.
require("class")
package.loaded.containers = {}
GetGameModeProperty = function() return false end
TUNING = {
    STACK_SIZE_MEDITEM = 40, PERISH_FRIDGE_MULT = .5,
    PERISH_COLD_FROZEN_MULT = 0, PERISH_FOOD_PRESERVER_MULT = 0,
    PERISH_GROUND_MULT = 1.5,
}
MAXUINT = 4294967295
local Container = require("components/container")
local Stackable = require("components/stackable")
local Storage = require("nac_storage")
local world, guid, passed = {}, 0, 0
local function noop() end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end

local function entity(name, x, tags)
    guid = guid + 1
    local e = { prefab = name, GUID = guid, x = x or 0, z = 0, tags = tags or {}, components = {} }
    function e:IsValid() return not self.removed end
    function e:Remove() self.removed = true end
    function e:HasTag(tag) return self.tags[tag] == true end
    function e:PushEvent(name, data) if self.callback then self.callback(name, data) end end
    function e:GetDistanceSqToInst(other) return (self.x - other.x)^2 end
    function e:GetPosition()
        local x = self.x
        return { x = x, y = 0, z = 0, Get = function() return x, 0, 0 end }
    end
    e.ListenForEvent = noop
    e.Transform = {
        GetWorldPosition = function() return e.x, 0, 0 end,
        SetPosition = function(_, x) e.x = x end,
    }
    e.entity = { GetParent = function() return e.parent end }
    e.replica = {
        container = setmetatable({}, { __index = function() return noop end }),
        stackable = setmetatable({}, { __index = function() return noop end }),
    }
    world[#world + 1] = e
    return e
end

local function item(name, n, x)
    local e = entity(name, x, { _inventoryitem = true })
    local inventoryitem = {
        cangoincontainer = true, owner = nil,
        GetMoisture = function() return 0 end,
        IsWet = function() return false end,
        GetTemperature = function() return 20 end,
    }
    function inventoryitem:OnPutInInventory(owner) self.owner = owner; e.tags.INLIMBO = true end
    function inventoryitem:OnRemoved() self.owner = nil; e.tags.INLIMBO = nil end
    function inventoryitem:OnDropped() self:OnRemoved(); e.dropped = true end
    inventoryitem.InheritMoisture = noop
    inventoryitem.SetTemperature = noop
    inventoryitem.DiluteMoisture = noop
    inventoryitem.DiluteTemperature = noop
    e.components.inventoryitem = inventoryitem
    e.components.stackable = Stackable(e)
    e.components.stackable:SetStackSize(n or 1)
    return e
end
SpawnPrefab = function(name) return item(name, 1) end

local function chest(name, x, size)
    local e = entity(name, x, { structure = true })
    e.components.container = Container(e)
    e.components.container.type = "chest"
    e.components.container.numslots = size or 2
    return e
end
local function put(owner, object, slot)
    assert(owner.components.container:GiveItem(object, slot, nil, false))
end
TheSim = { FindEntities = function(_, x, y, z, radius)
    local found = {}
    for _, e in ipairs(world) do
        if e:IsValid() and math.abs(e.x - x) <= radius then found[#found + 1] = e end
    end
    return found
end }
local function test(name, fn)
    world = {}
    fn()
    passed = passed + 1
    print("PASS " .. name)
end

test("complete plan spans stacks and preserves recipe order", function()
    local pot = entity("cookpot", 0)
    local a, b = chest("treasurechest", 1), chest("icebox", 2)
    put(a, item("berries", 2), 1)
    put(b, item("berries", 1), 1)
    put(b, item("meat", 1), 2)
    local plan = assert(Storage.PlanIngredients(pot,
        {{ prefab = "meat", count = 1 }, { prefab = "berries", count = 3 }}, { radius = 8 }))
    local records = assert(Storage.TakeIngredients(plan))
    equal(#records, 4)
    equal(records[1].item.prefab, "meat")
    for _, record in ipairs(records) do
        equal(record.item.components.stackable:StackSize(), 1)
        equal(record.item.components.inventoryitem.owner, nil)
    end
    Storage.ReturnIngredients(records)
    equal(a.components.container.slots[1].components.stackable:StackSize(), 2)
    equal(b.components.container.slots[1].components.stackable:StackSize(), 1)
    equal(b.components.container.slots[2].prefab, "meat")
    equal(Storage.TakeIngredients(plan), nil) -- A transaction cannot be replayed.
end)

test("insufficient request consumes nothing", function()
    local pot, a = entity("cookpot", 0), chest("treasurechest", 1)
    local berries = item("berries", 2)
    put(a, berries, 1)
    equal(Storage.PlanIngredients(pot, {{ prefab = "berries", count = 3 }}, {}), nil)
    equal(berries.components.stackable:StackSize(), 2)
end)

test("preflight changed stack consumes nothing", function()
    local pot, a = entity("cookpot", 0), chest("treasurechest", 1)
    local berries = item("berries", 3)
    put(a, berries, 1)
    local plan = assert(Storage.PlanIngredients(pot, {{ prefab = "berries", count = 3 }}, {}))
    berries.components.stackable:SetStackSize(2)
    equal(Storage.TakeIngredients(plan), nil)
    equal(berries.components.stackable:StackSize(), 2)
end)

test("open fridge supplies ingredients and receives food even with legacy settings", function()
    local pot, a = entity("cookpot", 0), chest("icebox", 1)
    a.tags.fridge = true
    put(a, item("berries", 2), 1)
    a.components.container.opencount = 1
    local legacy = { skip_open = true }
    assert(Storage.IsStorage(a))
    local records = assert(Storage.TakeIngredients(assert(Storage.PlanIngredients(pot,
        {{ prefab = "berries", count = 1 }}, legacy))))
    equal(a.components.container.slots[1].components.stackable:StackSize(), 1)
    Storage.ReturnIngredients(records)
    equal(a.components.container.slots[1].components.stackable:StackSize(), 2)
    local product = item("meatballs", 1)
    equal(Storage.StoreProduct(pot, product, legacy), a)
    equal(product.components.inventoryitem.owner, a)
    equal(a.components.container.opencount, 1)
end)

test("opening storage after planning does not invalidate its ingredients", function()
    local pot, a = entity("cookpot", 0), chest("icebox", 1)
    put(a, item("berries", 3), 1)
    local plan = assert(Storage.PlanIngredients(pot, {berries=3}, {}))
    a.components.container.opencount = 1
    local records = assert(Storage.TakeIngredients(plan))
    equal(#records, 3)
    equal(a.components.container.slots[1], nil)
    Storage.ReturnIngredients(records)
    equal(a.components.container.slots[1].components.stackable:StackSize(), 3)
end)

test("manual movement from an open fridge still prevents a stale withdrawal", function()
    local pot, a = entity("cookpot", 0), chest("icebox", 1)
    local berries = item("berries", 3)
    put(a, berries, 1)
    a.components.container.opencount = 1
    local plan = assert(Storage.PlanIngredients(pot, {berries=3}, {}))
    local moved = a.components.container:RemoveItemBySlot(1)
    equal(moved, berries)
    equal(Storage.TakeIngredients(plan), nil)
    equal(berries.components.stackable:StackSize(), 3)
end)

test("open full fridge can merge food and routes only the remainder onward", function()
    local pot = entity("cookpot", 0)
    local fridge, box = chest("icebox", 2, 1), chest("treasurechest", 1, 1)
    fridge.tags.fridge = true
    fridge.components.container.opencount = 1
    local existing = item("meatballs", 39)
    put(fridge, existing, 1)
    local _, routes = Storage.StoreProduct(pot, item("meatballs", 3), {})
    equal(existing.components.stackable:StackSize(), 40)
    equal(#routes, 2)
    equal(routes[1].target, fridge)
    equal(routes[1].count, 1)
    equal(box.components.container.slots[1].components.stackable:StackSize(), 2)
end)

test("ground remains excluded when disabled", function()
    local pot = entity("cookpot", 0)
    item("berries", 2, 1)
    equal(Storage.PlanIngredients(pot, {{ prefab = "berries", count = 1 }}, { ground = false }), nil)
    local plan = assert(Storage.PlanIngredients(pot, {{ prefab = "berries", count = 2 }}, {}))
    equal(#assert(Storage.TakeIngredients(plan)), 2)
end)

test("negative preserver beats freezer then fridge then chest", function()
    local pot = entity("cookpot", 0)
    chest("treasurechest", 1)
    local fridge, freezer, cellar = chest("icebox", 2), chest("mega_freezer", 3), chest("storeroom", 4)
    fridge.tags.fridge = true
    freezer.tags.fridge = true
    cellar.components.preserver = { GetPerishRateMultiplier = function() return -.5 end }
    local food = item("meatballs", 1)
    local destination, routes = Storage.StoreProduct(pot, food, {})
    equal(destination, cellar)
    equal(#routes, 1)
    equal(routes[1].count, 1)
    equal(routes[1].target, cellar)
    equal(Storage.PreservationRate(freezer, food), 0)
    equal(Storage.PreservationRate(fridge, food), .5)
end)

test("real GiveItem partial false routes remainder without duplication", function()
    local pot = entity("cookpot", 0)
    local freezer, box = chest("mega_freezer", 3, 1), chest("treasurechest", 1, 1)
    local stack = item("meatballs", 39)
    put(freezer, stack, 1)
    local food = item("meatballs", 3)
    local destination, routes = Storage.StoreProduct(pot, food, {})
    equal(stack.components.stackable:StackSize(), 40)
    equal(destination, box)
    equal(#routes, 2)
    equal(routes[1].count, 1)
    equal(routes[2].count, 2)
    equal(box.components.container.slots[1].components.stackable:StackSize(), 2)
end)

test("nonstacking chest accepts single units across slots", function()
    local pot, box = entity("cookpot", 0), chest("treasurechest", 1, 2)
    box.components.container.acceptsstacks = false
    local food = item("meatballs", 3)
    local destination, routes = Storage.StoreProduct(pot, food, {})
    equal(destination, nil)
    equal(#routes, 2)
    equal(routes[1].count, 2)
    equal(routes[2].count, 1)
    equal(food.components.stackable:StackSize(), 1)
    assert(food.dropped)
    equal(box.components.container.slots[1].components.stackable:StackSize(), 1)
    equal(box.components.container.slots[2].components.stackable:StackSize(), 1)
end)

test("unacceptable preserving storage falls back to ordinary chest", function()
    local pot = entity("cookpot", 0)
    local freezer = chest("mega_freezer", 3, 1)
    freezer.components.container.itemtestfn = function() return false end
    local box = chest("treasurechest", 1, 1)
    equal(Storage.StoreProduct(pot, item("meatballs", 1), {}), box)
end)

test("registered cellar preference and callback failure fallback", function()
    local cellar = chest("custom_cellar", 3)
    cellar.tags.fridge = true
    Storage.RegisterPreservation("custom_cellar", function() return -.25 end)
    equal(Storage.PreservationRate(cellar), -.25)
    Storage.RegisterPreservation("custom_cellar", function() error("unavailable") end)
    equal(Storage.PreservationRate(cellar), .5)
    Storage.RegisterPreservation("custom_cellar", nil)
end)

test("removal callback changing a later slot restores withdrawn items", function()
    local pot, box = entity("cookpot", 0), chest("treasurechest", 1, 2)
    local meat, berries = item("meat", 1), item("berries", 3)
    put(box, meat, 1)
    put(box, berries, 2)
    local plan = assert(Storage.PlanIngredients(pot,
        {{ prefab = "meat", count = 1 }, { prefab = "berries", count = 3 }}, {}))
    box.callback = function(name, data)
        if name == "itemlose" and data.prev_item == meat then
            box.components.container:RemoveItem(berries, true)
        end
    end
    equal(Storage.TakeIngredients(plan), nil)
    equal(box.components.container.slots[1], meat)
    equal(berries.components.stackable:StackSize(), 3)
    equal(berries.components.inventoryitem.owner, nil)
end)

test("portable, parented, living and production containers are excluded", function()
    for _, field in ipairs({"inventoryitem", "inventory", "health", "locomotor", "stewer", "brewer", "melter", "container_proxy"}) do
        local box = chest("custom", 1)
        box.components[field] = {}
        assert(not Storage.IsStorage(box))
    end
    local box = chest("custom", 1)
    box.parent = {}
    assert(not Storage.IsStorage(box))
    box.parent = nil
    box.tags.burnt = true
    assert(not Storage.IsStorage(box))
end)

print("RESULT " .. passed .. " checks passed with real DST Container and Stackable")
