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
- Loaded via ui.xml (works in packed cat/dat installs)
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
    
    typedef struct {
        uint32_t nummacros;
        uint32_t numfactions;
    } BlacklistCounts;
    BlacklistCounts GetBlacklistInfoCounts(BlacklistID id);
    
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
        DEBUG_MODE = false,  -- true: init/update/FFI trace + per-macro verbose dumps
        BLACKLIST_NAME_PREFIX = "GT_ThreatAvoid_",
        THREAT_LEVEL_THRESHOLD = 3,  -- Default: Blacklist sectors with threat >= 3 (overridden by MD settings)
    },
    
    -- State tracking
    dynamic_blacklists = {},  -- { ship_id -> blacklist_id }
    blacklisted_sectors = {}, -- { sector_macro -> { threat_level, timestamp } } (GT auto metadata)
    fleet_blacklist_id = nil, -- Shared fleet-wide blacklist ID
    relation_value = "",      -- Stored relation value: "enemy" or ""
    last_written_fingerprint = "",
    last_written_macros = {}, -- { [macro] = true } GT-auto macros after last write
    self_write_in_progress = false,
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

-- Load/init visibility; INFO only when DEBUG_MODE (errors/warnings always)
local function logLoad(message, level)
    level = level or "INFO"
    if level ~= "ERROR" and level ~= "WARNING" and not GT_Blacklist.CONFIG.DEBUG_MODE then
        return
    end
    local prefix = "[GT-Blacklist-Lua] "
    DebugError(prefix .. message)
end

-- Runtime trace; INFO only when DEBUG_MODE (errors/warnings always)
local function logTrace(message, level)
    level = level or "INFO"
    if level ~= "ERROR" and level ~= "WARNING" and not GT_Blacklist.CONFIG.DEBUG_MODE then
        return
    end
    local prefix = "[GT-Blacklist-Lua] "
    if level == "ERROR" or level == "WARNING" then
        DebugError(prefix .. level .. ": " .. message)
    else
        DebugError(prefix .. message)
    end
end

local function logVerbose(message, level)
    if GT_Blacklist.CONFIG.DEBUG_MODE then
        local prefix = level == "ERROR" and "ERROR" or level == "WARN" and "WARN" or "DBG"
        local logText = string.format("[GT-Blacklist-Lua] %s: %s", prefix, message)
        if level == "ERROR" or level == "WARN" then
            DebugError(logText)
        else
            print(logText)
        end
    end
end

-- Backward-compatible alias used throughout this file
local function debugLog(message, level)
    logVerbose(message, level)
end

local function summarizeMacroList(macros, max_show)
    max_show = max_show or 5
    if not macros or #macros == 0 then
        return "(none)"
    end
    if #macros <= max_show then
        return table.concat(macros, ", ")
    end
    local shown = {}
    for i = 1, max_show do
        shown[i] = macros[i]
    end
    return table.concat(shown, ", ") .. string.format(" ... +%d more", #macros - max_show)
end

local function macroListToSet(macros)
    local set = {}
    if not macros then
        return set
    end
    for _, macro in ipairs(macros) do
        if macro and macro ~= "" and macro ~= "nil" then
            set[macro] = true
        end
    end
    return set
end

local function macroSetToSortedList(set)
    local list = {}
    for macro, _ in pairs(set or {}) do
        table.insert(list, macro)
    end
    table.sort(list)
    return list
end

local function fingerprintMacroList(macros)
    if not macros or #macros == 0 then
        return ""
    end
    local sorted = {}
    for _, macro in ipairs(macros) do
        if macro and macro ~= "" then
            table.insert(sorted, macro)
        end
    end
    table.sort(sorted)
    return table.concat(sorted, "|")
end

--- Read current sector macros from the vanilla fleet blacklist (player edits included).
local function readFleetBlacklistMacros()
    if not GT_Blacklist.fleet_blacklist_id or GT_Blacklist.fleet_blacklist_id == 0 then
        return {}
    end
    if type(C.GetBlacklistInfo2) ~= "cdata" or type(C.GetBlacklistInfoCounts) ~= "cdata" then
        logTrace("readFleetBlacklistMacros: GetBlacklistInfo2/Counts not available", "WARNING")
        return {}
    end

    local counts_ok, counts = pcall(function()
        return C.GetBlacklistInfoCounts(GT_Blacklist.fleet_blacklist_id)
    end)
    if not counts_ok or not counts then
        logTrace("readFleetBlacklistMacros: GetBlacklistInfoCounts failed", "WARNING")
        return {}
    end

    local nummacros = tonumber(counts.nummacros) or 0
    if nummacros == 0 then
        return {}
    end

    local buf = ffi.new("BlacklistInfo2")
    buf.nummacros = nummacros
    buf.macros = ffi.new("const char*[?]", nummacros)

    local ok, exists = pcall(function()
        return C.GetBlacklistInfo2(buf, GT_Blacklist.fleet_blacklist_id)
    end)
    if not ok or not exists then
        logTrace("readFleetBlacklistMacros: blacklist id not found", "WARNING")
        return {}
    end

    local macros = {}
    for i = 0, nummacros - 1 do
        if buf.macros[i] ~= nil then
            local macro = ffi.string(buf.macros[i])
            if macro and macro ~= "" and macro ~= "nil" then
                table.insert(macros, macro)
            end
        end
    end
    return macros
end

--- Merge vanilla base with GT auto adds/removes; preserve player manual sectors.
--- Player manual remove of a GT-auto sector is permanent until MD detects a new threat episode.
local function mergeFleetMacroList(vanilla_macros, add_macros, remove_macros)
    local final_set = macroListToSet(vanilla_macros)
    local remove_set = macroListToSet(remove_macros)
    local add_set = macroListToSet(add_macros)

    for macro, _ in pairs(add_set) do
        final_set[macro] = true
    end
    for macro, _ in pairs(remove_set) do
        final_set[macro] = nil
    end

    return macroSetToSortedList(final_set)
end

local function rememberWrittenMacros(macros)
    GT_Blacklist.last_written_macros = macroListToSet(macros)
    GT_Blacklist.last_written_fingerprint = fingerprintMacroList(macros)
end

--- Drop MD auto-add macros the player removed from vanilla since the last GT write.
local function filterAddMacrosExcludingSet(add_macros, exclude_set)
    local filtered = {}
    for _, macro in ipairs(add_macros or {}) do
        if macro and macro ~= "" and not exclude_set[macro] then
            table.insert(filtered, macro)
        end
    end
    return filtered
end

--- Macros present after last GT write but missing from live vanilla (player removed in empire UI).
local function macrosRemovedSinceLastWrite(current_macros)
    local removed = {}
    local current_set = macroListToSet(current_macros)
    for macro, _ in pairs(GT_Blacklist.last_written_macros or {}) do
        if not current_set[macro] then
            table.insert(removed, macro)
        end
    end
    table.sort(removed)
    return removed
end

local function logBlacklistVerify(blacklist_id, context)
    if not blacklist_id or blacklist_id == 0 then
        logTrace(string.format("%s: verify skipped (no blacklist id)", context), "WARNING")
        return
    end
    if type(C.GetBlacklistInfo2) ~= "cdata" then
        logTrace(string.format("%s: GetBlacklistInfo2 not available (id=%s)", context, tostring(blacklist_id)))
        return
    end
    local verify_buf = ffi.new("BlacklistInfo2")
    local ok, exists = pcall(function() return C.GetBlacklistInfo2(verify_buf, blacklist_id) end)
    if not ok then
        logTrace(string.format("%s: GetBlacklistInfo2 pcall failed for id=%s: %s", context, tostring(blacklist_id), tostring(exists)), "WARNING")
        return
    end
    if not exists then
        logTrace(string.format("%s: blacklist id=%s NOT FOUND in X4", context, tostring(blacklist_id)), "WARNING")
        return
    end
    local name = verify_buf.name and ffi.string(verify_buf.name) or "?"
    local relation = verify_buf.relation and ffi.string(verify_buf.relation) or ""
    logTrace(string.format(
        "%s: X4 confirms id=%s name='%s' nummacros=%d relation='%s'",
        context, tostring(blacklist_id), name, tonumber(verify_buf.nummacros) or 0, relation
    ))
end

--- Parse ship list from MD raise_lua_event param ("id1,id2,..." or single numeric component id)
local function parseShipListPayload(event_data)
    local ship_list = {}
    if not event_data then
        return ship_list
    end
    if type(event_data) == "number" then
        table.insert(ship_list, tostring(event_data))
    elseif type(event_data) == "string" and event_data ~= "" then
        for ship_id in string.gmatch(event_data, "([^,]+)") do
            table.insert(ship_list, ship_id)
        end
    end
    return ship_list
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

--- Write sector macros to the fleet blacklist (full macro array; relation preserved).
--- @param final_macro_list table Sorted list of sector macros
--- @param relation_value string "enemy" or ""
local function writeFleetBlacklistMacros(final_macro_list, relation_value)
    final_macro_list = final_macro_list or {}
    local relation_display = (relation_value == "enemy") and "enemy" or "disabled"
    logTrace(string.format(
        "writeFleetBlacklistMacros: %d sector macro(s), faction blocking=%s, fleet_id=%s",
        #final_macro_list, relation_display, tostring(GT_Blacklist.fleet_blacklist_id)
    ))

    local macro_strings = {}
    for _, macro_name in ipairs(final_macro_list) do
        if macro_name and macro_name ~= "" and macro_name ~= "nil" then
            table.insert(macro_strings, ffi.new("char[?]", #macro_name + 1, macro_name))
        end
    end

    local macros_array = nil
    if #macro_strings > 0 then
        macros_array = ffi.new("const char*[?]", #macro_strings)
        for i, macro_str in ipairs(macro_strings) do
            macros_array[i - 1] = macro_str
        end
    end

    local relation_str = ffi.new("char[?]", #relation_value + 1, relation_value)
    local blacklist_name = GT_Blacklist.CONFIG.BLACKLIST_NAME_PREFIX .. "Fleet"
    local name_str = ffi.new("char[?]", #blacklist_name + 1, blacklist_name)
    local type_str = ffi.new("char[?]", 13, "sectortravel")

    local info = ffi.new("BlacklistInfo2")
    info.name = name_str
    info.type = type_str
    info.nummacros = #macro_strings
    info.macros = macros_array
    info.numfactions = 0
    info.factions = nil
    info.relation = relation_str
    info.hazardous = false
    info.usemacrowhitelist = false
    info.usefactionwhitelist = false

    GT_Blacklist.self_write_in_progress = true

    if not GT_Blacklist.fleet_blacklist_id then
        local ok, new_id = pcall(function() return C.CreateBlacklist2(info) end)
        GT_Blacklist.self_write_in_progress = false
        if not ok or not new_id or new_id == 0 then
            logTrace("CreateBlacklist2 failed: " .. tostring(new_id), "ERROR")
            return false
        end
        GT_Blacklist.fleet_blacklist_id = new_id
        rememberWrittenMacros(final_macro_list)
        AddUITriggeredEvent("gt_blacklist_manager", "BlacklistCreated", GT_Blacklist.fleet_blacklist_id)
        logTrace(string.format("CreateBlacklist2 OK: id=%d macros=[%s]", new_id, summarizeMacroList(final_macro_list)))
        return true
    end

    local blacklist_still_exists = true
    if type(C.GetBlacklistInfo2) == "cdata" then
        local verify_buf = ffi.new("BlacklistInfo2")
        local success, exists = pcall(function()
            return C.GetBlacklistInfo2(verify_buf, GT_Blacklist.fleet_blacklist_id)
        end)
        if success then
            blacklist_still_exists = exists
        end
    end

    if not blacklist_still_exists then
        local ok, new_id = pcall(function() return C.CreateBlacklist2(info) end)
        GT_Blacklist.self_write_in_progress = false
        if not ok or not new_id or new_id == 0 then
            return false
        end
        GT_Blacklist.fleet_blacklist_id = new_id
        rememberWrittenMacros(final_macro_list)
        AddUITriggeredEvent("gt_blacklist_manager", "BlacklistCreated", GT_Blacklist.fleet_blacklist_id)
        return true
    end

    info.id = GT_Blacklist.fleet_blacklist_id
    local ok, err = pcall(function() C.UpdateBlacklist2(info) end)
    GT_Blacklist.self_write_in_progress = false
    if not ok then
        logTrace("UpdateBlacklist2 failed: " .. tostring(err), "ERROR")
        return false
    end

    rememberWrittenMacros(final_macro_list)
    logTrace(string.format(
        "UpdateBlacklist2 OK: id=%d macros=[%s] relation='%s'",
        GT_Blacklist.fleet_blacklist_id, summarizeMacroList(final_macro_list), relation_value
    ))
    return true
end

--- Read vanilla, detect player removals vs last GT write, merge, write. Preserves manual sectors.
local function mergeAndWriteFleetBlacklist(add_macros, remove_macros, relation_value, clear_all)
    if clear_all then
        GT_Blacklist.blacklisted_sectors = {}
        GT_Blacklist.last_written_macros = {}
        GT_Blacklist.last_written_fingerprint = ""
        return writeFleetBlacklistMacros({}, relation_value)
    end

    local vanilla_macros = readFleetBlacklistMacros()
    local player_removed = macrosRemovedSinceLastWrite(vanilla_macros)
    local player_removed_set = macroListToSet(player_removed)
    local filtered_add_macros = add_macros

    if #player_removed > 0 then
        logTrace(string.format(
            "mergeAndWriteFleetBlacklist: player removed %d GT-written macro(s) from vanilla: [%s]",
            #player_removed, summarizeMacroList(player_removed)
        ))
        for _, macro in ipairs(player_removed) do
            AddUITriggeredEvent("gt_blacklist_manager", "VanillaSectorRemoved", macro)
        end
        filtered_add_macros = filterAddMacrosExcludingSet(add_macros, player_removed_set)
    end

    local final_macros = mergeFleetMacroList(vanilla_macros, filtered_add_macros, remove_macros)
    return writeFleetBlacklistMacros(final_macros, relation_value)
end

--- Backward-compatible alias used by init (relation-only refresh).
local function updateFleetBlacklist(threatened_macro_list, relation_value)
    return mergeAndWriteFleetBlacklist(threatened_macro_list or {}, {}, relation_value, false)
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
        logTrace("applyFleetBlacklistToAllShips: no fleet blacklist id to apply", "WARNING")
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

--- Parse MD update payload: adds (macro:level:ts|...) and optional #rem=macro|macro
local function parseUpdatePayload(event_data)
    if event_data == "!CLEAR!" then
        return true, {}, {}
    end

    local adds_part = event_data or ""
    local removes_part = ""
    local rem_pos = string.find(adds_part, "#rem=", 1, true)
    if rem_pos then
        removes_part = string.sub(adds_part, rem_pos + 5)
        adds_part = string.sub(adds_part, 1, rem_pos - 1)
    end

    local add_macros = {}
    local remove_macros = {}

    if adds_part ~= "" then
        for sector_entry in string.gmatch(adds_part, "([^|]+)") do
            local parts = {}
            for part in string.gmatch(sector_entry, "([^:]+)") do
                table.insert(parts, part)
            end
            if #parts >= 1 then
                local sector_macro = parts[1]
                if sector_macro and sector_macro ~= "" and sector_macro ~= "nil" then
                    table.insert(add_macros, sector_macro)
                    if #parts >= 3 then
                        GT_Blacklist.blacklisted_sectors[sector_macro] = {
                            threat_level = tonumber(parts[2]) or 0,
                            timestamp = tonumber(parts[3]) or 0,
                        }
                    end
                end
            end
        end
    end

    if removes_part ~= "" then
        for macro in string.gmatch(removes_part, "([^|]+)") do
            if macro and macro ~= "" and macro ~= "nil" then
                table.insert(remove_macros, macro)
            end
        end
    end

    return false, add_macros, remove_macros
end

--- Parse threat data from MD script format (legacy helper)
local function parseThreatData(threat_data_string)
    local _, add_macros, _ = parseUpdatePayload(threat_data_string)
    logTrace(string.format(
        "parseThreatData: %d macro(s) sample=[%s]",
        #add_macros, summarizeMacroList(add_macros)
    ))
    return add_macros
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

-- Track dropped updates when not initialized (always log first; then every 25th)
local dropped_update_count = 0

--- Initialize the blacklist system
local function onInitialize(_, event_data)
    local already_initialized = GT_Blacklist.initialized
    logTrace(string.format(
        "EVENT Initialize received (initialized=%s, payload_len=%d)",
        tostring(GT_Blacklist.initialized), event_data and #event_data or 0
    ))
    debugLog("Initializing GalaxyTrader Dynamic Blacklist System...")
    
    if already_initialized then
        logTrace("Initialize re-sync: refreshing settings and fleet blacklist shell")
        debugLog("System already initialized - re-syncing", "WARN")
    end
    
    -- Verify FFI functions are available
    if type(C.CreateBlacklist2) ~= "cdata" then
        logTrace("Initialize failed: CreateBlacklist2 FFI not available", "ERROR")
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
        logTrace(string.format(
            "Initialize payload parsed: relation='%s' existing_id=%s threshold=%s",
            tostring(parts[1] or ""), tostring(parts[2] or "0"), tostring(parts[3] or "3")
        ))
        debugLog(string.format("Parsed parts: [1]='%s', [2]='%s', [3]='%s'",
                 tostring(parts[1] or "nil"), tostring(parts[2] or "nil"), tostring(parts[3] or "nil")))
        relation_value = parts[1] or ""
        existing_id = tonumber(parts[2]) or 0
        threshold = tonumber(parts[3]) or 3
    else
        logTrace("Initialize payload empty - using defaults (relation='', id=0, threshold=3)", "WARNING")
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
    
    -- Create/Update blacklist shell (read-merge-write preserves any existing player sectors)
    local success = mergeAndWriteFleetBlacklist({}, {}, GT_Blacklist.relation_value, false)
    
    if not success then
        logTrace("Initialize failed: updateFleetBlacklist returned false", "ERROR")
        debugLog(" Failed to create/update blacklist", "WARN")
        return false
    end
    
    -- If we created a NEW blacklist, notify MD to store the ID
    if not already_initialized and existing_id == 0 and GT_Blacklist.fleet_blacklist_id then
        logTrace(string.format("Notifying MD BlacklistCreated id=%d", GT_Blacklist.fleet_blacklist_id))
        debugLog(string.format("Notifying MD of new blacklist ID: %d", GT_Blacklist.fleet_blacklist_id))
        AddUITriggeredEvent("gt_blacklist_manager", "BlacklistCreated", GT_Blacklist.fleet_blacklist_id)
    end

    -- Seed written snapshot from live vanilla when reusing an existing blacklist id
    if existing_id > 0 then
        rememberWrittenMacros(readFleetBlacklistMacros())
    end
    
    debugLog("Fleet blacklist initialized with faction-based blocking enabled")
    
    GT_Blacklist.initialized = true
    dropped_update_count = 0
    logTrace(string.format(
        "%s: id=%s threshold=%d relation='%s' (awaiting Update/ApplyToFleet)",
        already_initialized and "RE-SYNC OK" or "INIT OK",
        tostring(GT_Blacklist.fleet_blacklist_id), threshold, relation_value
    ))
    debugLog("Dynamic Blacklist System initialized successfully")
    
    return true
end

--- Update blacklists based on current threat data (read-merge-write)
local function onUpdateBlacklist(_, event_data)
    local payload_len = event_data and #event_data or 0
    if not GT_Blacklist.initialized then
        dropped_update_count = dropped_update_count + 1
        if dropped_update_count == 1 or (dropped_update_count % 25) == 0 then
            logTrace(string.format(
                "EVENT Update DROPPED (#%d): initialized=false payload_len=%d (MD sent update before Initialize?)",
                dropped_update_count, payload_len
            ), "WARNING")
        end
        debugLog("System not initialized - ignoring update request", "WARN")
        return false
    end

    logTrace(string.format("EVENT Update received payload_len=%d", payload_len))
    debugLog("Received blacklist update request")

    GT_Blacklist.blacklisted_sectors = {}
    local clear_all, add_macros, remove_macros = parseUpdatePayload(event_data or "")

    local ok = mergeAndWriteFleetBlacklist(add_macros, remove_macros, GT_Blacklist.relation_value, clear_all)
    if ok then
        AddUITriggeredEvent("gt_blacklist_manager", "BlacklistWritten", GT_Blacklist.last_written_fingerprint or "")
        logTrace(string.format(
            "EVENT Update applied: clear=%s adds=%d removes=%d final_macros=%d id=%s",
            tostring(clear_all), #add_macros, #remove_macros,
            #macroSetToSortedList(GT_Blacklist.last_written_macros),
            tostring(GT_Blacklist.fleet_blacklist_id)
        ))
    else
        logTrace("EVENT Update failed: mergeAndWriteFleetBlacklist returned false", "ERROR")
    end
    return ok
end

--- Apply blacklist to GT fleet ships
local function onApplyToFleet(_, event_data)
    if not GT_Blacklist.initialized then
        logTrace("EVENT ApplyToFleet DROPPED: initialized=false", "WARNING")
        debugLog("System not initialized - ignoring apply request", "WARN")
        return false
    end
    
    local ship_list = parseShipListPayload(event_data)
    logTrace(string.format(
        "EVENT ApplyToFleet received ships=%d fleet_id=%s",
        #ship_list, tostring(GT_Blacklist.fleet_blacklist_id)
    ))
    debugLog("Received fleet application request")
    
    if #ship_list == 0 then
        logTrace("EVENT ApplyToFleet failed: empty ship list", "ERROR")
        debugLog("No ship list provided", "ERROR")
        return false
    end
    
    local ok = applyFleetBlacklistToAllShips(ship_list)
    logTrace(string.format(
        "EVENT ApplyToFleet finished: ships=%d ok=%s fleet_id=%s",
        #ship_list, tostring(ok), tostring(GT_Blacklist.fleet_blacklist_id)
    ))
    return ok
end

--- Clean up expired threats and update blacklist
local function onCleanupExpired(_, event_data)
    if not GT_Blacklist.initialized then
        logTrace("EVENT CleanupExpired DROPPED: initialized=false", "WARNING")
        return false
    end
    
    logTrace(string.format("EVENT CleanupExpired received payload_len=%d", event_data and #event_data or 0))
    
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
    
    -- MD runs UpdateBlacklistOnThreat after cleanup; only prune local metadata here.
    cleanupExpiredThreats(current_time, expiry_time)

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
    logTrace("EVENT Recreate received - resetting initialized flag")
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
    logLoad("================================================================================")
    logLoad("GalaxyTrader MK3 - Dynamic Blacklist Manager Loading...")
    logLoad("================================================================================")
    
    -- Verify FFI availability
    if not ffi then
        logLoad("ERROR: FFI not available!", "ERROR")
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
            logLoad(string.format("Registered event: %s", event.name))
        else
            logLoad(string.format("Failed to register event: %s", event.name), "ERROR")
        end
    end

    logLoad("================================================================================")
    logLoad("Dynamic Blacklist Manager loaded successfully!")
    logLoad("Signalled MD: gt_blacklist_manager Ready")
    logLoad("Runtime state: initialized=false (waiting for GT_Blacklist.Initialize from MD)")
    logLoad("================================================================================")

    AddUITriggeredEvent("gt_blacklist_manager", "Ready", {})
    
    return true
end

-- Initialize module immediately
init()

-- Export module for debugging/testing
return GT_Blacklist

