local M = {}
local visuals = {}

local function ReadAnim(anim, method)
    local fn = anim ~= nil and anim[method] or nil
    if fn ~= nil then
        local ok, value = pcall(fn, anim)
        if ok and value ~= nil and value ~= 0 then
            return value
        end
    end
end

local function RecipeVisual(prefab)
    local cooking = require("cooking")
    for _, recipes in pairs(cooking.recipes) do
        local recipe = recipes[prefab]
        if recipe ~= nil then
            return {
                bank = "cook_pot_food",
                build = recipe.overridebuild or "cook_pot_food",
                anim = "idle",
                override = { "swap_food", recipe.overridebuild or "cook_pot_food", recipe.basename or recipe.name or prefab },
            }
        end
    end
end

function M.Capture(item)
    if type(item) == "table" and item.bank ~= nil and item.build ~= nil and item.anim ~= nil then
        return item
    end
    local prefab = type(item) == "string" and item or item ~= nil and item.prefab or nil
    if type(item) ~= "string" and item ~= nil and item:IsValid() and item.AnimState ~= nil then
        local data = {
            bank = ReadAnim(item.AnimState, "GetBankHash"),
            build = ReadAnim(item.AnimState, "GetBuild"),
            anim = ReadAnim(item.AnimState, "GetCurrentAnimationHash") or item.scrapbook_anim or "idle",
        }
        -- Prepared foods share a bank; their actual meal is a swapped symbol.
        local override = item.scrapbook_overridedata
        if type(override) == "table" and override[1] ~= nil and override[2] ~= nil and override[3] ~= nil
            and type(override[1]) ~= "table" then
            data.override = { override[1], override[2], override[3] }
        end
        if item:HasTag("spicedfood") and prefab ~= nil then
            data.garnish = prefab:match("_(spice_%w+)$")
        end
        if data.bank ~= nil and data.build ~= nil then
            if prefab ~= nil then visuals[prefab] = data end
            return data
        end
    end
    if prefab ~= nil then
        if visuals[prefab] ~= nil then return visuals[prefab] end
        local recipe = RecipeVisual(prefab)
        if recipe ~= nil then return recipe end
        -- Entity callers supply exact metadata. A name-only caller can use common
        -- ingredient banks without creating a second, functional inventory item.
        local base = prefab:match("^(.-)_cooked$")
        return { bank = base or prefab, build = base or prefab, anim = base ~= nil and "cooked" or "idle" }
    end
    return { bank = "carrot", build = "carrot", anim = "idle" }
end

function M.Play(item_or_prefab, frompos, topos)
    if TheWorld == nil or not TheWorld.ismastersim or frompos == nil or topos == nil then
        return nil
    end
    local fx = SpawnPrefab("nac_transfer_fx")
    if fx == nil then return nil end
    local ok = pcall(function()
        fx:Setup(M.Capture(item_or_prefab), frompos, topos)
    end)
    if not ok then
        fx:Remove()
        return nil
    end
    return fx
end

return M
