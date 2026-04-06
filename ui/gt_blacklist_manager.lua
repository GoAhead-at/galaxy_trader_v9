--[[
==============================================================================
GalaxyTrader MK3 - Dynamic Blacklist Manager
==============================================================================
Bridges MD threat intelligence with X4's native blacklist system

Features:
- Creates empty fleet blacklist at game start/save load (avoids creation lag)
- Updates blacklist dynamically as threats are detected/cleared
- Automatically applies blacklist to all GT ships
- Uses vanilla pathfinding for automatic route recalculation

Dependencies: 
- sn_mod_support_apis (Lua Loader API)
- X4 FFI blacklist functions

Author: GalaxyTrader Development Team
Version: 1.0
==============================================================================
]]--

local ffi = require("ffi")
local C = ffi.C

-- =============================================================================
-- FFI DEFINITIONS - X4 Blacklist API
-- =============================================================================

ffi.cdef[[
    typedef int32_t BlacklistID;
    
    typedef struct {
        const char* name;
        const char* type;           // "sectortravel" or "sectoractivity"
        uint32_t nummacros;         // Number of sector macros
        const char** macros;        // Array of sector macro names
        uint32_t numfactions;       // Number of factions
        const char** factions;      // Array of faction IDs
        const char* relation;       // Relation threshold
        bool hazardous;
        bool usemacrowhitelist;
        bool usefactionwhitelist;
        BlacklistID id;             // ID for updates
    } BlacklistInfo2;
    
    BlacklistID CreateBlacklist2(BlacklistInfo2 info);
    void UpdateBlacklist2(BlacklistInfo2 info);
    void RemoveBlacklist(BlacklistID id);
    void SetControllableBlacklist(uint64_t controllableid, BlacklistID id, const char* listtype, bool value);
    BlacklistID GetControllableBlacklistID(uint64_t controllableid, const char* listtype, const char* defaultgroup);
    bool IsComponentBlacklisted(uint64_t componentid, const char* listtype, const char* defaultgroup, uint64_t controllableid);
    bool GetBlacklistInfo2(BlacklistInfo2* info, BlacklistID id);
    
    // Component lookup
    uint64_t ConvertStringTo64Bit(const char* idcode);
    const char* ConvertIDToString(uint64_t componentid);
    const char* GetComponentData(uint64_t componentid, const char* propertyname);
]]

-- =============================================================================
-- MODULE STATE
-- =============================================================================

local GT_Blacklist = {
    -- Configuration
    CONFIG = {
        DEBUG_MODE = false,  -- Set to true to enable debug logging
        BLACKLIST_NAME_PREFIX = "GT_ThreatAvoid_",
        THREAT_LEVEL_THRESHOLD = 3,  -- Default: Blacklist sectors with threat >= 3 (overridden by MD settings)
        UPDATE_INTERVAL = 5.0,        -- Check for updates every 5 seconds
    },
    
    -- State tracking
    dynamic_blacklists = {},  -- { ship_id -> blacklist_id }
    blacklisted_sectors = {}, -- { sector_name -> { threat_level, timestamp } }
    fleet_blacklist_id = nil, -- Shared fleet-wide blacklist ID
    relation_value = "",      -- Stored relation value: "enemy" or ""
    last_update = 0,
    initialized = false,
}

-- =============================================================================
-- STRING UTILITY FUNCTIONS (for ship name processing)
-- =============================================================================

-- Strip GT formatting from ship names
-- Removes: prefixes like "ADVANCE", "[TRAINING]", "AVANÇAR" (any ALL-CAPS word or bracketed text)
-- Removes: suffixes like "(Comerciante Lv.10 XP:3150)"
local function stripGTFormatting(shipName)
    if not shipName or shipName == "" then
        return ""
    end
    
    local cleanName = shipName
    
    -- Step 1: Remove bracketed prefix like "[TRAINING]", "[AUSBILDUNG]", etc.
    cleanName = cleanName:gsub("^%[.-%]%s+", "")
    
    -- Step 2: Remove ALL-CAPS word prefix (like "ADVANCE ", "AVANÇAR ", "FORTSCHRITT ", etc.)
    cleanName = cleanName:gsub("^[%u%d]+%s+", "")
    
    -- Step 3: Remove parenthetical suffix like "(Comerciante Lv.10 XP:3150)"
    local parenPos = cleanName:find("%s%(")
    if parenPos then
        cleanName = cleanName:sub(1, parenPos - 1)
    end
    
    -- Trim any trailing/leading whitespace
    cleanName = cleanName:match("^%s*(.-)%s*$")
    
    return cleanName
end

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

local function debugLog(message, level)
    if GT_Blacklist.CONFIG.DEBUG_MODE then
        local prefix = level == "ERROR" and "❌" or level == "WARN" and "" or "🛡️"
        local logText = string.format("[GT-Blacklist] %s %s", prefix, message)
        
        -- Only use DebugError for actual errors and warnings
        if level == "ERROR" or level == "WARN" then
            DebugError(logText)
        else
            -- For info/success messages, use standard print (appears in Scripts log, not as error)
            print(logText)
        end
    end
end

local function convertStringToID(idcode)
    if not idcode or idcode == "" then
        return 0
    end
    -- Match UPB pattern: tonumber -> tostring -> ConvertStringTo64Bit
    -- This handles numeric strings from MD like "123456789"
    local num = tonumber(idcode)
    if not num then
        debugLog(string.format("Failed to convert '%s' to number", idcode), "WARN")
        return 0
    end
    return C.ConvertStringTo64Bit(tostring(num))
end

-- NOTE: ConvertIDToString is restricted in FFI, so we can't use it
-- local function convertIDToString(componentid)
--     if not componentid or componentid == 0 then
--         return ""
--     end
--     return ffi.string(C.ConvertIDToString(componentid))
-- end

-- =============================================================================
-- BLACKLIST MANAGEMENT - CORE FUNCTIONS
-- =============================================================================

--- Create or update the fleet-wide dynamic blacklist
--- @param threatened_macro_list table List of sector macros with direct threats
--- @param relation_value string "enemy" to block enemy factions, "" to disable
local function updateFleetBlacklist(threatened_macro_list, relation_value)
    local relation_display = (relation_value == "enemy") and '"enemy"' or 'disabled'
    debugLog(string.format("Updating fleet blacklist with %d threatened sector macros, faction blocking: %s", 
             #threatened_macro_list, relation_display))
    
    -- MD already sent us the macros, so we can use them directly!
    local macro_strings = {}  -- Keep references to prevent garbage collection
    
    for _, macro_name in ipairs(threatened_macro_list) do
        if macro_name and macro_name ~= "" and macro_name ~= "nil" then
            -- Store FFI string to prevent GC
            table.insert(macro_strings, ffi.new("char[?]", #macro_name + 1, macro_name))
            debugLog(string.format("  Added threatened sector macro: %s", macro_name))
        else
            debugLog(string.format("WARNING: Skipping invalid macro: '%s'", tostring(macro_name)), "WARN")
        end
    end
    
    -- Allow empty blacklist (0 sectors) - this is intentional for "clear all threats"
    debugLog(string.format("Processed %d valid threatened sector macros", #macro_strings))
    
    -- Prepare FFI array of string pointers (handle empty case)
    local macros_array = nil
    if #macro_strings > 0 then
        macros_array = ffi.new("const char*[?]", #macro_strings)
        for i, macro_str in ipairs(macro_strings) do
            macros_array[i-1] = macro_str
        end
    end
    
    -- Set up relation value for automatic faction blocking
    -- X4 expects the literal string "enemy" to block enemy factions
    --   "enemy" = block all sectors owned by enemy factions
    --   ""      = disabled (no faction blocking)
    local relation_str = ffi.new("char[?]", #relation_value + 1, relation_value)
    
    if relation_value == "enemy" then
        debugLog("Faction-based blocking: ENABLED (blocks all enemy faction sectors)")
    else
        debugLog(" Faction-based blocking: DISABLED")
    end
    
    -- Create blacklist info structure
    local blacklist_name = GT_Blacklist.CONFIG.BLACKLIST_NAME_PREFIX .. "Fleet"
    local name_str = ffi.new("char[?]", #blacklist_name + 1, blacklist_name)
    local type_str = ffi.new("char[?]", 13, "sectortravel")  -- 12 chars + null
    
    local info = ffi.new("BlacklistInfo2")
    info.name = name_str
    info.type = type_str
    info.nummacros = #macro_strings
    info.macros = macros_array
    info.numfactions = 0
    info.factions = nil
    info.relation = relation_str  -- X4 will automatically block sectors owned by hostile factions!
    info.hazardous = false
    info.usemacrowhitelist = false
    info.usefactionwhitelist = false
    
    -- Log what we're creating/updating
    debugLog("========== BLACKLIST CONFIGURATION ==========")
    debugLog(string.format("  name: %s", blacklist_name))
    debugLog(string.format("  type: %s", ffi.string(type_str)))
    debugLog(string.format("  nummacros: %d", #macro_strings))
    debugLog(string.format("  numfactions: %d", info.numfactions))
    debugLog(string.format("  relation: '%s' (length: %d)", ffi.string(relation_str), #ffi.string(relation_str)))
    debugLog(string.format("  hazardous: %s", tostring(info.hazardous)))
    debugLog(string.format("  usemacrowhitelist: %s", tostring(info.usemacrowhitelist)))
    debugLog(string.format("  usefactionwhitelist: %s", tostring(info.usefactionwhitelist)))
    debugLog("=============================================")
    
    -- Create or update blacklist
    if not GT_Blacklist.fleet_blacklist_id then
        debugLog(string.format("Creating new fleet blacklist: %s", blacklist_name))
        GT_Blacklist.fleet_blacklist_id = C.CreateBlacklist2(info)
        debugLog(string.format("Fleet blacklist created with ID: %d", GT_Blacklist.fleet_blacklist_id))
    else
        -- Try to verify blacklist still exists before updating (player might have deleted it manually)
        local blacklist_still_exists = false
        
        -- Check if GetBlacklistInfo2 is available (might be restricted by X4 security)
        if type(C.GetBlacklistInfo2) == "cdata" then
            local verify_buf = ffi.new("BlacklistInfo2")
            local success, exists = pcall(function() return C.GetBlacklistInfo2(verify_buf, GT_Blacklist.fleet_blacklist_id) end)
            
            if success then
                blacklist_still_exists = exists
                if not exists then
                    debugLog(string.format(" Blacklist ID %d no longer exists (manually deleted?)", GT_Blacklist.fleet_blacklist_id))
                end
            else
                -- Function failed (likely restricted) - assume blacklist exists
                debugLog(" GetBlacklistInfo2 is restricted - cannot verify blacklist existence", "WARN")
                blacklist_still_exists = true -- Assume it exists
            end
        else
            -- Function not available - assume blacklist exists
            debugLog(" GetBlacklistInfo2 not available - cannot verify blacklist existence", "WARN")
            blacklist_still_exists = true -- Assume it exists
        end
        
        if not blacklist_still_exists then
            -- Blacklist was deleted - recreate it
            debugLog("Recreating deleted blacklist...")
            GT_Blacklist.fleet_blacklist_id = C.CreateBlacklist2(info)
            debugLog(string.format("Fleet blacklist recreated with new ID: %d", GT_Blacklist.fleet_blacklist_id))
            
            -- Notify MD to update the stored ID
            AddUITriggeredEvent("gt_blacklist_manager", "BlacklistCreated", GT_Blacklist.fleet_blacklist_id)
        else
            -- Blacklist exists (or we can't verify) - update it
            debugLog(string.format("Updating existing fleet blacklist ID: %d", GT_Blacklist.fleet_blacklist_id))
            info.id = GT_Blacklist.fleet_blacklist_id
            C.UpdateBlacklist2(info)
            debugLog("Fleet blacklist updated")
        end
    end
    
    return true
end

--- Apply blacklist to a specific ship
local function applyBlacklistToShip(ship_id, blacklist_id)
    if not ship_id or ship_id == 0 then
        debugLog("Invalid ship ID provided", "ERROR")
        return false
    end
    
    if not blacklist_id or blacklist_id == 0 then
        debugLog("Invalid blacklist ID provided", "ERROR")
        return false
    end
    
    -- Apply blacklist to ship for sector travel (no per-ship logging for performance)
    C.SetControllableBlacklist(ship_id, blacklist_id, "sectortravel", true)
    
    -- Track assignment
    GT_Blacklist.dynamic_blacklists[ship_id] = blacklist_id
    
    return true
end

--- Remove blacklist from a specific ship
local function removeBlacklistFromShip(ship_id)
    if not ship_id or ship_id == 0 then
        debugLog("Invalid ship ID provided", "ERROR")
        return false
    end
    
    local blacklist_id = GT_Blacklist.dynamic_blacklists[ship_id]
    if not blacklist_id then
        return true -- Already has no blacklist
    end
    
    -- Remove blacklist assignment (-1 = use default)
    C.SetControllableBlacklist(ship_id, -1, "sectortravel", false)
    
    -- Clear tracking
    GT_Blacklist.dynamic_blacklists[ship_id] = nil
    
    return true
end

--- Apply fleet blacklist to non-subordinate GT ships (subordinates inherit from commanders)
local function applyFleetBlacklistToAllShips(ship_list)
    if not GT_Blacklist.fleet_blacklist_id then
        debugLog("No fleet blacklist to apply", "WARN")
        return false
    end
    
    debugLog(string.format("Applying fleet blacklist to %d non-subordinate ships", #ship_list))
    
    -- Debug: Show first 3 ship ID strings
    if #ship_list > 0 then
        debugLog(string.format("Sample ship IDs: %s, %s, %s", 
            ship_list[1] or "nil", 
            ship_list[2] or "nil", 
            ship_list[3] or "nil"))
    end
    
    local success_count = 0
    local fail_count = 0
    for i, ship_id_string in ipairs(ship_list) do
        local ship_id = convertStringToID(ship_id_string)
        
        -- Debug first 3 conversions
        if i <= 3 then
            debugLog(string.format("  Ship %d: '%s' ID: %s", i, ship_id_string, tostring(ship_id)))
        end
        
        if ship_id ~= 0 then
            if applyBlacklistToShip(ship_id, GT_Blacklist.fleet_blacklist_id) then
                success_count = success_count + 1
            else
                fail_count = fail_count + 1
            end
        else
            fail_count = fail_count + 1
            if i <= 3 then
                debugLog(string.format("  Failed to convert ship ID string: '%s'", ship_id_string), "WARN")
            end
        end
    end
    
    debugLog(string.format("Fleet blacklist applied to %d/%d non-subordinate ships (%d failed)", success_count, #ship_list, fail_count))
    return true
end

-- =============================================================================
-- THREAT DATA PROCESSING
-- =============================================================================

--- Parse threat data from MD script format
--- @param threat_data_string string Format: "sector_macro1:level1:timestamp1|sector_macro2:level2:timestamp2|..."
--- @return table threatened_macros List of sector macros to blacklist
local function parseThreatData(threat_data_string)
    debugLog(string.format("Parsing threat data: %s", threat_data_string))
    
    -- Simple format: "sector_macro1:level1:timestamp1|sector_macro2:level2:timestamp2|..."
    local threatened_macros = {}
    
    for sector_entry in string.gmatch(threat_data_string, "([^|]+)") do
        local parts = {}
        for part in string.gmatch(sector_entry, "([^:]+)") do
            table.insert(parts, part)
        end
        
        if #parts >= 3 then
            local sector_macro = parts[1]
            local threat_level = tonumber(parts[2]) or 0
            local timestamp = tonumber(parts[3]) or 0
            
            -- Only blacklist if threat level is above threshold and macro is valid
            if threat_level >= GT_Blacklist.CONFIG.THREAT_LEVEL_THRESHOLD and sector_macro and sector_macro ~= "" and sector_macro ~= "nil" then
                table.insert(threatened_macros, sector_macro)
                GT_Blacklist.blacklisted_sectors[sector_macro] = {
                    threat_level = threat_level,
                    timestamp = timestamp
                }
            end
        end
    end
    
    debugLog(string.format("Found %d sector macros above threat threshold", #threatened_macros))
    return threatened_macros
end

--- Clean up expired threats from tracking
local function cleanupExpiredThreats(current_time, expiry_time)
    local removed_count = 0
    
    for sector_name, threat_info in pairs(GT_Blacklist.blacklisted_sectors) do
        local age = current_time - threat_info.timestamp
        if age > expiry_time then
            GT_Blacklist.blacklisted_sectors[sector_name] = nil
            removed_count = removed_count + 1
        end
    end
    
    if removed_count > 0 then
        debugLog(string.format("Cleaned up %d expired threat entries", removed_count))
    end
    
    return removed_count
end

-- =============================================================================
-- EVENT HANDLERS - MD SCRIPT INTERFACE
-- =============================================================================

--- Initialize the blacklist system
local function onInitialize(_, event_data)
    debugLog("Initializing GalaxyTrader Dynamic Blacklist System...")
    
    if GT_Blacklist.initialized then
        debugLog("System already initialized", "WARN")
        return true
    end
    
    -- Verify FFI functions are available
    if type(C.CreateBlacklist2) ~= "cdata" then
        debugLog("ERROR: CreateBlacklist2 FFI function not available!", "ERROR")
        return false
    end
    
    -- Parse init data: "relation|existing_id|threshold"
    -- relation is "enemy" (enabled) or "" (disabled)
    -- existing_id is the blacklist ID (0 = create new)
    -- threshold is the threat level threshold (1-5)
    debugLog(string.format("Received event_data from MD: '%s' (type: %s, length: %d)",
             tostring(event_data), type(event_data), event_data and #event_data or 0))
    
    local relation_value, existing_id, threshold = "", 0, 3
    if event_data and event_data ~= "" then
        local parts = {}
        for part in string.gmatch(event_data, "[^|]+") do
            table.insert(parts, part)
        end
        debugLog(string.format("Parsed parts: [1]='%s', [2]='%s', [3]='%s'",
                 tostring(parts[1] or "nil"), tostring(parts[2] or "nil"), tostring(parts[3] or "nil")))
        relation_value = parts[1] or ""
        existing_id = tonumber(parts[2]) or 0
        threshold = tonumber(parts[3]) or 3
    end
    
    -- Apply threshold from MD settings
    GT_Blacklist.CONFIG.THREAT_LEVEL_THRESHOLD = threshold
    debugLog(string.format("Blacklist threshold set to: %d", threshold))
    
    GT_Blacklist.relation_value = relation_value
    
    -- Check if we're reusing an existing blacklist or creating new
    local faction_blocking_status = (relation_value == "enemy") and '"enemy"' or 'disabled'
    if existing_id > 0 then
        debugLog(string.format("♻️ Reusing existing blacklist ID: %d (faction blocking: %s)", existing_id, faction_blocking_status))
        GT_Blacklist.fleet_blacklist_id = existing_id
        -- No need to notify MD - it already knows the ID
    else
        debugLog(string.format("🆕 Creating NEW fleet blacklist (faction blocking: %s)", faction_blocking_status))
    end
    
    -- Create/Update blacklist with relation value
    -- X4 will automatically block all sectors owned by enemy factions if relation="enemy"
    local empty_sectors = {}
    local success = updateFleetBlacklist(empty_sectors, GT_Blacklist.relation_value)
    
    if not success then
        debugLog(" Failed to create/update blacklist", "WARN")
        return false
    end
    
    -- If we created a NEW blacklist, notify MD to store the ID
    if existing_id == 0 and GT_Blacklist.fleet_blacklist_id then
        debugLog(string.format("Notifying MD of new blacklist ID: %d", GT_Blacklist.fleet_blacklist_id))
        AddUITriggeredEvent("gt_blacklist_manager", "BlacklistCreated", GT_Blacklist.fleet_blacklist_id)
    end
    
    debugLog("Fleet blacklist initialized with faction-based blocking enabled")
    
    GT_Blacklist.initialized = true
    debugLog("Dynamic Blacklist System initialized successfully")
    
    return true
end

--- Update blacklists based on current threat data
local function onUpdateBlacklist(_, event_data)
    if not GT_Blacklist.initialized then
        debugLog("System not initialized - ignoring update request", "WARN")
        return false
    end
    
    debugLog("Received blacklist update request")
    
    -- Parse threat data from MD (empty string = no threats)
    local threatened_sectors = {}
    if event_data and event_data ~= "" then
        threatened_sectors = parseThreatData(event_data)
    else
        debugLog("No threat data provided - updating blacklist to empty")
    end
    
    -- Update fleet blacklist with threatened sectors AND relation value (must pass it every time!)
    return updateFleetBlacklist(threatened_sectors, GT_Blacklist.relation_value)
end

--- Apply blacklist to GT fleet ships
local function onApplyToFleet(_, event_data)
    if not GT_Blacklist.initialized then
        debugLog("System not initialized - ignoring apply request", "WARN")
        return false
    end
    
    debugLog("Received fleet application request")
    
    if not event_data or event_data == "" then
        debugLog("No ship list provided", "ERROR")
        return false
    end
    
    -- Parse ship list: "ship1,ship2,ship3,..."
    local ship_list = {}
    for ship_id in string.gmatch(event_data, "([^,]+)") do
        table.insert(ship_list, ship_id)
    end
    
    return applyFleetBlacklistToAllShips(ship_list)
end

--- Clean up expired threats and update blacklist
local function onCleanupExpired(_, event_data)
    if not GT_Blacklist.initialized then
        return false
    end
    
    -- Check for nil/empty event_data before parsing (prevents crash)
    if not event_data or event_data == "" then
        debugLog("Invalid cleanup parameters: event_data is nil or empty", "ERROR")
        return false
    end
    
    -- Format: "current_time:expiry_time"
    local parts = {}
    for part in string.gmatch(event_data, "([^:]+)") do
        table.insert(parts, part)
    end
    
    if #parts < 2 then
        debugLog("Invalid cleanup parameters", "ERROR")
        return false
    end
    
    local current_time = tonumber(parts[1]) or 0
    local expiry_time = tonumber(parts[2]) or 3600
    
    debugLog(string.format("Cleaning up threats older than %d seconds", expiry_time))
    
    -- Remove expired threats
    local removed = cleanupExpiredThreats(current_time, expiry_time)
    
    -- Rebuild blacklist with remaining threats
    local threatened_sectors = {}
    for sector_name, _ in pairs(GT_Blacklist.blacklisted_sectors) do
        table.insert(threatened_sectors, sector_name)
    end
    
    updateFleetBlacklist(threatened_sectors, GT_Blacklist.relation_value)
    
    return true
end

--- Remove blacklist from a specific ship
local function onRemoveFromShip(_, event_data)
    if not GT_Blacklist.initialized then
        return false
    end
    
    local ship_id = convertStringToID(event_data)
    return removeBlacklistFromShip(ship_id)
end

--- Force recreate the blacklist (bypasses initialized check)
local function onRecreateBlacklist(_, event_data)
    debugLog("FORCE RECREATE: Resetting blacklist system...")
    
    -- Reset initialized flag to allow recreation
    GT_Blacklist.initialized = false
    
    -- Call the normal initialize function
    return onInitialize(_, event_data)
end

-- =============================================================================
-- MODULE INITIALIZATION
-- =============================================================================

local function init()
    debugLog("================================================================================")
    debugLog("GalaxyTrader MK3 - Dynamic Blacklist Manager Loading...")
    debugLog("================================================================================")
    
    -- Verify FFI availability
    if not ffi then
        debugLog("ERROR: FFI not available!", "ERROR")
        return false
    end
    
    -- Register event handlers
    local events = {
        { name = "GT_Blacklist.Initialize",      handler = onInitialize },
        { name = "GT_Blacklist.Update",          handler = onUpdateBlacklist },
        { name = "GT_Blacklist.ApplyToFleet",    handler = onApplyToFleet },
        { name = "GT_Blacklist.CleanupExpired",  handler = onCleanupExpired },
        { name = "GT_Blacklist.RemoveFromShip",  handler = onRemoveFromShip },
        { name = "GT_Blacklist.Recreate",        handler = onRecreateBlacklist },
    }
    
    for _, event in ipairs(events) do
        local success = pcall(RegisterEvent, event.name, event.handler)
        if success then
            debugLog(string.format("Registered event: %s", event.name))
        else
            debugLog(string.format("Failed to register event: %s", event.name), "ERROR")
        end
    end
    
    debugLog("================================================================================")
    debugLog("Dynamic Blacklist Manager loaded successfully!")
    debugLog("Waiting for initialization signal from MD scripts...")
    debugLog("================================================================================")
    
    return true
end

-- Initialize module immediately
init()

-- Export module for debugging/testing
return GT_Blacklist

