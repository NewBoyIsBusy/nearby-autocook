local Screen = require("widgets/screen")
local Image = require("widgets/image")
local Text = require("widgets/text")
local TextEdit = require("widgets/textedit")
local TEMPLATES = require("widgets/redux/templates")

local function ReadQuantity(value)
    if type(value) ~= "string" or #value > 4 or not value:match("^%d+$") then return nil end
    local quantity = tonumber(value)
    return quantity ~= nil and quantity >= 0 and quantity <= 9999 and quantity or nil
end

local ManageScreen = Class(Screen, function(self, pot, send, readstate, canmanage)
    Screen._ctor(self, "NearbyAutocookManage")
    self.pot, self.player = pot, ThePlayer
    self.send, self.readstate, self.canmanage = send, readstate, canmanage
    self.black = self:AddChild(TEMPLATES.BackgroundTint(.65))
    self.root = self:AddChild(TEMPLATES.ScreenRoot())
    self.window = self.root:AddChild(TEMPLATES.CurlyWindow(520, 250, "调整烹饪", {
        {text="取消配方", cb=function() self:CancelRecipe() end},
        {text="关闭", cb=function() self:Close() end},
    }, 250))
    self.label = self.window:AddChild(Text(UIFONT, 28, "剩余锅数"))
    self.label:SetPosition(-100, 55)
    self.background = self.window:AddChild(Image("images/global_redux.xml", "textbox3_gold_normal.tex"))
    self.background:SetPosition(65, 55)
    self.background:ScaleToSize(120, 42)
    self.batch = self.window:AddChild(TextEdit(UIFONT, 29, "1"))
    self.batch:SetPosition(65, 55)
    self.batch:SetRegionSize(105, 40)
    self.batch:SetTextLengthLimit(4)
    self.batch:SetCharacterFilter("0123456789")
    self.batch:SetForceEdit(true)
    self.batch:SetPassControlToScreen(CONTROL_CANCEL, true)
    self.batch:SetIdleTextColour(.12, .12, .12, 1)
    self.batch:SetEditTextColour(.12, .12, .12, 1)
    self.batch:SetFocusedImage(self.background, "images/global_redux.xml",
        "textbox3_gold_normal.tex", "textbox3_gold_hover.tex", "textbox3_gold_focus.tex")
    self.hint = self.window:AddChild(Text(UIFONT, 24, "含当前锅；0=连续；回车或移开焦点生效"))
    self.hint:SetPosition(0, 5)
    self.notice = self.window:AddChild(Text(UIFONT, 23, "取消后，当前锅仍会煮完并收存。"))
    self.notice:SetPosition(0, -33)
    self.status = self.window:AddChild(Text(UIFONT, 23, ""))
    self.status:SetPosition(0, -68)
    self.status:SetRegionSize(480, 30)

    self.batch.OnTextEntered = function()
        self.batch:SetEditing(false)
        self:SaveQuantity()
    end
    local losefocus = self.batch.OnLoseFocus
    self.batch.OnLoseFocus = function(edit, ...)
        edit:SetEditing(false)
        losefocus(edit, ...)
        if self._closed then return end
        -- Focus changes before button callbacks. Defer until those callbacks
        -- can close/cancel the screen and suppress an unintended quantity save.
        self:CancelFocusSave()
        self._focus_save = self.inst:DoTaskInTime(0, function()
            self._focus_save = nil
            if not self._closed then self:SaveQuantity() end
        end)
    end
    self.default_focus = self.batch
    self.batch:SetFocusChangeDir(MOVE_DOWN, self.window.actions)
    self.window.actions:SetFocusChangeDir(MOVE_UP, self.batch)
    self:RefreshState(0)
end)

function ManageScreen:CancelFocusSave()
    if self._focus_save ~= nil then self._focus_save:Cancel(); self._focus_save = nil end
end

function ManageScreen:SaveQuantity()
    if self._closed or not self.canmanage(self.pot, self.player) then return false end
    local quantity = ReadQuantity(self.batch:GetString())
    if quantity == nil then
        self.status:SetString("请输入 0 到 9999 的整数")
        return false
    end
    local state = self.readstate(self.pot)
    if quantity ~= self._saved_quantity or (self._pending_quantity == nil
        and state ~= nil and quantity ~= state.quantity) then
        if not self.send("setbatch", quantity) then return false end
        self._saved_quantity = quantity
        self._pending_quantity, self._pending_age = quantity, 0
        self.status:SetString("已提交数量")
    end
    return true
end

function ManageScreen:CancelRecipe()
    if self._closed then return end
    -- Close and invalidate focus callbacks before sending cancellation.
    local canmanage = self.canmanage(self.pot, self.player)
    self:Close()
    if canmanage then self.send("cancel") end
end

function ManageScreen:RefreshState(dt)
    local state = self.readstate(self.pot)
    if state == nil then return end
    local quantity = state.quantity
    if type(quantity) ~= "number" or quantity < 0 or quantity > 9999 or quantity ~= math.floor(quantity) then return end
    if self._pending_quantity ~= nil then
        self._pending_age = self._pending_age + (dt or 0)
        if quantity == self._pending_quantity or self._pending_age >= 2 then self._pending_quantity = nil end
    end
    if not self.batch.editing and self._focus_save == nil and self._pending_quantity == nil then
        self.batch:SetString(tostring(quantity))
        self._saved_quantity = quantity
    end
    if self._pending_quantity == nil then self.status:SetString(state.status or "") end
end

function ManageScreen:OnUpdate(dt)
    if self._closed then return end
    if not self.canmanage(self.pot, self.player) then self:Close(); return end
    self:RefreshState(dt)
end

function ManageScreen:Close()
    if self._closed then return end
    self._closed = true
    self:CancelFocusSave()
    self.batch:SetEditing(false)
    TheFrontEnd:PopScreen(self)
end

function ManageScreen:Kill()
    self._closed = true
    self:CancelFocusSave()
    if self.batch ~= nil then self.batch:SetEditing(false) end
    if self.player ~= nil and self.player._nac_manage_screen == self then self.player._nac_manage_screen = nil end
    ManageScreen._base.Kill(self)
end

function ManageScreen:OnControl(control, down)
    if control == CONTROL_CANCEL and not down then self:Close(); return true end
    return ManageScreen._base.OnControl(self, control, down)
end

return ManageScreen
