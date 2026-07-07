--[[
GalaxyTrader MK3 - MD/Lua player bridge helpers
Use LuaID for SetNPCBlackboard / GetNPCBlackboard, 64-bit UniverseID for SignalObject.
]]

local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
    UniverseID GetPlayerID(void);
    uint64_t ConvertStringTo64Bit(const char* idcode);
]]

local GT_PlayerBridge = {}

function GT_PlayerBridge.GetPlayerBlackboardId()
    return ConvertStringToLuaID(tostring(C.GetPlayerID()))
end

function GT_PlayerBridge.GetPlayerSignalId()
    return ConvertStringTo64Bit(tostring(C.GetPlayerID()))
end

local function ModProbeCacheKey(shipIdCode)
    local idCode = shipIdCode or "UNKNOWN"
    if string.sub(idCode, 1, 1) == "$" then
        return idCode
    end
    return "$" .. idCode
end

function GT_PlayerBridge.StoreModProbeByIdCode(shipIdCode, shipWare, engineWare, shipNonGT, engineNonGT)
    local cacheKey = ModProbeCacheKey(shipIdCode)
    local playerBbId = GT_PlayerBridge.GetPlayerBlackboardId()
    local cache = GetNPCBlackboard(playerBbId, "$GT_ModProbeByShip")
    if type(cache) ~= "table" then
        cache = {}
    end
    cache[cacheKey] = {
        ShipWare = shipWare or "none",
        EngineWare = engineWare or "none",
        ShipNonGT = shipNonGT and 1 or 0,
        EngineNonGT = engineNonGT and 1 or 0,
    }
    SetNPCBlackboard(playerBbId, "$GT_ModProbeByShip", cache)
end

function GT_PlayerBridge.ClearModProbeByIdCode(shipIdCode)
    local cacheKey = ModProbeCacheKey(shipIdCode)
    local playerBbId = GT_PlayerBridge.GetPlayerBlackboardId()
    local cache = GetNPCBlackboard(playerBbId, "$GT_ModProbeByShip")
    if type(cache) ~= "table" then
        return
    end
    cache[cacheKey] = nil
    -- Legacy bare idcode entries from older bridge builds.
    local bareId = shipIdCode or "UNKNOWN"
    if bareId ~= cacheKey then
        cache[bareId] = nil
    end
    SetNPCBlackboard(playerBbId, "$GT_ModProbeByShip", cache)
end

_G.GT_PlayerBridge = GT_PlayerBridge

return GT_PlayerBridge
