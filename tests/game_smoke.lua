-- Loaded only by run_game_smoke.py in its disposable offline test world.
local Storage = require("nac_storage")
local FX = require("nac_fx")
local spawned, passed = {}, 0
local config = { radius = 12, ground = true, skip_open = true }
local function track(inst)
    spawned[#spawned + 1] = inst
    return inst
end
local function spawn(prefab, x)
    local inst = track(assert(SpawnPrefab(prefab), "Cannot spawn " .. prefab))
    inst.Transform:SetPosition(100 + (x or 0), 0, 100)
    return inst
end
local function stack(prefab, count, x)
    local item = spawn(prefab, x)
    if item.components.stackable ~= nil then item.components.stackable:SetStackSize(count) end
    return item
end
local function size(item)
    return item:IsValid() and (item.components.stackable ~= nil and item.components.stackable:StackSize() or 1) or 0
end
local function count(container, prefab)
    local result = 0
    for slot = 1, container:GetNumSlots() do
        local item = container:GetItemInSlot(slot)
        if item ~= nil and item.prefab == prefab then result = result + size(item) end
    end
    return result
end
local function approx(a, b)
    assert(math.abs(a - b) < .002, tostring(a) .. " ~= " .. tostring(b))
end
local function cleanup()
    for _, inst in ipairs(spawned) do
        if inst:IsValid() then inst:Remove() end
    end
    spawned = {}
end
local function test(name, fn)
    fn()
    passed = passed + 1
    print("AUTOCOOK_GAME_PASS " .. name)
    cleanup()
end

test("missing recipe ingredients leave real stacks untouched", function()
    local pot = spawn("cookpot")
    local chest = spawn("treasurechest", 2).components.container
    local meat = stack("meat", 3)
    assert(chest:GiveItem(meat, 1))
    local plan, reason = Storage.PlanIngredients(pot, { meat = 1, berries = 3 }, config)
    assert(plan == nil and reason == "missing_ingredients")
    assert(size(meat) == 3 and chest:GetItemInSlot(1) == meat)
end)

test("single-item extraction across chest and ground stacks, then rollback", function()
    local pot = spawn("cookpot")
    local chest = spawn("treasurechest", 3).components.container
    local meat, berries = stack("meat", 3), stack("berries", 2)
    local ground = stack("berries", 5, 1)
    assert(chest:GiveItem(meat, 1) and chest:GiveItem(berries, 2))
    local plan = assert(Storage.PlanIngredients(pot, {{prefab="meat",count=1},{prefab="berries",count=3}}, config))
    local records = assert(Storage.TakeIngredients(plan))
    assert(#records == 4 and size(meat) == 2 and size(ground) == 4 and count(chest, "berries") == 0)
    for _, record in ipairs(records) do
        track(record.item)
        assert(size(record.item) == 1 and record.item.components.inventoryitem.owner == nil)
    end
    Storage.ReturnIngredients(records, pot:GetPosition())
    assert(count(chest, "meat") == 3 and count(chest, "berries") == 2 and size(ground) == 5)
end)

test("a source callback changing a later ingredient rolls back the first", function()
    local pot = spawn("cookpot")
    local chest = spawn("treasurechest", 2).components.container
    local meat, berries = spawn("meat"), stack("berries", 3)
    assert(chest:GiveItem(meat, 1) and chest:GiveItem(berries, 2))
    local plan = assert(Storage.PlanIngredients(pot, {{prefab="meat",count=1},{prefab="berries",count=3}}, config))
    local changed = false
    chest.inst:ListenForEvent("itemlose", function(_, data)
        if not changed and data.prev_item == meat then
            changed = true
            local moved = chest:RemoveItemBySlot(2)
            moved.Transform:SetPosition(102, 0, 100)
            moved.components.inventoryitem:OnDropped(true)
        end
    end)
    local records = Storage.TakeIngredients(plan)
    assert(records == nil and changed)
    assert(count(chest, "meat") == 1 and size(berries) == 3 and berries.components.inventoryitem.owner == nil)
end)

test("open storages supply ingredients and accept food while backpacks stay excluded", function()
    local pot = spawn("cookpot")
    local chest = spawn("treasurechest", 1).components.container
    local backpack = spawn("backpack", 2)
    assert(chest:GiveItem(stack("berries", 4)))
    chest.opencount = 1
    assert(Storage.IsStorage(chest.inst, config))
    assert(not Storage.IsStorage(backpack, config))
    local records = assert(Storage.TakeIngredients(assert(Storage.PlanIngredients(pot, {berries=4}, config))))
    assert(#records == 4 and count(chest, "berries") == 0)
    for _, record in ipairs(records) do track(record.item) end
    Storage.ReturnIngredients(records, pot:GetPosition())
    assert(count(chest, "berries") == 4)
    assert(Storage.StoreProduct(pot, spawn("meatballs"), config) == chest.inst)
    assert(count(chest, "meatballs") == 1 and chest:IsOpen())
end)

test("preservation outranks distance and returns an exact destination", function()
    local pot = spawn("cookpot")
    local chest, fridge = spawn("treasurechest", 1), spawn("icebox", 6)
    local product = spawn("meatballs")
    product.components.perishable:SetPercent(.42)
    local destination, routes = Storage.StoreProduct(pot, product, config)
    assert(destination == fridge and #routes == 1 and routes[1].count == 1)
    assert(product.components.inventoryitem.owner == fridge and chest.components.container:IsEmpty())
    approx(product.components.perishable:GetPercent(), .42)
end)

test("negative preserver rates rank ahead of an ordinary fridge", function()
    local pot, fridge, chest = spawn("cookpot"), spawn("icebox", 1), spawn("treasurechest", 6)
    chest:AddComponent("preserver")
    chest.components.preserver:SetPerishRateMultiplier(function(_, item)
        return item.prefab == "meatballs" and -.5 or 1
    end)
    local product = spawn("meatballs")
    assert(Storage.StoreProduct(pot, product, config) == chest)
    assert(product.components.inventoryitem.owner == chest and fridge.components.container:IsEmpty())
end)

test("partial stack merge routes leftovers into the next storage", function()
    local pot, fridge, chest = spawn("cookpot"), spawn("icebox", 1), spawn("treasurechest", 2)
    for slot = 2, fridge.components.container:GetNumSlots() do
        assert(fridge.components.container:GiveItem(spawn("carrot"), slot))
    end
    local existing = spawn("meatballs")
    local maxsize = existing.components.stackable.maxsize
    existing.components.stackable:SetStackSize(maxsize - 1)
    assert(fridge.components.container:GiveItem(existing))
    local product = stack("meatballs", 4)
    local destination, routes = Storage.StoreProduct(pot, product, config)
    assert(destination == chest and #routes == 2)
    assert(routes[1].target == fridge and routes[1].count == 1 and routes[2].count == 3)
    assert(size(existing) == maxsize and count(chest.components.container, "meatballs") == 3)
end)

test("non-stacking storages receive separate singles without dropping extras", function()
    local pot, chest = spawn("cookpot"), spawn("treasurechest", 1)
    local container = chest.components.container
    container:WidgetSetup("treasurechest", {widget=container.widget, type="chest", acceptsstacks=false})
    local product = stack("meatballs", 3)
    assert(Storage.StoreProduct(pot, product, config) == chest)
    assert(count(container, "meatballs") == 3)
    for slot = 1, 3 do track(assert(container:GetItemInSlot(slot))) end
end)

test("a rejected output falls onto the ground at the cooking building", function()
    local pot, chest = spawn("cookpot"), spawn("treasurechest", 2)
    local container = chest.components.container
    container:WidgetSetup("treasurechest", {widget=container.widget, type="chest", itemtestfn=function() return false end})
    local product = stack("meatballs", 3, 4)
    local destination, routes = Storage.StoreProduct(pot, product, config)
    assert(destination == nil and #routes == 1 and routes[1].target == nil and routes[1].count == 3)
    assert(product.components.inventoryitem.owner == nil)
    approx(product:GetDistanceSqToInst(pot), 0)
end)

test("native stewer harvest preserves ingredient freshness and recipe stack size", function()
    local pot = spawn("cookpot")
    for slot, prefab in ipairs({"meat", "berries", "berries", "berries"}) do
        local item = spawn(prefab)
        item.components.perishable:SetPercent(.2)
        assert(pot.components.container:GiveItem(item, slot))
    end
    local stewer = pot.components.stewer
    stewer:StartCooking()
    assert(stewer:IsCooking() and stewer.product == "meatballs")
    stewer:LongUpdate(stewer:GetTimeToCook())
    local product
    assert(stewer:Harvest({userid=false, PushEvent=function() end, components={inventory={GiveItem=function(_, item) product=track(item) end}}}))
    assert(product.prefab == "meatballs")
    approx(product.components.perishable:GetPercent(), .6)
    for slot, prefab in ipairs({"royal_jelly", "berries", "berries", "berries"}) do
        assert(pot.components.container:GiveItem(spawn(prefab), slot))
    end
    stewer:StartCooking()
    assert(stewer.product == "jellybean")
    stewer:LongUpdate(stewer:GetTimeToCook())
    assert(stewer:Harvest({userid=false, PushEvent=function() end, components={inventory={GiveItem=function(_, item) product=track(item) end}}}))
    assert(product.prefab == "jellybean" and size(product) == 3)
end)

test("network flight copies actual item visuals without spawning inventory items", function()
    local food = spawn("meatballs")
    local data = FX.Capture(food)
    assert(data.bank == food.AnimState:GetBankHash() and data.build == food.AnimState:GetBuild())
    assert(data.override ~= nil and data.override[3] == "meatballs")
    local fx = track(assert(FX.Play(data, Vector3(100,0,100), Vector3(104,1,100))))
    assert(not fx.persists and fx:HasTag("FX") and fx:HasTag("NOCLICK"))
    assert(fx.components.inventoryitem == nil and fx.components.stackable == nil)
    assert(fx.Network ~= nil and fx._ready:value() and fx._dx:value() == 4)
    assert(size(food) == 1 and food:IsValid())
end)

if NAC_TEST_COMPAT then
    test("installed Arcadiea Deep Freezer wins over an ordinary fridge", function()
        local pot, fridge, freezer = spawn("cookpot"), spawn("icebox", 1), spawn("mega_freezer", 5)
        freezer.components.container.opencount = 1
        assert(Storage.IsStorage(freezer, config))
        local product = spawn("meatballs")
        assert(Storage.PreservationRate(freezer, product) == 0)
        assert(Storage.StoreProduct(pot, product, config) == freezer)
        assert(product.components.inventoryitem.owner == freezer and fridge.components.container:IsEmpty())
        local records = assert(Storage.TakeIngredients(assert(Storage.PlanIngredients(pot, {meatballs=1}, config))))
        assert(#records == 1 and freezer.components.container:IsEmpty())
        Storage.ReturnIngredients(records, pot:GetPosition())
        assert(count(freezer.components.container, "meatballs") == 1 and freezer.components.container:IsOpen())
    end)
    test("installed Storeroom uses its own container and preservation component", function()
        local pot, cellar = spawn("cookpot"), spawn("storeroom", 3)
        cellar.components.container.opencount = 1
        assert(Storage.IsStorage(cellar, config))
        local product = spawn("meatballs")
        assert(Storage.StoreProduct(pot, product, config) == cellar)
        assert(product.components.inventoryitem.owner == cellar)
        local records = assert(Storage.TakeIngredients(assert(Storage.PlanIngredients(pot, {meatballs=1}, config))))
        track(records[1].item)
        assert(#records == 1)
        Storage.ReturnIngredients(records, pot:GetPosition())
        assert(count(cellar.components.container, "meatballs") == 1 and cellar.components.container:IsOpen())
    end)
end

local function setup(prefab)
    local pot = spawn(prefab or "cookpot")
    local comp = assert(pot.components.nearbyautocook, "modmain did not attach nearbyautocook to " .. pot.prefab)
    comp:Configure({radius=8, ground=true, skip_open=true, interval=.25, visuals=true})
    return pot, comp
end
local function fill(pot, ingredients)
    for slot, prefab in ipairs(ingredients or {"meat", "berries", "berries", "berries"}) do
        assert(pot.components.container:GiveItem(spawn(prefab), slot))
    end
end
local function finish(pot, comp)
    local stewer = pot.components.stewer
    assert(stewer:IsCooking())
    stewer:LongUpdate(stewer:GetTimeToCook())
    assert(stewer:IsDone())
    comp:Tick()
end

test("native cook button learns actual slots and counts the first pot", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    fridge.opencount = 1
    assert(fridge:GiveItem(stack("meat", 2)) and fridge:GiveItem(stack("berries", 6)))
    fill(pot)
    assert(comp:SetBatch(3))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp.collecting and comp.remaining == 2 and #comp.recipe == 4)
    for _ = 1, 3 do finish(pot, comp) end
    assert(count(fridge, "meatballs") == 3 and count(fridge, "meat") == 0 and count(fridge, "berries") == 0)
    assert(not comp.enabled and comp.remaining == 0 and fridge:IsOpen())
end)

test("manual native cooking replaces the recipe without an extra record command", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    local chest = spawn("treasurechest", 3).components.container
    fill(pot)
    assert(comp.batch == 1)
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    finish(pot, comp)
    assert(count(fridge, "meatballs") == 1 and not comp.enabled)
    fill(pot, {"royal_jelly", "berries", "berries", "berries"})
    assert(fridge:GiveItem(stack("royal_jelly", 1)) and fridge:GiveItem(stack("berries", 3)))
    assert(comp:SetBatch(2))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp.recipe[1] == "royal_jelly" and comp.remaining == 1)
    finish(pot, comp)
    finish(pot, comp)
    -- Jellybeans do not perish and the vanilla icebox rejects them.
    assert(count(chest, "jellybean") == 6 and count(fridge, "meatballs") == 1 and not comp.enabled)
end)

test("setting quantity alone does not start or consume a prepared pot", function()
    local pot, comp = setup()
    fill(pot)
    assert(comp:SetBatch(6))
    comp:Tick()
    assert(not comp.enabled and not pot.components.stewer:IsCooking() and pot.components.container:IsFull())
    assert(not comp:SetBatch(-1) and comp.batch == 6)
    assert(comp:SetBatch(0))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp.remaining == -1 and comp.collecting)
end)

test("shortening native closed cooking keeps exactly its current dish", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 4)) and fridge:GiveItem(stack("berries", 12)))
    fill(pot)
    assert(comp:SetBatch(5))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(pot.components.stewer:IsCooking() and not pot.components.container.canbeopened)
    assert(comp:CanManage() and comp:GetState().quantity == 5 and comp:GetState().collecting)
    local remainingtime = pot.components.stewer:GetTimeToCook()
    assert(comp:SetBatch(1))
    assert(comp.remaining == 0 and comp:GetState().quantity == 1 and comp:CanManage())
    approx(pot.components.stewer:GetTimeToCook(), remainingtime)
    assert(count(fridge, "meat") == 4 and count(fridge, "berries") == 12)
    finish(pot, comp)
    comp:Tick()
    assert(not comp:CanManage() and not comp.collecting and not pot.components.stewer:IsCooking())
    assert(count(fridge, "meatballs") == 1 and count(fridge, "meat") == 4 and count(fridge, "berries") == 12)
end)

test("extending an active batch includes the cooking or finished current dish", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 2)) and fridge:GiveItem(stack("berries", 6)))
    fill(pot)
    assert(comp:SetBatch(1))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp:SetBatch(2) and comp.remaining == 1 and comp:GetState().quantity == 2)
    local stewer = pot.components.stewer
    stewer:LongUpdate(stewer:GetTimeToCook())
    assert(stewer:IsDone() and comp.collecting)
    assert(comp:SetBatch(3) and comp.remaining == 2 and comp:GetState().quantity == 3)
    assert(count(fridge, "meat") == 2 and count(fridge, "berries") == 6)
    comp:Tick()
    assert(count(fridge, "meatballs") == 1 and stewer:IsCooking())
    finish(pot, comp)
    finish(pot, comp)
    assert(count(fridge, "meatballs") == 3 and count(fridge, "meat") == 0 and count(fridge, "berries") == 0)
    assert(not comp:CanManage() and comp.remaining == 0)
end)

test("switching an active batch to continuous and back obeys the new quota", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 3)) and fridge:GiveItem(stack("berries", 9)))
    fill(pot)
    assert(comp:SetBatch(1))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp:SetBatch(0) and comp.remaining == -1 and comp:GetState().quantity == 0)
    finish(pot, comp)
    assert(pot.components.stewer:IsCooking() and comp.remaining == -1 and comp:GetState().quantity == 0)
    assert(comp:SetBatch(2) and comp.remaining == 1 and comp:GetState().quantity == 2)
    assert(count(fridge, "meat") == 2 and count(fridge, "berries") == 6)
    finish(pot, comp)
    finish(pot, comp)
    comp:Tick()
    assert(count(fridge, "meatballs") == 3 and count(fridge, "meat") == 1 and count(fridge, "berries") == 3)
    assert(not comp:CanManage() and not pot.components.stewer:IsCooking())
end)

test("cancel keeps the current native dish and the next manual cook uses a new recipe", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    local chest = spawn("treasurechest", 3).components.container
    assert(fridge:GiveItem(stack("meat", 2)) and fridge:GiveItem(stack("berries", 6)))
    fill(pot)
    assert(comp:SetBatch(0))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    local remainingtime = pot.components.stewer:GetTimeToCook()
    comp:Cancel()
    assert(comp.recipe == nil and not comp.enabled and comp.remaining == 0 and comp.batch == 1)
    assert(not comp:CanManage() and not comp:GetState().canmanage and comp.collecting)
    approx(pot.components.stewer:GetTimeToCook(), remainingtime)
    assert(pot.components.stewer:IsCooking() and pot.components.container:IsEmpty())
    assert(count(fridge, "meat") == 2 and count(fridge, "berries") == 6)
    finish(pot, comp)
    comp:Tick()
    assert(count(fridge, "meatballs") == 1 and not comp.collecting and not pot.components.stewer:IsCooking())
    assert(count(fridge, "meat") == 2 and count(fridge, "berries") == 6)
    fill(pot, {"royal_jelly", "berries", "berries", "berries"})
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp.recipe[1] == "royal_jelly" and comp.remaining == 0 and comp:CanManage())
    finish(pot, comp)
    assert(count(chest, "jellybean") == 3 and count(fridge, "meatballs") == 1 and not comp:CanManage())
end)

test("a missing-ingredient job can be resized and cancelled without withdrawing partial supplies", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    fill(pot)
    assert(comp:SetBatch(2))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    finish(pot, comp)
    assert(comp:CanManage() and not comp.collecting and comp.remaining == 1)
    assert(not pot.components.stewer:IsCooking() and pot.components.container:IsEmpty())
    assert(comp:SetBatch(4) and comp.remaining == 4 and comp:GetState().quantity == 4)
    assert(fridge:GiveItem(stack("meat", 1)) and fridge:GiveItem(stack("berries", 2)))
    comp:Tick()
    assert(count(fridge, "meat") == 1 and count(fridge, "berries") == 2 and comp.remaining == 4)
    assert(comp:SetBatch(0) and comp.remaining == -1 and comp:GetState().quantity == 0)
    assert(comp:SetBatch(2) and comp.remaining == 2 and comp:GetState().quantity == 2)
    comp:Cancel()
    assert(not comp:CanManage() and comp.recipe == nil and comp.remaining == 0 and comp.batch == 1)
    assert(fridge:GiveItem(spawn("berries")))
    comp:Tick()
    assert(not pot.components.stewer:IsCooking() and pot.components.container:IsEmpty())
    assert(count(fridge, "meatballs") == 1 and count(fridge, "meat") == 1 and count(fridge, "berries") == 3)
end)

test("save and reload preserve a mid-cook quantity change", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 2)) and fridge:GiveItem(stack("berries", 6)))
    fill(pot)
    assert(comp:SetBatch(8))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    assert(comp:SetBatch(2) and comp.remaining == 1)
    local record = pot:GetSaveRecord()
    pot:Remove()
    local loaded = track(assert(SpawnSaveRecord(record)))
    loaded.Transform:SetPosition(100, 0, 100)
    local saved = assert(loaded.components.nearbyautocook)
    saved:Configure({radius=8, ground=true, interval=.25, visuals=true})
    assert(saved:CanManage() and saved.collecting and saved.batch == 2 and saved.remaining == 1)
    assert(saved:GetState().quantity == 2 and loaded.components.stewer:IsCooking())
    finish(loaded, saved)
    finish(loaded, saved)
    saved:Tick()
    assert(count(fridge, "meatballs") == 2 and count(fridge, "meat") == 1 and count(fridge, "berries") == 3)
    assert(not saved:CanManage() and not loaded.components.stewer:IsCooking())
end)

test("save and reload never resurrect a cancelled recipe but still store its current dish", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 2)) and fridge:GiveItem(stack("berries", 6)))
    fill(pot)
    assert(comp:SetBatch(0))
    assert(ACTIONS.COOK.fn({target=pot, doer={components={}}}))
    comp:Cancel()
    local record = pot:GetSaveRecord()
    pot:Remove()
    local loaded = track(assert(SpawnSaveRecord(record)))
    loaded.Transform:SetPosition(100, 0, 100)
    local saved = assert(loaded.components.nearbyautocook)
    saved:Configure({radius=8, ground=true, interval=.25, visuals=true})
    assert(not saved:CanManage() and saved.recipe == nil and saved.collecting and saved.batch == 1)
    assert(saved.remaining == 0 and loaded.components.stewer:IsCooking())
    finish(loaded, saved)
    saved:Tick()
    assert(count(fridge, "meatballs") == 1 and count(fridge, "meat") == 2 and count(fridge, "berries") == 6)
    assert(not loaded.components.stewer:IsCooking() and not saved.collecting and saved.recipe == nil)
end)

test("the registered scene action stays reachable while native cooking locks the pot", function()
    local pot, comp = setup()
    -- Use a real harmless entity for native action collection. No player is
    -- connected and no client RPC or fabricated player session is involved.
    local probe = spawn("carrot", 1)
    local manage = assert(ACTIONS.NAC_MANAGE, "management action was not registered")
    local function contains(action, right)
        local actions = {}
        pot:CollectActions("SCENE", probe, actions, right)
        for _, candidate in ipairs(actions) do
            if candidate == action then return true end
        end
        return false
    end
    assert(not contains(manage, true))
    fill(pot)
    assert(comp:SetBatch(3))
    assert(ACTIONS.COOK.fn({target=pot, doer=probe}))
    assert(pot.components.stewer:IsCooking() and not pot.components.container.canbeopened)
    assert(comp:CanManage(), "server job is not manageable after native cooking")
    assert(pot._nac_controller == comp.controller, "controller did not bind to its server pot")
    local synced = require("json").decode(comp.controller._state:value())
    assert(synced and synced.canmanage == true, "network job state is not manageable")
    assert(pot.modactioncomponents ~= nil, "mod component action IDs did not register on the pot")
    assert(contains(manage, true), "closed cooking pot did not offer the management action")
    assert(not contains(manage, false), "management action must not replace a left-click action")
    comp:Cancel()
    assert(not contains(manage, true), "cancelled recipe remained exposed as manageable")
    local stewer = pot.components.stewer
    stewer:LongUpdate(stewer:GetTimeToCook())
    assert(contains(ACTIONS.HARVEST, false), "native harvest disappeared after cancellation")
end)

for _, prefab in ipairs({"cookpot", "portablecookpot"}) do
    test("finite two-batch automatic recipe on " .. prefab, function()
        local pot, comp = setup(prefab)
        local fridge = spawn("icebox", 2).components.container
        assert(fridge:GiveItem(stack("meat", 2), 1))
        assert(fridge:GiveItem(stack("berries", 6), 2))
        fridge.opencount = 1
        fill(pot)
        assert(comp:Command("start", 2))
        assert(pot.components.stewer:IsCooking() and comp.collecting)
        finish(pot, comp)
        -- A tick may harvest and refill together, or refill on the next scan.
        comp:Tick()
        assert(pot.components.stewer:IsCooking())
        finish(pot, comp)
        comp:Tick()
        assert(not pot.components.stewer:IsCooking() and not pot.components.stewer:IsDone())
        assert(count(fridge, "meatballs") == 2 and count(fridge, "meat") == 1 and count(fridge, "berries") == 3)
        assert(comp.remaining == 0)
        assert(fridge:IsOpen())
    end)
end

test("empty unsampled pots and stacked sample slots are rejected safely", function()
    local pot, comp = setup()
    assert(not comp:Command("start", 1))
    fill(pot)
    local sample = pot.components.container:GetItemInSlot(1)
    sample.components.stackable:SetStackSize(2)
    assert(not comp:Command("start", 1))
    assert(not pot.components.stewer:IsCooking() and size(sample) == 2 and pot.components.container:IsFull())
end)

test("pause still stores the current result and stops the following batch", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 2)) and fridge:GiveItem(stack("berries", 6)))
    fill(pot)
    assert(comp:Command("start", 0))
    assert(comp:Command("pause"))
    finish(pot, comp)
    comp:Tick()
    assert(not comp.enabled and not pot.components.stewer:IsCooking())
    assert(count(fridge, "meatballs") == 1 and count(fridge, "meat") == 2 and count(fridge, "berries") == 6)
end)

test("an open cooking container waits for the player to finish", function()
    local pot, comp = setup()
    fill(pot)
    pot.components.container.opencount = 1
    comp:Command("start", 1)
    comp:Tick()
    assert(not pot.components.stewer:IsCooking() and pot.components.container:IsFull())
    pot.components.container.opencount = 0
    if not comp.enabled then assert(comp:Command("start", 1)) end
    comp:Tick()
    assert(pot.components.stewer:IsCooking())
end)

test("save records retain the remembered recipe and pending native cooking result", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    assert(fridge:GiveItem(stack("meat", 1)) and fridge:GiveItem(stack("berries", 3)))
    fill(pot)
    assert(comp:Command("start", 2))
    local record = pot:GetSaveRecord()
    pot:Remove()
    local loaded = track(assert(SpawnSaveRecord(record)))
    loaded.Transform:SetPosition(100, 0, 100)
    local saved = assert(loaded.components.nearbyautocook)
    saved:Configure({radius=8, ground=true, skip_open=true, interval=.25, visuals=true})
    assert(saved.recipe ~= nil and #saved.recipe == 4 and saved.collecting)
    finish(loaded, saved)
    saved:Tick()
    assert(loaded.components.stewer:IsCooking())
    finish(loaded, saved)
    assert(count(fridge, "meatballs") == 2 and count(fridge, "meat") == 0 and count(fridge, "berries") == 0)
end)

test("manual harvest followed by another script's nil-doer cooking is never auto-collected", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    fill(pot)
    assert(comp:Command("start", 2))
    local stewer = pot.components.stewer
    stewer:LongUpdate(stewer:GetTimeToCook())
    local manualfood
    assert(stewer:Harvest({userid=false, PushEvent=function() end,
        components={inventory={GiveItem=function(_, item) manualfood=track(item) end}}}))
    assert(not comp.collecting and manualfood.prefab == "meatballs")
    fill(pot, {"royal_jelly", "berries", "berries", "berries"})
    stewer:StartCooking()
    stewer:LongUpdate(stewer:GetTimeToCook())
    comp:Tick()
    assert(stewer:IsDone() and stewer.product == "jellybean")
    assert(count(fridge, "jellybean") == 0 and count(fridge, "meatballs") == 0 and size(manualfood) == 1)
end)

test("missing ingredients wait without consumption and resume when supplied", function()
    local pot, comp = setup()
    local fridge = spawn("icebox", 2).components.container
    fill(pot)
    assert(comp:Command("learn", 1))
    local lastberry
    for slot = 1, 4 do
        local item = pot.components.container:RemoveItemBySlot(slot)
        if slot < 4 then
            assert(fridge:GiveItem(item))
        else
            lastberry = item
            item.Transform:SetPosition(150, 0, 100)
        end
    end
    assert(comp:Command("start", 1))
    comp:Tick()
    assert(not pot.components.stewer:IsCooking() and pot.components.container:IsEmpty())
    assert(count(fridge, "meat") == 1 and count(fridge, "berries") == 2 and comp.remaining == 1)
    assert(fridge:GiveItem(lastberry))
    comp:Tick()
    finish(pot, comp)
    assert(count(fridge, "meatballs") == 1 and count(fridge, "meat") == 0 and count(fridge, "berries") == 0)
    assert(comp.remaining == 0)
end)

test("a target-slot callback change rolls all withdrawn ingredients back", function()
    local pot, comp = setup()
    local chest = spawn("treasurechest", 2).components.container
    fill(pot)
    assert(comp:Command("learn", 1))
    for slot = 1, 4 do assert(chest:GiveItem(pot.components.container:RemoveItemBySlot(slot))) end
    local changed, obstruction = false, nil
    pot:ListenForEvent("itemget", function(_, data)
        if not changed and data.slot == 1 then
            changed = true
            obstruction = spawn("carrot")
            assert(pot.components.container:GiveItem(obstruction, 2))
        end
    end)
    assert(comp:Command("start", 1))
    assert(changed and not pot.components.stewer:IsCooking() and comp.remaining == 1)
    assert(count(chest, "meat") == 1 and count(chest, "berries") == 3)
    assert(pot.components.container:GetItemInSlot(2) == obstruction)
    assert(pot.components.container:NumItems() == 1)
end)

-- Keep the world running: this exercises actual scheduled scans and cook tasks,
-- rather than only calling Tick and LongUpdate directly.
require("nac_flight_reference_smoke")()
local timedpot, timedcomp = setup()
local timedfridge = spawn("icebox", 2).components.container
assert(timedfridge:GiveItem(stack("meat", 1)) and timedfridge:GiveItem(stack("berries", 3)))
fill(timedpot)
timedpot.components.stewer.cooktimemult = .002
timedfridge.opencount = 1
assert(timedcomp:SetBatch(2))
assert(ACTIONS.COOK.fn({target=timedpot, doer={components={}}}))
TheWorld:DoTaskInTime(5, function()
    local ok, reason = pcall(function()
        assert(count(timedfridge, "meatballs") == 2, "scheduled cycles did not deliver two dishes")
        assert(not timedpot.components.stewer:IsCooking() and timedcomp.remaining == 0)
        for _, entity in pairs(Ents) do
            assert(entity.prefab ~= "nac_transfer_fx", "expired transfer FX did not clean itself up")
        end
    end)
    if ok then
        print("AUTOCOOK_GAME_SUCCESS " .. passed .. " synchronous cases and actual scheduled two-batch cooking")
    else
        print("AUTOCOOK_GAME_FAILURE " .. tostring(reason))
    end
    cleanup()
    c_shutdown(false)
end)
