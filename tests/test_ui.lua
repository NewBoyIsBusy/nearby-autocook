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
    "SetFocusedImage", "ScaleToSize" }) do Widget[method] = function() end end
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
        for _, task in ipairs(tasks) do if not task.cancelled then task.fn() end end
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
print("AUTOCOOK_UI_SUCCESS " .. passed)
