-- The ordinary pot container closes while cooking. This separate scene action
-- keeps an active automatic recipe reachable without changing vanilla harvest.
return function(env, CanManage)
    local G = env.GLOBAL or _G
    local json = G.require("json")

    local function ReadState(pot)
        -- Component state is authoritative on the host. A newly spawned pot's
        -- classified controller may not have bound its network entity yet.
        local component = G.TheWorld ~= nil and G.TheWorld.ismastersim
            and pot ~= nil and pot.components and pot.components.nearbyautocook or nil
        if component ~= nil then return component:GetState() end
        local controller = pot ~= nil and pot._nac_controller or nil
        if controller == nil or not controller:IsValid() or controller._state == nil then return nil end
        local raw = controller._state:value()
        if type(raw) ~= "string" or raw == "" then return nil end
        local ok, state = pcall(json.decode, raw)
        return ok and type(state) == "table" and state or nil
    end

    local function ClientCanManage(pot, player)
        if pot == nil or not pot:IsValid() or player == nil or not player:IsValid()
            or player:HasTag("playerghost") or pot:HasTag("burnt")
            or player:GetDistanceSqToInst(pot) > 36
            or (pot:HasTag("mastercookware") and not player:HasTag("masterchef")) then return false end
        local container = pot.replica and pot.replica.container
        if container == nil or (container.IsReadOnlyContainer ~= nil and container:IsReadOnlyContainer()) then return false end
        local state = ReadState(pot)
        return state ~= nil and state.canmanage == true
    end

    env.AddClientModRPCHandler("nearby_autocook", "openmanage", function(pot)
        if G.TheNet:IsDedicated() or G.TheFrontEnd == nil or not ClientCanManage(pot, G.ThePlayer) then return end
        local old = G.ThePlayer._nac_manage_screen
        if old ~= nil and not old._closed then
            if old.pot == pot then return end
            old:Close()
        end
        local ManageScreen = G.require("screens/nac_manage")
        local screen = ManageScreen(pot, function(command, quantity)
            if not ClientCanManage(pot, G.ThePlayer) then return false end
            env.SendModRPCToServer(env.GetModRPC("nearby_autocook", "command"), pot, command, quantity)
            return true
        end, ReadState, ClientCanManage)
        G.ThePlayer._nac_manage_screen = screen
        G.TheFrontEnd:PushScreen(screen)
    end)

    local action = env.AddAction("NAC_MANAGE", "调整烹饪", function(act)
        if G.TheWorld == nil or not G.TheWorld.ismastersim or not CanManage(act.doer, act.target) then return false end
        env.SendModRPCToClient(env.GetClientModRPC("nearby_autocook", "openmanage"), act.doer.userid, act.target)
        return true
    end)
    action.priority = 2
    action.rmb = true
    action.distance = 3
    action.invalid_hold_action = true

    env.AddComponentAction("SCENE", "nearbyautocook", function(pot, doer, actions, right)
        if not right or doer == nil or doer:HasTag("playerghost") or pot:HasTag("burnt")
            or (pot:HasTag("mastercookware") and not doer:HasTag("masterchef")) then return end
        local container = pot.replica and pot.replica.container
        if container == nil or (container.IsReadOnlyContainer ~= nil and container:IsReadOnlyContainer()) then return end
        local state = ReadState(pot)
        if state ~= nil and state.canmanage == true then table.insert(actions, action) end
    end)
    env.AddStategraphActionHandler("wilson", G.ActionHandler(action, "doshortaction"))
    env.AddStategraphActionHandler("wilson_client", G.ActionHandler(action, "doshortaction"))
end
