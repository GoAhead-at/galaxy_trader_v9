-- GalaxyTrader MK2 - Ware exchange queue bridge
-- Resolves internal-transfer deals via GetWareExchangeTradeList and queues them
-- with AddTradeToShipQueue (buy legs first, then sell), matching normal MK2 flow.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    const char* ConvertIDToString(uint64_t componentid);
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

local function prepareVirtualCargo(shipId, stationId)
    if shipId ~= 0 then
        local numTradeComputerTrades = 0
        pcall(function()
            numTradeComputerTrades = tonumber(C.GetNumTradeComputerOrders(shipId)) or 0
        end)
        SetVirtualCargoMode(shipId, true, numTradeComputerTrades > 0 and numTradeComputerTrades or -1)
    end
    if stationId ~= 0 then
        local operational = true
        pcall(function()
            operational = C.IsComponentOperational(stationId)
        end)
        if operational then
            SetVirtualCargoMode(stationId, true, -1)
        end
    end
end

local function offerMatchesDirection(tradeData, wantPickup)
    if wantPickup then
        return tradeData.isselloffer == true
    end
    return tradeData.isbuyoffer == true
end

local function canQueueOffer(tradeData, shipId, amount)
    if tradeData == nil or tradeData.id == nil then
        return false
    end
    local minAmount = tonumber(tradeData.minamount) or 1
    local queueAmount = tonumber(amount) or 0
    if queueAmount < minAmount then
        return false
    end
    local ok, canTrade = pcall(function()
        return CanTradeWith(tradeData.id, shipId, minAmount)
    end)
    if ok then
        return canTrade
    end
    return true
end

local function resolveWareExchangeLeg(shipId, leg)
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

    prepareVirtualCargo(shipId, stationId)

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
                if canQueueOffer(tradeData, shipId, amount) then
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

local function writeResult(playerId, result)
    SetNPCBlackboard(playerId, "$GT_MK2_WareExchangeResult", result)
end

RegisterEvent("gt.mk2QueueWareExchange", function(_, requestId)
    local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    local request = GetNPCBlackboard(playerId, "$GT_MK2_WareExchangeRequest")
    local result = {
        RequestId = requestId,
        Success = false,
        Queued = 0,
        Error = "missing request",
        QueueLegs = {},
    }

    if type(request) ~= "table" then
        writeResult(playerId, result)
        return
    end

    local reqId = request.RequestId or request["$RequestId"]
    if reqId ~= requestId then
        result.Error = "request id mismatch"
        writeResult(playerId, result)
        return
    end

    local shipId = resolveShipId(request.Ship or request["$Ship"], request.ShipIdCode or request["$ShipIdCode"])
    if shipId == 0 then
        result.Error = "invalid ship"
        writeResult(playerId, result)
        SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
        return
    end

    local legs = collectLegs(request.Legs or request["$Legs"])
    if #legs == 0 then
        result.Error = "missing legs"
        writeResult(playerId, result)
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

    local queueLegs = {}
    local function resolveAndQueueBatch(batch)
        for _, leg in ipairs(batch) do
            local offerId, err = resolveWareExchangeLeg(shipId, leg)
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

    local err = resolveAndQueueBatch(pickups)
    if err then
        result.Error = err
        writeResult(playerId, result)
        SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
        debugLog(result.Error)
        return
    end

    err = resolveAndQueueBatch(delivers)
    if err then
        result.Error = err
        writeResult(playerId, result)
        SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
        debugLog(result.Error)
        return
    end

    result.Success = true
    result.Queued = #queueLegs
    result.Error = ""
    result.QueueLegs = queueLegs
    writeResult(playerId, result)
    SignalObject(shipId, "gt_mk2_ware_exchange_done", requestId)
    debugLog("queued " .. tostring(#queueLegs) .. " ware-exchange legs for " .. tostring(requestId))
end)
