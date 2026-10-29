local G = GLOBAL
local cooking = G.require("cooking")
PrefabFiles = { "nac_controller", "nac_transfer_fx" }

local config = {
    radius = GetModConfigData("SEARCH_RADIUS") or 12,
    ground = GetModConfigData("GROUND_INGREDIENTS") ~= false,
    interval = GetModConfigData("CHECK_INTERVAL") or 1,
    visuals = GetModConfigData("TRANSFER_FX") ~= false,
}

AddPrefabPostInitAny(function(inst)
    if G.TheWorld == nil or not G.TheWorld.ismastersim then return end
    local c = inst.components
    if c.stewer ~= nil and c.container ~= nil and cooking.recipes[inst.prefab] ~= nil
        and c.container:GetNumSlots() > 0 and c.container:GetNumSlots() <= 16 then
        -- Add synchronously so the component exists when engine save data loads.
        inst:AddComponent("nearbyautocook")
        inst.components.nearbyautocook:Configure(config)
    end
end)

local function CanAccess(player, pot)
    if player == nil or not player:IsValid() or player:HasTag("playerghost")
        or (player.components.health ~= nil and player.components.health:IsDead())
        or type(pot) ~= "table" or not pot.IsValid or not pot:IsValid()
        or pot.components.nearbyautocook == nil or player:GetDistanceSqToInst(pot) > 36
        or pot:HasTag("burnt") or pot:HasTag("INLIMBO") then return false end
    local container = pot.components.container
    if container == nil or container.readonlycontainer or container:IsOpenedByOthers(player)
        or (pot:HasTag("mastercookware") and not player:HasTag("masterchef"))
        or (container.restrictedtag ~= nil and not player:HasTag(container.restrictedtag)) then return false end
    return true
end

G.require("nac_actions")(env, function(player, pot)
    return CanAccess(player, pot) and pot.components.nearbyautocook:CanManage()
end)

AddModRPCHandler("nearby_autocook", "command", function(player, pot, command, batch)
    if not CanAccess(player, pot) then return end
    local component = pot.components.nearbyautocook
    local container = pot.components.container
    if command == "cancel" then
        if component:CanManage() then component:Cancel() end
        return
    end
    if command ~= "cook" and command ~= "setbatch" then return end
    if type(batch) ~= "number" or batch ~= batch or batch < 0 or batch > 9999 or batch ~= G.math.floor(batch) then return end
    if command == "setbatch" then
        -- Native stewer closes and locks the container while cooking. The
        -- separate management action may still adjust an existing nearby job.
        if container:IsOpenedBy(player) or component:CanManage() then component:SetBatch(batch) end
        return
    end
    if not container:IsOpenedBy(player) then return end
    if player:HasTag("busy") or pot:HasTag("burnt") or container.canbeopened == false then return end
    local stewer = pot.components.stewer
    if stewer == nil or stewer:IsCooking() or stewer:IsDone() or not stewer:CanCook() then return end
    local now = G.GetTime()
    if player._nac_lastcook ~= nil and now - player._nac_lastcook < .2 then return end
    player._nac_lastcook = now
    pot.components.nearbyautocook:SetBatch(batch)
    -- Preserve the native action, including pot/character callbacks. The stewer
    -- wrapper records the actual ingredients only when native cooking succeeds.
    G.BufferedAction(player, pot, G.ACTIONS.COOK):Do()
end)

if not G.TheNet:IsDedicated() then G.require("nac_ui")(env) end
