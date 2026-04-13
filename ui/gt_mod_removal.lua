--[[
GalaxyTrader MK3 - Equipment Mod Removal Lua Module
Handles removal of GT-installed modifications using C API
]]

local GT_ModRemoval = {}

-- Debug logging wrapper
-- Note: X4 Lua only has DebugError and DebugWarning, not DebugLog
local function logDebug(message, level)
    level = level or "INFO"
    local prefix = "[GT-Mods-Lua] "
    if level == "ERROR" then
        DebugError(prefix .. message)
    elseif level == "WARNING" then
        -- Some runtimes don't expose DebugWarning; use DebugError as safe fallback.
        DebugError(prefix .. message)
    else
        -- X4 Lua has no reliable normal debug logger for extension scripts.
        -- Route INFO through DebugError as well so module load and event flow stay visible.
        DebugError(prefix .. message)
    end
end

-- FFI setup for C API access
local ffi = require("ffi")
local C = ffi.C

-- FFI definitions for C API mod removal functions
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef struct {
        const char* Name;
        const char* RawName;
        const char* Ware;
        uint32_t Quality;
        const char* PropertyType;
        float ForwardThrustFactor;
        float StrafeAccFactor;
        float StrafeThrustFactor;
        float RotationThrustFactor;
        float BoostAccFactor;
        float BoostThrustFactor;
        float BoostDurationFactor;
        float BoostAttackTimeFactor;
        float BoostReleaseTimeFactor;
        float BoostChargeTimeFactor;
        float BoostRechargeTimeFactor;
        float TravelThrustFactor;
        float TravelStartThrustFactor;
        float TravelAttackTimeFactor;
        float TravelReleaseTimeFactor;
        float TravelChargeTimeFactor;
    } UIEngineMod2;
    typedef struct {
        const char* Name;
        const char* RawName;
        const char* Ware;
        uint32_t Quality;
        const char* PropertyType;
        float MassFactor;
        float DragFactor;
        float MaxHullFactor;
        float RadarRangeFactor;
        uint32_t AddedUnitCapacity;
        uint32_t AddedMissileCapacity;
        uint32_t AddedCountermeasureCapacity;
        uint32_t AddedDeployableCapacity;
        float RadarCloakFactor;
        float RegionDamageProtection;
        float HideCargoChance;
    } UIShipMod2;
    void DismantleShipMod(UniverseID shipid);
    void DismantleEngineMod(UniverseID objectid);
    void DismantleShieldMod(UniverseID defensibleid, UniverseID contextid, const char* group);
    void DismantleWeaponMod(UniverseID weaponid);
    void DismantleThrusterMod(UniverseID objectid);
    bool InstallEngineMod(UniverseID objectid, const char* wareid);
    bool InstallShipMod(UniverseID shipid, const char* wareid);
    bool InstallShieldMod(UniverseID defensibleid, UniverseID contextid, const char* group, const char* wareid);
    bool GetInstalledEngineMod2(UniverseID objectid, UIEngineMod2* enginemod);
    bool GetInstalledShipMod2(UniverseID shipid, UIShipMod2* shipmod);
]]

-- Convert a serialized UniverseID string to a 64-bit universe ID.
local function ConvertStringTo64Bit(str)
    if not str or str == "" then
        logDebug("ERROR: Empty string passed to ConvertStringTo64Bit", "ERROR")
        return 0
    end

    local num
    if type(str) == "string" and string.sub(str, 1, 2) == "0x" then
        num = tonumber(string.sub(str, 3), 16)
    else
        num = tonumber(str)
    end

    if not num then
        logDebug(string.format("ERROR: Failed to convert '%s' to number", tostring(str)), "ERROR")
        return 0
    end
    return ffi.cast("uint64_t", num)
end

-- Split pipe-separated parameters (format: "type|shipId|componentId|contextId|group")
local function SplitParams(params, sep)
    sep = sep or "|"
    local result = {}
    local pattern = string.format("([^%s]+)", sep)
    for match in string.gmatch(params, pattern) do
        table.insert(result, match)
    end
    return result
end

local function ToUniverseID(value)
    if value == nil or value == 0 or value == "0" then
        return ffi.cast("uint64_t", 0)
    end

    local valueType = type(value)
    if valueType == "string" or valueType == "number" then
        return ConvertStringTo64Bit(tostring(value))
    end

    local ok, converted = pcall(ConvertIDTo64Bit, value)
    if ok and converted and converted ~= 0 then
        return converted
    end

    logDebug(string.format("ERROR: Failed to convert component payload to UniverseID: %s", tostring(value)), "ERROR")
    return ffi.cast("uint64_t", 0)
end

local function ParseModPayload(params)
    if type(params) == "table" then
        return {
            type = params.type or params.modType or params.kind,
            component = params.component or params.ship or params.object,
            shipIdCode = params.shipIdCode or params.idcode or "UNKNOWN",
            wareId = params.wareId or params.ware or params.mod,
            reason = params.reason or "manual",
            group = params.group,
            componentId = params.componentId,
            contextId = params.contextId,
        }
    end

    local tPackets = SplitParams(params, "|")
    local isActionPayload = tPackets[1] == "ship" or tPackets[1] == "engine" or tPackets[1] == "shield" or tPackets[1] == "weapon" or tPackets[1] == "thruster"
    local hasExtendedFields = isActionPayload and (#tPackets >= 6)
    return {
        type = isActionPayload and tPackets[1] or nil,
        component = isActionPayload and tPackets[2] or tPackets[1],
        shipIdCode = isActionPayload and (hasExtendedFields and tPackets[3] or tPackets[2]) or tPackets[2],
        wareId = isActionPayload and (hasExtendedFields and tPackets[6] or tPackets[3]) or nil,
        reason = isActionPayload and nil or tPackets[3],
        componentId = isActionPayload and tPackets[4] or nil,
        contextId = isActionPayload and tPackets[5] or nil,
        group = isActionPayload and tPackets[6] or nil,
        packets = tPackets,
    }
end

local function SafeCString(value, defaultValue)
    defaultValue = defaultValue or "none"
    if value == nil then
        return defaultValue
    end
    local ok, text = pcall(ffi.string, value)
    if ok and text and text ~= "" then
        return text
    end
    return defaultValue
end

local function IsGTShipModWareId(wareId)
    return wareId == "mod_ship_gt_level1"
        or wareId == "mod_ship_gt_level2"
        or wareId == "mod_ship_gt_level3"
        or wareId == "mod_penalty_ship_light"
        or wareId == "mod_penalty_ship_moderate"
        or wareId == "mod_penalty_ship_severe"
        or wareId == "mod_penalty_light"
        or wareId == "mod_penalty_moderate"
        or wareId == "mod_penalty_severe"
end

local function IsGTEngineModWareId(wareId)
    return wareId == "mod_engine_gt_level1"
        or wareId == "mod_engine_gt_level2"
        or wareId == "mod_engine_gt_level3"
        or wareId == "mod_penalty_engine_light"
        or wareId == "mod_penalty_engine_moderate"
        or wareId == "mod_penalty_engine_severe"
        or wareId == "mod_penalty_light"
        or wareId == "mod_penalty_moderate"
        or wareId == "mod_penalty_severe"
end

local function GT_DismantleDetectedGTMods(_, params)
    if not params then
        logDebug("ERROR: GT_Mods.DismantleDetected called with nil params", "ERROR")
        return
    end

    local payload = ParseModPayload(params)
    if not payload.component then
        logDebug(string.format("ERROR: Invalid GT_Mods.DismantleDetected params format: %s", tostring(params)), "ERROR")
        return
    end

    local shipIdCode = payload.shipIdCode or "UNKNOWN"
    local reason = payload.reason or "manual"
    local shipId = ToUniverseID(payload.component)

    local shipBuf = ffi.new("UIShipMod2")
    local engineBuf = ffi.new("UIEngineMod2")
    local hasShip = C.GetInstalledShipMod2(shipId, shipBuf)
    local hasEngine = C.GetInstalledEngineMod2(shipId, engineBuf)
    local shipWare = hasShip and SafeCString(shipBuf.Ware) or "none"
    local engineWare = hasEngine and SafeCString(engineBuf.Ware) or "none"

    local removedShip = false
    local removedEngine = false

    if hasShip and IsGTShipModWareId(shipWare) then
        C.DismantleShipMod(shipId)
        removedShip = true
    end
    if hasEngine and IsGTEngineModWareId(engineWare) then
        C.DismantleEngineMod(shipId)
        removedEngine = true
    end

    logDebug(string.format("Detected GT mod cleanup ship=%s reason=%s removedShip=%s removedEngine=%s shipWare=%s engineWare=%s", shipIdCode, reason, tostring(removedShip), tostring(removedEngine), shipWare, engineWare), "WARNING")
end

-- Remove modification from ship
local function GT_DismantleMod(_, params)
    if not params then
        logDebug("ERROR: GT_Mods.Dismantle called with nil params", "ERROR")
        return
    end
    
    local payload = ParseModPayload(params)
    if not payload.type or not payload.component then
        logDebug(string.format("ERROR: Invalid params format: %s", tostring(params)), "ERROR")
        return
    end
    
    local type = payload.type
    local shipIdCode = payload.shipIdCode or "UNKNOWN"
    local shipId = ToUniverseID(payload.component)
    
    if type == "ship" then
        local shipBuf = ffi.new("UIShipMod2")
        local hasShip = C.GetInstalledShipMod2(shipId, shipBuf)
        local shipWare = hasShip and SafeCString(shipBuf.Ware) or "none"
        if hasShip and IsGTShipModWareId(shipWare) then
            C.DismantleShipMod(shipId)
            -- logDebug(string.format("Dismantled ship mod from %s ware=%s", shipIdCode, shipWare), "WARNING")
        end
    elseif type == "engine" then
        local engineBuf = ffi.new("UIEngineMod2")
        local hasEngine = C.GetInstalledEngineMod2(shipId, engineBuf)
        local engineWare = hasEngine and SafeCString(engineBuf.Ware) or "none"
        if hasEngine and IsGTEngineModWareId(engineWare) then
            C.DismantleEngineMod(shipId)
            -- logDebug(string.format("Dismantled engine mod from %s ware=%s", shipIdCode, engineWare), "WARNING")
        end
    elseif type == "shield" then
        local contextId = shipId
        local group = (payload.group and payload.group ~= "null") and payload.group or nil
        
        if group then
            C.DismantleShieldMod(shipId, contextId, group)
        else
            C.DismantleShieldMod(shipId, contextId, "")
        end
    elseif type == "weapon" then
        local componentId = nil
        if payload.componentId and tostring(payload.componentId) ~= "0" then
            componentId = ToUniverseID(payload.componentId)
        end
        
        if componentId then
            C.DismantleWeaponMod(componentId)
        else
            logDebug(string.format("WARNING: No component ID provided for weapon mod - ship: %s", shipIdCode), "WARNING")
        end
    elseif type == "thruster" then
        C.DismantleThrusterMod(shipId)
    else
        logDebug(string.format("ERROR: Unknown mod type: %s", type), "ERROR")
    end
end

-- Install modification on ship
local function GT_InstallMod(_, params)
    if not params then
        logDebug("ERROR: GT_Mods.Install called with nil params", "ERROR")
        return
    end

    local payload = ParseModPayload(params)
    if not payload.type or not payload.component or not payload.wareId then
        logDebug(string.format("ERROR: Invalid GT_Mods.Install params format: %s", tostring(params)), "ERROR")
        return
    end

    local type = payload.type
    local shipIdStr = payload.shipIdCode or "UNKNOWN"
    local shipId = ToUniverseID(payload.component)
    local wareId = payload.wareId

    -- logDebug(string.format("Install request type=%s shipId=%s ware=%s", tostring(type), tostring(shipIdStr), tostring(wareId)), "WARNING")

    if type == "ship" then
        local ok, success = pcall(C.InstallShipMod, shipId, wareId)
        if not ok then
            logDebug(string.format("InstallShipMod raised error for ship ID %s ware %s: %s", shipIdStr, wareId, tostring(success)), "ERROR")
            return
        end
        if not success then
            logDebug(string.format("Failed to install ship mod (%s) on ship ID: %s", wareId, shipIdStr), "ERROR")
        else
            local shipBuf = ffi.new("UIShipMod2")
            local hasShip = C.GetInstalledShipMod2(shipId, shipBuf)
            local installedWare = hasShip and SafeCString(shipBuf.Ware) or "none"
            -- logDebug(string.format("InstallShipMod observed ship ID %s requested=%s observed=%s hasShip=%s", shipIdStr, wareId, installedWare, tostring(hasShip)), "WARNING")
            if installedWare ~= wareId then
                logDebug(string.format("Ship mod install verification mismatch on ship ID %s: requested=%s, observed=%s", shipIdStr, wareId, installedWare), "WARNING")
            end
        end
    elseif type == "engine" or type == "thruster" then
        local ok, success = pcall(C.InstallEngineMod, shipId, wareId)
        if not ok then
            logDebug(string.format("InstallEngineMod raised error for ship ID %s ware %s: %s", shipIdStr, wareId, tostring(success)), "ERROR")
            return
        end
        if not success then
            logDebug(string.format("Failed to install engine mod (%s) on ship ID: %s", wareId, shipIdStr), "ERROR")
        else
            local engineBuf = ffi.new("UIEngineMod2")
            local hasEngine = C.GetInstalledEngineMod2(shipId, engineBuf)
            local installedWare = hasEngine and SafeCString(engineBuf.Ware) or "none"
            -- logDebug(string.format("InstallEngineMod observed ship ID %s requested=%s observed=%s hasEngine=%s", shipIdStr, wareId, installedWare, tostring(hasEngine)), "WARNING")
            if installedWare ~= wareId then
                logDebug(string.format("Engine mod install verification mismatch on ship ID %s: requested=%s, observed=%s", shipIdStr, wareId, installedWare), "WARNING")
            end
        end
    else
        logDebug(string.format("ERROR: Unknown mod type for installation: %s", type), "ERROR")
    end
end

-- Initialize module
local function init()
    logDebug("================================================================================")
    logDebug("GalaxyTrader MK3 - Mod Removal Lua Module Loading...")
    logDebug("================================================================================")
    
    if not ffi then
        logDebug("ERROR: FFI not available!", "ERROR")
        return false
    end
    
    local success1 = pcall(RegisterEvent, "GT_Mods.Dismantle", GT_DismantleMod)
    if success1 then
        logDebug("Registered event: GT_Mods.Dismantle")
    else
        logDebug("Failed to register event: GT_Mods.Dismantle", "ERROR")
        return false
    end
    
    local success2 = pcall(RegisterEvent, "GT_Mods.Install", GT_InstallMod)
    if success2 then
        logDebug("Registered event: GT_Mods.Install")
    else
        logDebug("Failed to register event: GT_Mods.Install", "ERROR")
        return false
    end

    local success3 = pcall(RegisterEvent, "GT_Mods.DismantleDetected", GT_DismantleDetectedGTMods)
    if success3 then
        logDebug("Registered event: GT_Mods.DismantleDetected")
    else
        logDebug("Failed to register event: GT_Mods.DismantleDetected", "ERROR")
        return false
    end
    
    logDebug("================================================================================")
    logDebug("Mod Removal Lua Module loaded successfully!")
    logDebug("================================================================================")
    
    return true
end

-- Initialize module immediately
init()

-- Export module
return GT_ModRemoval

