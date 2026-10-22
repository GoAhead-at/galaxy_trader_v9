-- GalaxyTrader MK2 - Ware exchange queue bridge
-- Resolves internal-transfer deals via GetWareExchangeTradeList and queues them
-- with AddTradeToShipQueue (buy legs first, then sell), matching normal MK2 flow.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    bool IsComponentOperational(uint64_t componentid);
    uint32_t GetNumAllFactionShips(const char* factionid);
    uint32_t GetAllFactionShips(UniverseID* result, uint32_t resultlen, const char* factionid);
    uint32_t GetNumAllFactionStations(const char* factionid);
    uint32_t GetAllFactionStations(UniverseID* result, uint32_t resultlen, const char* factionid);
]]

local DEBUG = false

local function debugLog(msg)
    if DEBUG then
        DebugError("[GT-MK2-WX] " .. tostring(msg))
    end
end

local function legField(leg, key)
    if leg == nil then
        return nil
    end
    local v = leg[key]
    if v ~= nil then
        return v
    end
    return leg["$" .. key]
end

local function toId64(value)
    if value == nil then
        return 0
    end
    if type(value) == "number" then
        return value
    end
    return ConvertStringTo64Bit(tostring(value))
end

local function componentIdCode(componentId)
    if componentId == nil or componentId == 0 then
        return nil
    end
    local ok, code = pcall(function()
        return GetComponentData(componentId, "idcode")
    end)
    if ok and code and code ~= "" then
        return tostring(code)
    end
    return nil
end

local function resolveByIdCode(idcode, listFn, countFn)
    if idcode == nil or idcode == "" then
        return 0
    end
    local code = tostring(idcode)
    local count = countFn("player")
    if not count or count <= 0 then
        return 0
    end
    local ids = ffi.new("UniverseID[?]", count)
    local found = listFn(ids, count, "player")
    for i = 0, found - 1 do
        local candidate = ids[i]
        if candidate and candidate ~= 0 then
            local candidateCode = componentIdCode(candidate)
            if candidateCode == code then
                return candidate
            end
        end
    end
    return 0
end

local function resolveShipId(shipRef, shipIdCode)
    if shipRef ~= nil then
        local id = toId64(shipRef)
        if id ~= 0 and componentIdCode(id) then
            return id
        end
    end
    if shipIdCode then
        local id = resolveByIdCode(shipIdCode, C.GetAllFactionShips, C.GetNumAllFactionShips)
        if id ~= 0 then
            return id
        end
    end
    return 0
end

local function resolveStationId(leg)
    local stationRef = legField(leg, "Station")
    if stationRef ~= nil then
        local id = toId64(stationRef)
        if id ~= 0 and componentIdCode(id) then
            return id
        end
    end
    local stationCode = legField(leg, "StationId")
    if stationCode then
        local id = resolveByIdCode(stationCode, C.GetAllFactionStations, C.GetNumAllFactionStations)
        if id ~= 0 then
            return id
        end
    end
    return 0
end

local function normalizeWareToken(value)
    if value == nil then
        return nil
    end
    local text = string.lower(tostring(value))
    text = string.gsub(text, "^ware%.", "")
    text = string.gsub(text, "%s+", "")
    return text
end

local function wareKey(ware)
    if ware == nil then
        return nil
    end
    if type(ware) == "string" then
        return normalizeWareToken(ware)
    end
    local ok, id = pcall(function()
        return ConvertIDToString(ware)
    end)
    if ok and id and id ~= "" then
        return normalizeWareToken(id)
    end
    return normalizeWareToken(tostring(ware))
end

local function collectWareKeys(ware)
    local keys = {}
    local function add(value)
        local token = normalizeWareToken(value)
        if token and token ~= "" then
            keys[token] = true
        end
    end

    if ware == nil then
        return keys
    end

    add(wareKey(ware))
    if type(ware) == "string" then
        add(ware)
    else
        local ok, id = pcall(function()
            return ConvertIDToString(ware)
        end)
        if ok then
            add(id)
        end
    end

    pcall(function()
        add(GetWareData(ware, "name"))
    end)

    return keys
end

local function legsMatchWare(tradeData, reqWare)
    if tradeData == nil or tradeData.ware == nil or reqWare == nil then
        return false
    end
    if tradeData.ware == reqWare then
        return true
    end
    local reqKeys = collectWareKeys(reqWare)
    local offerKeys = collectWareKeys(tradeData.ware)
    for key, _ in pairs(reqKeys) do
        if offerKeys[key] then
            return true
        end
    end
    return false
end

local function collectLegs(legs)
    local items = {}
    if type(legs) ~= "table" then
        return items
    end
    for i = 1, #legs do
        if legs[i] then
            table.insert(items, legs[i])
        end
    end
    if #items == 0 then
        for _, leg in pairs(legs) do
            if type(leg) == "table" then
                table.insert(items, leg)
            end
        end
    end
    return items
end

local function isOperational(componentId)
    local operational = true
    pcall(function()
        operational = C.IsComponentOperational(componentId)
    end)
    return operational
end

-- Virtual cargo mode makes cargo reads (incl. the player's cargo UI) report the state after all
-- queued trades. Vanilla menus pair every enable with a disable; every component enabled here is
-- recorded in `touched` so the request handler can switch it back off on every exit path.
local function markTouched(touched, componentId)
    local key = tostring(componentId)
    if not touched.seen[key] then
        touched.seen[key] = true
        table.insert(touched.ids, componentId)
    end
end

local function prepareVirtualCargo(shipId, stationId, touched)
    if shipId ~= 0 then
        -- -1 = predict over the whole trade queue, so deliver legs see pickups queued earlier
        -- in this request (vanilla only limits it to trade-computer orders for immediate trades).
        SetVirtualCargoMode(shipId, true, -1)
        markTouched(touched, shipId)
    end
    if stationId ~= 0 and isOperational(stationId) then
        SetVirtualCargoMode(stationId, true, -1)
        markTouched(touched, stationId)
    end
end

local function restoreVirtualCargo(touched)
    for _, componentId in ipairs(touched.ids) do
        if isOperational(componentId) then
            local ok, err = pcall(SetVirtualCargoMode, componentId, false)
            if not ok then
                debugLog("virtual cargo restore failed for " .. tostring(componentId) .. ": " .. tostring(err))
            end
        end
    end
    touched.ids = {}
    touched.seen = {}
end

local function offerMatchesDirection(tradeData, wantPickup)
    if wantPickup then
        return tradeData.isselloffer == true
    end
    return tradeData.isbuyoffer == true
end

local function canQueueOffer(tradeData, shipId, amount, wantPickup)
    if tradeData == nil or tradeData.id == nil then
        return false
    end
    local minAmount = tonumber(tradeData.minamount) or 1
    local queueAmount = tonumber(amount) or 0
    if queueAmount < minAmount then
        return false
    end
    -- Deliver is resolved after pickup is queued, but TradePerform has not run, so the
    -- physical hold is still empty. Vanilla CanTradeWith on a station buy offer requires
    -- the ware already aboard (map UI greys it out). MD already validated dest gap / dock / lane.
    if not wantPickup then
        return true
    end
    local ok, canTrade = pcall(function()
        return CanTradeWith(tradeData.id, shipId, minAmount)
    end)
    if ok then
        return canTrade
    end
    return true
end

local function resolveWareExchangeLeg(shipId, leg, touched)
    local stationId = resolveStationId(leg)
    local amount = tonumber(legField(leg, "Amount")) or 0
    local reqWare = legField(leg, "Ware") or legField(leg, "WareName")
    local direction = legField(leg, "Direction")
    if shipId == 0 or stationId == 0 or amount <= 0 then
        return nil, "invalid leg (ship=" .. tostring(shipId)
            .. " station=" .. tostring(stationId)
            .. " amount=" .. tostring(amount)
            .. " dir=" .. tostring(direction)
            .. " stationId=" .. tostring(legField(leg, "StationId")) .. ")"
    end

    prepareVirtualCargo(shipId, stationId, touched)

    local offers = GetWareExchangeTradeList(shipId, stationId) or {}
    local wantPickup = (direction == "pickup")
    local offerCount = 0
    local wareHits = 0
    local directionHits = 0

    for _, tradeData in pairs(offers) do
        offerCount = offerCount + 1
        if legsMatchWare(tradeData, reqWare) then
            wareHits = wareHits + 1
            if offerMatchesDirection(tradeData, wantPickup) then
                directionHits = directionHits + 1
                if canQueueOffer(tradeData, shipId, amount, wantPickup) then
                    return tradeData.id, nil
                end
            end
        end
    end

    local wantDir = wantPickup and "pickup" or "deliver"
    return nil, "no ware exchange " .. wantDir .. " match for " .. tostring(wareKey(reqWare))
        .. " (offers=" .. tostring(offerCount) .. ", wareHits=" .. tostring(wareHits)
        .. ", directionHits=" .. tostring(directionHits) .. ")"
end

local function queueResolvedLeg(shipId, offerId, amount)
    AddTradeToShipQueue(ConvertStringToLuaID(tostring(offerId)), shipId, amount, false)
end

local function writeResult(entityId, result)
    SetNPCBlackboard(entityId, "$GT_MK2_WareExchangeResult", result)
end

-- MD raises this with the requesting pilot entity; request and result live on that entity's
-- blackboard, so concurrent ships never share a mailbox.
RegisterEvent("gt.mk2QueueWareExchange", function(_, entity)
    local entityId = entity and ConvertIDTo64Bit(entity) or 0
    if entityId == 0 then
        debugLog("missing requesting entity")
        return
    end
    local request = GetNPCBlackboard(entityId, "$GT_MK2_WareExchangeRequest")
    if type(request) ~= "table" then
        -- Caller already timed out and removed its request; nobody is waiting.
        debugLog("missing request on entity " .. tostring(entityId))
        return
    end

    local requestId = request.RequestId or request["$RequestId"]
    local previous = GetNPCBlackboard(entityId, "$GT_MK2_WareExchangeResult")
    if type(previous) == "table" and (previous.RequestId or previous["$RequestId"]) == requestId then
        -- Already answered: a second event for the same request must not queue the legs twice.
        return
    end

    local result = {
        RequestId = requestId,
        Success = false,
        Queued = 0,
        Error = "",
        QueueLegs = {},
    }

    local shipId = resolveShipId(request.Ship or request["$Ship"], request.ShipIdCode or request["$ShipIdCode"])
    if shipId == 0 then
        result.Error = "invalid ship"
        writeResult(entityId, result)
        debugLog(result.Error)
        return
    end

    local legs = collectLegs(request.Legs or request["$Legs"])
    if #legs == 0 then
        result.Error = "missing legs"
        writeResult(entityId, result)
        SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
        return
    end

    local pickups = {}
    local delivers = {}
    for _, leg in ipairs(legs) do
        local direction = legField(leg, "Direction")
        if direction == "pickup" then
            table.insert(pickups, leg)
        elseif direction == "deliver" then
            table.insert(delivers, leg)
        end
    end

    -- Queue pickups first so dest GetWareExchangeTradeList / virtual cargo can see the inbound ware.
    -- Deliver still skips CanTradeWith (physical hold is empty until TradePerform runs).
    -- If deliver then fails, return error with whatever was queued; MK2 deny cancels leftover
    -- TradePerform so a pickup-only cycle cannot run.
    local queueLegs = {}
    local touched = { ids = {}, seen = {} }
    local function resolveAndQueueBatch(batch)
        for _, leg in ipairs(batch) do
            local offerId, err = resolveWareExchangeLeg(shipId, leg, touched)
            if not offerId then
                return err or "resolve failed"
            end
            local amount = tonumber(legField(leg, "Amount")) or 0
            queueResolvedLeg(shipId, offerId, amount)
            table.insert(queueLegs, {
                Direction = legField(leg, "Direction"),
                Amount = amount,
                TradeOffer = offerId,
            })
        end
        return nil
    end

    local function fail(err)
        result.Error = err
        result.Queued = #queueLegs
        result.QueueLegs = queueLegs
        writeResult(entityId, result)
        SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
        debugLog(result.Error)
    end

    -- Virtual cargo stays on for the whole request (deliver resolution needs the predicted
    -- inbound from the queued pickups) and is restored before the result is published, on
    -- success, resolve failure and Lua error alike.
    local ok, err = pcall(function()
        local batchErr = resolveAndQueueBatch(pickups)
        if batchErr then
            return batchErr
        end
        return resolveAndQueueBatch(delivers)
    end)
    restoreVirtualCargo(touched)
    if not ok then
        fail("lua error: " .. tostring(err))
        return
    end
    if err then
        fail(err)
        return
    end

    result.Success = true
    result.Queued = #queueLegs
    result.Error = ""
    result.QueueLegs = queueLegs
    writeResult(entityId, result)
    SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
    debugLog("queued " .. tostring(#queueLegs) .. " ware-exchange legs for " .. tostring(requestId))
end)
