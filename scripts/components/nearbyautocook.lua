local cooking = require("cooking")
local storage = require("nac_storage")
local fx = require("nac_fx")
local json = require("json")

local function Count(item)
    return item.components.stackable ~= nil and item.components.stackable:StackSize() or 1
end

local function Aggregate(slots)
    local result, byname = {}, {}
    for _, prefab in ipairs(slots or {}) do
        if byname[prefab] == nil then
            byname[prefab] = { prefab = prefab, count = 0 }
            result[#result + 1] = byname[prefab]
        end
        byname[prefab].count = byname[prefab].count + 1
    end
    return result
end

local function Available(inst)
    return inst:IsValid() and not inst:HasTag("burnt") and not inst:HasTag("INLIMBO")
        and not inst:HasTag("NOCLICK") and inst.entity:GetParent() == nil
        and not (inst.components.burnable ~= nil and inst.components.burnable:IsBurning())
end

local NearbyAutocook = Class(function(self, inst)
    self.inst = inst
    self.recipe = nil
    self.enabled = false
    self.remaining = 0
    self.batch = 1
    self.collecting = false
    self.status = "放好食材、填写数量，再点击烹饪"
    self.config = { radius = 12, ground = true, interval = 1, visuals = true }
    -- A player may harvest between scheduler ticks. Retire that job immediately
    -- so a subsequent manually started meal is never mistaken for our own.
    local stewer = inst.components.stewer
    self.original_startcooking = stewer.StartCooking
    self.wrapped_startcooking = function(component, doer, ...)
        -- The native Cook action supplies the real player. Our subsequent
        -- batches use nil, so they cannot reset their own recipe or quota.
        local recipe = doer ~= nil and self:CaptureRecipe(true) or nil
        local result = self.original_startcooking(component, doer, ...)
        if recipe ~= nil and (component:IsCooking() or component:IsDone()) then
            self.recipe = recipe
            self.enabled = true
            self.remaining = self.batch == 0 and -1 or self.batch - 1
            self.collecting = true
            self:Publish("正在烹饪")
        end
        return result
    end
    stewer.StartCooking = self.wrapped_startcooking
    self.original_harvest = stewer.Harvest
    self.wrapped_harvest = function(component, ...)
        local result = self.original_harvest(component, ...)
        if result and self.collecting and not self.harvesting then
            self.collecting = false
            if not self.enabled then
                self:Publish(self.recipe == nil and "已取消，当前料理已收取" or "已暂停，当前料理已收取")
            end
        end
        return result
    end
    stewer.Harvest = self.wrapped_harvest
    self.controller = SpawnPrefab("nac_controller")
    if self.controller ~= nil then
        self.controller:Attach(inst)
    end
    self:Publish()
end)

function NearbyAutocook:CanManage()
    return self.enabled and self.recipe ~= nil
end

function NearbyAutocook:HasPendingMeal()
    local stewer = self.inst.components.stewer
    return self.collecting and stewer ~= nil and (stewer:IsCooking() or stewer:IsDone())
end

function NearbyAutocook:GetState()
    local canmanage = self:CanManage()
    local quantity = self.batch
    if canmanage then
        quantity = self.remaining == -1 and 0 or self.remaining + (self:HasPendingMeal() and 1 or 0)
    end
    return { recipe = Aggregate(self.recipe), enabled = self.enabled,
        remaining = self.remaining, batch = self.batch, status = self.status,
        canmanage = canmanage, collecting = self.collecting, quantity = quantity }
end

function NearbyAutocook:Publish(status)
    if status ~= nil then self.status = status end
    if self.controller ~= nil and self.controller:IsValid() then
        local value = json.encode(self:GetState())
        if value ~= self.last_state then
            self.last_state = value
            self.controller._state:set(value)
        end
    end
end

function NearbyAutocook:Configure(config)
    for key, value in pairs(config or {}) do self.config[key] = value end
    if self.task ~= nil then self.task:Cancel() end
    self.task = self.inst:DoPeriodicTask(self.config.interval, function() self:Tick() end,
        .5 + math.random() * self.config.interval)
end

function NearbyAutocook:CaptureRecipe(skip_prediction)
    local container, stewer = self.inst.components.container, self.inst.components.stewer
    if container == nil or stewer == nil or stewer:IsCooking() or stewer:IsDone() then
        return nil, "请在空闲的锅中放好食材"
    end
    if container.readonlycontainer or container:GetNumSlots() < 1 or container:GetNumSlots() > 16
        or not container:IsFull() then
        return nil, "请填满一锅食材；每格放一份"
    end
    local recipe = {}
    for slot = 1, container:GetNumSlots() do
        local item = container:GetItemInSlot(slot)
        if item == nil or not item:IsValid() or Count(item) ~= 1
            or not container:CanTakeItemInSlot(item, slot) then
            return nil, "每个食材格必须恰好放一份"
        end
        recipe[slot] = item.prefab
    end
    -- Standard stewer assumes CalculateRecipe always returns a registered recipe.
    if not skip_prediction then
        local ok, product = pcall(cooking.CalculateRecipe, self.inst.prefab, recipe)
        if not ok or product == nil or cooking.GetRecipe(self.inst.prefab, product) == nil then
            return nil, "该建筑或配方没有标准烹饪结果"
        end
    end
    return recipe
end

function NearbyAutocook:SetBatch(batch)
    if type(batch) ~= "number" or batch ~= batch or batch < 0 or batch > 9999 or batch ~= math.floor(batch) then
        return false
    end
    self.batch = batch
    if self:CanManage() then
        -- A live edit replaces the work still requested, including the current
        -- uncollected meal. It never repeats already completed batches.
        self.remaining = batch == 0 and -1 or math.max(0, batch - (self:HasPendingMeal() and 1 or 0))
    end
    self:Publish()
    return true
end

function NearbyAutocook:Cancel()
    self.enabled = false
    self.recipe = nil
    self.remaining = 0
    self.batch = 1
    -- Native cooking has already consumed its ingredients. Keep responsibility
    -- for that one result so it finishes and is stored without loss or duplication.
    self:Publish(self:HasPendingMeal() and "已取消配方，当前一锅煮好后收存" or "配方已取消，可重新放料烹饪")
    return true
end

function NearbyAutocook:Command(command, batch)
    if command == "pause" or command == "clear" then
        self.enabled = false
        if command == "clear" then self.recipe = nil; self.remaining = 0 end
        self:Publish(self.collecting and "已暂停，当前一锅煮好后收存" or
            (command == "clear" and "配方已清除" or "已暂停"))
        return true
    end
    if command ~= "start" and command ~= "learn" then return false, "无效指令" end
    if type(batch) ~= "number" or batch ~= batch or batch < 0 or batch > 9999 or batch ~= math.floor(batch) then
        return false, "锅数必须为 0–9999 的整数"
    end
    local container = self.inst.components.container
    if not Available(self.inst) or container == nil then return false, "锅目前不可使用" end
    if command == "learn" or not container:IsEmpty() then
        local recipe, reason = self:CaptureRecipe()
        if recipe == nil then self:Publish(reason); return false, reason end
        self.recipe = recipe
    end
    if self.recipe == nil then self:Publish("请先放入食材并记录配方"); return false, self.status end
    self.batch = batch
    if command == "learn" then
        self.enabled = false
        self:Publish("配方已记录，点击开始即可自动烹饪")
    else
        self.enabled = true
        self.remaining = batch == 0 and -1 or batch
        self:Publish("等待开始")
        self:Tick()
    end
    return true
end

function NearbyAutocook:Store(loot)
    local visual = self.config.visuals and fx.Capture(loot) or nil
    local from = self.inst:GetPosition()
    local _, routes = storage.StoreProduct(self.inst, loot, self.config)
    if visual ~= nil then
        for _, route in ipairs(routes) do
            local to = route.pos
            if route.target == nil then
                -- A small visible arc for ground output; keep the real food at the pot.
                to = Vector3(to.x + .5, to.y, to.z + .3)
            end
            fx.Play(visual, from, to)
        end
    end
end

function NearbyAutocook:Collect()
    local stewer = self.inst.components.stewer
    local loot = {}
    local receiver = { userid = false, PushEvent = function() end,
        components = { inventory = { GiveItem = function(_, item) loot[#loot + 1] = item; return true end } } }
    -- Preserve native product count, freshness, callbacks and cooking duration.
    self.harvesting = true
    local ok, result = pcall(stewer.Harvest, stewer, receiver)
    self.harvesting = false
    for _, item in ipairs(loot) do
        if item:IsValid() then
            if not ok and stewer.product ~= nil and stewer:IsDone() then
                -- A broken third-party harvest callback emitted loot without
                -- clearing the original meal. Keep the original claim in the pot.
                item:Remove()
            else
                self:Store(item)
            end
        end
    end
    if not ok then
        self.enabled = false
        self.collecting = false
        self:Publish("收获接口异常，已暂停；请手动检查锅")
        print("[NearbyAutocook] Harvest failed: " .. tostring(result))
        return false
    end
    if result then
        self.collecting = false
        if not self.enabled then
            self:Publish(self.recipe == nil and "已取消，当前料理已收存" or "已暂停，当前料理已收存")
        end
    end
    return result == true
end

function NearbyAutocook:Rollback(records, container)
    for _, record in ipairs(records) do
        local item = record.item
        if item:IsValid() and item.components.inventoryitem.owner == self.inst then
            container:RemoveItem(item, true)
        end
    end
    storage.ReturnIngredients(records, self.inst:GetPosition())
end

function NearbyAutocook:StartBatch()
    local inst = self.inst
    local container, stewer = inst.components.container, inst.components.stewer
    if container:GetNumSlots() ~= #self.recipe then self:Publish("锅的格数已变化，请重新记录配方"); return end
    local missing, slots = {}, {}
    for slot, prefab in ipairs(self.recipe) do
        local item = container:GetItemInSlot(slot)
        if item ~= nil then
            if item.prefab ~= prefab or Count(item) ~= 1 then
                self:Publish("锅内食材与记录不同，等待手动整理")
                return
            end
        else
            missing[#missing + 1] = { prefab = prefab, count = 1 }
            slots[#slots + 1] = slot
        end
    end
    local plan = storage.PlanIngredients(inst, missing, self.config)
    if plan == nil then self:Publish("缺少食材，等待补充"); return end
    -- Check destination restrictions BEFORE withdrawing any source items.
    for index, entry in ipairs(plan.entries) do
        if not container:CanTakeItemInSlot(entry.item, slots[index]) then
            self:Publish("锅不接受记录中的食材，请重新设置")
            return
        end
    end
    local records = storage.TakeIngredients(plan)
    if records == nil then self:Publish("食材已变化，等待重试"); return end
    local visuals = {}
    for index, record in ipairs(records) do
        if not Available(inst) or container:GetItemInSlot(slots[index]) ~= nil
            or not container:CanTakeItemInSlot(record.item, slots[index]) then
            self:Rollback(records, container)
            self:Publish("锅内物品发生变化，已归还取出的食材")
            return
        end
        if self.config.visuals then
            visuals[#visuals + 1] = { data = fx.Capture(record.item), pos = record.origin.pos }
        end
        container:GiveItem(record.item, slots[index], record.origin.pos, false)
        if not record.item:IsValid() or container:GetItemInSlot(slots[index]) ~= record.item then
            self:Rollback(records, container)
            self:Publish("食材放入被拒绝，已归还")
            return
        end
    end
    for slot, prefab in ipairs(self.recipe) do
        local item = container:GetItemInSlot(slot)
        if item == nil or item.prefab ~= prefab or Count(item) ~= 1 then
            self:Rollback(records, container)
            self:Publish("锅内物品发生变化，已暂停本次烹饪")
            return
        end
    end
    if not stewer:CanCook() then
        self:Rollback(records, container)
        self:Publish("锅尚未满足烹饪条件")
        return
    end
    local ok, err = pcall(stewer.StartCooking, stewer, nil)
    local started = stewer:IsCooking() or stewer:IsDone()
    if started then
        self.collecting = true
        if self.remaining > 0 then self.remaining = self.remaining - 1 end
        for _, visual in ipairs(visuals) do fx.Play(visual.data, visual.pos, inst:GetPosition()) end
    else
        self:Rollback(records, container)
    end
    if not ok then
        self.enabled = false
        self:Publish("烹饪接口异常，已暂停；请检查锅")
        print("[NearbyAutocook] StartCooking failed: " .. tostring(err))
    else
        self:Publish(started and "正在烹饪" or "锅未开始烹饪，等待重试")
    end
end

function NearbyAutocook:Tick()
    if not Available(self.inst) then return end
    local stewer, container = self.inst.components.stewer, self.inst.components.container
    if stewer == nil or container == nil or container.readonlycontainer then return end
    if self.collecting then
        if stewer:IsDone() then
            if not self:Collect() then return end
        elseif not stewer:IsCooking() then
            -- Manual harvesting/hammering/burning must never create a duplicate.
            self.collecting = false
        end
    end
    if not self.enabled then return end
    if stewer:IsCooking() then self:Publish("正在烹饪"); return end
    if stewer:IsDone() then self:Publish("请先收取锅内原有料理"); return end
    if self.remaining == 0 then
        self.enabled = false
        self:Publish("设定锅数已完成，成品已收存")
        return
    end
    if container:IsOpen() then self:Publish("等待玩家关闭锅"); return end
    if not container.canbeopened then self:Publish("锅目前不可使用"); return end
    if self.recipe == nil then self.enabled = false; self:Publish("请先记录配方"); return end
    self:StartBatch()
end

function NearbyAutocook:OnSave()
    return { recipe = self.recipe, enabled = self.enabled, remaining = self.remaining,
        batch = self.batch, collecting = self.collecting }
end

function NearbyAutocook:OnLoad(data)
    if type(data) ~= "table" then return end
    if type(data.recipe) == "table" and #data.recipe > 0 and #data.recipe <= 16 then
        local recipe = {}
        for _, prefab in ipairs(data.recipe) do
            if type(prefab) ~= "string" or #prefab > 100 then return end
            recipe[#recipe + 1] = prefab
        end
        self.recipe = recipe
    end
    local remaining = tonumber(data.remaining) or 0
    self.remaining = remaining == -1 and -1 or math.max(0, math.min(9999, math.floor(remaining)))
    self.batch = math.max(0, math.min(9999, math.floor(tonumber(data.batch) or 1)))
    self.enabled = data.enabled == true and self.recipe ~= nil
    self.collecting = data.collecting == true
    self:Publish(self.enabled and "已恢复自动烹饪" or
        (self.recipe == nil and (self.collecting and "已取消配方，当前一锅煮好后收存" or "配方已取消，可重新放料烹饪") or "已暂停"))
end

function NearbyAutocook:OnRemoveFromEntity()
    if self.task ~= nil then self.task:Cancel() end
    if self.controller ~= nil and self.controller:IsValid() then self.controller:Remove() end
    local stewer = self.inst.components.stewer
    if stewer ~= nil and stewer.Harvest == self.wrapped_harvest then
        stewer.Harvest = self.original_harvest
    end
    if stewer ~= nil and stewer.StartCooking == self.wrapped_startcooking then
        stewer.StartCooking = self.original_startcooking
    end
end

NearbyAutocook.OnRemoveEntity = NearbyAutocook.OnRemoveFromEntity
return NearbyAutocook
