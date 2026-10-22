-- Server projectile plus client-only image, using DST's real complexprojectile.
-- This checks native component calls and cleanup, not rendered pixels.
package.path = (NAC_MOD_ROOT or "nearby_autocook") .. "/scripts/?.lua;"
    .. (NAC_GAME_SCRIPTS or "game_scripts_reference/scripts") .. "/?.lua;" .. package.path
require("class")
require("vector3")
local ComplexProjectile = require("components/complexprojectile")
local flight = require("nac_flight")
table.removearrayvalue = function(values, wanted)
    for index, value in ipairs(values) do
        if value == wanted then return table.remove(values, index) end
    end
end

local created, dedicated = {}, false
TheWorld = { ismastersim = false }
TheNet = { IsDedicated = function() return dedicated end }
Asset = function(kind, path) return {kind=kind,path=path} end
Prefab = function(name, fn, assets) return {name=name,fn=fn,assets=assets} end
local function net(initial)
    return { current=initial,
        value=function(self) return self.current end,
        set=function(self, value) self.current=value end }
end
net_float = function() return net(0) end
net_hash = function() return net(0) end
net_bool = function() return net(false) end
DEGREES = math.pi / 180

MakeInventoryPhysics = function(inst, mass, radius)
    inst.physics_config={mass=mass,radius=radius}
    inst.Physics={
        ClearCollisionMask=function() inst.physics_config.no_collision=true end,
        Teleport=function(_, x,y,z) inst.Transform:SetPosition(x,y,z) end,
        SetMotorVel=function(_, x,y,z) inst.motor={x=x,y=y,z=z} end,
        Stop=function() inst.physics_stopped=true end,
    }
end

CreateEntity = function()
    local inst = { GUID=#created+1, components={}, tags={}, events={}, tasks={} }
    inst.entity = {
        AddTransform=function()
            inst.position={x=0,y=0,z=0}
            inst.Transform = {
                SetPosition=function(_, x,y,z) inst.position={x=x,y=y,z=z} end,
                GetWorldPosition=function() return inst.position.x,inst.position.y,inst.position.z end,
                GetRotation=function() return inst.rotation or 0 end,
            }
        end,
        AddNetwork=function() inst.networked=true end,
        AddAnimState=function()
            inst.animation = {overrides={}}
            inst.AnimState = {
                SetBank=function(_, value) inst.animation.bank=value end,
                SetBuild=function(_, value) inst.animation.build=value end,
                PlayAnimation=function(_, value, loop) inst.animation.anim=value; inst.animation.loop=loop end,
                OverrideSymbol=function(_, symbol, build, name)
                    inst.animation.overrides[symbol]={build=build,name=name}
                end,
                SetFinalOffset=function(_, value) inst.animation.offset=value end,
                SetScale=function(_, x,y) inst.animation.scale={x,y} end,
            }
        end,
        SetCanSleep=function(_, value) inst.can_sleep=value end,
        SetParent=function(_, value) inst.parent=value end,
        SetPristine=function() inst.pristine=true end,
    }
    function inst:AddTag(tag) self.tags[tag]=true end
    function inst:RemoveTag(tag) self.tags[tag]=nil end
    function inst:GetPosition() return Vector3(self.position.x,self.position.y,self.position.z) end
    function inst:GetCurrentPlatform() return nil end
    function inst:ForceFacePoint(x,y,z)
        self.rotation=-math.atan2(z-self.position.z,x-self.position.x)/DEGREES
    end
    function inst:AddComponent(name)
        assert(name == "complexprojectile", "FX must only own its native flight component: " .. name)
        self.components[name]=ComplexProjectile(self)
    end
    function inst:ListenForEvent(event, fn) self.events[event]=fn end
    function inst:DoTaskInTime(delay, fn) self.tasks[#self.tasks+1]={delay=delay,fn=fn} end
    function inst:Remove()
        self.removed=true
        if self.OnRemoveEntity then self.OnRemoveEntity(self) end
    end
    function inst:StartUpdatingComponent(component) self.updating=component end
    function inst:StopUpdatingComponent(component)
        assert(self.updating == component); self.updating=nil
    end
    created[#created+1]=inst
    return inst
end
local prefab = require("prefabs/nac_transfer_fx")
local function newfx()
    created={}
    local inst=prefab.fn()
    assert(inst.networked and inst.pristine and inst.persists == false and inst.Setup == nil)
    assert(inst.physics_config.mass == 1 and inst.physics_config.radius == .5 and inst.physics_config.no_collision)
    return inst
end
local function wire(inst, symbols)
    inst._dx:set(8); inst._dy:set(2); inst._dz:set(-4)
    local duration, arc = flight.Calculate(80, 2)
    inst._duration:set(duration); inst._arc:set(arc)
    inst._bank:set(123); inst._build:set(234); inst._anim:set(345)
    if symbols then
        inst._symbol:set(456); inst._symbolbuild:set(567); inst._symbolname:set(678)
        inst._garnish:set(789)
    end
    inst._ready:set(true)
end
local function approx(actual, expected)
    assert(math.abs(actual-expected)<1e-8, tostring(actual).." ~= "..tostring(expected))
end
local passed=0
local function test(name, fn)
    fn(); passed=passed+1; print("AUTOCOOK_FX_PASS "..name)
end

test("flight matches native complexprojectile high-arc velocity with CookDiary tuning", function()
    assert(flight.HEIGHT == 6.5 and flight.GRAVITY == 25
        and flight.SPEED_MULTIPLIER == 1.1 and flight.OFFSET_Y == 3.2)
    local projectile = ComplexProjectile({AddTag=function() end})
    projectile:SetGravity(-25)
    for _, distance in ipairs({.1, 1, 4, 8, 12, 24}) do
        for _, dy in ipairs({0, 1, -2}) do
            local speed = math.sqrt((25 * distance * distance + 16 * 25 * 6.5 * 6.5) / (8 * 6.5)) * 1.1
            projectile:CalculateTrajectory(Vector3(0,3.2,0), Vector3(distance,3.2+dy,0), speed)
            local duration, arc = flight.Calculate(distance * distance, dy)
            approx(distance / duration, projectile.velocity.x)
            approx(dy / duration + 25 * duration / 2, projectile.velocity.y)
            approx(arc, 25 * duration * duration / 8)
        end
    end
end)

test("zero-distance and elevated targets produce finite reachable arcs", function()
    local duration, arc = flight.Calculate(0, 0)
    approx(arc, 6.5 * 1.1 * 1.1)
    approx(duration, math.sqrt(8 * arc / 25))
    for _, dy in ipairs({-100, 0, 100}) do
        duration, arc = flight.Calculate(0, dy)
        assert(duration > 0 and duration < math.huge and arc > 0 and arc < math.huge)
    end
end)

test("network readiness creates one local-only visual with exact food symbols", function()
    local inst=newfx()
    inst.tasks[1].fn(inst)
    assert(#created == 1 and inst._visual == nil)
    wire(inst, true)
    inst.events.nac_transfer_fx_dirty(inst)
    local visual=assert(inst._visual)
    assert(#created == 2 and not visual.networked and visual.parent == inst.entity)
    assert(visual.persists == false and visual.components.inventoryitem == nil)
    approx(visual.position.y, 0)
    assert(visual.Physics == nil and inst.components.complexprojectile == nil)
    assert(visual.tags.FX and visual.tags.NOCLICK and visual.can_sleep == false)
    assert(visual.animation.bank == 123 and visual.animation.build == 234 and visual.animation.anim == 345)
    assert(visual.animation.overrides[456].build == 567 and visual.animation.overrides[456].name == 678)
    assert(visual.animation.overrides.swap_garnish.build == "spices" and visual.animation.overrides.swap_garnish.name == 789)
    inst.events.nac_transfer_fx_dirty(inst)
    inst.tasks[1].fn(inst)
    assert(#created == 2 and inst._visual == visual)
end)

test("client image follows only its network parent without local trajectory updates", function()
    local inst=newfx()
    wire(inst, false)
    inst.events.nac_transfer_fx_dirty(inst)
    local visual=inst._visual
    assert(next(visual.animation.overrides) == nil)
    inst.Transform:SetPosition(6,10,9)
    approx(visual.position.x,0); approx(visual.position.y,0); approx(visual.position.z,0)
    assert(visual.parent == inst.entity and next(inst.components) == nil and next(visual.components) == nil)
    inst:Remove()
    assert(visual.removed and inst._visual == nil)
end)

test("parent removal cleans a visual before its arc finishes", function()
    local inst=newfx()
    wire(inst, false)
    inst.tasks[1].fn(inst)
    local visual=assert(inst._visual)
    inst:Remove()
    assert(visual.removed and inst._visual == nil)
    inst:Remove()
end)

test("dedicated processes do not construct a client visual", function()
    dedicated=true
    local inst=newfx()
    wire(inst, true)
    inst.events.nac_transfer_fx_dirty(inst)
    assert(#created == 1 and inst._visual == nil and inst.components.updatelooper == nil)
    dedicated=false
end)
test("native server projectile uses exact reference launch and arrival without an inventory item", function()
    TheWorld.ismastersim=true
    local inst=prefab.fn()
    local target=Vector3(10,1,3)
    inst:Setup({bank=123,build=234,anim=345}, Vector3(2,0,3), target)
    local p=inst.components.complexprojectile
    approx(inst.position.x,2); approx(inst.position.y,3.2); approx(inst.position.z,3)
    approx(target.y,1)
    approx(inst._dx:value(),8); approx(inst._dy:value(),1)
    approx(p.gravity,-25); approx(p.horizontalSpeed,flight.Speed(64))
    assert(p.usehigharc and p.targetoffset.y == 3.2 and p.launchoffset.y == 3.2)
    assert(inst.components.inventoryitem == nil and inst.components.stackable == nil)
    local initial_y=p.velocity.y
    p:OnUpdate(1/30)
    approx(inst.motor.y,initial_y); approx(p.velocity.y,initial_y-25/30)
    assert(not inst.removed)
    p.velocity.y=-1
    inst.Transform:SetPosition(10,3.21,3)
    p:OnUpdate(1/30)
    assert(not inst.removed, "falling above the pot must continue")
    inst.Transform:SetPosition(10,3.2,3)
    p:OnUpdate(1/30)
    assert(inst.removed and inst.physics_stopped and inst._visual == nil and inst.updating == nil)
    TheWorld.ismastersim=false
end)

test("server fallback allows long flights and removes unconfigured effects", function()
    TheWorld.ismastersim=true
    local inst=prefab.fn()
    local duration, arc=flight.Calculate(10000, 0)
    inst:Setup({bank=123,build=234,anim=345}, Vector3(2,0,3), Vector3(102,0,3))
    approx(inst._duration:value(), duration); approx(inst._arc:value(), arc)
    approx(inst.position.x, 2); approx(inst.position.y, 3.2); approx(inst.position.z, 3)
    assert(duration > 3 and inst._ready:value())
    inst.tasks[1].fn(inst)
    assert(not inst.removed, "unconfigured-FX timer must not cut a configured flight short")
    approx(inst.tasks[2].delay, duration+.6)
    inst.tasks[2].fn(inst)
    assert(inst.removed and inst._visual == nil)
    local unconfigured=prefab.fn()
    unconfigured.tasks[1].fn(unconfigured)
    assert(unconfigured.removed)
    TheWorld.ismastersim=false
end)
print("AUTOCOOK_FX_SUCCESS "..passed)
