-- Offline checks for the quantity field attached to the native container UI.
-- Widget methods below mirror the actual game TextEdit/ContainerWidget API;
-- visual appearance and engine text focus still require a game client.
package.path = (NAC_MOD_ROOT or "nearby_autocook") .. "/scripts/?.lua;"
    .. (NAC_GAME_SCRIPTS or "game_scripts_reference/scripts") .. "/?.lua;" .. package.path
require("class")
local json = require("json")
UIFONT = "ui"

local tasks = {}
local Widget = Class(function(self, name)
    self.name, self.children, self.shown, self.enabled = name, {}, true, true
    self.inst = { DoPeriodicTask = function(_, period, fn)
        assert(period == .2)
        local task = { fn=fn, Cancel=function(task) task.cancelled = true end }
        tasks[#tasks + 1] = task
        return task
    end, DoTaskInTime = function(_, delay, fn)
        assert(delay == 0)
        local task = { fn=function(task) fn(); end, once=true, Cancel=function(task) task.cancelled=true end }
        tasks[#tasks + 1] = task
        return task
    end }
end)
function Widget:AddChild(child) self.children[child] = true; child.parent = self; return child end
function Widget:Kill()
    self.killed = true
    for child in pairs(self.children) do child:Kill() end
    if self.parent then self.parent.children[self] = nil end
end
function Widget:Enable() self.enabled = true end
function Widget:Disable() self.enabled = false; if self.SetEditing then self:SetEditing(false) end end
function Widget:SetPosition(x, y) self.x, self.y = x, y end
function Widget:SetString(value) self.value = value end
function Widget:GetString() return self.value end
function Widget:SetOnClick(fn) self.onclick = fn end
function Widget:SetEditing(value) self.editing = value; self.force_active = self.force and value end
function Widget:OnLoseFocus() self.focus = false end
function Widget:SetTextLengthLimit(value) self.limit = value end
function Widget:SetCharacterFilter(value) self.characters = value end
function Widget:SetForceEdit(value) self.force = value end
for _, method in ipairs({ "SetRegionSize", "SetIdleTextColour", "SetEditTextColour",
    "SetFocusedImage", "ScaleToSize", "SetFocusChangeDir", "SetPassControlToScreen" }) do Widget[method] = function() end end
function Widget:OnControl() return false end
local Text = Class(Widget, function(self, font, size, value)
    Widget._ctor(self, "text"); self:SetString(value)
end)
package.loaded["widgets/widget"] = Widget
package.loaded["widgets/text"] = Text
package.loaded["widgets/textedit"] = Text
package.loaded["widgets/image"] = Widget
package.loaded["cooking"] = { recipes={ cookpot={} } }

local hook, sent, dedicated = nil, {}, false
local rpc = {}
TheNet = { IsDedicated=function() return dedicated end }
TheInput = { AddKeyUpHandler=function() error("quantity UI must not register a shortcut") end }
TheFrontEnd = { PushScreen=function() error("quantity UI must not open another screen") end }
local env = {
    GLOBAL=_G,
    GetModRPC=function(namespace, name)
        assert(namespace == "nearby_autocook" and name == "command"); return rpc
    end,
    SendModRPCToServer=function(id, pot, command, batch)
        assert(id == rpc); sent[#sent + 1] = {pot=pot, command=command, batch=batch}
    end,
    AddClassPostConstruct=function(name, fn)
        assert(name == "widgets/containerwidget"); hook = fn
    end,
}
local Install = require("nac_ui")
Install(env)
assert(hook ~= nil)

local function Entity()
    return {
        valid=true, prefab="cookpot", tags={stewer=true}, distsq=9,
        IsValid=function(self) return self.valid end,
        HasTag=function(self, tag) return self.tags[tag] == true end,
        GetDistanceSqToInst=function(_, pot) return pot.distsq end,
    }
end
local function SetState(pot, batch)
    pot.wire = json.encode({batch=batch, recipe={}, status="等待手动烹饪"})
    pot._nac_controller = Entity()
    pot._nac_controller._state = { value=function() return pot.wire end }
end
local function Fixture(batch)
    sent, tasks = {}, {}
    local doer, pot = Entity(), Entity()
    doer.components = {playercontroller={IsEnabled=function() return true, false end}}
    pot.can_cook, pot.native_calls = true, 0
    pot.widget = {buttoninfo={
        position={x=12,y=-100}, text="烹饪",
        validfn=function(target) return target.can_cook end,
        fn=function(target) target.native_calls = target.native_calls + 1 end,
    }}
    pot.replica = {container={
        GetWidget=function() return pot.widget end,
        IsReadOnlyContainer=function() return pot.readonly == true end,
    }}
    if batch ~= nil then SetState(pot, batch) end
    local container = Widget("container")
    container.Close = function(self)
        if self.button ~= nil then self.button:Kill(); self.button = nil end
        self.isopen, self.container = false, nil
    end
    container.Refresh = function(self) self.refreshes = (self.refreshes or 0) + 1 end
    container.Open = function(self, target, player)
        self:Close()
        self.isopen, self.container = true, target
        if target.widget.buttoninfo ~= nil then
            self.button = self:AddChild(Widget("native Cook button"))
            self.button.value = target.widget.buttoninfo.text
            self.button.original_style = true
            self.button:SetOnClick(function() target.widget.buttoninfo.fn(target, player) end)
        end
        self:Refresh()
    end
    hook(container)
    return pot, doer, container
end
local function Open(batch)
    local pot, doer, container = Fixture(batch)
    container:Open(pot, doer)
    return pot, doer, container, container._nac_quantity
end
local function Tick(count)
    for _ = 1, count or 1 do
        for _, task in ipairs(tasks) do
            if not task.cancelled then
                if task.once then task.cancelled = true end
                task.fn()
            end
        end
    end
end
local function ChildCount(widget)
    local count = 0; for _ in pairs(widget.children) do count = count + 1 end; return count
end
local passed = 0
local function test(name, fn)
    fn(); passed = passed + 1; print("AUTOCOOK_UI_PASS " .. name)
end

test("one quantity field below the unchanged native Cook button", function()
    local pot, doer, widget, row = Open(6)
    assert(widget.button.original_style and widget.button.value == "烹饪")
    assert(ChildCount(widget) == 2 and ChildCount(row) == 4)
    assert(row.x == 12 and row.y < -100)
    assert(row.label:GetString() == "数量" and row.hint:GetString() == "含本锅；0=连续")
    assert(row.batch:GetString() == "6" and row.batch.limit == 4 and row.batch.characters == "0123456789")
    assert(#tasks == 0 and #sent == 0)
end)

test("Cook sends the current quantity in the same RPC without an extra action", function()
    for _, value in ipairs({"1", "0", "9999", "007"}) do
        local pot, doer, widget, row = Open(2)
        row.batch:SetEditing(true)
        row.batch:SetString(value)
        widget.button.onclick()
        assert(#sent == 1 and sent[1].pot == pot and sent[1].command == "cook")
        assert(sent[1].batch == tonumber(value) and not row.batch.editing and not row.batch.force_active)
        assert(pot.native_calls == 0)
    end
end)

test("Enter and focus loss save a preference without starting a cook", function()
    local pot, doer, widget, row = Open(1)
    row.batch:SetEditing(true)
    row.batch:SetString("8")
    row.batch.OnTextEntered()
    assert(#sent == 1 and sent[1].command == "setbatch" and sent[1].batch == 8)
    row.batch:OnLoseFocus()
    assert(#sent == 1 and not row.batch.editing)
    row.batch:SetEditing(true)
    row.batch:SetString("12")
    row.batch:OnLoseFocus()
    assert(#sent == 2 and sent[2].command == "setbatch" and sent[2].batch == 12)
    widget.button.onclick()
    assert(#sent == 3 and sent[3].command == "cook" and sent[3].batch == 12)
end)

test("invalid numbers never send either command", function()
    local pot, doer, widget, row = Open(1)
    for _, value in ipairs({"", "-1", "1.5", "10000", "00000", "1e2", " 2", "abc"}) do
        row.batch:SetString(value)
        row.batch.OnTextEntered()
        row.batch:OnLoseFocus()
        widget.button.onclick()
    end
    assert(#sent == 0 and pot.native_calls == 0)
end)

test("native validity busy and disabled-control checks still govern Cook", function()
    local pot, doer, widget, row = Open(1)
    pot.can_cook = false; widget.button.onclick(); assert(#sent == 0)
    pot.can_cook = true; doer.tags.busy = true; widget.button.onclick(); assert(#sent == 0)
    doer.tags.busy = nil
    doer.components.playercontroller.IsEnabled = function() return false, false end
    widget.button.onclick(); assert(#sent == 0)
    doer.components.playercontroller.IsEnabled = function() return false, true end
    widget.button.onclick(); assert(#sent == 1 and sent[1].command == "cook")
end)

test("read-only access cannot edit or send even after access changes", function()
    local pot, doer, widget = Fixture(1)
    pot.readonly = true; widget:Open(pot, doer)
    local row = widget._nac_quantity
    assert(not row.batch.enabled)
    row.batch:SetEditing(true); assert(not row.batch.editing)
    row.batch:SetString("5"); row.batch.OnTextEntered(); widget.button.onclick(); assert(#sent == 0)
    pot.readonly = false; widget:Refresh(); assert(row.batch.enabled)
    row.batch:SetEditing(true); assert(row.batch.editing)
    pot.readonly = true; widget:Refresh()
    assert(not row.batch.enabled and not row.batch.editing and not row.batch.force_active)
    row.batch:OnLoseFocus(); widget.button.onclick(); assert(#sent == 0)
end)

test("delayed controller state initializes once including zero", function()
    local pot, doer, widget, row = Open()
    assert(row.batch:GetString() == "1" and row._nac_sync_task ~= nil)
    local task = row._nac_sync_task
    Tick(); assert(row.batch:GetString() == "1")
    SetState(pot, 0); Tick()
    assert(row.batch:GetString() == "0" and task.cancelled and row._nac_sync_task == nil)
    SetState(pot, 88); Tick(); assert(row.batch:GetString() == "0")
end)

test("late state never overwrites input and malformed state is tolerated", function()
    local pot, doer, widget, row = Open()
    local task = row._nac_sync_task
    row.batch:SetEditing(true); row.batch:SetString("21")
    SetState(pot, 99); Tick()
    assert(row.batch:GetString() == "21" and task.cancelled)
    pot, doer, widget, row = Open()
    SetState(pot, 3); pot.wire = "invalid JSON"; Tick()
    assert(row.batch:GetString() == "1")
    for _, invalid in ipairs({-1, 10000, 1.5, "8"}) do
        SetState(pot, invalid); Tick(); assert(row.batch:GetString() == "1")
    end
    SetState(pot, 9); Tick(); assert(row.batch:GetString() == "9")
end)

test("controller discovery polling is bounded", function()
    local pot, doer, widget, row = Open()
    local task = row._nac_sync_task
    Tick(25)
    assert(task.cancelled and row._nac_sync_task == nil and row.batch:GetString() == "1")
end)

test("unsupported pots retain native clicks while controllers enable custom pots", function()
    local pot, doer, widget = Fixture()
    pot.prefab = "unsupported_stewer"; widget:Open(pot, doer)
    assert(widget._nac_quantity == nil)
    widget.button.onclick(); assert(pot.native_calls == 1 and #sent == 0)
    SetState(pot, 4); pot.tags.stewer = nil; widget:Open(pot, doer)
    assert(widget._nac_quantity.batch:GetString() == "4")
    widget.button.onclick(); assert(sent[1].command == "cook")
    widget:Close(); pot.widget.buttoninfo = nil; widget:Open(pot, doer)
    assert(widget._nac_quantity == nil)
end)

test("close reopen and destruction release children tasks and text input", function()
    local pot, doer, widget, first = Open()
    local task = first._nac_sync_task
    widget:Open(pot, doer)
    assert(first.killed and task.cancelled and widget._nac_quantity ~= first and ChildCount(widget) == 2)
    local row = widget._nac_quantity
    row.batch:SetEditing(true); row.batch:SetString("9")
    local click = widget.button.onclick
    widget:Close()
    assert(row.killed and not row.batch.force_active and widget._nac_quantity == nil and ChildCount(widget) == 0)
    row.batch:OnLoseFocus(); click(); assert(#sent == 0)
    widget:Open(pot, doer)
    row = widget._nac_quantity; task = row._nac_sync_task
    widget:Kill()
    assert(row.killed and task.cancelled and widget._nac_quantity == nil)
end)

test("distant dead and removed entities cannot send stale requests", function()
    for _, cause in ipairs({"distance", "ghost", "removed", "player_removed"}) do
        local pot, doer, widget, row = Open(1)
        if cause == "distance" then pot.distsq = 37
        elseif cause == "ghost" then doer.tags.playerghost = true
        elseif cause == "removed" then pot.valid = false
        else doer.valid = false end
        row.batch:SetString("7"); row.batch.OnTextEntered(); widget.button.onclick()
        assert(#sent == 0)
    end
end)

test("dedicated server installs no UI hooks", function()
    dedicated = true
    Install({GLOBAL=_G, AddClassPostConstruct=function() error("unexpected UI hook") end})
    dedicated = false
end)

test("native quantity field shows remaining quantity instead of original batch", function()
    local pot, doer, widget = Fixture(30)
    pot.wire = json.encode({batch=30, quantity=7, canmanage=true})
    widget:Open(pot, doer)
    assert(widget._nac_quantity.batch:GetString() == "7")
end)

-- Exercise the real management screen with a closed, actively cooking pot.
CONTROL_CANCEL, MOVE_DOWN, MOVE_UP = 1, 2, 3
local Screen = Class(Widget, function(self, name) Widget._ctor(self, name) end)
package.loaded["widgets/screen"] = Screen
package.loaded["widgets/redux/templates"] = {
    BackgroundTint=function() return Widget("tint") end,
    ScreenRoot=function() return Widget("root") end,
    CurlyWindow=function(width, height, title, buttons)
        local window = Widget("window")
        window.buttons = buttons
        window.actions = window:AddChild(Widget("actions"))
        return window
    end,
}
local panels = {}
TheFrontEnd = {
    PushScreen=function(_, screen) panels[#panels+1] = screen end,
    PopScreen=function(_, screen)
        for i=#panels,1,-1 do if panels[i] == screen then table.remove(panels,i) end end
        screen:Kill()
    end,
}
local ManageScreen = require("screens/nac_manage")
local function Manage(quantity)
    sent, tasks, panels = {}, {}, {}
    local pot, player = Entity(), Entity()
    pot.closed, pot.cooking = true, true
    pot.state = {canmanage=true, batch=50, quantity=quantity or 6, status="正在烹饪"}
    ThePlayer = player
    local screen = ManageScreen(pot, function(command, batch)
        sent[#sent+1] = {pot=pot, command=command, batch=batch}; return true
    end, function(target) return target.state end, function(target, doer)
        return target.valid and doer.valid and not doer:HasTag("playerghost")
            and target.distsq <= 36 and target.state.canmanage
    end)
    player._nac_manage_screen = screen
    TheFrontEnd:PushScreen(screen)
    return pot, player, screen
end

test("closed cooking pot has a minimal remaining-quantity manager", function()
    local pot, player, screen = Manage(4)
    assert(pot.closed and pot.cooking and screen.batch:GetString() == "4")
    assert(#screen.window.buttons == 2)
    assert(screen.window.buttons[1].text == "取消配方" and screen.window.buttons[2].text == "关闭")
    assert(#sent == 0)
    screen.batch:SetEditing(true); screen.batch:SetString("3")
    screen.batch.OnTextEntered()
    assert(#sent == 1 and sent[1].command == "setbatch" and sent[1].batch == 3)
end)

test("manager accepts continuous zero and rejects malformed quantities", function()
    local pot, player, screen = Manage()
    for _, value in ipairs({"", "-1", "1.5", "10000", "0x10", "1e2", " 3"}) do
        screen.batch:SetString(value); screen.batch.OnTextEntered()
    end
    assert(#sent == 0)
    screen.batch:SetString("0"); screen.batch.OnTextEntered()
    assert(#sent == 1 and sent[1].batch == 0)
end)

test("manager synchronizes remaining count without replacing typed input", function()
    local pot, player, screen = Manage(8)
    pot.state.quantity = 7; screen:OnUpdate(.2)
    assert(screen.batch:GetString() == "7")
    screen.batch:SetEditing(true); screen.batch:SetString("21")
    pot.state.quantity = 6; screen:OnUpdate(.2)
    assert(screen.batch:GetString() == "21")
    screen.batch:OnLoseFocus(); screen:OnUpdate(.2)
    assert(screen.batch:GetString() == "21" and #sent == 0)
    Tick(); assert(#sent == 1 and sent[1].batch == 21)
    screen:OnUpdate(.2); assert(screen.batch:GetString() == "21")
    pot.state.quantity = 21; screen:OnUpdate(.2)
    assert(screen._pending_quantity == nil and screen.batch:GetString() == "21")
end)

test("entering the displayed count still reapplies it after progress during editing", function()
    local pot, player, screen = Manage(8)
    screen.batch:SetEditing(true)
    pot.state.quantity=7; screen:OnUpdate(.2)
    assert(screen.batch:GetString() == "8")
    screen.batch.OnTextEntered()
    assert(#sent == 1 and sent[1].command == "setbatch" and sent[1].batch == 8)
    screen.batch:OnLoseFocus(); Tick()
    assert(#sent == 1)
end)

test("cancel button suppresses pending focus-save and clears only future recipe", function()
    local pot, player, screen = Manage()
    screen.batch:SetEditing(true); screen.batch:SetString("55")
    screen.batch:OnLoseFocus()
    screen.window.buttons[1].cb(); Tick()
    assert(#sent == 1 and sent[1].command == "cancel" and sent[1].batch == nil)
    assert(screen._closed and screen.killed and player._nac_manage_screen == nil)
    assert(not screen.batch.force_active and #panels == 0)
    screen.batch.OnTextEntered(); screen.batch:OnLoseFocus(); Tick()
    assert(#sent == 1)
end)

test("manager Escape close and destruction never save an unfinished edit", function()
    for _, close in ipairs({
        function(screen) screen:OnControl(CONTROL_CANCEL, false) end,
        function(screen) screen.window.buttons[2].cb() end,
        function(screen) screen:Kill() end,
    }) do
        local pot, player, screen = Manage()
        screen.batch:SetEditing(true); screen.batch:SetString("34")
        screen.batch:OnLoseFocus(); close(screen); Tick()
        assert(screen._closed and not screen.batch.force_active and #sent == 0)
        assert(player._nac_manage_screen == nil)
    end
end)

test("manager closes after distance death removal or task completion", function()
    for _, cause in ipairs({"distance", "ghost", "removed", "player_removed", "finished"}) do
        local pot, player, screen = Manage()
        screen.batch:SetEditing(true); screen.batch:SetString("19")
        if cause == "distance" then pot.distsq = 37
        elseif cause == "ghost" then player.tags.playerghost = true
        elseif cause == "removed" then pot.valid = false
        elseif cause == "player_removed" then player.valid = false
        else pot.state.canmanage = false end
        screen:OnUpdate(.1); Tick()
        assert(screen._closed and #sent == 0 and not screen.batch.force_active)
    end
end)

-- Actual scene registration and server/client handoff, with game networking mocked.
local action, collector, clienthandler, handlers, opened, allowed
local clientrpc = {}
TheWorld = {ismastersim=true}
ActionHandler = function(act, state) return {action=act, state=state} end
local actionenv = {
    GLOBAL=_G,
    AddAction=function(id, text, fn) action={id=id, text=text, fn=fn}; return action end,
    AddComponentAction=function(kind, component, fn)
        assert(kind == "SCENE" and component == "nearbyautocook"); collector = fn
    end,
    AddClientModRPCHandler=function(namespace, name, fn)
        assert(namespace == "nearby_autocook" and name == "openmanage"); clienthandler=fn
    end,
    AddStategraphActionHandler=function(name, handler) handlers[name]=handler end,
    GetClientModRPC=function(namespace, name)
        assert(namespace == "nearby_autocook" and name == "openmanage"); return clientrpc
    end,
    SendModRPCToClient=function(id, userid, pot)
        assert(id == clientrpc); opened[#opened+1]={userid=userid,pot=pot}
    end,
    GetModRPC=env.GetModRPC,
    SendModRPCToServer=env.SendModRPCToServer,
}
handlers, opened, allowed = {}, {}, true
require("nac_actions")(actionenv, function(player, pot) return allowed end)
local function ActionFixture()
    local pot, player, widget = Fixture(20)
    pot.wire = json.encode({batch=20,quantity=4,canmanage=true,status="正在烹饪"})
    pot.replica.container.CanBeOpened = function() return false end
    pot.replica.container.IsOpenedBy = function() return false end
    player.userid = "KU_test"
    ThePlayer = player
    return pot, player
end

test("right click action works during closed cooking without hijacking left harvest", function()
    local pot, player = ActionFixture()
    local harvest = {}
    local left = {harvest}; collector(pot, player, left, false)
    assert(#left == 1 and left[1] == harvest)
    local right = {harvest}; collector(pot, player, right, true)
    assert(#right == 2 and right[2] == action)
    assert(action.id == "NAC_MANAGE" and action.priority == 2 and action.distance == 3)
    assert(action.rmb and not action.instant and action.invalid_hold_action)
    assert(handlers.wilson.state == "doshortaction" and handlers.wilson_client.state == "doshortaction")
    assert(action.fn({doer=player,target=pot}) and opened[#opened].pot == pot)
    allowed=false; assert(not action.fn({doer=player,target=pot})); allowed=true
end)

test("inactive inaccessible and unsupported pots do not offer management", function()
    for _, cause in ipairs({"inactive", "readonly", "burnt", "ghost", "role", "unsynced"}) do
        local pot, player = ActionFixture()
        if cause == "inactive" then pot.wire = json.encode({canmanage=false})
        elseif cause == "readonly" then pot.readonly=true
        elseif cause == "burnt" then pot.tags.burnt=true
        elseif cause == "ghost" then player.tags.playerghost=true
        elseif cause == "role" then pot.tags.mastercookware=true
        else pot._nac_controller=nil end
        local actions={}; collector(pot, player, actions, true); assert(#actions == 0)
    end
end)

test("server scene action reads authoritative component before controller binding", function()
    local pot, player = ActionFixture()
    local state = {canmanage=true,quantity=3}
    pot.components = {nearbyautocook={GetState=function() return state end}}
    pot._nac_controller = nil
    local actions={}; collector(pot, player, actions, true)
    assert(#actions == 1 and actions[1] == action)
    SetState(pot, 30)
    pot.wire = json.encode({canmanage=false,quantity=30})
    actions={}; collector(pot, player, actions, true)
    assert(#actions == 1 and actions[1] == action)
    state.canmanage=false
    pot.wire = json.encode({canmanage=true,quantity=30})
    actions={}; collector(pot, player, actions, true); assert(#actions == 0)
    TheWorld.ismastersim=false
    actions={}; collector(pot, player, actions, true)
    assert(#actions == 1 and actions[1] == action)
    TheWorld.ismastersim=true
end)

test("client open RPC reaches real panel and sends current manager commands", function()
    panels={}
    local pot, player = ActionFixture()
    clienthandler(pot)
    local screen = player._nac_manage_screen
    assert(screen and #panels == 1 and screen.batch:GetString() == "4")
    clienthandler(pot); assert(#panels == 1)
    screen.batch:SetString("2"); screen.batch.OnTextEntered()
    assert(#sent == 1 and sent[1].command == "setbatch" and sent[1].batch == 2)
    screen:CancelRecipe(); assert(#sent == 2 and sent[2].command == "cancel")
    assert(#panels == 0 and player._nac_manage_screen == nil)
    pot.distsq=37; clienthandler(pot); assert(#panels == 0)
    pot.distsq=9; dedicated=true; clienthandler(pot); assert(#panels == 0); dedicated=false
end)
print("AUTOCOOK_UI_SUCCESS " .. passed)
