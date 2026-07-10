-- GalaxyTrader Context Menu - Pilot Redistribution
-- Redistributes pilots by level rank to ship class rank:
-- - sort pilots by level descending, ships by class descending
-- - assign highest level to largest ship, next to next largest, etc.
-- - only cross-class swaps (no S<->S, M<->M, L<->L, XL<->XL)
-- - never allow penalty outcomes (< 0 modifier)
-- - Fleet commander: only receives a same-class subordinate pilot when that pilot is on a higher
--   penalty tier than the commander (see skillTier / performanceModifier bands in gt_ship_management)

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef uint64_t NPCSeed;
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
    typedef struct {
        const char* reason;
        NPCSeed person;
        NPCSeed partnerperson;
    } UICrewExchangeResult;
    bool IsComponentClass(UniverseID componentid, const char* classname);
    bool IsOrderSelectableFor(const char* orderdefid, UniverseID controllableid);
    UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);
    float GetDistanceBetween(UniverseID component1id, UniverseID component2id);
    uint32_t CreateOrder(UniverseID controllableid, const char* orderid, bool defaultorder);
    void EnableOrder(UniverseID controllableid, uint32_t idx);
    UniverseID ConvertStringTo64Bit(const char* idcode);
    uint32_t GetNumAllFactionShips(const char* factionid);
    uint32_t GetAllFactionShips(UniverseID* result, uint32_t resultlen, const char* factionid);
    uint32_t GetNumOrders(UniverseID controllableid);
    uint32_t GetOrders(Order* result, uint32_t resultlen, UniverseID controllableid);
    bool GetDefaultOrder(Order* result, UniverseID controllableid);
    float GetEntityCombinedSkill(UniverseID entityid, const char* roleid, const char* postid);
    UICrewExchangeResult PerformCrewExchange2(UniverseID controllableid, UniverseID partnercontrollableid, NPCSeed* npcs, uint32_t numnpcs, NPCSeed* partnernpcs, uint32_t numpartnernpcs, NPCSeed captainfromcontainer, NPCSeed captainfrompartner, bool exchangecaptains, bool checkonly);
    bool IsCurrentOrderCritical(UniverseID controllableid);
]]

local GT_ORDER_IDS = {
    GalaxyTraderMK1 = true,
    GalaxyTraderMK2 = true,
    GalaxyTraderMK3 = true,
    GalaxyTraderMK4Supply = true,
    GalaxyTraderMK4Supply2 = true,
    GalaxyMiner = true,
}

local function debugLog(msg)
    DebugError("[GT Redistribute] " .. tostring(msg))
end

local function formatTextId(textId, ...)
    local template = ReadText(77000, textId) or ""
    if select("#", ...) > 0 then
        local values = { ... }
        template = tostring(template):gsub("%%(%d+)", function(idx)
            local n = tonumber(idx)
            if n and values[n] ~= nil then
                return tostring(values[n])
            end
            return "%" .. tostring(idx)
        end)
    end
    return template
end

local function showPlayerNotification(text, timeoutSec, priority)
    local msg = tostring(text or "")
    if msg == "" then
        return
    end
    if type(AddUITriggeredEvent) == "function" then
        AddUITriggeredEvent("GT_Redistribute", "Notification", {
            text = msg,
            timeout = tonumber(timeoutSec) or 12,
            priority = tonumber(priority) or 5,
        })
    end
    debugLog(msg)
end

local function notify(msg, priority)
    showPlayerNotification(msg, 8, priority)
end

local function notifyText(textId, ...)
    notify(formatTextId(textId, ...), 5)
end

local function logPilotExchangeMenu(msg)
    DebugError("[GT PilotExchange Menu] " .. tostring(msg))
end

local function requestPilotExchangeBusyShipRefresh()
    if type(AddUITriggeredEvent) == "function" then
        AddUITriggeredEvent("GT_Redistribute", "RefreshBusyShipIds", {})
    end
end

local peBusyShipIdSet = nil

local function loadPilotExchangeBusyShipIdSet()
    local set = {}
    if GT_PlayerBridge and GT_PlayerBridge.GetPlayerBlackboardId then
        local raw = GetNPCBlackboard(GT_PlayerBridge.GetPlayerBlackboardId(), "$GT_PilotExchange_BusyShipIds")
        if type(raw) == "table" then
            for i = 1, #raw do
                local idcode = tostring(raw[i] or "")
                if idcode ~= "" then
                    set[idcode] = true
                end
            end
        end
    end
    return set
end

local function getPilotExchangeBusyShipIdSet()
    peBusyShipIdSet = loadPilotExchangeBusyShipIdSet()
    return peBusyShipIdSet
end

local function publishMapSelectionShipCount()
    requestPilotExchangeBusyShipRefresh()
    getPilotExchangeBusyShipIdSet()
    local ships = {}
    local seen = {}
    local pilotIndex = getGTPilotIndexByShipId()
    local interactMenu = Helper.getMenu("InteractMenu")
    if interactMenu and interactMenu.selectedplayerships then
        for _, ship in ipairs(interactMenu.selectedplayerships) do
            tryAddEligibleGTShip(ship, ships, seen, pilotIndex, {})
        end
    elseif menu and menu.selectedcomponents then
        for id, _ in pairs(menu.selectedcomponents) do
            local selectedComponent = ConvertStringTo64Bit(tostring(id))
            if selectedComponent and selectedComponent ~= 0 and C.IsComponentClass(selectedComponent, "ship") then
                tryAddEligibleGTShip(selectedComponent, ships, seen, pilotIndex, {})
            end
        end
    end
    local count = #ships
    if GT_PlayerBridge and GT_PlayerBridge.GetPlayerBlackboardId then
        SetNPCBlackboard(GT_PlayerBridge.GetPlayerBlackboardId(), "$GT_PilotExchange_SelectionShipCount", count)
    end
    return count
end

local function logMapSelectionState(trigger)
    if not menu then
        DebugError("[GT PilotExchange Menu] Lua map selection: MapMenu unavailable trigger=" .. tostring(trigger or ""))
        return
    end
    local shipCount = 0
    local shipIds = {}
    if menu.selectedcomponents then
        for id, _ in pairs(menu.selectedcomponents) do
            local selectedComponent = ConvertStringTo64Bit(tostring(id))
            if selectedComponent and selectedComponent ~= 0 and C.IsComponentClass(selectedComponent, "ship") then
                shipCount = shipCount + 1
                local idcode = GetComponentData(selectedComponent, "idcode") or tostring(id)
                table.insert(shipIds, tostring(idcode))
            end
        end
    end
    table.sort(shipIds)

    local interactMenu = Helper.getMenu("InteractMenu")
    local interactShipCount = -1
    local interactShipIds = {}
    if interactMenu and interactMenu.selectedplayerships then
        interactShipCount = #interactMenu.selectedplayerships
        for _, ship in ipairs(interactMenu.selectedplayerships) do
            table.insert(interactShipIds, tostring(GetComponentData(ship, "idcode") or ship))
        end
        table.sort(interactShipIds)
    end

    DebugError("[GT PilotExchange Menu] Lua map selection trigger=" .. tostring(trigger or "")
        .. " mapSelectedShipCount=" .. tostring(shipCount)
        .. " mapShips=" .. table.concat(shipIds, ",")
        .. " interactSelectedShipCount=" .. tostring(interactShipCount)
        .. " interactShips=" .. table.concat(interactShipIds, ",")
        .. " publishedBlackboardCount=" .. tostring(publishMapSelectionShipCount()))
end

local menu = Helper.getMenu("MapMenu")
local pendingRedistributeCommander = nil
local pendingRedistributeSelection = false
local pendingRedistributeFleet = false
local pendingSelectionDispatch = nil
local pendingPlanPreview = nil
local pilotDataRefreshRequestedAt = 0
local PILOT_DATA_REFRESH_TIMEOUT = 5.0
local PILOT_DATA_FLEET_REUSE_MAX_AGE = 60.0
local pendingSwapShipsByPair = {}
local completedSwapByPair = {}
local pendingDockAssignmentsByPair = {}
local pendingReleaseRetries = {}
local pendingPostSwapRefreshRetries = {}
local pendingDirectSwapQueue = nil
local directSwapWatchState = {}
local directSwapWatchLastProbeAt = 0
local DIRECT_SWAP_WATCH_PROBE_INTERVAL = 0.75
local DIRECT_SWAP_DEFER_FALLBACK_SEC = 5.0
local pilotIndexCacheByShipId = nil

local function invalidatePilotIndexCache()
    pilotIndexCacheByShipId = nil
end

local function buildShipsByRank(ships)
    local byRank = { {}, {}, {}, {} }
    for _, s in ipairs(ships or {}) do
        local r = s.rank
        if r and r >= 1 and r <= 4 then
            table.insert(byRank[r], s)
        end
    end
    return byRank
end

local function isShipInPendingRedistribution(ship, idcode)
    local shipKey = tostring(ship or "")
    local codeKey = tostring(idcode or "")
    for _, item in pairs(pendingDockAssignmentsByPair) do
        if item then
            if codeKey ~= "" and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
                return true
            end
            if shipKey ~= "" and (tostring(item.leftShip or "") == shipKey or tostring(item.rightShip or "") == shipKey) then
                return true
            end
        end
    end
    for key, _ in pairs(pendingSwapShipsByPair) do
        local a, b = string.match(tostring(key), "^([^|]+)|([^|]+)$")
        if codeKey ~= "" and ((a and a == codeKey) or (b and b == codeKey)) then
            return true
        end
    end
    for _, item in ipairs(pendingReleaseRetries) do
        if item and codeKey ~= "" and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
            return true
        end
    end
    for _, item in ipairs(pendingPostSwapRefreshRetries) do
        if item and codeKey ~= "" and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
            return true
        end
    end
    return false
end

local function clearPendingRedistributionForShip(idcode)
    if not idcode or idcode == "" then
        return
    end
    local codeKey = tostring(idcode)
    for key, item in pairs(pendingDockAssignmentsByPair) do
        if item and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
            pendingDockAssignmentsByPair[key] = nil
        end
    end
    -- Clear remembered swap pairs as well to avoid stale growth if an exchange is cancelled early.
    -- Swap execution now receives authoritative ship objects from MD, so we do not depend on this cache.
    for key, pair in pairs(pendingSwapShipsByPair) do
        if pair and (tostring(pair.left or "") == codeKey or tostring(pair.right or "") == codeKey) then
            pendingSwapShipsByPair[key] = nil
        end
    end
    for key, item in pairs(completedSwapByPair) do
        if item and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
            completedSwapByPair[key] = nil
        end
    end
    for i = #pendingReleaseRetries, 1, -1 do
        local item = pendingReleaseRetries[i]
        if item and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
            table.remove(pendingReleaseRetries, i)
        end
    end
    for i = #pendingPostSwapRefreshRetries, 1, -1 do
        local item = pendingPostSwapRefreshRetries[i]
        if item and (tostring(item.left or "") == codeKey or tostring(item.right or "") == codeKey) then
            table.remove(pendingPostSwapRefreshRetries, i)
        end
    end
    local queue = pendingDirectSwapQueue
    if queue and queue.active and codeKey ~= "" then
        local newItems = {}
        local removedBeforeIndex = 0
        for i, item in ipairs(queue.items) do
            if tostring(item.leftCode or "") == codeKey or tostring(item.rightCode or "") == codeKey then
                if i < queue.index then
                    removedBeforeIndex = removedBeforeIndex + 1
                end
            else
                table.insert(newItems, item)
            end
        end
        if #newItems ~= #queue.items then
            queue.items = newItems
            queue.index = math.max(1, queue.index - removedBeforeIndex)
            if queue.index > #queue.items then
                queue.active = false
                pendingDirectSwapQueue = nil
            end
        end
    end
end

local function publishPilotExchangeRenameState(leftCode, rightCode, active)
    if type(AddUITriggeredEvent) ~= "function" then
        return
    end
    AddUITriggeredEvent("GT_Redistribute", "PilotExchangeState", {
        left = tostring(leftCode or ""),
        right = tostring(rightCode or ""),
        active = active == true,
    })
end

local function publishPilotExchangeRelease(leftCode, rightCode, leftShip, rightShip)
    if type(AddUITriggeredEvent) ~= "function" then
        return
    end
    AddUITriggeredEvent("GT_Redistribute", "ReleaseDockHold", {
        left = tostring(leftCode or ""),
        right = tostring(rightCode or ""),
    })
end

local function publishPostSwapNameRefresh(leftCode, rightCode, leftShip, rightShip)
    if type(AddUITriggeredEvent) ~= "function" then
        return
    end
    AddUITriggeredEvent("GT_Redistribute", "PostSwapNameRefresh", {
        left = tostring(leftCode or ""),
        right = tostring(rightCode or ""),
    })
    debugLog("PostSwapNameRefresh emitted left=" .. tostring(leftCode or "")
        .. " right=" .. tostring(rightCode or "")
        .. " leftShip=" .. tostring(leftShip or 0)
        .. " rightShip=" .. tostring(rightShip or 0))
    if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData and type(Mods.GalaxyTrader.PilotData.requestRefresh) == "function" then
        invalidatePilotIndexCache()
        Mods.GalaxyTrader.PilotData.requestRefresh()
        debugLog("PostSwapNameRefresh requested GT pilot data refresh left=" .. tostring(leftCode or "")
            .. " right=" .. tostring(rightCode or ""))
    else
        debugLog("PostSwapNameRefresh could not request GT pilot data refresh")
    end
end

local function schedulePilotExchangeReleaseRetry(leftCode, rightCode, leftShip, rightShip)
    if not leftCode or not rightCode then
        return
    end
    table.insert(pendingReleaseRetries, {
        left = tostring(leftCode),
        right = tostring(rightCode),
        leftShip = leftShip or 0,
        rightShip = rightShip or 0,
        dueAt = getElapsedTime() + 2.0,
        attemptsLeft = 5,
    })
end

local function schedulePostSwapNameRefreshRetry(leftCode, rightCode, leftShip, rightShip)
    if not leftCode or not rightCode then
        return
    end
    table.insert(pendingPostSwapRefreshRetries, {
        left = tostring(leftCode),
        right = tostring(rightCode),
        leftShip = leftShip or 0,
        rightShip = rightShip or 0,
        dueAt = getElapsedTime() + 1.0,
        attemptsLeft = 4,
    })
end

local function isGTOrder(orderId)
    return orderId and GT_ORDER_IDS[orderId] == true
end

local function asComponentId(entry)
    if not entry then
        return nil
    end
    if type(entry) == "table" and entry.component then
        return asComponentId(entry.component)
    end
    if type(entry) == "cdata" then
        local luaId = ConvertStringToLuaID(tostring(entry))
        if luaId then
            return ConvertIDTo64Bit(luaId)
        end
        return nil
    end
    return ConvertIDTo64Bit(entry)
end

local function asLuaComponent(entry)
    if not entry then
        return nil
    end
    if type(entry) == "table" and entry.component then
        return asLuaComponent(entry.component)
    end
    if type(entry) == "cdata" then
        return ConvertStringToLuaID(tostring(entry))
    end
    return entry
end

local function getDefaultOrderId(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return nil
    end
    local buf = ffi.new("Order")
    if C.GetDefaultOrder(buf, shipId) and buf.orderdef then
        return ffi.string(buf.orderdef)
    end
    return nil
end

local function getOrderParamsSafe(shipId, orderIdx)
    if type(GetOrderParams) ~= "function" then
        return nil
    end
    local params = GetOrderParams(shipId, orderIdx)
    if params ~= nil then
        return params
    end
    local asLua = ConvertStringToLuaID(tostring(shipId))
    if asLua then
        return GetOrderParams(asLua, orderIdx)
    end
    return nil
end

local function getCallerOrderIdFromParams(params)
    if type(params) ~= "table" then
        return nil
    end
    local caller = params.callerid
    if type(caller) == "string" then
        return caller
    end
    if type(caller) == "table" then
        if type(caller.id) == "string" then
            return caller.id
        end
        if type(caller.orderid) == "string" then
            return caller.orderid
        end
    end
    return nil
end

local function orderIsPilotExchange(orderdef, callerId)
    return orderdef == "DockAndPilotExchange"
        or (orderdef == "DockAndWait" and callerId == "DockAndPilotExchange")
end

local function shipHasActiveOrQueuedPilotExchangeOrder(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return false
    end

    local defaultOrder = getDefaultOrderId(ship)
    if defaultOrder == "DockAndPilotExchange" then
        return true
    end
    if defaultOrder == "DockAndWait" then
        local params = getOrderParamsSafe(shipId, 1)
        if orderIsPilotExchange(defaultOrder, getCallerOrderIdFromParams(params)) then
            return true
        end
    end

    local numOrders = tonumber(C.GetNumOrders(shipId) or 0) or 0
    if numOrders <= 1 then
        return false
    end

    local orders = ffi.new("Order[?]", numOrders)
    local count = tonumber(C.GetOrders(orders, numOrders, shipId) or 0) or 0
    if count <= 0 then
        return false
    end

    for i = 0, count - 1 do
        local orderdef = orders[i].orderdef and ffi.string(orders[i].orderdef) or ""
        if orderdef == "DockAndPilotExchange" then
            return true
        end
        if orderdef == "DockAndWait" then
            local orderIdx = tonumber(orders[i].queueidx) or (i + 1)
            local params = getOrderParamsSafe(shipId, orderIdx)
            local callerId = getCallerOrderIdFromParams(params)
            if orderIsPilotExchange(orderdef, callerId) then
                return true
            end
        end
    end

    return false
end

local function shipHasActiveOrQueuedDockAndTrain(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return false
    end

    if getDefaultOrderId(shipId) == "DockAndTrain" then
        return true
    end

    local numOrders = tonumber(C.GetNumOrders(shipId) or 0) or 0
    if numOrders <= 1 then
        return false
    end

    local orders = ffi.new("Order[?]", numOrders)
    local count = tonumber(C.GetOrders(orders, numOrders, shipId) or 0) or 0
    for i = 0, count - 1 do
        local orderdef = orders[i].orderdef and ffi.string(orders[i].orderdef) or ""
        if orderdef == "DockAndTrain" then
            return true
        end
    end

    return false
end

local DEFERRED_SWAP_REASONS = {
    pilotbusy = true,
    previouspilotbusy = true,
    intransit = true,
    awaiting_transfer = true,
}

local function isDeferredSwapReason(reason)
    return reason and DEFERRED_SWAP_REASONS[tostring(reason)] == true
end

local function isShipOrderCritical(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return false
    end
    return C.IsCurrentOrderCritical(shipId)
end

local function trySwapCaptains(leftShip, rightShip, execute)
    execute = (execute ~= false)
    local emptyA = ffi.new("NPCSeed[1]")
    local emptyB = ffi.new("NPCSeed[1]")
    debugLog("PerformCrewExchange2 check leftShip=" .. tostring(leftShip) .. " rightShip=" .. tostring(rightShip))
    local check = C.PerformCrewExchange2(leftShip, rightShip, emptyA, 0, emptyB, 0, 0, 0, true, true)
    local checkReason = check.reason and ffi.string(check.reason) or ""
    debugLog("PerformCrewExchange2 check result leftShip=" .. tostring(leftShip) .. " rightShip=" .. tostring(rightShip) .. " reason=" .. tostring(checkReason))
    if checkReason ~= "" then
        return false, checkReason
    end
    if not execute then
        return true, ""
    end

    debugLog("PerformCrewExchange2 execute leftShip=" .. tostring(leftShip) .. " rightShip=" .. tostring(rightShip))
    local exec = C.PerformCrewExchange2(leftShip, rightShip, emptyA, 0, emptyB, 0, 0, 0, true, false)
    local reason = exec.reason and ffi.string(exec.reason) or ""
    debugLog("PerformCrewExchange2 execute result leftShip=" .. tostring(leftShip) .. " rightShip=" .. tostring(rightShip) .. " reason=" .. tostring(reason))
    if reason ~= "" then
        return false, reason
    end
    return true, ""
end

local function shipIsInDirectSwapQueue(idcode)
    local queue = pendingDirectSwapQueue
    if not queue or not queue.active then
        return false
    end
    local code = tostring(idcode or "")
    if code == "" then
        return false
    end
    for i = queue.index, #queue.items do
        local item = queue.items[i]
        if item and (tostring(item.leftCode) == code or tostring(item.rightCode) == code) then
            return true
        end
    end
    return false
end

-- Planning exclusion only: already queued for exchange (not operational busy - those defer at execution).
local function shipIsAlreadyQueuedForPilotExchange(ship, idcode)
    if shipIsInDirectSwapQueue(idcode) then
        return true
    end
    if shipHasActiveOrQueuedPilotExchangeOrder(ship) then
        return true
    end
    if isShipInPendingRedistribution(ship, idcode) then
        return true
    end
    local codeKey = tostring(idcode or (ship and GetComponentData(ship, "idcode")) or "")
    if codeKey ~= "" then
        local busySet = peBusyShipIdSet or getPilotExchangeBusyShipIdSet()
        if busySet[codeKey] then
            return true
        end
    end
    return false
end

local function publishDirectQueueBusyShipIds()
    local ids = {}
    local seen = {}
    local queue = pendingDirectSwapQueue
    if queue and queue.active then
        for i = queue.index, #queue.items do
            local item = queue.items[i]
            if item then
                for _, code in ipairs({ item.leftCode, item.rightCode }) do
                    code = tostring(code or "")
                    if code ~= "" and not seen[code] then
                        seen[code] = true
                        table.insert(ids, code)
                    end
                end
            end
        end
    end
    if GT_PlayerBridge and GT_PlayerBridge.GetPlayerBlackboardId then
        local playerId = GT_PlayerBridge.GetPlayerBlackboardId()
        if playerId then
            SetNPCBlackboard(playerId, "$GT_PilotExchange_DirectQueueBusyIds", ids)
        end
    end
end

local function clearDirectSwapWatchState()
    directSwapWatchState = {}
    directSwapWatchLastProbeAt = 0
end

local function seedDirectSwapWatchState(left, right)
    for _, ship in ipairs({ left, right }) do
        if ship and ship ~= 0 then
            directSwapWatchState[tostring(ship)] = {
                critical = isShipOrderCritical(ship),
            }
        end
    end
end

local function getCommanderId(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return nil
    end
    local cmd = GetCommander(shipId)
    local cmdId = asComponentId(cmd)
    if cmdId and cmdId ~= 0 then
        return cmdId
    end
    return nil
end

local function pairKey(leftCode, rightCode)
    local a = tostring(leftCode or "")
    local b = tostring(rightCode or "")
    if a < b then
        return a .. "|" .. b
    end
    return b .. "|" .. a
end

local function swapPairKeyForState(a, b)
    return pairKey(a and a.idcode, b and b.idcode)
end

local function dedupeSwaps(swaps)
    local out = {}
    local seen = {}
    for _, swap in ipairs(swaps or {}) do
        local leftCode = GetComponentData(swap.left, "idcode")
        local rightCode = GetComponentData(swap.right, "idcode")
        local key = pairKey(leftCode, rightCode)
        if key ~= "|" and not seen[key] then
            seen[key] = true
            table.insert(out, swap)
        end
    end
    return out
end

local function rememberSwapPair(leftCode, rightCode, leftShip, rightShip)
    if not leftCode or not rightCode or not leftShip or not rightShip then
        return
    end
    pendingSwapShipsByPair[pairKey(leftCode, rightCode)] = {
        left = leftShip,
        right = rightShip,
    }
end

local function popRememberedSwapPair(leftCode, rightCode)
    local key = pairKey(leftCode, rightCode)
    local pair = pendingSwapShipsByPair[key]
    pendingSwapShipsByPair[key] = nil
    return pair
end

local function resolveShipFromIdCode(idcode)
    if not idcode or idcode == "" then
        return nil
    end
    local code = tostring(idcode)
    -- Fast path for numeric/serialized values.
    local shipId = C.ConvertStringTo64Bit(code)
    if shipId and shipId ~= 0 then
        local resolvedCode = GetComponentData(shipId, "idcode")
        if resolvedCode and tostring(resolvedCode) == code then
            return shipId
        end
    end

    -- Authoritative idcode resolution for player ships across save/load:
    -- enumerate player-owned ships and match by idcode exactly.
    local numShips = C.GetNumAllFactionShips("player")
    if numShips and numShips > 0 then
        local shipIds = ffi.new("UniverseID[?]", numShips)
        local count = C.GetAllFactionShips(shipIds, numShips, "player")
        for i = 0, count - 1 do
            local candidate = shipIds[i]
            if candidate and candidate ~= 0 then
                local candidateCode = GetComponentData(candidate, "idcode")
                if candidateCode and tostring(candidateCode) == code then
                    return candidate
                end
            end
        end
    end
    return nil
end

local function classRank(ship)
    if C.IsComponentClass(ship, "ship_xl") then return 4, "XL" end
    if C.IsComponentClass(ship, "ship_l") then return 3, "L" end
    if C.IsComponentClass(ship, "ship_m") then return 2, "M" end
    if C.IsComponentClass(ship, "ship_s") then return 1, "S" end
    return 0, "UNK"
end

local function getGTPilotBridge()
    if not Mods or not Mods.GalaxyTrader or not Mods.GalaxyTrader.PilotData then
        return nil
    end
    local bridge = Mods.GalaxyTrader.PilotData
    if type(bridge.getPilots) ~= "function" then
        return nil
    end
    return bridge
end

local function getGTPilotIndexByShipId()
    if pilotIndexCacheByShipId then
        return pilotIndexCacheByShipId
    end
    local bridge = getGTPilotBridge()
    if not bridge then
        return nil
    end
    local pilots = bridge.getPilots() or {}
    local index = {}
    for _, p in ipairs(pilots) do
        if p and p.shipId and p.shipId ~= "" then
            index[tostring(p.shipId)] = p
        end
    end
    pilotIndexCacheByShipId = index
    return pilotIndexCacheByShipId
end

local function pilotDataCacheIsFresh()
    local bridge = getGTPilotBridge()
    if not bridge or type(bridge.getLastUpdate) ~= "function" then
        return false
    end
    if type(bridge.isInitialized) == "function" and not bridge.isInitialized() then
        return false
    end
    local lastUpdate = bridge.getLastUpdate() or 0
    if lastUpdate <= 0 then
        return false
    end
    return (getElapsedTime() - lastUpdate) <= PILOT_DATA_FLEET_REUSE_MAX_AGE
end

local function getGTPilotDataByShip(ship, pilotIndex)
    local shipIdCode = GetComponentData(ship, "idcode")
    if not shipIdCode or shipIdCode == "" then
        return nil
    end
    local index = pilotIndex or getGTPilotIndexByShipId()
    return index and index[tostring(shipIdCode)] or nil
end

local function getGTLevelByShip(ship, pilotIndex)
    local pilotData = getGTPilotDataByShip(ship, pilotIndex)
    if pilotData and pilotData.level ~= nil then
        local lvl = tonumber(pilotData.level)
        if lvl then
            return math.max(1, math.min(15, math.floor(lvl)))
        end
    end
    return nil
end

local function pilotDataIndicatesBlocked(pilotData)
    if not pilotData then
        return false, nil
    end
    local blockedLevel = tonumber(pilotData.blockedLevel) or 0
    if blockedLevel > 0 then
        return true, "blockedLevel_" .. tostring(blockedLevel)
    end
    if pilotData.trainingBlocked == true then
        return true, "trainingBlocked_true"
    end
    if type(pilotData.status) == "string" then
        local statusUpper = string.upper(pilotData.status)
        if string.find(statusUpper, "[BL]", 1, true)
            or string.find(statusUpper, "BLOCKED", 1, true) then
            return true, "status_" .. tostring(pilotData.status)
        end
    end
    return false, nil
end

local function pilotDataIndicatesTraining(pilotData)
    if type(pilotData) == "table" and type(pilotData.status) == "string" then
        local statusUpper = string.upper(pilotData.status)
        if string.find(statusUpper, "TRAINING", 1, true)
            or string.find(statusUpper, "[TR]", 1, true) then
            return true, "status_" .. tostring(pilotData.status)
        end
    end
    return false, nil
end

local function shipIsUnavailableForPilotExchange(ship, idcode, pilotData)
    if shipIsAlreadyQueuedForPilotExchange(ship, idcode) then
        return true, "pilot_exchange_queued"
    end
    local isTraining, trainingReason = pilotDataIndicatesTraining(pilotData)
    if isTraining then
        return true, trainingReason
    end
    local shipId = asComponentId(ship)
    if shipId and shipId ~= 0 then
        local defaultOrder = getDefaultOrderId(shipId)
        local numOrders = tonumber(C.GetNumOrders(shipId) or 0) or 0
        if defaultOrder ~= "DockAndTrain" and numOrders <= 1 then
            -- No queued training order to scan.
        elseif shipHasActiveOrQueuedDockAndTrain(ship) then
            return true, "pilot_training_dock_and_train"
        end
    elseif shipHasActiveOrQueuedDockAndTrain(ship) then
        return true, "pilot_training_dock_and_train"
    end
    local isBlocked, blockedReason = pilotDataIndicatesBlocked(pilotData)
    if isBlocked then
        return true, blockedReason
    end
    return false, nil
end

-- Mirrors gt_ship_management.xml Calculate_Performance_Modifier
local function performanceModifier(level, rank)
    if level <= 2 then
        if rank == 1 then return 0 end
        if rank == 2 then return -5 end
        if rank == 3 then return -15 end
        if rank == 4 then return -25 end
    elseif level == 3 then
        if rank == 1 then return 3 end
        if rank == 2 then return 0 end
        if rank == 3 then return -8 end
        if rank == 4 then return -15 end
    elseif level >= 4 and level <= 6 then
        if rank == 1 then return 3 end
        if rank == 2 then return 0 end
        if rank == 3 then return -8 end
        if rank == 4 then return -15 end
    elseif level >= 7 and level <= 15 then
        local modifier = 0
        if level >= 12 then
            if rank == 1 then modifier = 12
            elseif rank == 2 then modifier = 9
            elseif rank == 3 then modifier = 6
            elseif rank == 4 then modifier = 3 end
        elseif level >= 9 then
            if rank == 1 then modifier = 9
            elseif rank == 2 then modifier = 6
            elseif rank == 3 then modifier = 3
            elseif rank == 4 then modifier = 0 end
        else -- 7-8
            if rank == 1 then modifier = 6
            elseif rank == 2 then modifier = 3
            elseif rank == 3 then modifier = 0
            elseif rank == 4 then modifier = -8 end
        end
        if level == 15 then
            modifier = modifier + 3
        end
        return modifier
    end
    return 0
end

-- Penalty-tier index aligned with performanceModifier / Calculate_Performance_Modifier level branches.
-- T1: 1-2 | T2: 3-6 | T3: 7-8 | T4: 9-11 | T5: 12-14 | T6: 15 (level 15 adds +3 in penalty math)
local function skillTier(level)
    local l = math.max(1, math.min(15, math.floor(tonumber(level) or 1)))
    if l <= 2 then return 1 end
    if l <= 6 then return 2 end
    if l <= 8 then return 3 end
    if l <= 11 then return 4 end
    if l <= 14 then return 5 end
    return 6
end

-- Priority within same target class: lower-level targets first.
local function compareTargetPriorityWithinClass(a, b)
    if a.level == b.level then
        return tostring(a.idcode) < tostring(b.idcode)
    end
    return a.level < b.level
end

local function shipIsFleetCommander(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return false
    end
    local subs = GetSubordinates(shipId) or {}
    return #subs > 0
end

local function tryAddEligibleGTShip(ship, ships, seen, pilotIndex, opts)
    opts = opts or {}
    ship = asComponentId(ship)
    if not ship or ship == 0 or seen[tostring(ship)] then
        return
    end

    local pilot = GetComponentData(ship, "assignedpilot")
    local order = getDefaultOrderId(ship)
    local commanderOrder = nil
    local commanderId = opts.commanderId
    local isCommander = false
    if commanderId and ship == commanderId then
        isCommander = true
    elseif not commanderId then
        isCommander = shipIsFleetCommander(ship)
    end
    if not isCommander then
        local shipCommander = getCommanderId(ship)
        if shipCommander then
            commanderOrder = getDefaultOrderId(shipCommander)
        end
    end
    local isGTControlled = isCommander
        or (order and isGTOrder(order))
        or (order == "Assist" and commanderOrder and isGTOrder(commanderOrder))
    if pilot and isGTControlled then
        local rank, size = classRank(ship)
        if rank > 0 then
            local pilot64 = ConvertIDTo64Bit(pilot)
            local idcode = GetComponentData(ship, "idcode") or "UNK"
            local pilotData = getGTPilotDataByShip(ship, pilotIndex)
            local unavailable, unavailableReason = shipIsUnavailableForPilotExchange(ship, idcode, pilotData)
            if unavailable and not opts.forPlanDisplay then
                if not opts.quietUnavailable then
                    debugLog("Eligible ship ignored: " .. tostring(idcode) .. " reason=" .. tostring(unavailableReason or "unavailable"))
                end
                return
            end
            local gtLevel = getGTLevelByShip(ship, pilotIndex)
            if gtLevel then
                local exchangeQueued = unavailable and unavailableReason == "pilot_exchange_queued"
                local planExcludeReason = (unavailable and not exchangeQueued) and unavailableReason or nil
                table.insert(ships, {
                    ship = ship,
                    idcode = idcode,
                    pilot = pilot64,
                    level = gtLevel,
                    rank = rank,
                    size = size,
                    orderId = order or "NONE",
                    commanderOrderId = commanderOrder or "NONE",
                    levelSource = "GT_PilotData",
                    isCommander = isCommander,
                    startLevel = gtLevel,
                    exchangeQueued = exchangeQueued,
                    planExcludeReason = planExcludeReason,
                })
                seen[tostring(ship)] = true
            elseif unavailable and opts.forPlanDisplay then
                if not opts.quietUnavailable then
                    debugLog("Plan display ship ignored (no GT level): " .. tostring(idcode)
                        .. " reason=" .. tostring(unavailableReason or "unavailable"))
                end
            else
                debugLog("Eligible ship ignored: " .. tostring(idcode)
                    .. " reason=missing_GT_level order=" .. tostring(order or "NONE")
                    .. " commanderOrder=" .. tostring(commanderOrder or "NONE"))
            end
        end
    else
        if not opts.quietReject then
            local idcode = GetComponentData(ship, "idcode") or "UNK"
            debugLog("Eligible ship ignored: " .. tostring(idcode)
                .. " pilot=" .. tostring(pilot ~= nil)
                .. " gtControlled=" .. tostring(isGTControlled)
                .. " order=" .. tostring(order or "NONE")
                .. " commanderOrder=" .. tostring(commanderOrder or "NONE"))
        end
    end
end

local function smallerAndLargerShip(a, b)
    if a.rank < b.rank then
        return a, b
    end
    if b.rank < a.rank then
        return b, a
    end
    return nil, nil
end

local function isCrossClassInversion(a, b)
    local small, large = smallerAndLargerShip(a, b)
    if not small then
        return false
    end
    return small.level > large.level
end

local function countCrossClassInversions(ships)
    local byRank = buildShipsByRank(ships)
    local count = 0
    for r1 = 1, 3 do
        for r2 = r1 + 1, 4 do
            for _, a in ipairs(byRank[r1]) do
                for _, b in ipairs(byRank[r2]) do
                    if a.level > b.level then
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

local function isSelectionWellOrdered(ships)
    return countCrossClassInversions(ships) == 0
end

local function distinctClassRankCount(ships)
    local ranks = {}
    local count = 0
    for _, s in ipairs(ships) do
        if not ranks[s.rank] then
            ranks[s.rank] = true
            count = count + 1
        end
    end
    return count
end

local function swapPassesSelectionGates(small, large)
    local modSmall = performanceModifier(large.level, small.rank)
    local modLarge = performanceModifier(small.level, large.rank)
    if modSmall < 0 or modLarge < 0 then
        return false
    end
    if small.isCommander and large.level < small.startLevel then
        return false
    end
    if large.isCommander and small.level < large.startLevel then
        return false
    end
    return true
end

local function applyVirtualPilotSwap(a, b)
    a.pilot, b.pilot = b.pilot, a.pilot
    a.level, b.level = b.level, a.level
end

local function pairInversion(s1, s2)
    if s1.rank == s2.rank then
        return 0
    end
    local small, large = smallerAndLargerShip(s1, s2)
    if not small then
        return 0
    end
    return (small.level > large.level) and 1 or 0
end

local function inversionDeltaForSwap(state, a, b)
    if a.rank == b.rank then
        return 0
    end
    local la, lb = a.level, b.level
    local before = pairInversion(a, b)
    for _, other in ipairs(state) do
        if other ~= a and other ~= b then
            before = before + pairInversion(a, other) + pairInversion(b, other)
        end
    end
    a.level, b.level = lb, la
    local after = pairInversion(a, b)
    for _, other in ipairs(state) do
        if other ~= a and other ~= b then
            after = after + pairInversion(a, other) + pairInversion(b, other)
        end
    end
    a.level, b.level = la, lb
    return before - after
end

local function planSelectionSwaps(ships)
    local quietPlanLog = #ships > 30
    local state = {}
    for _, s in ipairs(ships) do
        table.insert(state, {
            ship = s.ship,
            idcode = s.idcode,
            pilot = s.pilot,
            level = s.level,
            rank = s.rank,
            size = s.size,
            isCommander = s.isCommander,
            startLevel = s.startLevel,
        })
    end

    local swaps = {}
    local usedPairs = {}
    local maxIterations = math.max(1, #state)
    local iterations = 0

    while not isSelectionWellOrdered(state) and iterations < maxIterations do
        iterations = iterations + 1
        local buckets = buildShipsByRank(state)
        local candidates = {}
        for r1 = 1, 3 do
            for r2 = r1 + 1, 4 do
                for _, a in ipairs(buckets[r1]) do
                    for _, b in ipairs(buckets[r2]) do
                        if isCrossClassInversion(a, b) then
                            local pairKey = swapPairKeyForState(a, b)
                            if not usedPairs[pairKey] then
                                local small, large = smallerAndLargerShip(a, b)
                                local gap = small.level - large.level
                                local invDelta = inversionDeltaForSwap(state, a, b)
                                if swapPassesSelectionGates(small, large) and invDelta > 0 then
                                    table.insert(candidates, {
                                        a = a,
                                        b = b,
                                        small = small,
                                        large = large,
                                        gap = gap,
                                        invDelta = invDelta,
                                        pairKey = pairKey,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end

        if #candidates == 0 then
            break
        end

        table.sort(candidates, function(x, y)
            if x.gap ~= y.gap then
                return x.gap > y.gap
            end
            if x.invDelta ~= y.invDelta then
                return x.invDelta > y.invDelta
            end
            return tostring(x.small.idcode) < tostring(y.small.idcode)
        end)

        local pick = candidates[1]
        usedPairs[pick.pairKey] = true
        local smallLevel = pick.small.level
        local largeLevel = pick.large.level
        applyVirtualPilotSwap(pick.a, pick.b)
        table.insert(swaps, {
            left = pick.a.ship,
            right = pick.b.ship,
            smallIdcode = pick.small.idcode,
            largeIdcode = pick.large.idcode,
            smallLevel = smallLevel,
            largeLevel = largeLevel,
            smallSize = pick.small.size,
            largeSize = pick.large.size,
        })
        if not quietPlanLog then
            debugLog("Selection swap planned: "
                .. tostring(pick.small.idcode) .. "(lvl " .. tostring(smallLevel) .. ", " .. tostring(pick.small.size) .. ") <-> "
                .. tostring(pick.large.idcode) .. "(lvl " .. tostring(largeLevel) .. ", " .. tostring(pick.large.size) .. ")")
        end
    end

    return dedupeSwaps(swaps)
end

local function findShipEntry(ships, component)
    local idcode = GetComponentData(component, "idcode")
    for _, s in ipairs(ships) do
        if idcode and tostring(s.idcode) == tostring(idcode) then
            return s
        end
        if s.ship == component then
            return s
        end
    end
    return nil
end

local function findShipEntryByIdcode(ships, idcode)
    if not idcode then
        return nil
    end
    local key = tostring(idcode)
    for _, s in ipairs(ships or {}) do
        if s.idcode and tostring(s.idcode) == key then
            return s
        end
    end
    return nil
end

local function formatShipPilotLine(name, idcode, size, level)
    return string.format("%s (%s, %s L%s)",
        tostring(name), tostring(idcode), tostring(size), tostring(level))
end

local function buildSwapPlanLine(ships, swap)
    if not swap.smallIdcode or not swap.largeIdcode then
        return nil
    end
    local smallLevel = tonumber(swap.smallLevel)
    local largeLevel = tonumber(swap.largeLevel)
    if not smallLevel or not largeLevel or smallLevel <= largeLevel then
        debugLog("Swap plan line skipped: not a cross-class inversion "
            .. tostring(swap.smallIdcode) .. " L" .. tostring(smallLevel) .. " " .. tostring(swap.smallSize)
            .. " vs " .. tostring(swap.largeIdcode) .. " L" .. tostring(largeLevel) .. " " .. tostring(swap.largeSize))
        return nil
    end
    local smallShip = findShipEntryByIdcode(ships, swap.smallIdcode)
    local largeShip = findShipEntryByIdcode(ships, swap.largeIdcode)
    if not smallShip or not largeShip then
        return nil
    end
    local smallName = GetComponentData(smallShip.ship, "name") or tostring(swap.smallIdcode)
    local largeName = GetComponentData(largeShip.ship, "name") or tostring(swap.largeIdcode)
    return formatTextId(
        31317,
        smallName, tostring(swap.smallIdcode), tostring(swap.smallSize), tostring(smallLevel),
        largeName, tostring(swap.largeIdcode), tostring(swap.largeSize), tostring(largeLevel)
    )
end

local function appendSwapPlanLines(lines, ships, swap)
    local line = buildSwapPlanLine(ships, swap)
    if line then
        table.insert(lines, line)
    end
end

local function classSortKey(size)
    if size == "S" then return 1 end
    if size == "M" then return 2 end
    if size == "L" then return 3 end
    if size == "XL" then return 4 end
    return 5
end

local function collectGroupShipEntries(ships, group)
    local entries = {}
    local seen = {}
    local function addComponent(shipComp)
        local entry = findShipEntry(ships, shipComp)
        if entry and not seen[tostring(entry.idcode)] then
            seen[tostring(entry.idcode)] = true
            table.insert(entries, entry)
        end
    end
    if group.ships then
        for _, shipComp in ipairs(group.ships) do
            addComponent(shipComp)
        end
    end
    if group.swaps then
        for _, swap in ipairs(group.swaps) do
            addComponent(swap.left)
            addComponent(swap.right)
        end
    end
    table.sort(entries, function(a, b)
        local ka, kb = classSortKey(a.size), classSortKey(b.size)
        if ka ~= kb then
            return ka < kb
        end
        return tostring(a.idcode) < tostring(b.idcode)
    end)
    return entries
end

local function simulateSwapLevelsOnMap(levelMap, swap)
    local lc = GetComponentData(swap.left, "idcode")
    local rc = GetComponentData(swap.right, "idcode")
    if not lc or not rc then
        return
    end
    lc, rc = tostring(lc), tostring(rc)
    local leftLevel = levelMap[lc]
    local rightLevel = levelMap[rc]
    if leftLevel and rightLevel then
        levelMap[lc], levelMap[rc] = rightLevel, leftLevel
    end
end

local function buildLevelMapAfterSwaps(ships, swapList)
    local levelMap = {}
    for _, s in ipairs(ships or {}) do
        if s.idcode then
            levelMap[tostring(s.idcode)] = tonumber(s.level)
        end
    end
    for _, swap in ipairs(swapList or {}) do
        simulateSwapLevelsOnMap(levelMap, swap)
    end
    return levelMap
end

local function formatCycleShipLines(entries, levelMap)
    local lines = {}
    for _, entry in ipairs(entries) do
        local code = tostring(entry.idcode)
        local level = levelMap[code]
        if level then
            local name = GetComponentData(entry.ship, "name") or code
            table.insert(lines, "  " .. formatShipPilotLine(name, code, entry.size, level))
        end
    end
    return lines
end

local function buildCyclePlanLines(ships, group)
    local entries = collectGroupShipEntries(ships, group)
    if #entries < 3 then
        return nil
    end
    local beforeMap = buildLevelMapAfterSwaps(ships, {})
    local afterMap = buildLevelMapAfterSwaps(ships, group.swaps or {})
    local lines = {}
    table.insert(lines, formatTextId(31320, tostring(#entries), tostring(#(group.swaps or {}))))
    for _, line in ipairs(formatCycleShipLines(entries, beforeMap)) do
        table.insert(lines, line)
    end
    table.insert(lines, "  =>")
    for _, line in ipairs(formatCycleShipLines(entries, afterMap)) do
        table.insert(lines, line)
    end
    return lines
end

local function buildGroupedSwapPlanLines(ships, swaps, groups)
    local lines = {}
    groups = groups or buildRendezvousGroups(swaps)
    for _, group in ipairs(groups) do
        if group.kind == "cycle" then
            local cycleLines = buildCyclePlanLines(ships, group)
            if cycleLines then
                for _, line in ipairs(cycleLines) do
                    table.insert(lines, line)
                end
            else
                for _, swap in ipairs(group.swaps or {}) do
                    appendSwapPlanLines(lines, ships, swap)
                end
            end
        else
            for _, swap in ipairs(group.swaps or {}) do
                appendSwapPlanLines(lines, ships, swap)
            end
        end
    end
    return lines
end

local UNCHANGED_REASON_ID = {
    optimal = 31330,
    commander = 31331,
    penalty = 31332,
    same_class = 31333,
    no_swap = 31334,
    exchange_queued = 31340,
    pilot_training = 31341,
    pilot_blocked = 31342,
}

local function planExcludeReasonToTextId(reason)
    if reason == "pilot_exchange_queued" then
        return UNCHANGED_REASON_ID.exchange_queued
    end
    if reason == "pilot_training_dock_and_train" or (reason and string.find(reason, "TRAINING", 1, true)) then
        return UNCHANGED_REASON_ID.pilot_training
    end
    if reason and (string.find(reason, "blocked", 1, true) or string.find(reason, "BLOCKED", 1, true) or string.find(reason, "BL", 1, true)) then
        return UNCHANGED_REASON_ID.pilot_blocked
    end
    return nil
end

local function filterShipsForSwapPlanning(ships)
    local out = {}
    for _, ship in ipairs(ships or {}) do
        if not ship.exchangeQueued and not ship.planExcludeReason then
            table.insert(out, ship)
        end
    end
    return out
end

local function shipEntryForPlanLine(ships, idcode, pilotIndex)
    local entry = findShipEntryByIdcode(ships, idcode)
    if entry then
        return entry
    end
    local ship = resolveShipFromIdCode(idcode)
    if not ship or ship == 0 then
        return nil
    end
    local rank, size = classRank(ship)
    if rank <= 0 then
        return nil
    end
    pilotIndex = pilotIndex or getGTPilotIndexByShipId()
    local level = getGTLevelByShip(ship, pilotIndex)
    if not level then
        return nil
    end
    return {
        ship = ship,
        idcode = tostring(idcode),
        level = level,
        rank = rank,
        size = size,
    }
end

local function buildQueuedSwapPairLine(ships, leftCode, rightCode, pilotIndex)
    local leftEntry = shipEntryForPlanLine(ships, leftCode, pilotIndex)
    local rightEntry = shipEntryForPlanLine(ships, rightCode, pilotIndex)
    if not leftEntry or not rightEntry then
        return tostring(leftCode) .. " <-> " .. tostring(rightCode)
    end
    local small, large = smallerAndLargerShip(leftEntry, rightEntry)
    if not small then
        local leftName = GetComponentData(leftEntry.ship, "name") or tostring(leftCode)
        local rightName = GetComponentData(rightEntry.ship, "name") or tostring(rightCode)
        return leftName .. " (" .. tostring(leftCode) .. ") <-> "
            .. rightName .. " (" .. tostring(rightCode) .. ")"
    end
    local smallName = GetComponentData(small.ship, "name") or tostring(small.idcode)
    local largeName = GetComponentData(large.ship, "name") or tostring(large.idcode)
    return formatTextId(
        31317,
        smallName, tostring(small.idcode), tostring(small.size), tostring(small.level),
        largeName, tostring(large.idcode), tostring(large.size), tostring(large.level)
    )
end

local function buildQueuedSwapLinesForShips(ships)
    local queue = pendingDirectSwapQueue
    if not queue or not queue.active or not queue.items then
        return {}
    end
    local selectedCodes = {}
    for _, ship in ipairs(ships or {}) do
        selectedCodes[tostring(ship.idcode)] = true
    end
    local lines = {}
    local seen = {}
    local pilotIndex = getGTPilotIndexByShipId()
    for i = queue.index, #queue.items do
        local item = queue.items[i]
        if item then
            local leftCode = tostring(item.leftCode or "")
            local rightCode = tostring(item.rightCode or "")
            if leftCode ~= "" and rightCode ~= "" and (selectedCodes[leftCode] or selectedCodes[rightCode]) then
                local key = pairKey(leftCode, rightCode)
                if not seen[key] then
                    seen[key] = true
                    table.insert(lines, buildQueuedSwapPairLine(ships, leftCode, rightCode, pilotIndex))
                end
            end
        end
    end
    return lines
end

local function buildSwapParticipantSet(swaps)
    local set = {}
    for _, swap in ipairs(swaps or {}) do
        local leftCode = GetComponentData(swap.left, "idcode")
        local rightCode = GetComponentData(swap.right, "idcode")
        if leftCode then
            set[tostring(leftCode)] = true
        end
        if rightCode then
            set[tostring(rightCode)] = true
        end
    end
    return set
end

local function classifyUnchangedShipReasonId(ship, allShips)
    local buckets = buildShipsByRank(allShips)
    local hasCrossClassPartner = false
    local hasInversion = false
    local commanderBlock = false
    local penaltyBlock = false

    for r = 1, 4 do
        if r ~= ship.rank and #buckets[r] > 0 then
            hasCrossClassPartner = true
            for _, other in ipairs(buckets[r]) do
                if isCrossClassInversion(ship, other) then
                    hasInversion = true
                    local small, large = smallerAndLargerShip(ship, other)
                    if small and large and not swapPassesSelectionGates(small, large) then
                        if ship.isCommander then
                            if (small.idcode == ship.idcode and large.level < small.startLevel)
                                or (large.idcode == ship.idcode and small.level < large.startLevel) then
                                commanderBlock = true
                            end
                        end
                        local modSmall = performanceModifier(large.level, small.rank)
                        local modLarge = performanceModifier(small.level, large.rank)
                        if modSmall < 0 or modLarge < 0 then
                            penaltyBlock = true
                        end
                    end
                end
            end
        end
    end

    if not hasCrossClassPartner then
        return UNCHANGED_REASON_ID.same_class
    end
    if not hasInversion then
        return UNCHANGED_REASON_ID.optimal
    end
    if commanderBlock then
        return UNCHANGED_REASON_ID.commander
    end
    if penaltyBlock then
        return UNCHANGED_REASON_ID.penalty
    end
    return UNCHANGED_REASON_ID.no_swap
end

local function buildUnchangedShipLines(ships, swaps)
    local swapSet = buildSwapParticipantSet(swaps)
    local swappableShips = filterShipsForSwapPlanning(ships)
    local lines = {}
    for _, ship in ipairs(ships or {}) do
        if not swapSet[tostring(ship.idcode)] then
            local name = GetComponentData(ship.ship, "name") or tostring(ship.idcode)
            local reasonId = nil
            if ship.exchangeQueued then
                reasonId = UNCHANGED_REASON_ID.exchange_queued
            elseif ship.planExcludeReason then
                reasonId = planExcludeReasonToTextId(ship.planExcludeReason) or UNCHANGED_REASON_ID.no_swap
            else
                reasonId = classifyUnchangedShipReasonId(ship, swappableShips)
            end
            table.insert(lines, formatTextId(
                31329,
                name,
                tostring(ship.idcode),
                tostring(ship.size or "?"),
                tostring(ship.level),
                formatTextId(reasonId)
            ))
        end
    end
    return lines
end

local function readBlackboardStringList(playerId, key)
    local raw = GetNPCBlackboard(playerId, key)
    if type(raw) ~= "table" then
        return {}
    end
    local lines = {}
    for i = 1, #raw do
        local line = raw[i]
        if type(line) == "string" and line ~= "" then
            table.insert(lines, line)
        end
    end
    return lines
end

local function buildStationPreviewPayload(groups)
    local payloadGroups = {}
    for _, group in ipairs(groups or {}) do
        local shipEntries = {}
        if group.kind == "pair" and group.swaps and group.swaps[1] then
            for _, ship in ipairs({ group.swaps[1].left, group.swaps[1].right }) do
                local idcode = GetComponentData(ship, "idcode")
                if idcode and idcode ~= "" then
                    table.insert(shipEntries, {
                        idcode = tostring(idcode),
                        obj = ConvertStringToLuaID(tostring(ship)),
                    })
                end
            end
        elseif group.kind == "cycle" and group.ships then
            for _, ship in ipairs(group.ships) do
                local idcode = GetComponentData(ship, "idcode")
                if idcode and idcode ~= "" then
                    table.insert(shipEntries, {
                        idcode = tostring(idcode),
                        obj = ConvertStringToLuaID(tostring(ship)),
                    })
                end
            end
        end
        if #shipEntries >= 2 then
            table.insert(payloadGroups, { ships = shipEntries })
        end
    end
    return { groups = payloadGroups }
end

local function requestAcceptLogbookMessages(groups)
    if type(AddUITriggeredEvent) ~= "function" then
        debugLog("Accept logbook skipped: AddUITriggeredEvent unavailable")
        return
    end
    local payload = buildStationPreviewPayload(groups)
    if not payload or not payload.groups or #payload.groups == 0 then
        return
    end
    AddUITriggeredEvent("GT_Redistribute", "AcceptLogbook", payload)
    debugLog("Accept logbook queued groups=" .. tostring(#payload.groups))
end

local function buildSelectionExchangePlanSections(ships, swaps, groups, rendezvousLines, extra)
    extra = extra or {}
    swaps = swaps or {}
    groups = groups or buildRendezvousGroups(swaps)

    local swapLines = {}
    if #swaps > 0 then
        swapLines = buildGroupedSwapPlanLines(ships, swaps, groups)
    end

    local unchangedLines = buildUnchangedShipLines(ships, swaps)

    return {
        swapLines = swapLines,
        rendezvousLines = rendezvousLines or {},
        unchangedLines = unchangedLines,
        queuedSwapLines = extra.queuedSwapLines or {},
        readOnly = extra.readOnly == true,
    }
end

local function planOverlayHasContent(sections)
    if not sections then
        return false
    end
    return #(sections.swapLines or {}) > 0
        or #(sections.unchangedLines or {}) > 0
        or #(sections.queuedSwapLines or {}) > 0
end

local function requestStationPreviewAndOpenPlan(ships, swaps, groups)
    local sections = buildSelectionExchangePlanSections(ships, swaps, groups, nil)
    if not sections or #sections.swapLines == 0 then
        return false
    end
    if type(AddUITriggeredEvent) ~= "function" then
        debugLog("Station preview unavailable: AddUITriggeredEvent missing")
        return false
    end
    pendingPlanPreview = {
        sections = sections,
    }
    AddUITriggeredEvent("GT_Redistribute", "PreviewStations", buildStationPreviewPayload(groups))
    return true
end

local function openPlanPreviewWithRendezvous()
    if not pendingPlanPreview or not pendingPlanPreview.sections then
        return false
    end
    local playerId = GT_PlayerBridge and GT_PlayerBridge.GetPlayerBlackboardId and GT_PlayerBridge.GetPlayerBlackboardId()
    if playerId then
        pendingPlanPreview.sections.rendezvousLines = readBlackboardStringList(
            playerId, "$GT_PilotExchange_Plan_RendezvousLines")
    end
    local sections = pendingPlanPreview.sections
    pendingPlanPreview = nil
    if GT_PilotExchangePlan and GT_PilotExchangePlan.openOverlay then
        return GT_PilotExchangePlan.openOverlay(sections)
    end
    return false
end

local function openPilotExchangePlanOverlayDirect(ships, swaps, groups, extra)
    local sections = buildSelectionExchangePlanSections(ships, swaps, groups, {}, extra)
    if not planOverlayHasContent(sections) then
        return false
    end
    if GT_PilotExchangePlan and GT_PilotExchangePlan.openOverlay then
        return GT_PilotExchangePlan.openOverlay(sections)
    end
    return false
end

local function publishAndOpenPilotExchangePlanOverlay(ships, swaps, groups, opts)
    opts = opts or {}
    return openPilotExchangePlanOverlayDirect(ships, swaps, groups, {
        queuedSwapLines = opts.queuedSwapLines,
        readOnly = opts.readOnly,
    })
end

local function openExcludedOnlyPilotExchangePlanOverlay(ships)
    local unchangedLines = buildUnchangedShipLines(ships, {})
    if #unchangedLines == 0 then
        return false
    end
    pendingSelectionDispatch = nil
    pendingPlanPreview = nil
    if GT_PilotExchangePlan and GT_PilotExchangePlan.openOverlay then
        return GT_PilotExchangePlan.openOverlay({
            swapLines = {},
            rendezvousLines = {},
            unchangedLines = unchangedLines,
            readOnly = true,
        })
    end
    return false
end

local function buildRendezvousGroups(swaps)
    if #swaps == 0 then
        return {}
    end

    local parent = {}
    local function findShipId(idcode)
        if parent[idcode] == nil then
            parent[idcode] = idcode
        end
        if parent[idcode] ~= idcode then
            parent[idcode] = findShipId(parent[idcode])
        end
        return parent[idcode]
    end
    local function unionShipIds(a, b)
        parent[findShipId(a)] = findShipId(b)
    end

    for _, swap in ipairs(swaps) do
        local leftCode = GetComponentData(swap.left, "idcode")
        local rightCode = GetComponentData(swap.right, "idcode")
        if leftCode and rightCode then
            unionShipIds(tostring(leftCode), tostring(rightCode))
        end
    end

    local compSwaps = {}
    local compOrder = {}
    for _, swap in ipairs(swaps) do
        local leftCode = tostring(GetComponentData(swap.left, "idcode") or "")
        local root = findShipId(leftCode)
        if not compSwaps[root] then
            compSwaps[root] = {}
            table.insert(compOrder, root)
        end
        table.insert(compSwaps[root], swap)
    end

    local groups = {}
    for _, root in ipairs(compOrder) do
        local comp = compSwaps[root]
        local shipSet = {}
        local ships = {}
        for _, swap in ipairs(comp) do
            local leftCode = tostring(GetComponentData(swap.left, "idcode") or "")
            local rightCode = tostring(GetComponentData(swap.right, "idcode") or "")
            if leftCode ~= "" and not shipSet[leftCode] then
                shipSet[leftCode] = true
                table.insert(ships, swap.left)
            end
            if rightCode ~= "" and not shipSet[rightCode] then
                shipSet[rightCode] = true
                table.insert(ships, swap.right)
            end
        end
        if #ships <= 2 and #comp == 1 then
            table.insert(groups, { kind = "pair", swaps = comp })
        else
            -- Cycle: 3-4 linked hulls (e.g. S/M/L or S/M/L/XL chain) share one station.
            table.insert(groups, { kind = "cycle", ships = ships, swaps = comp })
        end
    end
    return groups
end

local function requestDockOrdersFromMD(leftShip, rightShip, leftCode, rightCode)
    if type(AddUITriggeredEvent) ~= "function" then
        return false
    end
    if (not leftShip) or leftShip == 0 or (not rightShip) or rightShip == 0 then
        return false
    end
    if not leftCode or not rightCode then
        return false
    end
    AddUITriggeredEvent("GT_Redistribute", "AssignDockOrders", {
        left = tostring(leftCode),
        right = tostring(rightCode),
        leftObj = ConvertStringToLuaID(tostring(leftShip)),
        rightObj = ConvertStringToLuaID(tostring(rightShip)),
        immediate = true,
    })
    return true
end

local function requestCycleDockOrdersFromMD(cycleId, ships, swaps)
    if type(AddUITriggeredEvent) ~= "function" then
        return false
    end
    if not cycleId or cycleId == "" or not ships or #ships < 3 or not swaps or #swaps < 1 then
        return false
    end

    local shipPayload = {}
    for i, ship in ipairs(ships) do
        local idcode = GetComponentData(ship, "idcode")
        if not idcode or idcode == "" then
            return false
        end
        shipPayload[i] = {
            idcode = tostring(idcode),
            obj = ConvertStringToLuaID(tostring(ship)),
        }
    end

    local swapPayload = {}
    for i, swap in ipairs(swaps) do
        local leftCode = GetComponentData(swap.left, "idcode")
        local rightCode = GetComponentData(swap.right, "idcode")
        if not leftCode or not rightCode then
            return false
        end
        swapPayload[i] = {
            left = tostring(leftCode),
            right = tostring(rightCode),
            leftObj = ConvertStringToLuaID(tostring(swap.left)),
            rightObj = ConvertStringToLuaID(tostring(swap.right)),
        }
    end

    AddUITriggeredEvent("GT_Redistribute", "AssignCycleDockOrders", {
        cycleId = tostring(cycleId),
        ships = shipPayload,
        swaps = swapPayload,
        immediate = true,
    })
    return true
end

local function pilotKey(pilot)
    if pilot == nil then
        return ""
    end
    if type(pilot) == "userdata" or type(pilot) == "cdata" then
        local id = ConvertIDTo64Bit(pilot)
        if id and id ~= 0 then
            return tostring(id)
        end
    end
    return tostring(pilot)
end

local function pilotsWereExchanged(left, right, preLeftPilot, preRightPilot)
    local wasLeft = pilotKey(preLeftPilot)
    local wasRight = pilotKey(preRightPilot)
    if wasLeft == "" or wasRight == "" then
        return false
    end
    local nowLeft = pilotKey(GetComponentData(left, "assignedpilot"))
    local nowRight = pilotKey(GetComponentData(right, "assignedpilot"))
    return nowLeft == wasRight and nowRight == wasLeft
end

local function fireCycleSwapCompleteIfNeeded(item, leftCode, rightCode, left, right)
    if item and item.cycleId and item.cycleId ~= "" and type(AddUITriggeredEvent) == "function" then
        AddUITriggeredEvent("GT_Redistribute", "CycleSwapComplete", {
            cycleId = tostring(item.cycleId),
            left = tostring(leftCode),
            right = tostring(rightCode),
            leftObj = ConvertStringToLuaID(tostring(left or 0)),
            rightObj = ConvertStringToLuaID(tostring(right or 0)),
        })
    end
end

local function finishDirectSwapQueueIfDone(queue)
    if queue.index > #queue.items then
        queue.active = false
        pendingDirectSwapQueue = nil
        clearDirectSwapWatchState()
        publishDirectQueueBusyShipIds()
        requestPilotExchangeBusyShipRefresh()
        debugLog("Direct swap queue finished")
    end
end

local function markDirectSwapCompleted(leftCode, rightCode, left, right)
    local keyA, keyB = tostring(leftCode), tostring(rightCode)
    if keyA > keyB then
        keyA, keyB = keyB, keyA
    end
    completedSwapByPair[keyA .. "|" .. keyB] = {
        left = tostring(leftCode),
        right = tostring(rightCode),
        done = true,
    }
    publishPilotExchangeRenameState(leftCode, rightCode, false)
    publishPostSwapNameRefresh(leftCode, rightCode, left, right)
    schedulePostSwapNameRefreshRetry(leftCode, rightCode, left, right)
end

local function resolveSwapShipPair(leftCode, rightCode, leftShip, rightShip)
    local left = asComponentId(leftShip)
    local right = asComponentId(rightShip)
    if not left or left == 0 then
        left = resolveShipFromIdCode(leftCode)
    end
    if not right or right == 0 then
        right = resolveShipFromIdCode(rightCode)
    end
    return left, right
end

local function attemptDirectSwap(leftCode, rightCode, leftShip, rightShip)
    local left, right = resolveSwapShipPair(leftCode, rightCode, leftShip, rightShip)
    if not left or left == 0 or not right or right == 0 then
        return "fail", "invalid_ship"
    end
    local resolvedLeftCode = tostring(GetComponentData(left, "idcode") or "")
    local resolvedRightCode = tostring(GetComponentData(right, "idcode") or "")
    if resolvedLeftCode ~= tostring(leftCode) or resolvedRightCode ~= tostring(rightCode) then
        return "fail", "resolved_mismatch"
    end
    if isShipOrderCritical(left) or isShipOrderCritical(right) then
        return "defer", "critical_order"
    end
    local preLeftPilot = GetComponentData(left, "assignedpilot")
    local preRightPilot = GetComponentData(right, "assignedpilot")
    local ok, reason = trySwapCaptains(left, right, false)
    if not ok then
        if isDeferredSwapReason(reason) then
            return "defer", reason
        end
        publishPilotExchangeRenameState(leftCode, rightCode, false)
        return "fail", reason
    end
    publishPilotExchangeRenameState(leftCode, rightCode, true)
    ok, reason = trySwapCaptains(left, right, true)
    if not ok then
        if isDeferredSwapReason(reason) then
            return "defer", reason
        end
        publishPilotExchangeRenameState(leftCode, rightCode, false)
        return "fail", reason
    end
    if pilotsWereExchanged(left, right, preLeftPilot, preRightPilot) then
        markDirectSwapCompleted(leftCode, rightCode, left, right)
        return "ok", ""
    end
    return "settle", "awaiting_transfer", preLeftPilot, preRightPilot
end

local function attemptDirectSwapSettlement(item, leftCode, rightCode, leftShip, rightShip)
    local left, right = resolveSwapShipPair(leftCode, rightCode, leftShip, rightShip)
    if not left or left == 0 or not right or right == 0 then
        return "fail", "invalid_ship"
    end
    if pilotsWereExchanged(left, right, item.preLeftPilot, item.preRightPilot) then
        markDirectSwapCompleted(leftCode, rightCode, left, right)
        return "ok", ""
    end
    if isShipOrderCritical(left) or isShipOrderCritical(right) then
        return "defer", "critical_order"
    end
    local ok, reason = trySwapCaptains(left, right, false)
    if not ok then
        if isDeferredSwapReason(reason) then
            return "defer", reason
        end
        publishPilotExchangeRenameState(leftCode, rightCode, false)
        return "fail", reason
    end
    return "defer", "awaiting_transfer"
end

local function processDirectSwapQueue()
    local queue = pendingDirectSwapQueue
    if not queue or not queue.active then
        return
    end
    local now = getElapsedTime()
    if queue.nextRetryAt and now < queue.nextRetryAt then
        return
    end
    if queue.index > #queue.items then
        finishDirectSwapQueueIfDone(queue)
        return
    end

    local item = queue.items[queue.index]
    local leftCode = item.leftCode
    local rightCode = item.rightCode
    local status, reason, preLeftPilot, preRightPilot
    if item.awaitingSettlement then
        status, reason = attemptDirectSwapSettlement(item, leftCode, rightCode, item.left, item.right)
    else
        status, reason, preLeftPilot, preRightPilot = attemptDirectSwap(leftCode, rightCode, item.left, item.right)
    end

    local left, right = resolveSwapShipPair(leftCode, rightCode, item.left, item.right)
    if status == "defer" then
        queue.nextRetryAt = now + DIRECT_SWAP_DEFER_FALLBACK_SEC
        seedDirectSwapWatchState(left, right)
        publishDirectQueueBusyShipIds()
        debugLog("Direct swap deferred left=" .. tostring(leftCode) .. " right=" .. tostring(rightCode)
            .. " reason=" .. tostring(reason)
            .. (item.awaitingSettlement and " (settlement)" or ""))
        requestPilotExchangeBusyShipRefresh()
        return
    elseif status == "fail" then
        notify("Pilot swap failed (" .. tostring(reason) .. "): " .. tostring(leftCode) .. " <-> " .. tostring(rightCode))
        item.awaitingSettlement = false
        queue.index = queue.index + 1
        queue.nextRetryAt = 0
        publishDirectQueueBusyShipIds()
        finishDirectSwapQueueIfDone(queue)
        return
    elseif status == "settle" then
        item.awaitingSettlement = true
        item.preLeftPilot = preLeftPilot
        item.preRightPilot = preRightPilot
        seedDirectSwapWatchState(left, right)
        publishDirectQueueBusyShipIds()
        queue.nextRetryAt = now + DIRECT_SWAP_WATCH_PROBE_INTERVAL
        debugLog("Direct swap transfer started left=" .. tostring(leftCode) .. " right=" .. tostring(rightCode))
        requestPilotExchangeBusyShipRefresh()
        return
    end

    debugLog("Direct swap completed left=" .. tostring(leftCode) .. " right=" .. tostring(rightCode)
        .. (item.awaitingSettlement and " (settled)" or ""))
    fireCycleSwapCompleteIfNeeded(item, leftCode, rightCode, left, right)
    item.awaitingSettlement = false
    queue.index = queue.index + 1
    queue.nextRetryAt = 0
    publishDirectQueueBusyShipIds()
    finishDirectSwapQueueIfDone(queue)
end

local function getActiveDirectSwapPairShips()
    local queue = pendingDirectSwapQueue
    if not queue or not queue.active or queue.index > #queue.items then
        return nil, nil
    end
    local item = queue.items[queue.index]
    if not item then
        return nil, nil
    end
    return resolveSwapShipPair(item.leftCode, item.rightCode, item.left, item.right)
end

-- Event-style retry: detect critical-order release, then probe PerformCrewExchange2 checkonly.
local function updateDirectSwapAvailabilityWatch()
    local queue = pendingDirectSwapQueue
    if not queue or not queue.active then
        return
    end

    local left, right = getActiveDirectSwapPairShips()
    if not left or left == 0 or not right or right == 0 then
        return
    end

    local becameReady = false
    for _, ship in ipairs({ left, right }) do
        local key = tostring(ship)
        local critical = isShipOrderCritical(ship)
        local prev = directSwapWatchState[key]
        if prev and prev.critical and not critical then
            becameReady = true
        end
        directSwapWatchState[key] = { critical = critical }
    end

    local now = getElapsedTime()
    local shouldProbe = becameReady
        or (now - directSwapWatchLastProbeAt) >= DIRECT_SWAP_WATCH_PROBE_INTERVAL
    if not shouldProbe then
        return
    end
    directSwapWatchLastProbeAt = now

    if becameReady then
        queue.nextRetryAt = 0
    end
end

local function tickDirectSwapQueue()
    updateDirectSwapAvailabilityWatch()
    local queue = pendingDirectSwapQueue
    if not queue or not queue.active then
        return
    end
    local now = getElapsedTime()
    if (not queue.nextRetryAt) or now >= queue.nextRetryAt then
        processDirectSwapQueue()
    end
end

local function dispatchDirectExchangePlan(groups, logPrefix)
    local items = {}
    for gi, group in ipairs(groups or {}) do
        local cycleId = nil
        if group.kind == "cycle" and group.ships then
            local idParts = {}
            for _, ship in ipairs(group.ships) do
                table.insert(idParts, tostring(GetComponentData(ship, "idcode") or "UNK"))
            end
            table.sort(idParts)
            cycleId = "pe_cycle_" .. table.concat(idParts, "_") .. "_" .. tostring(gi)
        end
        for _, swap in ipairs(group.swaps or {}) do
            local leftCode = GetComponentData(swap.left, "idcode")
            local rightCode = GetComponentData(swap.right, "idcode")
            if leftCode and rightCode then
                table.insert(items, {
                    left = swap.left,
                    right = swap.right,
                    leftCode = tostring(leftCode),
                    rightCode = tostring(rightCode),
                    cycleId = cycleId,
                })
            end
        end
    end

    if #items == 0 then
        return 0, 0
    end

    pendingDirectSwapQueue = {
        active = true,
        items = items,
        index = 1,
        nextRetryAt = 0,
        logPrefix = logPrefix,
    }
    clearDirectSwapWatchState()
    publishDirectQueueBusyShipIds()
    requestPilotExchangeBusyShipRefresh()
    if logPrefix then
        debugLog(logPrefix .. " direct exchange queue swaps=" .. tostring(#items))
    end
    processDirectSwapQueue()
    return #items, 0
end

local function dispatchRendezvousPlan(groups, logPrefix)
    return dispatchDirectExchangePlan(groups, logPrefix)
end

local function dispatchSwapPairs(swaps, logPrefix)
    return dispatchRendezvousPlan(buildRendezvousGroups(swaps), logPrefix)
end

local function collectSelectedShips(fallbackComponent)
    requestPilotExchangeBusyShipRefresh()
    getPilotExchangeBusyShipIdSet()
    local ships = {}
    local seen = {}
    local pilotIndex = getGTPilotIndexByShipId()
    local rawSelectedShipCount = 0

    if menu and menu.selectedcomponents then
        for id, _ in pairs(menu.selectedcomponents) do
            local selectedComponent = ConvertStringTo64Bit(tostring(id))
            if selectedComponent and selectedComponent ~= 0 and C.IsComponentClass(selectedComponent, "ship") then
                rawSelectedShipCount = rawSelectedShipCount + 1
                tryAddEligibleGTShip(selectedComponent, ships, seen, pilotIndex, { forPlanDisplay = true })
            end
        end
    end

    local fallbackId = "none"
    if fallbackComponent then
        fallbackId = tostring(GetComponentData(fallbackComponent, "idcode") or fallbackComponent)
    end
    logPilotExchangeMenu("collectSelectedShips rawSelectedShipCount=" .. tostring(rawSelectedShipCount)
        .. " eligibleShipCount=" .. tostring(#ships)
        .. " fallback=" .. fallbackId)

    if #ships == 0 and fallbackComponent then
        tryAddEligibleGTShip(fallbackComponent, ships, seen, pilotIndex, { forPlanDisplay = true })
        logPilotExchangeMenu("collectSelectedShips after fallback eligibleShipCount=" .. tostring(#ships))
    end

    return ships
end

local function collectAllEligibleGTShips()
    requestPilotExchangeBusyShipRefresh()
    getPilotExchangeBusyShipIdSet()
    local ships = {}
    local seen = {}
    local pilotIndex = getGTPilotIndexByShipId()
    local rawPlayerShipCount = 0
    local collectOpts = { quietReject = true, quietUnavailable = true }

    local numShips = C.GetNumAllFactionShips("player")
    if numShips and numShips > 0 then
        local shipIds = ffi.new("UniverseID[?]", numShips)
        local count = C.GetAllFactionShips(shipIds, numShips, "player")
        for i = 0, count - 1 do
            local candidate = shipIds[i]
            if candidate and candidate ~= 0 and C.IsComponentClass(candidate, "ship") then
                rawPlayerShipCount = rawPlayerShipCount + 1
                tryAddEligibleGTShip(candidate, ships, seen, pilotIndex, collectOpts)
            end
        end
    end

    logPilotExchangeMenu("collectAllEligibleGTShips rawPlayerShipCount=" .. tostring(rawPlayerShipCount)
        .. " eligibleShipCount=" .. tostring(#ships))
    return ships
end

local function collectFleetShips(commanderComponent)
    local commander = ConvertIDTo64Bit(commanderComponent)
    local ships = {}
    local seen = {}
    local pilotIndex = getGTPilotIndexByShipId()

    tryAddEligibleGTShip(commanderComponent, ships, seen, pilotIndex, { commanderId = commander })
    local subs = GetSubordinates(commander) or {}
    for _, sub in ipairs(subs) do
        tryAddEligibleGTShip(sub, ships, seen, pilotIndex, { commanderId = commander })
    end
    return ships
end

local function redistribute(commanderComponent)
    local commander = ConvertIDTo64Bit(commanderComponent)
    if not commander or commander == 0 then
        return
    end

    local ships = collectFleetShips(commanderComponent)
    debugLog("Fleet setup for redistribution (eligible ships=" .. tostring(#ships) .. "):")
    for _, s in ipairs(ships) do
        debugLog(" - " .. tostring(s.idcode)
            .. " class=" .. tostring(s.size)
            .. " level=" .. tostring(s.level)
            .. " levelSource=" .. tostring(s.levelSource)
            .. " order=" .. tostring(s.orderId)
            .. " commanderOrder=" .. tostring(s.commanderOrderId))
    end
    if #ships < 2 then
        notify("Pilot redistribution: not enough eligible GT ships in fleet.")
        return
    end

    local swaps = {}
    local usedShips = {}  -- ships already committed to a swap (ensures each ship appears in at most one pair)
    local commanderShip = nil
    local subordinates = {}
    for _, s in ipairs(ships) do
        if s.isCommander then
            commanderShip = s
        else
            table.insert(subordinates, s)
        end
    end

    local function addSwap(srcShip, dstShip, reason)
        if not srcShip or not dstShip then
            return
        end
        local srcLevelBefore = srcShip.level
        local dstLevelBefore = dstShip.level
        table.insert(swaps, { left = srcShip.ship, right = dstShip.ship })
        usedShips[srcShip.idcode] = true
        usedShips[dstShip.idcode] = true
        srcShip.pilot, dstShip.pilot = dstShip.pilot, srcShip.pilot
        srcShip.level, dstShip.level = dstShip.level, srcShip.level
        debugLog("Rank swap (" .. tostring(reason or "rule") .. "): "
            .. tostring(srcShip.idcode) .. "(lvl " .. tostring(srcLevelBefore) .. ", " .. tostring(srcShip.size) .. "->" .. tostring(dstShip.size) .. ") <-> "
            .. tostring(dstShip.idcode) .. "(lvl " .. tostring(dstLevelBefore) .. ", " .. tostring(dstShip.size) .. "->" .. tostring(srcShip.size) .. ")")
    end

    -- Round 1: Fleet commander only if a same-class subordinate is on a higher penalty tier (not merely higher level within tier).
    if commanderShip then
        local cmdTier = skillTier(commanderShip.level)
        local bestForCommander = nil
        local bestTier = nil
        for _, src in ipairs(subordinates) do
            if (not usedShips[src.idcode]) and src.rank == commanderShip.rank then
                local st = skillTier(src.level)
                if st > cmdTier then
                    if (not bestForCommander)
                        or st > bestTier
                        or (st == bestTier and src.level > bestForCommander.level) then
                        bestForCommander = src
                        bestTier = st
                    end
                end
            end
        end
        if bestForCommander then
            addSwap(bestForCommander, commanderShip, "commander_round")
        else
            debugLog("Commander round: no same-class subordinate on a higher penalty tier for commander "
                .. tostring(commanderShip.idcode) .. " (cmdTier=" .. tostring(cmdTier) .. ")")
        end
    end

    -- Round 2: Subordinate-only priority assignment by destination class (XL -> L -> M).
    local classPriority = { 4, 3, 2 }
    for _, dstRank in ipairs(classPriority) do
        local destinations = {}
        for _, dst in ipairs(subordinates) do
            if (not usedShips[dst.idcode]) and dst.rank == dstRank then
                table.insert(destinations, dst)
            end
        end
        table.sort(destinations, compareTargetPriorityWithinClass)
        if #destinations > 0 then
            local order = {}
            for _, d in ipairs(destinations) do
                table.insert(order, tostring(d.idcode) .. ":lvl" .. tostring(d.level))
            end
            debugLog("Priority round rank " .. tostring(dstRank) .. " destination order (lowest first): " .. table.concat(order, ", "))
        end

        for _, dst in ipairs(destinations) do
            if not usedShips[dst.idcode] then
                local bestSource = nil
                for _, src in ipairs(subordinates) do
                    if (not usedShips[src.idcode]) and src.idcode ~= dst.idcode then
                        local classRuleOk = (src.rank < dst.rank) -- strictly lower class to higher class
                        local levelRuleOk = (src.level > dst.level) -- destination must strictly improve
                        if classRuleOk and levelRuleOk then
                            local modHigh = performanceModifier(src.level, dst.rank)
                            local modLow = performanceModifier(dst.level, src.rank)
                            local noPenalty = (modHigh >= 0 and modLow >= 0)
                            if noPenalty then
                                if (not bestSource)
                                    or (src.level > bestSource.level)
                                    or (src.level == bestSource.level and src.rank > bestSource.rank) then
                                    bestSource = src
                                end
                            end
                        end
                    end
                end

                if bestSource then
                    addSwap(bestSource, dst, "priority_round_rank_" .. tostring(dstRank))
                else
                    debugLog("Priority round rank " .. tostring(dstRank) .. ": no valid source for destination "
                        .. tostring(dst.idcode) .. " lvl=" .. tostring(dst.level))
                end
            end
        end
    end

    if #swaps == 0 then
        notify("Pilot redistribution: pilots already optimally distributed (level-to-class rank), or no penalty-free cross-class swaps possible.")
        debugLog("No swaps selected after commander + class-priority evaluation.")
        return
    end

    local requestCount = 0
    local failCount = 0
    requestCount, failCount = dispatchSwapPairs(swaps, "Redistribution dispatch for commander " .. tostring(GetComponentData(commander, "idcode") or "UNKNOWN"))

    notify("Pilot redistribution dispatch started. Pairs: " .. tostring(requestCount) .. " requested, " .. tostring(failCount) .. " failed.")
end

local function runPilotExchangePlanForShips(ships, setupLogLabel, dispatchLogPrefix, opts)
    opts = opts or {}
    if not opts.quietSetupLog then
        debugLog(setupLogLabel .. " (display ships=" .. tostring(#ships) .. "):")
        for _, s in ipairs(ships) do
            debugLog(" - " .. tostring(s.idcode)
                .. " class=" .. tostring(s.size)
                .. " level=" .. tostring(s.level)
                .. " commander=" .. tostring(s.isCommander)
                .. " queued=" .. tostring(s.exchangeQueued == true))
        end
    else
        logPilotExchangeMenu(setupLogLabel .. " displayShipCount=" .. tostring(#ships))
    end

    if #ships == 0 then
        notifyText(31311)
        return
    end

    local swappableShips = filterShipsForSwapPlanning(ships)
    local swaps = {}
    if #swappableShips >= 2 then
        swaps = planSelectionSwaps(swappableShips)
    end
    local groups = buildRendezvousGroups(swaps)
    local queuedSwapLines = buildQueuedSwapLinesForShips(ships)
    local hasNewSwaps = #swaps > 0

    if hasNewSwaps then
        pendingSelectionDispatch = {
            groups = groups,
            logPrefix = dispatchLogPrefix,
        }
    else
        pendingSelectionDispatch = nil
    end

    local overlayOpts = {
        queuedSwapLines = queuedSwapLines,
        readOnly = not hasNewSwaps,
    }
    if not publishAndOpenPilotExchangePlanOverlay(ships, swaps, groups, overlayOpts) then
        pendingSelectionDispatch = nil
        notifyText(31311)
        return
    end
    logPilotExchangeMenu(dispatchLogPrefix .. " plan overlay opened swaps=" .. tostring(#swaps)
        .. " groups=" .. tostring(#groups)
        .. " queuedLines=" .. tostring(#queuedSwapLines)
        .. " readOnly=" .. tostring(not hasNewSwaps))
end

local function redistributeSelection(triggerComponent)
    local ships = collectSelectedShips(triggerComponent)
    runPilotExchangePlanForShips(ships, "Selection setup for pilot exchange", "Selection pilot exchange dispatch")
end

local function redistributeAllGtShips()
    local ships = collectAllEligibleGTShips()
    runPilotExchangePlanForShips(ships, "HQ fleet setup for pilot exchange", "Fleet pilot exchange dispatch", {
        skipStationPreview = true,
        quietSetupLog = true,
    })
end

local function dispatchPendingSelectionExchange()
    local pending = pendingSelectionDispatch
    pendingSelectionDispatch = nil
    if not pending or not pending.groups then
        debugLog("dispatchPendingSelectionExchange: no pending dispatch")
        return
    end
    local requestCount, failCount = dispatchRendezvousPlan(pending.groups, pending.logPrefix or "Selection pilot exchange dispatch")
    requestAcceptLogbookMessages(pending.groups)
    if failCount > 0 then
        notify(formatTextId(31314, tostring(requestCount)) .. " (" .. tostring(failCount) .. " failed)")
    elseif requestCount > 0 then
        notifyText(31314, tostring(requestCount))
    end
end

local function cancelPendingSelectionExchange()
    pendingSelectionDispatch = nil
    pendingPlanPreview = nil
end

local function executeSwapByIdCode(payload)
    if type(payload) ~= "table" then
        return
    end
    local leftCode = payload.left or payload.leftCode
    local rightCode = payload.right or payload.rightCode
    if not leftCode or not rightCode then
        return
    end
    debugLog("Swap execution event received left=" .. tostring(leftCode) .. " right=" .. tostring(rightCode))
    local keyA, keyB = tostring(leftCode), tostring(rightCode)
    if keyA > keyB then
        keyA, keyB = keyB, keyA
    end
    local pairKey = keyA .. "|" .. keyB
    local completed = completedSwapByPair[pairKey]
    if completed and completed.done then
        debugLog("Swap execution skipped (already completed) pair=" .. tostring(pairKey))
        return
    end

    local left = asComponentId(payload.leftUid or payload.leftObj)
    local right = asComponentId(payload.rightUid or payload.rightObj)
    local rememberedPair = popRememberedSwapPair(leftCode, rightCode)
    if (not left or left == 0) then
        left = rememberedPair and rememberedPair.left or nil
    end
    if (not right or right == 0) then
        right = rememberedPair and rememberedPair.right or nil
    end
    if not left or left == 0 or not right or right == 0 then
        left = resolveShipFromIdCode(leftCode)
        right = resolveShipFromIdCode(rightCode)
    end
    -- Enforce that resolved IDs match the expected pair idcodes before executing.
    local resolvedLeftCode = (left and left ~= 0) and tostring(GetComponentData(left, "idcode") or "") or ""
    local resolvedRightCode = (right and right ~= 0) and tostring(GetComponentData(right, "idcode") or "") or ""
    if resolvedLeftCode ~= tostring(leftCode) then
        left = resolveShipFromIdCode(leftCode)
        resolvedLeftCode = (left and left ~= 0) and tostring(GetComponentData(left, "idcode") or "") or ""
    end
    if resolvedRightCode ~= tostring(rightCode) then
        right = resolveShipFromIdCode(rightCode)
        resolvedRightCode = (right and right ~= 0) and tostring(GetComponentData(right, "idcode") or "") or ""
    end
    debugLog("Swap execution resolved leftCode=" .. tostring(leftCode) .. " leftShip=" .. tostring(left or 0)
        .. " rightCode=" .. tostring(rightCode) .. " rightShip=" .. tostring(right or 0)
        .. " resolvedLeftCode=" .. tostring(resolvedLeftCode) .. " resolvedRightCode=" .. tostring(resolvedRightCode))
    if not left or left == 0 or not right or right == 0 then
        publishPilotExchangeRelease(leftCode, rightCode, left, right)
        publishPilotExchangeRenameState(leftCode, rightCode, false)
        notify("Pilot swap failed: invalid ship IDs for queued exchange.")
        debugLog("Swap execution aborted: invalid IDs left=" .. tostring(leftCode) .. " right=" .. tostring(rightCode))
        return
    end
    if resolvedLeftCode ~= tostring(leftCode) or resolvedRightCode ~= tostring(rightCode) then
        publishPilotExchangeRelease(leftCode, rightCode, left, right)
        publishPilotExchangeRenameState(leftCode, rightCode, false)
        notify("Pilot swap failed: resolved ships do not match queued pair.")
        debugLog("Swap execution aborted: resolved mismatch expected=" .. tostring(leftCode) .. "/" .. tostring(rightCode)
            .. " got=" .. tostring(resolvedLeftCode) .. "/" .. tostring(resolvedRightCode))
        return
    end

    local ok, reason = trySwapCaptains(left, right)
    debugLog("Swap execution result left=" .. tostring(leftCode) .. " right=" .. tostring(rightCode) .. " ok=" .. tostring(ok) .. " reason=" .. tostring(reason))
    local cycleId = payload.cycleId or payload.cycleID or payload.CycleId
    if ok and cycleId and tostring(cycleId) ~= "" then
        if type(AddUITriggeredEvent) == "function" then
            AddUITriggeredEvent("GT_Redistribute", "CycleSwapComplete", {
                cycleId = tostring(cycleId),
                left = tostring(leftCode),
                right = tostring(rightCode),
                leftObj = ConvertStringToLuaID(tostring(left)),
                rightObj = ConvertStringToLuaID(tostring(right)),
            })
        end
        completedSwapByPair[pairKey] = {
            left = tostring(leftCode),
            right = tostring(rightCode),
            done = true,
        }
        publishPostSwapNameRefresh(leftCode, rightCode, left, right)
        schedulePostSwapNameRefreshRetry(leftCode, rightCode, left, right)
        return
    end

    publishPilotExchangeRelease(leftCode, rightCode, left, right)
    schedulePilotExchangeReleaseRetry(leftCode, rightCode, left, right)
    publishPilotExchangeRenameState(leftCode, rightCode, false)
    if ok then
        completedSwapByPair[pairKey] = {
            left = tostring(leftCode),
            right = tostring(rightCode),
            done = true,
        }
        publishPostSwapNameRefresh(leftCode, rightCode, left, right)
        schedulePostSwapNameRefreshRetry(leftCode, rightCode, left, right)
    else
        notify("Pilot swap failed (" .. tostring(reason) .. "): " .. tostring(leftCode) .. " <-> " .. tostring(rightCode))
    end
end

local function handleDockAssignResult(payload)
    local status, leftCode, rightCode, stationCode, reason = nil, nil, nil, nil, nil
    if type(payload) == "table" then
        status = payload.status
        leftCode = payload.left or payload.leftCode
        rightCode = payload.right or payload.rightCode
        stationCode = payload.station or payload.stationCode
        reason = payload.reason
    elseif type(payload) == "string" then
        local a, b, c, d, e = string.match(payload, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)|?(.*)$")
        status, leftCode, rightCode, stationCode, reason = a, b, c, d, e
    end

    if status == "fail" and (not reason or reason == "") then
        reason = stationCode
        stationCode = nil
    end

    if not status or not leftCode or not rightCode then
        debugLog("Dock assignment result ignored: invalid payload")
        return
    end

    local keyA, keyB = tostring(leftCode), tostring(rightCode)
    if keyA > keyB then
        keyA, keyB = keyB, keyA
    end
    local pairKey = keyA .. "|" .. keyB
    local pending = pendingDockAssignmentsByPair[pairKey]
    pendingDockAssignmentsByPair[pairKey] = nil

    if status == "ok" then
        local leftShip = pending and pending.leftShip or resolveShipFromIdCode(leftCode)
        local rightShip = pending and pending.rightShip or resolveShipFromIdCode(rightCode)
        local station = nil
        if stationCode and stationCode ~= "" then
            station = C.ConvertStringTo64Bit(tostring(stationCode))
        end

        rememberSwapPair(leftCode, rightCode, leftShip, rightShip)
        completedSwapByPair[pairKey] = nil
        publishPilotExchangeRenameState(leftCode, rightCode, true)
        debugLog("Queued pilot swap docking orders for " .. tostring(leftCode) .. " <-> " .. tostring(rightCode) .. " station=" .. tostring(stationCode or ""))
        return
    end

    debugLog("Dock assignment failed for " .. tostring(leftCode) .. " <-> " .. tostring(rightCode) .. " reason=" .. tostring(reason or "unknown"))
end

local function requestFreshPilotDataAndRedistributeSelection(triggerComponent)
    local trigger = asComponentId(triggerComponent)
    logPilotExchangeMenu("requestFreshPilotDataAndRedistributeSelection trigger="
        .. tostring(GetComponentData(trigger, "idcode") or trigger or "nil"))
    if not trigger or trigger == 0 then
        notifyText(31311)
        return
    end
    if not Mods or not Mods.GalaxyTrader or not Mods.GalaxyTrader.PilotData or type(Mods.GalaxyTrader.PilotData.requestRefresh) ~= "function" then
        notify("Pilot exchange unavailable: GT pilot data bridge missing.")
        debugLog("Cannot refresh GT pilot data for selection exchange: Mods.GalaxyTrader.PilotData.requestRefresh unavailable")
        return
    end

    pendingRedistributeSelection = trigger
    pendingRedistributeCommander = nil
    pendingRedistributeFleet = false
    pilotDataRefreshRequestedAt = getElapsedTime()
    invalidatePilotIndexCache()
    Mods.GalaxyTrader.PilotData.requestRefresh()
    debugLog("Requested fresh GT pilot data for selection exchange trigger " .. tostring(GetComponentData(trigger, "idcode") or "UNKNOWN"))
end

local function requestFreshPilotDataAndRedistributeFleet(hqComponent)
    local hq = asComponentId(hqComponent)
    logPilotExchangeMenu("requestFreshPilotDataAndRedistributeFleet hq="
        .. tostring(GetComponentData(hq, "idcode") or hq or "nil"))
    if not hq or hq == 0 then
        notifyText(31311)
        return
    end
    if not Mods or not Mods.GalaxyTrader or not Mods.GalaxyTrader.PilotData or type(Mods.GalaxyTrader.PilotData.requestRefresh) ~= "function" then
        notify("Pilot exchange unavailable: GT pilot data bridge missing.")
        debugLog("Cannot refresh GT pilot data for fleet exchange: Mods.GalaxyTrader.PilotData.requestRefresh unavailable")
        return
    end

    if pilotDataCacheIsFresh() then
        logPilotExchangeMenu("fleet exchange: reusing fresh pilot data (age="
            .. tostring(string.format("%.1f", getElapsedTime() - (Mods.GalaxyTrader.PilotData.getLastUpdate() or 0)))
            .. "s)")
        redistributeAllGtShips()
        return
    end

    pendingRedistributeFleet = true
    pendingRedistributeSelection = false
    pendingRedistributeCommander = nil
    pilotDataRefreshRequestedAt = getElapsedTime()
    invalidatePilotIndexCache()
    Mods.GalaxyTrader.PilotData.requestRefresh()
    debugLog("Requested fresh GT pilot data for fleet exchange from HQ " .. tostring(GetComponentData(hq, "idcode") or "UNKNOWN"))
end

local function requestFreshPilotDataAndRedistribute(commanderComponent)
    local commander = asComponentId(commanderComponent)
    if not commander or commander == 0 then
        return
    end
    if not Mods or not Mods.GalaxyTrader or not Mods.GalaxyTrader.PilotData or type(Mods.GalaxyTrader.PilotData.requestRefresh) ~= "function" then
        notify("Pilot redistribution unavailable: GT pilot data bridge missing.")
        debugLog("Cannot refresh GT pilot data: Mods.GalaxyTrader.PilotData.requestRefresh unavailable")
        return
    end

    pendingRedistributeCommander = commander
    pendingRedistributeSelection = false
    pendingRedistributeFleet = false
    pilotDataRefreshRequestedAt = getElapsedTime()
    invalidatePilotIndexCache()
    Mods.GalaxyTrader.PilotData.requestRefresh()
    debugLog("Requested fresh GT pilot data for redistribution commander " .. tostring(GetComponentData(commander, "idcode") or "UNKNOWN"))
end

local function processPendingRedistributeAfterRefresh()
    if not pendingRedistributeCommander then
        return
    end
    local now = getElapsedTime()
    if (pilotDataRefreshRequestedAt > 0) and (now - pilotDataRefreshRequestedAt > PILOT_DATA_REFRESH_TIMEOUT) then
        debugLog("GT pilot data refresh timeout for redistribution")
        pendingRedistributeCommander = nil
        pendingRedistributeSelection = false
        pendingRedistributeFleet = false
        pilotDataRefreshRequestedAt = 0
    end
end

local function processPendingReleaseRetries()
    if #pendingReleaseRetries == 0 then
        return
    end
    local now = getElapsedTime()
    for i = #pendingReleaseRetries, 1, -1 do
        local item = pendingReleaseRetries[i]
        if item and now >= (item.dueAt or 0) then
            publishPilotExchangeRelease(item.left, item.right, item.leftShip, item.rightShip)
            item.attemptsLeft = (item.attemptsLeft or 0) - 1
            if item.attemptsLeft > 0 then
                item.dueAt = now + 2.0
                pendingReleaseRetries[i] = item
                debugLog("ReleaseDockHold retry scheduled left=" .. tostring(item.left) .. " right=" .. tostring(item.right) .. " remaining=" .. tostring(item.attemptsLeft))
            else
                table.remove(pendingReleaseRetries, i)
                debugLog("ReleaseDockHold retries completed left=" .. tostring(item.left) .. " right=" .. tostring(item.right))
            end
        end
    end
end

local function processPendingPostSwapRefreshRetries()
    if #pendingPostSwapRefreshRetries == 0 then
        return
    end
    local now = getElapsedTime()
    for i = #pendingPostSwapRefreshRetries, 1, -1 do
        local item = pendingPostSwapRefreshRetries[i]
        if item and now >= (item.dueAt or 0) then
            publishPostSwapNameRefresh(item.left, item.right, item.leftShip, item.rightShip)
            item.attemptsLeft = (item.attemptsLeft or 0) - 1
            if item.attemptsLeft > 0 then
                item.dueAt = now + 1.5
                pendingPostSwapRefreshRetries[i] = item
                debugLog("PostSwapNameRefresh retry scheduled left=" .. tostring(item.left) .. " right=" .. tostring(item.right) .. " remaining=" .. tostring(item.attemptsLeft))
            else
                table.remove(pendingPostSwapRefreshRetries, i)
                debugLog("PostSwapNameRefresh retries completed left=" .. tostring(item.left) .. " right=" .. tostring(item.right))
            end
        end
    end
end

if menu and menu.update then
    local originalUpdate = menu.update
    menu.update = function(...)
        originalUpdate(...)
        processPendingRedistributeAfterRefresh()
        processPendingReleaseRetries()
        processPendingPostSwapRefreshRetries()
    end
end

function onUpdate()
    processPendingRedistributeAfterRefresh()
    tickDirectSwapQueue()
    processPendingReleaseRetries()
    processPendingPostSwapRefreshRetries()
end
SetScript("onUpdate", onUpdate)

if menu then
    RegisterEvent("interact", function()
        logMapSelectionState("interact")
    end)
    RegisterEvent("updateselectedcomponents", function()
        logMapSelectionState("updateselectedcomponents")
    end)
end

RegisterEvent("gt.pilotExchangeStationPreviewReady", function()
    debugLog("Station preview ready for pilot exchange plan overlay")
    if not openPlanPreviewWithRendezvous() then
        pendingSelectionDispatch = nil
        notifyText(31313)
    end
end)

RegisterEvent("gt.redistributePilots", function(_, commanderComponent)
    requestFreshPilotDataAndRedistribute(commanderComponent)
end)

RegisterEvent("gt.redistributePilotsSelection", function(_, triggerComponent)
    logPilotExchangeMenu("gt.redistributePilotsSelection event received trigger="
        .. tostring(triggerComponent))
    requestFreshPilotDataAndRedistributeSelection(triggerComponent)
end)

RegisterEvent("gt.redistributePilotsFleet", function(_, hqComponent)
    logPilotExchangeMenu("gt.redistributePilotsFleet event received hq="
        .. tostring(hqComponent))
    requestFreshPilotDataAndRedistributeFleet(hqComponent)
end)

GT_PilotExchangePlan = GT_PilotExchangePlan or {}
GT_PilotExchangePlan.onAccept = dispatchPendingSelectionExchange
GT_PilotExchangePlan.onCancel = cancelPendingSelectionExchange
GT_PilotExchangePlan.hasPending = function()
    return pendingSelectionDispatch ~= nil or pendingPlanPreview ~= nil
end
debugLog("Pilot exchange plan handlers registered")

RegisterEvent("GT_PilotData.Update", function()
    invalidatePilotIndexCache()
    if pendingRedistributeFleet then
        pendingRedistributeFleet = false
        pendingRedistributeSelection = false
        pendingRedistributeCommander = nil
        pilotDataRefreshRequestedAt = 0
        redistributeAllGtShips()
        return
    end
    if pendingRedistributeSelection and pendingRedistributeSelection ~= 0 then
        local trigger = pendingRedistributeSelection
        pendingRedistributeSelection = false
        pendingRedistributeCommander = nil
        pilotDataRefreshRequestedAt = 0
        redistributeSelection(trigger)
        return
    end
    if pendingRedistributeCommander and pendingRedistributeCommander ~= 0 then
        local commander = pendingRedistributeCommander
        pendingRedistributeCommander = nil
        pilotDataRefreshRequestedAt = 0
        redistribute(commander)
    end
end)

RegisterEvent("gt.redistributeDockAssignResult", function(a, b, c, d)
    local payload = nil
    local args = { a, b, c, d }
    for _, v in ipairs(args) do
        if type(v) == "table" and (v.status or v.left or v.right or v.leftCode or v.rightCode) then
            payload = v
            break
        end
    end
    if not payload then
        for _, v in ipairs(args) do
            if type(v) == "string" and string.find(v, "|", 1, true) then
                payload = v
                break
            end
        end
    end
    if payload then
        handleDockAssignResult(payload)
    else
        debugLog("Dock assignment result event missing payload")
    end
end)

RegisterEvent("gt.redistributeOrderCancelled", function(_, idcode)
    clearPendingRedistributionForShip(idcode)
end)

RegisterEvent("gt.executePilotSwap", function(a, b, c, d)
    local payload = nil
    local args = { a, b, c, d }
    for _, v in ipairs(args) do
        if type(v) == "table" and (v.left or v.right or v.leftCode or v.rightCode) then
            payload = v
            break
        end
    end
    if not payload then
        for _, v in ipairs(args) do
            if type(v) == "string" and string.find(v, "|", 1, true) then
                local left, right, leftUid, rightUid = string.match(v, "^([^|]+)|([^|]+)|([^|]*)|([^|]*)$")
                if left and right and left ~= "" and right ~= "" then
                    payload = {
                        left = left,
                        right = right,
                        leftCode = left,
                        rightCode = right,
                        leftUid = leftUid,
                        rightUid = rightUid,
                    }
                    break
                end
                left, right = string.match(v, "^([^|]+)|([^|]+)$")
                if left and right and left ~= "" and right ~= "" then
                    payload = {
                        left = left,
                        right = right,
                        leftCode = left,
                        rightCode = right,
                    }
                    break
                end
            end
        end
    end
    if not payload then
        for _, v in ipairs(args) do
            if type(v) == "string" then
                local left = string.match(v, "left%s*=%s*([A-Z0-9%-]+)")
                local right = string.match(v, "right%s*=%s*([A-Z0-9%-]+)")
                if left and right and left ~= "" and right ~= "" then
                    payload = {
                        left = left,
                        right = right,
                        leftCode = left,
                        rightCode = right,
                    }
                    break
                end
            end
        end
    end
    if not payload then
        debugLog("Swap execution event payload missing/invalid argTypes="
            .. tostring(type(a)) .. "," .. tostring(type(b)) .. ","
            .. tostring(type(c)) .. "," .. tostring(type(d))
            .. " firstArg=" .. tostring(a))
        return
    end
    executeSwapByIdCode(payload)
end)

debugLog("Redistribution context integration loaded")
