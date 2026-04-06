-- GalaxyTrader MK3 Order Monitor
-- Batched order change detection (1 ship every 5 frames)

local L = {}

L.CHECK_INTERVAL = 5
L.frameCounter = 0
L.currentShipIndex = 0
L.shipList = {}
L.previousOrders = {}
L.previousPilots = {}
L.previousCommanders = {}
L.cleanupTriggered = {}
L.isMonitoring = false

-- FFI setup for order checking
local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    bool IsComponentClass(UniverseID componentid, const char* classname);
    const char* GetObjectIDCode(UniverseID objectid);
    uint64_t ConvertStringTo64Bit(const char* idcode);
    typedef struct {
        size_t queueidx;
        const char* state;
        const char* statename;
        const char* orderdef;
        size_t actualparams;
        bool enabled;
        bool isinfinite;
        bool issyncpointreached;
        bool istemporder;
    } Order;
    bool GetDefaultOrder(Order* result, UniverseID controllableid);
    uint32_t GetNumSubordinatesOfGroup(UniverseID commanderid, int group);
]]

function Init()
    RegisterEvent("GT_OrderMonitor.UpdateShipList", L.UpdateShipList)
    RegisterEvent("GT_OrderMonitor.Start", L.StartMonitoring)
    RegisterEvent("GT_OrderMonitor.Stop", L.StopMonitoring)
    SetScript("onUpdate", L.OnUpdate)
    AddUITriggeredEvent("GT_OrderMonitor", "Ready", {})
end

function onUpdate()
    L.OnUpdate()
end

function L.UpdateShipList(eventName, shipListString)
    if not shipListString or shipListString == "" then
        L.shipList = {}
        return
    end
    
    L.shipList = {}
    if type(shipListString) == "string" then
        for shipPair in string.gmatch(shipListString, "([^,]+)") do
            shipPair = shipPair:match("^%s*(.-)%s*$")
            if shipPair and shipPair ~= "" then
                local colonPos = string.find(shipPair, ":")
                local shipIDStr = colonPos and string.sub(shipPair, 1, colonPos - 1) or shipPair
                -- Fix: tonumber("0x1234", 16) returns nil - strip "0x" before calling with base, or use auto-detect
                local num
                if string.sub(shipIDStr, 1, 2) == "0x" then
                    -- Strip "0x" prefix before calling tonumber with base 16
                    num = tonumber(string.sub(shipIDStr, 3), 16)
                else
                    num = tonumber(shipIDStr)
                end
                if num and num ~= 0 then
                    table.insert(L.shipList, num)
                end
            end
        end
    end
    
    L.currentShipIndex = 0
    L.previousOrders = {}
    L.previousPilots = {}
    L.previousCommanders = {}
    L.cleanupTriggered = {}
    
    if not L.isMonitoring then
        L.isMonitoring = true
    end
    
    for _, ship in ipairs(L.shipList) do
        local orderBuf = ffi.new("Order")
        if C.GetDefaultOrder(orderBuf, ship) and orderBuf.orderdef then
            -- Check for NULL pointer before calling ffi.string (prevents crash)
            local orderdef_ptr = orderBuf.orderdef
            L.previousOrders[ship] = (orderdef_ptr ~= nil) and ffi.string(orderdef_ptr) or "NONE"
        else
            L.previousOrders[ship] = "NONE"
        end
        
        local pilot = GetComponentData(ship, "assignedpilot")
        L.previousPilots[ship] = pilot and tostring(pilot) or "NONE"
        
        -- Some UniverseIDs can exist in the list but not be "controllable" (e.g. stale IDs / non-ship components).
        -- Calling GetCommander() on those throws engine errors, so guard it like vanilla UI code does elsewhere.
        local commander = nil
        if C.IsComponentClass(ship, "controllable") then
            commander = GetCommander(ship)
        end
        if commander then
            local commanderNum = ConvertIDTo64Bit(commander)
            L.previousCommanders[ship] = (commanderNum and commanderNum ~= 0) and tostring(commanderNum) or "NONE"
        else
            L.previousCommanders[ship] = "NONE"
        end
    end
end

function L.StartMonitoring()
    L.frameCounter = 0
    L.currentShipIndex = 0
    L.isMonitoring = true
end

function L.StopMonitoring()
    L.shipList = {}
    L.currentShipIndex = 0
    L.previousOrders = {}
    L.previousPilots = {}
    L.previousCommanders = {}
    L.cleanupTriggered = {}
    L.isMonitoring = false
end

function L.OnUpdate()
    if #L.shipList == 0 or not L.isMonitoring then
        return
    end
    
    L.frameCounter = L.frameCounter + 1
    if L.frameCounter < L.CHECK_INTERVAL then
        return
    end
    L.frameCounter = 0
    
    L.currentShipIndex = L.currentShipIndex + 1
    if L.currentShipIndex > #L.shipList then
        L.currentShipIndex = 1
    end
    
    local ship = L.shipList[L.currentShipIndex]
    if not ship or ship == 0 then
        return
    end
    
    -- Check for NULL pointer before calling ffi.string (prevents crash)
    local idcode_ptr = C.GetObjectIDCode(ship)
    local shipIDCode = (idcode_ptr ~= nil) and ffi.string(idcode_ptr) or "UNKNOWN"
    
    if not C.IsComponentClass(ship, "ship") then
        return
    end
    
    local orderBuf = ffi.new("Order")
    local currentOrderID = "NONE"
    if C.GetDefaultOrder(orderBuf, ship) and orderBuf.orderdef then
        -- Check for NULL pointer before calling ffi.string (prevents crash)
        local orderdef_ptr = orderBuf.orderdef
        currentOrderID = (orderdef_ptr ~= nil) and ffi.string(orderdef_ptr) or "NONE"
    end
    
    local currentPilot = GetComponentData(ship, "assignedpilot")
    local currentPilotID = currentPilot and tostring(currentPilot) or "NONE"
    
    -- Guard against non-controllable / stale IDs to avoid engine spam:
    -- "[=ERROR=] ... GetCommander(): Component 'X' is not of class controllable"
    local currentCommander = nil
    if C.IsComponentClass(ship, "controllable") then
        currentCommander = GetCommander(ship)
    end
    local currentCommanderID = "NONE"
    local currentCommanderNum = nil
    
    if currentCommander then
        -- Convert userdata ID to number using ConvertIDTo64Bit (like vanilla code)
        currentCommanderNum = ConvertIDTo64Bit(currentCommander)
        if currentCommanderNum and currentCommanderNum ~= 0 then
            currentCommanderID = tostring(currentCommanderNum)
        end
    end
    
    local previousOrderID = L.previousOrders[ship] or "NONE"
    local previousPilotID = L.previousPilots[ship] or "NONE"
    local previousCommanderID = L.previousCommanders[ship] or "NONE"
    
    -- Check if ship was promoted to commander (had commander before, no commander now)
    local wasPromotedToCommander = false
    if previousCommanderID ~= "NONE" and currentCommanderID == "NONE" then
        -- Ship previously had a commander, now has none - might have been promoted
        -- Check if ship has subordinates (confirms it's a commander)
        local numSubordinates = 0
        for group = 1, 10 do
            local count = C.GetNumSubordinatesOfGroup(ship, group)
            if count and count > 0 then
                numSubordinates = numSubordinates + count
            end
        end
        if numSubordinates > 0 then
            wasPromotedToCommander = true
        end
    end
    
    if currentOrderID ~= previousOrderID then
        local wasGTOrder = (previousOrderID == "GalaxyTraderMK3" or previousOrderID == "GalaxyTraderMK2" or previousOrderID == "GalaxyTraderMK1" or previousOrderID == "GalaxyMiner")
        local isGTOrderNow = (currentOrderID == "GalaxyTraderMK3" or currentOrderID == "GalaxyTraderMK2" or currentOrderID == "GalaxyTraderMK1" or currentOrderID == "GalaxyMiner")
        if wasGTOrder and not isGTOrderNow then
            -- Only trigger cleanup if ship wasn't promoted to commander
            -- Newly promoted commanders might temporarily lose order while X4 assigns it
            if not wasPromotedToCommander then
                L.cleanupTriggered[ship] = true
                AddUITriggeredEvent("GT_OrderMonitor", "GTOrderRemoved", {
                    ship = shipIDCode,
                    oldOrder = previousOrderID,
                    newOrder = currentOrderID
                })
            end
        end
        L.previousOrders[ship] = currentOrderID
    end
    
    local hasGTOrder = false
    local commanderHasGTOrder = nil  -- nil = unknown, true = yes, false = no
    
    if currentOrderID == "GalaxyTraderMK3" or currentOrderID == "GalaxyTraderMK2" or currentOrderID == "GalaxyTraderMK1" or currentOrderID == "GalaxyMiner" then
        hasGTOrder = true
    elseif currentOrderID == "Assist" then
        -- Ship has Assist order - check commander's order
        if currentCommanderNum and currentCommanderNum ~= 0 then
            local commanderOrderBuf = ffi.new("Order")
            local getOrderSuccess = C.GetDefaultOrder(commanderOrderBuf, currentCommanderNum)
            if getOrderSuccess and commanderOrderBuf.orderdef then
                -- Check for NULL pointer before calling ffi.string (prevents crash)
                local orderdef_ptr = commanderOrderBuf.orderdef
                local commanderOrderID = (orderdef_ptr ~= nil) and ffi.string(orderdef_ptr) or nil
                if commanderOrderID == "GalaxyTraderMK3" or commanderOrderID == "GalaxyTraderMK2" or commanderOrderID == "GalaxyTraderMK1" or commanderOrderID == "GalaxyMiner" then
                    hasGTOrder = true
                    commanderHasGTOrder = true
                else
                    commanderHasGTOrder = false
                end
            end
            -- If GetDefaultOrder failed, commanderHasGTOrder stays nil (unknown)
        end
        -- If ship has Assist but we can't verify commander status, don't clean it up
        -- Only clean up if we can VERIFY commander doesn't have GT order
    end
    
    local shouldKeepShip = false
    if currentOrderID == "GalaxyTraderMK3" or currentOrderID == "GalaxyTraderMK2" or currentOrderID == "GalaxyTraderMK1" or currentOrderID == "GalaxyMiner" then
        -- Direct GT order - keep if has pilot
        shouldKeepShip = (currentPilotID ~= "NONE")
    elseif currentOrderID == "Assist" then
        -- Assist order - keep if commander has GT order AND has pilot
        -- If commander status unknown (nil), err on side of keeping ship
        if commanderHasGTOrder == true then
            shouldKeepShip = (currentPilotID ~= "NONE")
        elseif commanderHasGTOrder == false then
            -- Commander confirmed to NOT have GT order - can clean up
            shouldKeepShip = false
        else
            -- Commander status unknown - keep ship to avoid false positives
            shouldKeepShip = true
        end
    elseif wasPromotedToCommander then
        -- Ship was promoted to commander (had commander before, now has subordinates)
        -- Keep it even if it doesn't have GT order yet - X4 needs time to assign order
        -- This handles vanilla's automatic commander promotion when old commander destroyed
        shouldKeepShip = (currentPilotID ~= "NONE")
    end
    
    if not L.cleanupTriggered[ship] and not shouldKeepShip then
        L.cleanupTriggered[ship] = true
        if hasGTOrder and currentPilotID == "NONE" then
            AddUITriggeredEvent("GT_OrderMonitor", "MissingPilot", {
                ship = shipIDCode,
                order = currentOrderID,
                previousPilot = previousPilotID
            })
        else
            AddUITriggeredEvent("GT_OrderMonitor", "GTOrderRemoved", {
                ship = shipIDCode,
                oldOrder = previousOrderID or "UNKNOWN",
                newOrder = currentOrderID
            })
        end
    end
    
    L.previousPilots[ship] = currentPilotID
    L.previousCommanders[ship] = currentCommanderID
end

Init()
return L

