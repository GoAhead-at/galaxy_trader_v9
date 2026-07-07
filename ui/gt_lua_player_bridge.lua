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

function GT_PlayerBridge.StoreModProbeByIdCode(shipIdCode, shipWare, engineWare, shipNonGT, engineNonGT)
    local idCode = shipIdCode or "UNKNOWN"
    local playerBbId = GT_PlayerBridge.GetPlayerBlackboardId()
    local cache = GetNPCBlackboard(playerBbId, "$GT_ModProbeByShip")
    if type(cache) ~= "table" then
        cache = {}
    end
    cache[idCode] = {
        ShipWare = shipWare or "none",
        EngineWare = engineWare or "none",
        ShipNonGT = shipNonGT and 1 or 0,
        EngineNonGT = engineNonGT and 1 or 0,
    }
    SetNPCBlackboard(playerBbId, "$GT_ModProbeByShip", cache)
end

function GT_PlayerBridge.ClearModProbeByIdCode(shipIdCode)
    local idCode = shipIdCode or "UNKNOWN"
    local playerBbId = GT_PlayerBridge.GetPlayerBlackboardId()
    local cache = GetNPCBlackboard(playerBbId, "$GT_ModProbeByShip")
    if type(cache) ~= "table" then
        return
    end
    cache[idCode] = nil
    SetNPCBlackboard(playerBbId, "$GT_ModProbeByShip", cache)
end

_G.GT_PlayerBridge = GT_PlayerBridge

return GT_PlayerBridge
