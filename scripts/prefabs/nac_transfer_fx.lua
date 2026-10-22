-- Native, networked flight plus a client-only image. No inventory item is in flight.
local flight = require("nac_flight")
local assets = {
    Asset("ANIM", "anim/carrot.zip"),
    Asset("ANIM", "anim/cook_pot_food.zip"),
}

local function RemoveVisual(inst)
    if inst._visual ~= nil then
        inst._visual:Remove()
        inst._visual = nil
    end
end

local function StartVisual(inst)
    if not inst._ready:value() or inst._started or TheNet:IsDedicated() then
        return
    end
    inst._started = true
    local visual = CreateEntity()
    visual.entity:AddTransform()
    visual.entity:AddAnimState()
    visual.entity:SetCanSleep(false)
    visual.entity:SetParent(inst.entity)
    visual:AddTag("FX")
    visual:AddTag("NOCLICK")
    visual.persists = false
    visual.AnimState:SetBank(inst._bank:value())
    visual.AnimState:SetBuild(inst._build:value())
    visual.AnimState:PlayAnimation(inst._anim:value(), true)
    if inst._symbol:value() ~= 0 then
        visual.AnimState:OverrideSymbol(inst._symbol:value(), inst._symbolbuild:value(), inst._symbolname:value())
    end
    if inst._garnish:value() ~= 0 then
        visual.AnimState:OverrideSymbol("swap_garnish", "spices", inst._garnish:value())
    end
    visual.AnimState:SetFinalOffset(3)
    visual.AnimState:SetScale(.85, .85)
    -- The server moves the network parent with the same engine Physics as an
    -- ingredient projectile. Clients only draw at its replicated position.
    visual.Transform:SetPosition(0, 0, 0)
    inst._visual = visual
end

local function OnFlightUpdate(inst)
    local projectile = inst.components.complexprojectile
    local _, y = inst.Transform:GetWorldPosition()
    if projectile.velocity.y < 0 and y <= flight.OFFSET_Y then
        projectile:Hit()
        return true
    end
    return false
end

local function Setup(inst, data, frompos, topos)
    local dx, dy, dz = topos.x - frompos.x, (topos.y or 0) - (frompos.y or 0), topos.z - frompos.z
    -- complexprojectile's target offset is an absolute world height. Match
    -- CookDiary's 3.2 arrival threshold even if the caller's target has a y value.
    local duration, arc = flight.Calculate(dx * dx + dz * dz, -(frompos.y or 0))
    inst.Transform:SetPosition(frompos.x, frompos.y or 0, frompos.z)
    inst._dx:set(dx)
    inst._dy:set(dy)
    inst._dz:set(dz)
    inst._duration:set(duration)
    inst._arc:set(arc)
    inst._bank:set(data.bank)
    inst._build:set(data.build)
    inst._anim:set(data.anim)
    if data.override ~= nil then
        inst._symbol:set(data.override[1])
        inst._symbolbuild:set(data.override[2])
        inst._symbolname:set(data.override[3])
    end
    if data.garnish ~= nil then
        inst._garnish:set(data.garnish)
    end
    local projectile = inst.components.complexprojectile
    projectile:SetHorizontalSpeed(flight.Speed(dx * dx + dz * dz))
    projectile:SetGravity(-flight.GRAVITY)
    projectile:SetLaunchOffset({x=0, y=flight.OFFSET_Y, z=0})
    projectile:SetTargetOffset({y=flight.OFFSET_Y})
    projectile:SetOnUpdate(OnFlightUpdate)
    projectile:SetOnHit(inst.Remove)
    -- Launch changes targetPos.y internally; never mutate the caller's vector.
    projectile:Launch(Vector3(topos.x, topos.y or 0, topos.z), inst, inst)
    inst._ready:set(true)
    StartVisual(inst)
    -- Flight normally removes itself on arrival. Keep a bounded fallback for
    -- unexpected engine/mod interactions, including a missing hit callback.
    inst:DoTaskInTime(duration + .6, inst.Remove)
end

local function fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddNetwork()
    inst.entity:SetCanSleep(false)
    MakeInventoryPhysics(inst, 1, .5)
    -- This is a visual only: gravity/integration match real ingredients without
    -- allowing the effect to collide with or push any player, item, or building.
    inst.Physics:ClearCollisionMask()
    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.persists = false

    inst._dx = net_float(inst.GUID, "nac_transfer_fx.dx")
    inst._dy = net_float(inst.GUID, "nac_transfer_fx.dy")
    inst._dz = net_float(inst.GUID, "nac_transfer_fx.dz")
    inst._duration = net_float(inst.GUID, "nac_transfer_fx.duration")
    inst._arc = net_float(inst.GUID, "nac_transfer_fx.arc")
    inst._bank = net_hash(inst.GUID, "nac_transfer_fx.bank")
    inst._build = net_hash(inst.GUID, "nac_transfer_fx.build")
    inst._anim = net_hash(inst.GUID, "nac_transfer_fx.anim")
    inst._symbol = net_hash(inst.GUID, "nac_transfer_fx.symbol")
    inst._symbolbuild = net_hash(inst.GUID, "nac_transfer_fx.symbolbuild")
    inst._symbolname = net_hash(inst.GUID, "nac_transfer_fx.symbolname")
    inst._garnish = net_hash(inst.GUID, "nac_transfer_fx.garnish")
    inst._ready = net_bool(inst.GUID, "nac_transfer_fx.ready", "nac_transfer_fx_dirty")
    inst.OnRemoveEntity = RemoveVisual
    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        inst:ListenForEvent("nac_transfer_fx_dirty", StartVisual)
        inst:DoTaskInTime(0, StartVisual)
        return inst
    end
    inst:AddComponent("complexprojectile")
    inst.Setup = Setup
    -- Also clean up accidentally spawned, never configured visuals.
    inst:DoTaskInTime(3, function()
        if not inst._ready:value() then inst:Remove() end
    end)
    return inst
end

return Prefab("nac_transfer_fx", fn, assets)
