-- ==============================================================================
-- GalaxyTrader MK3 - Pilot Control Bridge
-- ==============================================================================
-- Purpose: Handle MD-Lua communication for pilot control actions
-- This module sends control commands from the UI to the MD scripts
-- ==============================================================================

local Mods = Mods or {}
Mods.GalaxyTrader = Mods.GalaxyTrader or {}
Mods.GalaxyTrader.PilotControl = Mods.GalaxyTrader.PilotControl or {}

-- Debug logging
local function debugLog(message)
    DebugError("[GT Pilot Control] " .. tostring(message))
end

-- ==============================================================================
-- ACTION SENDERS (UI MD)
-- ==============================================================================

-- Send ship to training
function Mods.GalaxyTrader.PilotControl.sendToTraining(shipId)
    debugLog("Sending ship to training: " .. tostring(shipId))
    
    -- Send training request to MD (shipId in param3)
    AddUITriggeredEvent("GT_PilotControl", "Training", tostring(shipId))
    
    debugLog("Training signal sent for ship: " .. tostring(shipId))
end

-- Deregister ship from GalaxyTrader system
function Mods.GalaxyTrader.PilotControl.deregisterShip(shipId)
    debugLog("Deregistering ship: " .. tostring(shipId))
    
    -- Send signal to MD
    local param = "deregister|" .. tostring(shipId)
    AddUITriggeredEvent("GT_PilotControl", "Action", param)
    
    debugLog("Deregister signal sent for ship: " .. tostring(shipId))
end

-- Force sell cargo
function Mods.GalaxyTrader.PilotControl.forceSellCargo(shipId)
    debugLog("Forcing cargo sale for ship: " .. tostring(shipId))
    
    -- Send signal to MD
    local param = "sellcargo|" .. tostring(shipId)
    AddUITriggeredEvent("GT_PilotControl", "Action", param)
    
    debugLog("Force sell cargo signal sent for ship: " .. tostring(shipId))
end

-- Send ship to repair
function Mods.GalaxyTrader.PilotControl.sendToRepair(shipId)
    debugLog("Sending ship to repair: " .. tostring(shipId))
    
    -- Send signal to MD
    local param = "repair|" .. tostring(shipId)
    AddUITriggeredEvent("GT_PilotControl", "Action", param)
    
    debugLog("Repair signal sent for ship: " .. tostring(shipId))
end

-- Send ship to resupply
function Mods.GalaxyTrader.PilotControl.sendToResupply(shipId)
    debugLog("Sending ship to resupply: " .. tostring(shipId))
    
    -- Send signal to MD
    local param = "resupply|" .. tostring(shipId)
    AddUITriggeredEvent("GT_PilotControl", "Action", param)
    
    debugLog("Resupply signal sent for ship: " .. tostring(shipId))
end

-- Stop all orders for ship
function Mods.GalaxyTrader.PilotControl.stopAllOrders(shipId)
    debugLog("Stopping all orders for ship: " .. tostring(shipId))
    
    -- Send signal to MD
    local param = "stoporders|" .. tostring(shipId)
    AddUITriggeredEvent("GT_PilotControl", "Action", param)
    
    debugLog("Stop orders signal sent for ship: " .. tostring(shipId))
end

-- ==============================================================================
-- CONFIRMATION HANDLERS (MD Lua)
-- ==============================================================================

-- Handle action confirmation from MD
local function onActionConfirmation(_, param)
    debugLog("Action confirmation received: " .. tostring(param))
    
    -- Parse confirmation message
    -- Format: "action|shipId|status|message"
    local parts = {}
    for part in string.gmatch(param .. "|", "(.-)|") do
        if part ~= "" then
            table.insert(parts, part)
        end
    end
    
    if #parts >= 4 then
        local action = parts[1]
        local shipId = parts[2]
        local status = parts[3]
        local message = parts[4]
        
        debugLog(string.format("Action '%s' for ship '%s': %s - %s", action, shipId, status, message))
        
        -- TODO: Show in-game notification to user
        -- TODO: Refresh pilot overview UI if needed
        
        -- Trigger UI refresh if info menu is open
        if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.InfoMenu and Mods.GalaxyTrader.InfoMenu.onDataUpdate then
            debugLog("Triggering UI refresh after action confirmation")
            Mods.GalaxyTrader.InfoMenu.onDataUpdate()
        end
    else
        debugLog("WARNING: Invalid action confirmation format - expected 4 parts, got " .. #parts)
    end
end

-- ==============================================================================
-- INITIALIZATION
-- ==============================================================================

local function init()
    debugLog("Initializing GalaxyTrader Pilot Control Bridge")
    
    -- Register event listener for action confirmations from MD
    RegisterEvent("GT_PilotControl.Confirmation", onActionConfirmation)
    
    debugLog("Pilot Control Bridge initialized - listening for action confirmations")
end

init()

