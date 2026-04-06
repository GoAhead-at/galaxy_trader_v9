-- GalaxyTrader MK3 - Credits Due Overlay
--
-- Displays GT projected due directly after player money on the left-side
-- player info line (line 3), while leaving vanilla due text untouched.
--
-- DESIGN NOTE:
-- All attempts to create an independent overlay frame via
-- Helper.createFrameHandle + display() on a dedicated layer crash the
-- MapMenu widget engine with "frameElement nil" (widget_fullscreen.lua:16258).
-- The widget_fullscreen presentation only supports the layers the MapMenu
-- registers (mainFrameLayer=6, infoFrameLayer=5, contextFrameLayer=2).
-- Creating a frame on any other layer causes persistent crashes on every
-- update tick.
--
-- This approach hooks Helper.playerInfoConfigTextLeft and appends compact GT
-- text to line 3 (player money), avoiding new lines and preserving vanilla
-- right-side due display.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    UniverseID GetPlayerID(void);
]]

if not Helper or (not Helper.playerInfoConfigTextLeft and not Helper.playerInfoConfigInfoText) then
    DebugError("[GT CreditsDue] Required Helper player info text function(s) not found - override not installed")
    return
end

-- =============================================================================
-- STATE
-- =============================================================================

local state = {
    lastPoll = 0,
    enabled = false,
    projectedCredits = 0,
    lastLoggedCredits = nil,
    lastLoggedEnabled = nil,
    numberFormat = "german",
    useMSuffix = true,
    mSuffixThreshold = 999999,
}

-- =============================================================================
-- HELPERS
-- =============================================================================

local function isTruthy(value)
    if value == true then
        return true
    end
    if value == false or value == nil then
        return false
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        local lower = string.lower(value)
        return (lower == "true") or (lower == "1")
    end
    return false
end

local function addThousandsSeparators(value, sep)
    local s = tostring(math.floor(math.abs(value)))
    local out = s
    while true do
        local replaced, count = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1" .. sep .. "%2")
        out = replaced
        if count == 0 then
            break
        end
    end
    return out
end

local function formatCredits(creditsAmount)
    local credits = tonumber(creditsAmount) or 0
    local absCredits = math.abs(credits)
    local thousandSep = (state.numberFormat == "german") and "." or ","
    local decimalSep = (state.numberFormat == "german") and "," or "."
    local prefix = (credits < 0) and "-" or ""

    if state.useMSuffix and absCredits >= (tonumber(state.mSuffixThreshold) or 999999) then
        local mValue = absCredits / 1000000
        local intPart = math.floor(mValue)
        local fracPart = math.floor((mValue - intPart) * 10 + 0.5)
        if fracPart >= 10 then
            intPart = intPart + 1
            fracPart = 0
        end
        local text = tostring(intPart) .. decimalSep .. tostring(fracPart) .. " M Cr"
        return prefix .. text
    end

    return prefix .. addThousandsSeparators(absCredits, thousandSep) .. " Cr"
end

local function formatCreditsCompact(creditsAmount)
    local credits = tonumber(creditsAmount) or 0
    local absCredits = math.abs(credits)
    local thousandSep = (state.numberFormat == "german") and "." or ","
    local decimalSep = (state.numberFormat == "german") and "," or "."
    local prefix = (credits < 0) and "-" or ""

    if state.useMSuffix and absCredits >= (tonumber(state.mSuffixThreshold) or 999999) then
        local mValue = absCredits / 1000000
        local intPart = math.floor(mValue)
        local fracPart = math.floor((mValue - intPart) * 10 + 0.5)
        if fracPart >= 10 then
            intPart = intPart + 1
            fracPart = 0
        end
        return prefix .. tostring(intPart) .. decimalSep .. tostring(fracPart) .. "M Cr"
    end

    return prefix .. addThousandsSeparators(absCredits, thousandSep) .. " Cr"
end

local function splitLines(text)
    local lines = {}
    for line in string.gmatch((text or "") .. "\n", "(.-)\n") do
        table.insert(lines, line)
    end
    while #lines < 3 do
        table.insert(lines, "")
    end
    return lines
end

-- =============================================================================
-- BRIDGE DATA (MD -> Lua via player.entity blackboard)
-- =============================================================================

local function pollBridgeData()
    local now = getElapsedTime()
    if (state.lastPoll + 1) > now then
        return
    end
    state.lastPoll = now

    local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    if not playerId or playerId == 0 then
        return
    end

    state.enabled = isTruthy(GetNPCBlackboard(playerId, "$GT_UI_UseCreditsDueOverride"))
    -- Read the RAW field directly. GetNPCBlackboard auto-converts centicredits
    -- to credits when reading from player.entity, so NO division needed here.
    -- MD stores 427720000 (centicredits) → GetNPCBlackboard returns 4277200 (Cr).
    local projectedRaw = tonumber(GetNPCBlackboard(playerId, "$GT_UI_CreditsDueProjectedRaw")) or 0
    state.projectedCredits = projectedRaw
    state.numberFormat = GetNPCBlackboard(playerId, "$GT_UI_NumberFormat") or "german"
    state.useMSuffix = isTruthy(GetNPCBlackboard(playerId, "$GT_UI_UseMSuffix"))
    state.mSuffixThreshold = tonumber(GetNPCBlackboard(playerId, "$GT_UI_MSuffixThreshold")) or 999999

    if (state.numberFormat ~= "german") and (state.numberFormat ~= "english") then
        state.numberFormat = "german"
    end

    state.lastLoggedCredits = state.projectedCredits
    state.lastLoggedEnabled = state.enabled
end

-- =============================================================================
-- PLAYER INFO TEXT HOOKS
-- =============================================================================

local function getDefaultMoneyLineWidth()
    if not Helper or not Helper.playerInfoConfig then
        return nil
    end
    return Helper.playerInfoConfig.width - Helper.playerInfoConfig.height - 2 * Helper.borderSize
end

local function appendGtDueToMoneyLine(vanillaResult, width, ismultiverse)
    if ismultiverse then
        return vanillaResult
    end

    pollBridgeData()
    if not state.enabled then
        return vanillaResult
    end

    local gtCredits = tonumber(state.projectedCredits) or 0
    if gtCredits <= 0 then
        return vanillaResult
    end

    local lines = splitLines(vanillaResult)
    local moneyLineIndex = #lines
    if moneyLineIndex < 1 then
        return vanillaResult
    end

    local gtToken = ColorText["text_positive"] .. " | GT " .. formatCreditsCompact(gtCredits) .. "\27X"
    lines[moneyLineIndex] = (lines[moneyLineIndex] or "") .. gtToken

    local moneyLineWidth = width
    if not moneyLineWidth or moneyLineWidth <= 0 then
        moneyLineWidth = getDefaultMoneyLineWidth()
    end
    if moneyLineWidth and moneyLineWidth > 0 then
        lines[moneyLineIndex] = TruncateText(lines[moneyLineIndex], Helper.playerInfoConfig.fontname, Helper.playerInfoConfig.fontsize, moneyLineWidth)
    end

    return table.concat(lines, "\n")
end

-- Hook legacy 3-line panel path (used in some monitors).
if Helper.playerInfoConfigTextLeft then
    local originalPlayerInfoConfigTextLeft = Helper.playerInfoConfigTextLeft
    Helper.playerInfoConfigTextLeft = function(cell, width, ismultiverse)
        local vanillaResult = originalPlayerInfoConfigTextLeft(cell, width, ismultiverse)
        return appendGtDueToMoneyLine(vanillaResult, width, ismultiverse)
    end
end

-- Hook X4 9 map path (player panel now uses playerInfoConfigInfoText).
if Helper.playerInfoConfigInfoText then
    local originalPlayerInfoConfigInfoText = Helper.playerInfoConfigInfoText
    Helper.playerInfoConfigInfoText = function(cell, width, ismultiverse)
        local vanillaResult = originalPlayerInfoConfigInfoText(cell, width, ismultiverse)
        return appendGtDueToMoneyLine(vanillaResult, width, ismultiverse)
    end
end

DebugError("[GT CreditsDue] player info hook installed (TextLeft/InfoText inline money approach)")
