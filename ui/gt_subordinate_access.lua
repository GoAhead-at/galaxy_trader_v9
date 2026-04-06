-- GalaxyTrader — Station Subordinate Order Access (UI Unlock)
--
-- Problem: When a ship is assigned as a station subordinate, vanilla menu_map.lua
-- makes all order parameters read-only by checking `infoTableData[instance].commander`.
-- This prevents the player from editing GT order settings on station-assigned ships.
--
-- Solution: Hook displayOrderParam and displayDefaultBehaviour in MapMenu.
-- For GT orders only, temporarily set commander = nil during rendering so vanilla
-- treats the params as editable, then immediately restore the original value.
--
-- Scope: Only unlocks editing for GT orders (GalaxyTraderMK1, MK2, MK3, GalaxyMiner).
-- All other orders (vanilla, other mods) remain read-only when station-assigned.

-- GT order IDs that should have order access when station-assigned
local GT_OrderIDs = {
    ["GalaxyTraderMK1"] = true,
    ["GalaxyTraderMK2"] = true,
    ["GalaxyTraderMK3"] = true,
    ["GalaxyTraderMK4Supply"] = true,
    ["GalaxyMiner"] = true,
}

-- Find MapMenu
local menu = Helper.getMenu("MapMenu")
if not menu then
    DebugError("[GT Subordinate Access] MapMenu not found — subordinate order access will not be available")
    return
end

-- Store original functions
local orig_displayOrderParam = menu.displayOrderParam
local orig_displayDefaultBehaviour = menu.displayDefaultBehaviour

-- Helper: check if an order ID is a GT order
local function isGTOrder(orderID)
    return orderID ~= nil and GT_OrderIDs[orderID] == true
end

-- Hook: displayOrderParam
-- Vanilla check (menu_map.lua ~line 9764):
--   paramactive = (menu.infoTableData[instance].commander == nil) and (not isplayeroccupiedship)
-- By temporarily nulling commander for GT orders, we make paramactive = true.
--
-- NOTE: The order table uses .orderdef (string ID), NOT .id.
-- Structure: { state, statename, orderdef="GalaxyTraderMK3", actualparams, enabled, orderdefref }
function menu.displayOrderParam(ftable, orderidx, order, paramidx, param, listidx, instance)
    local commander = nil
    local didOverride = false

    -- Only unlock for GT orders (order.orderdef holds the order ID string)
    if order and isGTOrder(order.orderdef) then
        commander = menu.infoTableData[instance].commander
        menu.infoTableData[instance].commander = nil
        didOverride = true
    end

    -- Call original (vanilla renders params as editable since commander is nil)
    orig_displayOrderParam(ftable, orderidx, order, paramidx, param, listidx, instance)

    -- Always restore commander
    if didOverride then
        menu.infoTableData[instance].commander = commander
    end
end

-- Hook: displayDefaultBehaviour
-- Vanilla check (menu_map.lua ~line 11786):
--   behaviouractive = (infoTableData.commander == nil) and isvalid and (not isplayeroccupiedship) and haspilot
-- Same approach: null commander for GT default orders.
--
-- NOTE: The defaultorder table uses .orderdef (string ID), NOT .id.
function menu.displayDefaultBehaviour(ftable, mode, titlerow, instance)
    local commander = nil
    local didOverride = false

    -- Check if the default order is a GT order
    local infoTableData = menu.infoTableData[instance]
    if infoTableData then
        local defaultorder = infoTableData.defaultorder
        if defaultorder and isGTOrder(defaultorder.orderdef) then
            commander = infoTableData.commander
            infoTableData.commander = nil
            didOverride = true
        end
    end

    -- Call original (vanilla renders default behaviour selector as active)
    orig_displayDefaultBehaviour(ftable, mode, titlerow, instance)

    -- Always restore commander
    if didOverride then
        menu.infoTableData[instance].commander = commander
    end
end

DebugError("[GT Subordinate Access] MapMenu hooks installed — GT orders editable when station-assigned")
