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
]]

local GT_ORDER_IDS = {
    GalaxyTraderMK1 = true,
    GalaxyTraderMK2 = true,
    GalaxyTraderMK3 = true,
    GalaxyTraderMK4Supply = true,
    GalaxyMiner = true,
}

local function debugLog(msg)
    DebugError("[GT Redistribute] " .. tostring(msg))
end

local function notify(msg)
    debugLog(msg)
end

local menu = Helper.getMenu("MapMenu")
local pendingRedistributeCommander = nil
local pilotDataRefreshRequestedAt = 0
local PILOT_DATA_REFRESH_TIMEOUT = 5.0
local pendingSwapShipsByPair = {}
local completedSwapByPair = {}
local pendingDockAssignmentsByPair = {}
local pendingReleaseRetries = {}
local pendingPostSwapRefreshRetries = {}
local pilotIndexCacheByShipId = nil

local function invalidatePilotIndexCache()
    pilotIndexCacheByShipId = nil
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
end

local function sendDockingLogbookMessage(leftShip, rightShip, station)
    if type(AddUITriggeredEvent) ~= "function" then
        debugLog("Logbook emit skipped: AddUITriggeredEvent unavailable")
        return
    end
    local leftName = GetComponentData(leftShip, "name") or "Unknown Ship"
    local rightName = GetComponentData(rightShip, "name") or "Unknown Ship"
    local leftCode = GetComponentData(leftShip, "idcode") or "UNK"
    local rightCode = GetComponentData(rightShip, "idcode") or "UNK"
    local stationName = GetComponentData(station, "name") or "Unknown Station"
    local stationCode = GetComponentData(station, "idcode") or "UNK"

    local title = ReadText(77000, 3120)
    local template = ReadText(77000, 3121) or ""
    local values = {
        tostring(leftName), tostring(leftCode),
        tostring(rightName), tostring(rightCode),
        tostring(stationName), tostring(stationCode),
    }
    local message = tostring(template):gsub("%%(%d+)", function(idx)
        local n = tonumber(idx)
        if n and values[n] ~= nil then
            return values[n]
        end
        return "%" .. tostring(idx)
    end)

    AddUITriggeredEvent("GT_Redistribute", "Logbook", {
        title = title,
        message = message,
    })
    debugLog("Logbook emit queued for " .. tostring(leftCode) .. " <-> " .. tostring(rightCode) .. " at " .. tostring(stationCode))
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

local function shipHasActiveOrQueuedPilotExchangeOrder(ship)
    local shipId = asComponentId(ship)
    if not shipId or shipId == 0 then
        return false
    end

    local numOrders = tonumber(C.GetNumOrders(shipId) or 0) or 0
    if numOrders <= 0 then
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
            if callerId == "DockAndPilotExchange" then
                return true
            end
        end
    end

    return false
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

local function isShipPilotBlocked(pilotData)
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
        if string.find(statusUpper, "ADVANCE", 1, true) or string.find(statusUpper, "[BL]", 1, true) then
            return true, "status_" .. tostring(pilotData.status)
        end
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

local function collectFleetShips(commanderComponent)
    local commander = ConvertIDTo64Bit(commanderComponent)
    local ships = {}
    local seen = {}
    local pilotIndex = getGTPilotIndexByShipId()

    local function addShip(ship)
        ship = asComponentId(ship)
        if ship and ship ~= 0 and not seen[tostring(ship)] then
            local pilot = GetComponentData(ship, "assignedpilot")
            local order = getDefaultOrderId(ship)
            local commanderOrder = nil
            local isCommander = (ship == commander)
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
                    if shipHasActiveOrQueuedPilotExchangeOrder(ship) then
                        debugLog("Fleet ship ignored: " .. tostring(idcode) .. " reason=active_or_queued_pilot_exchange_order")
                        return
                    end
                    if isShipInPendingRedistribution(ship, idcode) then
                        debugLog("Fleet ship ignored: " .. tostring(idcode) .. " reason=pending_pilot_exchange")
                        return
                    end
                    local pilotData = getGTPilotDataByShip(ship, pilotIndex)
                    local isBlocked, blockedReason = isShipPilotBlocked(pilotData)
                    if isBlocked then
                        debugLog("Fleet ship ignored: " .. tostring(idcode) .. " reason=pilot_blocked detail=" .. tostring(blockedReason or "unknown"))
                        return
                    end
                    local gtLevel = getGTLevelByShip(ship, pilotIndex)
                    if gtLevel then
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
                        })
                        seen[tostring(ship)] = true
                    else
                        debugLog("Fleet ship ignored: " .. tostring(idcode)
                            .. " reason=missing_GT_level order=" .. tostring(order or "NONE")
                            .. " commanderOrder=" .. tostring(commanderOrder or "NONE"))
                    end
                end
            else
                local idcode = GetComponentData(ship, "idcode") or "UNK"
                debugLog("Fleet ship ignored: " .. tostring(idcode)
                    .. " pilot=" .. tostring(pilot ~= nil)
                    .. " gtControlled=" .. tostring(isGTControlled)
                    .. " order=" .. tostring(order or "NONE")
                    .. " commanderOrder=" .. tostring(commanderOrder or "NONE"))
            end
        end
    end

    addShip(commanderComponent)
    local subs = GetSubordinates(commander) or {}
    for _, sub in ipairs(subs) do
        addShip(sub)
    end
    return ships
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

local function trySwapCaptains(leftShip, rightShip)
    local emptyA = ffi.new("NPCSeed[1]")
    local emptyB = ffi.new("NPCSeed[1]")
    debugLog("PerformCrewExchange2 check leftShip=" .. tostring(leftShip) .. " rightShip=" .. tostring(rightShip))
    local check = C.PerformCrewExchange2(leftShip, rightShip, emptyA, 0, emptyB, 0, 0, 0, true, true)
    local checkReason = check.reason and ffi.string(check.reason) or ""
    debugLog("PerformCrewExchange2 check result leftShip=" .. tostring(leftShip) .. " rightShip=" .. tostring(rightShip) .. " reason=" .. tostring(checkReason))
    if checkReason ~= "" then
        return false, checkReason
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
    for _, swap in ipairs(swaps) do
        local leftCode = GetComponentData(swap.left, "idcode") or "LEFT"
        local rightCode = GetComponentData(swap.right, "idcode") or "RIGHT"
        local assigned = requestDockOrdersFromMD(swap.left, swap.right, leftCode, rightCode)
        if assigned then
            local keyA, keyB = tostring(leftCode), tostring(rightCode)
            if keyA > keyB then
                keyA, keyB = keyB, keyA
            end
            pendingDockAssignmentsByPair[keyA .. "|" .. keyB] = {
                left = keyA,
                right = keyB,
                leftShip = swap.left,
                rightShip = swap.right,
            }
            requestCount = requestCount + 1
            debugLog("Dock assignment requested for " .. tostring(leftCode) .. " <-> " .. tostring(rightCode))
        else
            failCount = failCount + 1
            debugLog("Swap queue failed: could not request MD dock assignment")
        end
    end

    notify("Pilot redistribution dispatch started. Pairs: " .. tostring(requestCount) .. " requested, " .. tostring(failCount) .. " failed.")
    debugLog("Redistribution dispatch for commander " .. tostring(GetComponentData(commander, "idcode") or "UNKNOWN") .. " planned=" .. tostring(#swaps) .. " requested=" .. tostring(requestCount) .. " failed=" .. tostring(failCount))
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
        notify("Pilot swap executed: " .. tostring(leftCode) .. " <-> " .. tostring(rightCode))
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
        if leftShip and leftShip ~= 0 and rightShip and rightShip ~= 0 and station and station ~= 0 then
            sendDockingLogbookMessage(leftShip, rightShip, station)
        end
        debugLog("Queued pilot swap docking orders for " .. tostring(leftCode) .. " <-> " .. tostring(rightCode) .. " station=" .. tostring(stationCode or ""))
        return
    end

    debugLog("Dock assignment failed for " .. tostring(leftCode) .. " <-> " .. tostring(rightCode) .. " reason=" .. tostring(reason or "unknown"))
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
        debugLog("GT pilot data refresh timeout for redistribution commander " .. tostring(GetComponentData(pendingRedistributeCommander, "idcode") or "UNKNOWN"))
        pendingRedistributeCommander = nil
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

RegisterEvent("gt.redistributePilots", function(_, commanderComponent)
    requestFreshPilotDataAndRedistribute(commanderComponent)
end)

RegisterEvent("GT_PilotData.Update", function()
    invalidatePilotIndexCache()
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
