-- Server boundary: a single native Cook action carries the quantity atomically.
local handlers, now, cooks, preferences = {}, 1, 0, 0
GLOBAL = _G
TheNet = { IsDedicated = function() return true end }
GetTime = function() return now end
package.loaded.cooking = { recipes = {} }
GetModConfigData = function() end
AddPrefabPostInitAny = function() end
AddModRPCHandler = function(_, name, fn) handlers[name] = fn end
ACTIONS = { COOK = {} }
local selected
BufferedAction = function(player, pot, action)
    assert(action == ACTIONS.COOK)
    return { Do = function() cooks = cooks + 1; return true end }
end
assert(loadfile((NAC_MOD_ROOT or "nearby_autocook") .. "/modmain.lua"))()
local command = assert(handlers.command)
local player = {
    components = { health = { IsDead = function() return false end } },
    tags = {}, distance = 4,
    IsValid = function() return true end,
    HasTag = function(self, tag) return self.tags[tag] end,
    GetDistanceSqToInst = function(self) return self.distance end,
}
local container = {
    canbeopened = true, opened = true,
    IsOpenedByOthers = function(self) return self.others end,
    IsOpenedBy = function(self) return self.opened end,
    Close = function() error("The native action must own container closing") end,
}
local stewer = {
    IsCooking = function(self) return self.cooking end,
    IsDone = function(self) return self.done end,
    CanCook = function(self) return not self.incomplete end,
}
local pot = {
    components = { container = container, stewer = stewer, nearbyautocook = {
        SetBatch = function(_, batch) preferences = preferences + 1; selected = batch; return true end,
    } }, tags = {}, IsValid = function() return true end,
    HasTag = function(self, tag) return self.tags[tag] end,
}
local passed = 0
local function test(name, fn)
    now = now + 1
    local before = cooks
    fn(before)
    passed = passed + 1
    print("AUTOCOOK_RPC_PASS " .. name)
end
test("quantity and native cook are applied together", function(before)
    command(player, pot, "cook", 10)
    assert(cooks == before + 1 and selected == 10)
end)
test("saving a preference neither cooks nor blocks the following click", function(before)
    command(player, pot, "setbatch", 5)
    assert(cooks == before and selected == 5)
    command(player, pot, "cook", 7)
    assert(cooks == before + 1 and selected == 7)
end)
test("malformed targets and retired modal commands", function(before)
    command(player, 123, "cook", 1)
    command(player, nil, "cook", 1)
    command(player, {}, "cook", 1)
    for _, op in ipairs({"start", "learn", "pause", "clear", "delete"}) do command(player, pot, op, 1) end
    assert(cooks == before)
end)
test("non-finite fractional and oversized quantities change nothing", function(before)
    local prior = preferences
    for _, value in ipairs({-1, .5, math.huge, 0/0, 10000, "10"}) do command(player, pot, "cook", value) end
    assert(cooks == before and preferences == prior)
end)
test("distant dead or busy players cannot start a pot", function(before)
    player.distance = 37; command(player, pot, "cook", 1); player.distance = 4
    player.tags.playerghost = true; command(player, pot, "cook", 1); player.tags.playerghost = nil
    player.tags.busy = true; command(player, pot, "cook", 1); player.tags.busy = nil
    player.components.health.IsDead = function() return true end
    command(player, pot, "cook", 1)
    player.components.health.IsDead = function() return false end
    assert(cooks == before)
end)
test("the caller must be the pot's active opener", function(before)
    container.readonlycontainer = true; command(player, pot, "cook", 1); container.readonlycontainer = false
    container.others = true; command(player, pot, "cook", 1); container.others = false
    container.opened = false; command(player, pot, "cook", 1); command(player, pot, "setbatch", 1); container.opened = true
    assert(cooks == before)
end)
test("portable cookware retains character restriction", function(before)
    pot.tags.mastercookware = true
    command(player, pot, "cook", 1); assert(cooks == before)
    player.tags.masterchef = true
    command(player, pot, "cook", 1); assert(cooks == before + 1)
    pot.tags.mastercookware, player.tags.masterchef = nil, nil
end)
test("modded container restriction", function(before)
    container.restrictedtag = "customchef"
    command(player, pot, "cook", 1); assert(cooks == before)
    container.restrictedtag = nil
end)
test("burst clicks cannot repeatedly start a batch", function(before)
    command(player, pot, "cook", 1)
    command(player, pot, "cook", 1)
    assert(cooks == before + 1)
end)
test("occupied incomplete or burnt pots retain their existing quota", function(before)
    local prior = preferences
    stewer.cooking = true; command(player, pot, "cook", 1); stewer.cooking = nil
    stewer.done = true; command(player, pot, "cook", 1); stewer.done = nil
    stewer.incomplete = true; command(player, pot, "cook", 1); stewer.incomplete = nil
    pot.tags.burnt = true; command(player, pot, "cook", 1); pot.tags.burnt = nil
    assert(cooks == before and preferences == prior)
end)
print("AUTOCOOK_RPC_SUCCESS " .. passed)
