-- Separate network entity: no extra netvars are injected into vanilla prefabs.
local function Bind(inst)
    local pot = inst._pot:value()
    if pot ~= nil and pot:IsValid() then
        inst._bound = pot
        pot._nac_controller = inst
        return true
    end
end

local function fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddNetwork()
    inst:AddTag("CLASSIFIED")
    inst:AddTag("NOCLICK")
    inst.persists = false
    inst._pot = net_entity(inst.GUID, "nac_controller.pot", "nac_controller_dirty")
    inst._state = net_string(inst.GUID, "nac_controller.state")
    inst.entity:SetPristine()
    inst.OnRemoveEntity = function()
        if inst._bound ~= nil and inst._bound._nac_controller == inst then
            inst._bound._nac_controller = nil
        end
    end
    if not TheWorld.ismastersim then
        inst:ListenForEvent("nac_controller_dirty", Bind)
        inst:DoTaskInTime(0, Bind)
        return inst
    end
    inst.Attach = function(self, pot)
        self.entity:SetParent(pot.entity)
        self.Network:SetClassifiedTarget(nil)
        self._pot:set(pot)
        Bind(self)
    end
    return inst
end

return Prefab("nac_controller", fn)
