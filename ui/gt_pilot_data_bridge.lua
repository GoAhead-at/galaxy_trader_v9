--[[
==============================================================================
GalaxyTrader MK3 - Pilot Data Bridge
==============================================================================
Bridges MD pilot/ship data with Lua UI for the Info Menu

Features:
- Receives pilot data from MD via events
- Stores data in Lua-accessible format
- Provides data to gt_info_menu.lua for display

Dependencies: 
- sn_mod_support_apis (Lua Loader API)

Author: GalaxyTrader Development Team
Version: 1.0
==============================================================================
]]--

local ffi = require("ffi")
local C = ffi.C

-- =============================================================================
-- FFI DEFINITIONS
-- =============================================================================

ffi.cdef[[
    const char* GetComponentName(uint64_t componentid);
    uint64_t ConvertStringTo64Bit(const char* idcode);
    const char* ConvertIDToString(uint64_t componentid);
]]

-- =============================================================================
-- MODULE STATE
-- =============================================================================

local GT_PilotData = {
    -- Configuration
    CONFIG = {
        DEBUG_MODE = false,  -- Set to true to enable debug logging
    },
    
    -- Global settings (received from MD)
    settings = {
        autoTraining = true,    -- Default: automatic training enabled
        autoRepair = true,      -- Default: automatic repair enabled
        autoResupply = true,    -- Default: automatic resupply enabled
        pilotRenamingEnabled = false, -- Default: pilot rename tags disabled until synced from MD
    },
    
    -- Pilot data storage (received from MD)
    pilots = {},  -- Array of pilot info tables
    gtNameIndex = {},  -- Set of normalized GT pilot names (includes paused pilots)
    gtNameMap = {},  -- normalized base name -> tagged display name
    gtPilotIdMap = {},  -- pilot idcode -> tagged display name
    lastUpdate = 0,
    initialized = false,
}

-- =============================================================================
-- DEBUG LOGGING
-- =============================================================================

local function debugLog(message)
    if GT_PilotData.CONFIG.DEBUG_MODE then
        DebugError("[GT Pilot Bridge] " .. tostring(message))
    end
end

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Format money - delegate to GT_UI library (single source of truth)
local function formatMoney(amount)
    if GT_UI and GT_UI.formatMoney then
        return GT_UI.formatMoney(amount)
    end
    -- Fallback if library not loaded (shouldn't happen)
    local credits = amount / 100
    if credits >= 1000000000 then
        return string.format("%.1fB Cr", credits / 1000000000)
    elseif credits >= 1000000 then
        return string.format("%.1fM Cr", credits / 1000000)
    else
        return ConvertMoneyString(amount, false, false, 0, true)
    end
end

local function normalizePilotName(name)
    if not name then
        return ""
    end

    local normalized = tostring(name)
    -- Strip GT training prefix for matching against vanilla UI names.
    normalized = normalized:gsub("^%(T:%d+%)%s*", "")
    -- Trim whitespace.
    normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
    normalized = string.lower(normalized)
    return normalized
end

local function normalizeUniquePilotKey(key)
    if key == nil then
        return ""
    end
    local s = tostring(key)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    -- NPC seed strings can appear as "123...ULL" in Lua; normalize to bare digits.
    s = s:gsub("[Uu][Ll][Ll]$", "")
    s = s:gsub("[Ll][Ll]$", "")
    s = s:gsub("[Uu][Ll]$", "")
    s = s:gsub("[Uu]$", "")
    return s
end

-- MD may stringify hi/lo as signed 32-bit negatives; fold to unsigned before uint64 combine.
local function uint32FromWire(s)
    local n = tonumber(s)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    n = n % 4294967296
    if n < 0 then
        n = n + 4294967296
    end
    return n
end

-- Reconstruct exact NPC seed decimal string from MD u64p:hi32:lo32 wire (avoids FP rounding for seeds > 2^53).
local function u64DecimalStringFromHiLo(hiStr, loStr)
    local hiU = uint32FromWire(hiStr)
    local loU = uint32FromWire(loStr)
    if hiU == nil or loU == nil then
        return nil
    end
    local mult = ffi.new("uint64_t", 4294967296)
    local u = ffi.new("uint64_t", hiU) * mult + ffi.new("uint64_t", loU)
    return tostring(u)
end

-- Prefer engine uint64 (cdata); tostring(NPCSeed) alone can disagree with map keys for some builds.
local function npcSeedToCanonicalDecimalString(person)
    if person == nil then
        return nil
    end
    local ok, u = pcall(function()
        return ffi.cast("uint64_t", person)
    end)
    if ok and u ~= nil then
        return normalizeUniquePilotKey(tostring(u))
    end
    local s = normalizeUniquePilotKey(tostring(person))
    if not s or s == "" then
        return nil
    end
    if not s:match("^%-?%d+$") then
        return nil
    end
    local ok2, dec = pcall(function()
        if s:sub(1, 1) == "-" then
            return tostring(ffi.cast("uint64_t", ffi.new("int64_t", s)))
        end
        return tostring(ffi.new("uint64_t", s))
    end)
    if ok2 then
        return normalizeUniquePilotKey(dec)
    end
    return nil
end

-- All string keys we store for one logical id (matches MapMenu / MD wire).
local function collectPilotIdAliasKeys(keyRaw)
    local out = {}
    local seen = {}
    local function add(k)
        if k and k ~= "" and not seen[k] then
            seen[k] = true
            table.insert(out, k)
        end
    end
    if not keyRaw or keyRaw == "" then
        return out
    end
    add(keyRaw)
    local nk = normalizeUniquePilotKey(keyRaw)
    if nk ~= "" and nk ~= keyRaw then
        add(nk)
    end
    local body = nk:match("^s:(.+)$") or nk
    if not body:match("^%-?%d+$") then
        return out
    end

    local ok, u64, i64 = pcall(function()
        if body:sub(1, 1) == "-" then
            local i = ffi.new("int64_t", body)
            local u = ffi.cast("uint64_t", i)
            return u, i
        else
            local u = ffi.new("uint64_t", body)
            local i = ffi.cast("int64_t", u)
            return u, i
        end
    end)
    if not ok or not u64 or not i64 then
        return out
    end

    local u64s = tostring(u64)
    local i64s = tostring(i64)
    local u64n = normalizeUniquePilotKey(u64s)
    local i64n = normalizeUniquePilotKey(i64s)

    add(u64s)
    add(i64s)
    add(u64n)
    add(i64n)
    add("s:" .. u64s)
    add("s:" .. i64s)
    add("s:" .. u64n)
    add("s:" .. i64n)
    return out
end

-- MapMenu crew rows use tostring(NPCSeed) as unsigned decimal; MD may send the same 64-bit value
-- as signed (s:-…) or with s: prefix. Register all equivalent string keys so strict lookup succeeds.
local function addPilotIdMapKeyWithInt64Aliases(idMap, taggedName, keyRaw)
    if not keyRaw or keyRaw == "" or not taggedName or taggedName == "" then
        return 0
    end
    local added = 0
    for _, k in ipairs(collectPilotIdAliasKeys(keyRaw)) do
        if idMap[k] == nil then
            added = added + 1
        end
        idMap[k] = taggedName
    end
    return added
end

-- =============================================================================
-- DATA RECEPTION FROM MD
-- =============================================================================

-- Receive pilot data from MD
-- Expected format: "CONFIG:autoTraining|autoRepair|autoResupply||shipId|pilotName|...|tradeCount||..."
-- Config flags separated by "|", pilots separated by "||"
local function onReceivePilotData(_, param)
    debugLog("Received pilot data from MD")
    
    if not param or param == "" then
        debugLog("No pilot data received (empty)")
        GT_PilotData.pilots = {}
        return
    end
    
    -- Parse the data string
    local pilots = {}
    local pilotStrings = {}
    
    -- Split by pilot separator "||" (double pipe)
    -- Use pattern that captures everything up to double-pipe or end of string
    for pilotStr in string.gmatch(param .. "||", "(.-)||") do
        if pilotStr ~= "" then
            table.insert(pilotStrings, pilotStr)
        end
    end
    
    debugLog(string.format("Parsing %d records (including config)", #pilotStrings))
    
    -- Check if first record is config data
    local startIndex = 1
    if #pilotStrings > 0 and string.sub(pilotStrings[1], 1, 7) == "CONFIG:" then
        local configStr = string.sub(pilotStrings[1], 8)  -- Remove "CONFIG:" prefix
        local configFields = {}
        for field in string.gmatch(configStr, "[^|]+") do
            table.insert(configFields, field)
        end
        
        if #configFields >= 3 then
            GT_PilotData.settings.autoTraining = (tonumber(configFields[1]) or 1) ~= 0
            GT_PilotData.settings.autoRepair = (tonumber(configFields[2]) or 1) ~= 0
            GT_PilotData.settings.autoResupply = (tonumber(configFields[3]) or 1) ~= 0
            GT_PilotData.settings.pilotRenamingEnabled = (tonumber(configFields[4]) or 0) ~= 0
            
            debugLog(string.format("Config flags: AutoTraining=%s, AutoRepair=%s, AutoResupply=%s, PilotRenamingEnabled=%s",
                tostring(GT_PilotData.settings.autoTraining),
                tostring(GT_PilotData.settings.autoRepair),
                tostring(GT_PilotData.settings.autoResupply),
                tostring(GT_PilotData.settings.pilotRenamingEnabled)))
        end
        
        startIndex = 2  -- Skip config record, start parsing pilots from index 2
    end
    
    debugLog(string.format("Parsing %d pilot records", #pilotStrings - startIndex + 1))
    
    for i = startIndex, #pilotStrings do
        local pilotStr = pilotStrings[i]
        
        -- Split pilot data by pipe (handling empty fields correctly)
        -- Pattern [^|]+ skips empty fields, causing field misalignment
        -- Use manual splitting to preserve empty fields
        local fields = {}
        local startPos = 1
        while startPos <= #pilotStr do
            local endPos = string.find(pilotStr, "|", startPos)
            if endPos == nil then
                -- Last field (no trailing pipe)
                table.insert(fields, string.sub(pilotStr, startPos))
                break
            else
                -- Field ends at pipe (includes empty fields)
                table.insert(fields, string.sub(pilotStr, startPos, endPos - 1))
                startPos = endPos + 1
            end
        end
        
        if #fields >= 13 then
            local pilotInfo = {
                shipId = fields[1] or "???",
                pilotName = fields[2] or "Unknown",
                shipType = fields[3] or "Unknown Ship",
                status = fields[4] or "[ADVANCE]",  -- Already formatted by MD
                rank = fields[5] or "Apprentice",
                rankIndex = tonumber(fields[6]) or 1,
                level = tonumber(fields[7]) or 1,
                xp = tonumber(fields[8]) or 0,
                xpNext = tonumber(fields[9]) or 1000,
                pilotProfit = tonumber(fields[10]) or 0,  -- Pilot's lifetime profit (follows pilot)
                shipProfit = tonumber(fields[11]) or 0,   -- Ship's profit (current ship)
                location = fields[12] or "Unknown",
                tradeCount = tonumber(fields[13]) or 0,
                blockedLevel = tonumber(fields[14]) or 0,
            }
            pilotInfo.trainingBlocked = pilotInfo.blockedLevel > 1
            
            -- Format XP for display
            pilotInfo.xpFormatted = string.format("%s / %s",
                ConvertIntegerString(pilotInfo.xp, true, 0, true),
                ConvertIntegerString(pilotInfo.xpNext, true, 0, true))
            
            -- Format both profit values for display
            pilotInfo.pilotProfitFormatted = formatMoney(pilotInfo.pilotProfit)
            pilotInfo.shipProfitFormatted = formatMoney(pilotInfo.shipProfit)
            
            table.insert(pilots, pilotInfo)
            
            debugLog(string.format("  Pilot %d: %s (%s) - Level %d, Pilot: %s Cr, Ship: %s Cr", 
                i, pilotInfo.pilotName, pilotInfo.shipType, pilotInfo.level, 
                pilotInfo.pilotProfitFormatted, pilotInfo.shipProfitFormatted))
        else
            debugLog(string.format("  WARNING: Pilot %d has incomplete data (%d fields)", i, #fields))
        end
    end
    
    GT_PilotData.pilots = pilots
    GT_PilotData.lastUpdate = getElapsedTime()
    GT_PilotData.initialized = true
    
    debugLog(string.format("Stored %d pilots in Lua", #pilots))
    
    -- Trigger UI refresh if menu is open
    if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.InfoMenu and Mods.GalaxyTrader.InfoMenu.onDataUpdate then
        Mods.GalaxyTrader.InfoMenu.onDataUpdate()
    end
end

-- Receive GT name index from MD
-- Expected format: "Name1||Name2||Name3"
local function onReceivePilotNameIndex(_, param)
    local index = {}
    local entryCount = 0

    if param and param ~= "" then
        for nameStr in string.gmatch(param .. "||", "(.-)||") do
            if nameStr ~= "" then
                local normalized = normalizePilotName(nameStr)
                if normalized ~= "" then
                    if not index[normalized] then
                        entryCount = entryCount + 1
                    end
                    index[normalized] = true
                end
            end
        end
    end

    GT_PilotData.gtNameIndex = index
    debugLog(string.format("Updated GT name index with %d entries", entryCount))
end

-- Receive GT name -> tagged-name map from MD
-- Expected format: "Base Name|Tagged Name||Base2|Tagged2"
local function onReceivePilotNameMap(_, param)
    local nameMap = {}
    local entryCount = 0

    if param and param ~= "" then
        for mapStr in string.gmatch(param .. "||", "(.-)||") do
            if mapStr ~= "" then
                local baseName, taggedName = string.match(mapStr, "^(.-)|(.*)$")
                if baseName and taggedName and baseName ~= "" and taggedName ~= "" then
                    local normalized = normalizePilotName(baseName)
                    if normalized ~= "" then
                        if not nameMap[normalized] then
                            entryCount = entryCount + 1
                        end
                        nameMap[normalized] = taggedName
                    end
                end
            end
        end
    end

    GT_PilotData.gtNameMap = nameMap
    debugLog(string.format("Updated GT name map with %d entries", entryCount))
end

-- Receive GT pilot-id -> tagged-name map from MD
-- Expected format: "PILOTID1|Tagged Name1||PILOTID2|Tagged Name2"
-- Merges into the existing Lua map: MD snapshots can be partial after vanilla crew
-- swaps / reassignment; a full replace dropped seeds still shown in MapMenu crew rows.
local function onReceivePilotIdMap(_, param)
    local prev = GT_PilotData.gtPilotIdMap or {}
    local prevKeyCount = 0
    for _ in pairs(prev) do
        prevKeyCount = prevKeyCount + 1
    end

    local idMap = {}
    for k, v in pairs(prev) do
        idMap[k] = v
    end

    local entryCount = 0
    local malformedCount = 0
    local u64WireCount = 0
    local u64DecodedCount = 0
    local u64DecodeFailed = 0
    local aliasKeyAdds = 0
    local sampleKeys = {}

    if param and param ~= "" then
        for mapStr in string.gmatch(param .. "||", "(.-)||") do
            if mapStr ~= "" then
                local pilotId, taggedName = string.match(mapStr, "^(.-)|(.*)$")
                if pilotId and taggedName and pilotId ~= "" and taggedName ~= "" then
                    entryCount = entryCount + 1
                    if #sampleKeys < 5 then
                        table.insert(sampleKeys, tostring(pilotId))
                    end
                    -- MD wire may send signed 32-bit halves (e.g. negative hi/lo); accept both signs.
                    local hi32, lo32 = string.match(pilotId, "^u64p:(%-?%d+):(%-?%d+)$")
                    local keyForAliases = pilotId
                    if hi32 and lo32 then
                        u64WireCount = u64WireCount + 1
                        local dec = u64DecimalStringFromHiLo(hi32, lo32)
                        if dec then
                            u64DecodedCount = u64DecodedCount + 1
                            keyForAliases = dec
                        else
                            u64DecodeFailed = u64DecodeFailed + 1
                        end
                    end
                    idMap[pilotId] = taggedName -- keep raw wire key for diagnostics
                    aliasKeyAdds = aliasKeyAdds + addPilotIdMapKeyWithInt64Aliases(idMap, taggedName, keyForAliases)
                else
                    malformedCount = malformedCount + 1
                end
            end
        end
    end

    local totalKeys = 0
    for _ in pairs(idMap) do
        totalKeys = totalKeys + 1
    end

    -- Never replace a good map with an empty snapshot: MD can raise this during
    -- SendPilotData "early" branch or transient registry races (crew UI refresh).
    if entryCount == 0 then
        if prevKeyCount > 0 then
            DebugError(string.format(
                "[GT Pilot Bridge] PilotIdMap skipped empty update (keeping %d keys; raw_len=%d)",
                prevKeyCount,
                string.len(tostring(param or ""))
            ))
        end
        return
    end

    GT_PilotData.gtPilotIdMap = idMap
    DebugError(string.format(
        "[GT Pilot Bridge] PilotIdMap merged: incomingLogical=%d totalKeys=%d prevKeys=%d malformed=%d wireU64=%d decodedU64=%d decodeFail=%d aliasAdds=%d raw_len=%d sampleKeys=[%s]",
        entryCount,
        totalKeys,
        prevKeyCount,
        malformedCount,
        u64WireCount,
        u64DecodedCount,
        u64DecodeFailed,
        aliasKeyAdds,
        string.len(tostring(param or "")),
        table.concat(sampleKeys, ", ")
    ))
    debugLog(string.format("Updated GT pilot id map: %d logical entries, %d lookup keys (malformed=%d, wire=%d, decoded=%d, decodeFail=%d, aliasAdds=%d)", entryCount, totalKeys, malformedCount, u64WireCount, u64DecodedCount, u64DecodeFailed, aliasKeyAdds))
    if malformedCount > 0 then
        DebugError(string.format("[GT Pilot Bridge] WARNING: Received malformed PilotIdMap entries: %d", malformedCount))
    end
    if u64DecodeFailed > 0 then
        DebugError(string.format("[GT Pilot Bridge] WARNING: u64p decode failed for %d entries (wire=%d decoded=%d)", u64DecodeFailed, u64WireCount, u64DecodedCount))
    end
end

-- =============================================================================
-- PUBLIC API (for gt_info_menu.lua)
-- =============================================================================

-- Crew highlight: resolve tagged name using same alias keys as PilotIdMap (NPCSeed cdata-safe).
function GT_PilotData.lookupPilotIdMapTaggedName(idMap, person)
    if not idMap then
        return nil, nil
    end

    local function tryKey(k)
        if not k or k == "" then
            return nil, nil
        end
        local v = idMap[k]
        if v and v ~= "" then
            return v, k
        end
        local nk = normalizeUniquePilotKey(tostring(k))
        if nk and nk ~= "" and nk ~= tostring(k) then
            v = idMap[nk]
            if v and v ~= "" then
                return v, nk
            end
        end
        return nil, nil
    end

    -- Fast path: exact decimal and s:<signed int64> (must match MD StableIdentity / MapMenu).
    local dec = npcSeedToCanonicalDecimalString(person)
    if dec then
        local v, kk = tryKey(dec)
        if v then
            return v, kk
        end
        local decNorm = normalizeUniquePilotKey(dec)
        if decNorm and decNorm ~= "" and decNorm ~= dec then
            v, kk = tryKey(decNorm)
            if v then
                return v, kk
            end
        end
        local ok, u = pcall(function()
            return ffi.new("uint64_t", decNorm or dec)
        end)
        if ok and u then
            local i64 = ffi.cast("int64_t", u)
            v, kk = tryKey("s:" .. normalizeUniquePilotKey(tostring(i64)))
            if v then
                return v, kk
            end
            v, kk = tryKey(normalizeUniquePilotKey(tostring(u)))
            if v then
                return v, kk
            end
        end
    end

    local seen = {}
    local function probe(keyRaw)
        for _, k in ipairs(collectPilotIdAliasKeys(keyRaw)) do
            if not seen[k] then
                seen[k] = true
                local v, kk = tryKey(k)
                if v then
                    return v, kk
                end
            end
        end
        return nil, nil
    end

    local v, k = probe(dec)
    if v then
        return v, k
    end
    v, k = probe(normalizeUniquePilotKey(tostring(person)))
    if v then
        return v, k
    end
    return probe(tostring(person))
end

-- One-shot diagnostic when a crew row does not match any GT pilot id (expected for non-GT NPCs).
function GT_PilotData.diagnosePilotIdMapMiss(idMap, person, label)
    local canon = npcSeedToCanonicalDecimalString(person)
    local samples = {}
    local n = 0
    for key, val in pairs(idMap or {}) do
        if n < 10 then
            n = n + 1
            local vs = tostring(val)
            if string.len(vs) > 48 then
                vs = string.sub(vs, 1, 45) .. "..."
            end
            table.insert(samples, tostring(key) .. "=>" .. vs)
        end
    end
    DebugError(string.format(
        "[GT Pilot Bridge] lookup miss %s type=%s tostring=%s canonicalFFI=%s sampleKeys=[%s]",
        tostring(label or ""),
        type(person),
        tostring(person),
        tostring(canon),
        table.concat(samples, " | ")
    ))
end

function GT_PilotData.getPilots()
    -- Return a COPY of the pilots array to prevent external sorting from modifying our stored data
    local pilots = GT_PilotData.pilots or {}
    local copy = {}
    for i = 1, #pilots do
        copy[i] = pilots[i]
    end
    return copy
end

function GT_PilotData.getLastUpdate()
    return GT_PilotData.lastUpdate
end

function GT_PilotData.isInitialized()
    return GT_PilotData.initialized
end

function GT_PilotData.requestRefresh()
    debugLog("Refresh requested - sending event to MD")
    AddUITriggeredEvent("gt_pilot_data_bridge", "RequestPilotData", 1)
end

function GT_PilotData.getGTNameIndex()
    return GT_PilotData.gtNameIndex or {}
end

function GT_PilotData.getGTNameMap()
    return GT_PilotData.gtNameMap or {}
end

function GT_PilotData.getGTPilotIdMap()
    return GT_PilotData.gtPilotIdMap or {}
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

local function init()
    debugLog("Initializing GT Pilot Data Bridge")
    
    -- Register event listener for pilot data from MD
    RegisterEvent("GT_PilotData.Update", onReceivePilotData)
    RegisterEvent("GT_PilotNameIndex.Update", onReceivePilotNameIndex)
    RegisterEvent("GT_PilotNameMap.Update", onReceivePilotNameMap)
    RegisterEvent("GT_PilotIdMap.Update", onReceivePilotIdMap)
    
    debugLog("GT Pilot Data Bridge initialized - waiting for data from MD")
    -- Prime data once so MapMenu hooks have index data immediately.
    GT_PilotData.requestRefresh()
end

-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

-- Export to global scope so gt_info_menu.lua can access it
if not Mods then Mods = {} end
if not Mods.GalaxyTrader then Mods.GalaxyTrader = {} end
Mods.GalaxyTrader.PilotData = GT_PilotData

-- Initialize on load
init()

return GT_PilotData

