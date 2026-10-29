-- Add only a quantity field to the existing cooking container. The original
-- Cook button remains responsible for deciding whether the pot can be cooked.
return function(env)
    local G = env.GLOBAL or _G
    if G.TheNet:IsDedicated() then
        return
    end

    local Widget = require("widgets/widget")
    local Image = require("widgets/image")
    local Text = require("widgets/text")
    local TextEdit = require("widgets/textedit")
    local cooking = require("cooking")
    local json = require("json")

    local function IsCookingBuilding(pot)
        if pot == nil or not pot:IsValid() then return false end
        local controller = pot._nac_controller
        return (controller ~= nil and controller:IsValid())
            or (pot:HasTag("stewer") and cooking.recipes[pot.prefab] ~= nil)
    end

    local function ReadBatch(value)
        if type(value) ~= "string" or #value > 4 or not value:match("^%d+$") then return nil end
        local batch = tonumber(value)
        return batch ~= nil and batch >= 0 and batch <= 9999 and batch or nil
    end

    local function SyncedBatch(pot)
        local controller = pot._nac_controller
        if controller == nil or not controller:IsValid() or controller._state == nil then return nil end
        local raw = controller._state:value()
        if type(raw) ~= "string" or raw == "" then return nil end
        local ok, state = pcall(json.decode, raw)
        if not ok or type(state) ~= "table" then return nil end
        local quantity = state.quantity ~= nil and state.quantity or state.batch
        if type(quantity) ~= "number"
            or quantity < 0 or quantity > 9999 or quantity ~= math.floor(quantity) then
            return nil
        end
        return quantity
    end

    local function IsReadOnly(pot)
        local container = pot.replica and pot.replica.container
        return container == nil
            or (container.IsReadOnlyContainer ~= nil and container:IsReadOnlyContainer())
    end

    local function StopSync(row)
        if row._nac_sync_task ~= nil then
            row._nac_sync_task:Cancel()
            row._nac_sync_task = nil
        end
    end

    local function Cleanup(widget)
        local row = widget._nac_quantity
        if row ~= nil then
            -- Invalidate callbacks before releasing text focus or destroying children.
            widget._nac_quantity = nil
            StopSync(row)
            row.batch:SetEditing(false)
            row:Kill()
        end
    end

    env.AddClassPostConstruct("widgets/containerwidget", function(self)
        local oldopen, oldclose, oldkill, oldrefresh = self.Open, self.Close, self.Kill, self.Refresh
        self.Close = function(widget, ...)
            Cleanup(widget)
            return oldclose(widget, ...)
        end
        self.Kill = function(widget, ...)
            Cleanup(widget)
            return oldkill(widget, ...)
        end
        self.Refresh = function(widget, ...)
            local result = oldrefresh(widget, ...)
            local row = widget._nac_quantity
            if row ~= nil then
                if IsReadOnly(widget.container) then row.batch:Disable() else row.batch:Enable() end
            end
            return result
        end
        self.Open = function(widget, pot, doer, ...)
            oldopen(widget, pot, doer, ...)
            if not IsCookingBuilding(pot) or widget.button == nil then return end
            local info = pot.replica.container:GetWidget()
            local buttoninfo = info and info.buttoninfo
            if buttoninfo == nil or buttoninfo.fn == nil then return end

            local row = widget:AddChild(Widget("nearby_autocook_quantity"))
            widget._nac_quantity = row
            local position = buttoninfo.position
            row:SetPosition(position and position.x or 0, (position and position.y or 0) - 55)
            row.label = row:AddChild(Text(G.UIFONT, 25, "数量"))
            row.label:SetPosition(-65, 0)
            row.background = row:AddChild(Image("images/global_redux.xml", "textbox3_gold_normal.tex"))
            row.background:SetPosition(20, 0)
            row.background:ScaleToSize(94, 40)
            row.batch = row:AddChild(TextEdit(G.UIFONT, 27, "1"))
            row.batch:SetPosition(20, 0)
            row.batch:SetRegionSize(80, 38)
            row.batch:SetTextLengthLimit(4)
            row.batch:SetCharacterFilter("0123456789")
            row.batch:SetForceEdit(true)
            row.batch:SetIdleTextColour(.12, .12, .12, 1)
            row.batch:SetEditTextColour(.12, .12, .12, 1)
            row.batch:SetFocusedImage(row.background, "images/global_redux.xml",
                "textbox3_gold_normal.tex", "textbox3_gold_hover.tex", "textbox3_gold_focus.tex")
            row.hint = row:AddChild(Text(G.UIFONT, 21, "含本锅；0=连续"))
            row.hint:SetPosition(0, -34)

            local function CanSend()
                if widget._nac_quantity ~= row or not widget.isopen or not IsCookingBuilding(pot)
                    or IsReadOnly(pot) or doer == nil or not doer:IsValid()
                    or doer:HasTag("playerghost") or doer:HasTag("busy")
                    or doer:GetDistanceSqToInst(pot) > 36 then
                    return false
                end
                local playercontroller = doer.components and doer.components.playercontroller
                if playercontroller ~= nil then
                    local enabled, hudblocking = playercontroller:IsEnabled()
                    if not (enabled or hudblocking) then return false end
                end
                return true
            end

            local function Send(command, batch)
                if batch == nil or not CanSend() then return false end
                local rpc = env.GetModRPC and env.GetModRPC("nearby_autocook", "command")
                    or G.MOD_RPC and G.MOD_RPC.nearby_autocook and G.MOD_RPC.nearby_autocook.command
                local send = env.SendModRPCToServer or G.SendModRPCToServer
                if rpc == nil or send == nil then return false end
                send(rpc, pot, command, batch)
                row._nac_saved_batch = batch
                return true
            end

            local function SaveBatch()
                local batch = ReadBatch(row.batch:GetString())
                if batch ~= nil and batch ~= row._nac_saved_batch then Send("setbatch", batch) end
            end

            local setediting, losefocus = row.batch.SetEditing, row.batch.OnLoseFocus
            row.batch.SetEditing = function(edit, editing, ...)
                if editing then
                    if not CanSend() then return end
                    -- A late network packet must never replace a number being entered.
                    row._nac_touched = true
                    StopSync(row)
                end
                return setediting(edit, editing, ...)
            end
            row.batch.OnTextEntered = SaveBatch
            row.batch.OnLoseFocus = function(edit, ...)
                edit:SetEditing(false)
                losefocus(edit, ...)
                SaveBatch()
            end
            widget.button:SetOnClick(function()
                if not CanSend() then return end
                if buttoninfo.validfn ~= nil and not buttoninfo.validfn(pot) then return end
                local batch = ReadBatch(row.batch:GetString())
                if Send("cook", batch) then row.batch:SetEditing(false) end
            end)

            local function SyncBatch()
                if row._nac_touched or widget._nac_quantity ~= row or not pot:IsValid() then
                    StopSync(row)
                    return true
                end
                local batch = SyncedBatch(pot)
                if batch ~= nil then
                    row.batch:SetString(tostring(batch))
                    row._nac_saved_batch = batch
                    StopSync(row)
                    return true
                end
                return false
            end
            if not SyncBatch() then
                local attempts = 0
                row._nac_sync_task = widget.inst:DoPeriodicTask(.2, function()
                    attempts = attempts + 1
                    if not SyncBatch() and attempts >= 25 then StopSync(row) end
                end)
            end
            if IsReadOnly(pot) then row.batch:Disable() end
        end
    end)
end
