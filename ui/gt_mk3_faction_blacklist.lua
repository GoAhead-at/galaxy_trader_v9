-- MK3 per-ship faction blacklist (test UI)
-- Opens from interact menu action and lets player toggle dynamic faction entries.

local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
    typedef uint64_t UniverseID;
    UniverseID GetPlayerID(void);
]]

local menu = Helper.getMenu("MapMenu")
if not menu then
    DebugError("[GT MK3 FactionBlacklist] MapMenu not found - UI disabled")
    return
end

if not GT_UI then
    DebugError("[GT MK3 FactionBlacklist] GT_UI library not loaded - UI disabled")
    return
end

local state = {
    shipName = "Unknown",
    shipCode = "UNK",
    rows = {},
}

local function readBlackboard()
    local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    local data = GetNPCBlackboard(playerId, "$GT_MK3FBL_Data") or ""
    state.shipName = GetNPCBlackboard(playerId, "$GT_MK3FBL_ShipName") or "Unknown"
    state.shipCode = GetNPCBlackboard(playerId, "$GT_MK3FBL_ShipCode") or "UNK"
    state.rows = {}

    local entries = GT_UI.split(data, "@@")
    for _, entry in ipairs(entries) do
        if entry ~= "" then
            local fields = GT_UI.split(entry, "||")
            if #fields >= 3 then
                local idx = tonumber(fields[1]) or 0
                local name = tostring(fields[2] or "Unknown Faction")
                local selected = tostring(fields[3] or "0") == "1"
                if idx > 0 then
                    table.insert(state.rows, {
                        index = idx,
                        name = name,
                        selected = selected,
                    })
                end
            end
        end
    end
end

local function createFrame()
    local contextLayer = 2
    Helper.removeAllWidgetScripts(menu, contextLayer)

    local width = math.min(Helper.viewWidth * 0.62, Helper.scaleX(950))
    local height = math.min(Helper.viewHeight * 0.75, Helper.scaleY(860))
    local xpos = (Helper.viewWidth - width) / 2
    local ypos = (Helper.viewHeight - height) / 2

    menu.contextMenuMode = "gt_mk3_faction_blacklist"
    menu.contextMenuData = {
        xoffset = xpos,
        yoffset = ypos,
        width = width,
    }

    menu.contextFrame = Helper.createFrameHandle(menu, {
        x = xpos,
        y = ypos,
        width = width,
        height = height,
        layer = contextLayer,
        standardButtons = { close = true },
        closeOnUnhandledClick = false,
    })
    menu.contextFrame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

    local innerWidth = width - 2 * Helper.borderSize
    local titleTable = menu.contextFrame:addTable(1, {
        x = Helper.borderSize,
        y = Helper.borderSize,
        width = innerWidth,
        reserveScrollBar = false,
        highlightMode = "off",
    })
    local trow = titleTable:addRow(nil, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    trow[1]:createText("MK3 Faction Blacklist - " .. tostring(state.shipName) .. " (" .. tostring(state.shipCode) .. ")", {
        halign = "center",
        font = Helper.headerRow1Font,
        fontsize = Helper.headerRow1FontSize,
    })

    local headerY = Helper.borderSize + Helper.headerRow1FontSize + 16
    local listTable = GT_UI.createScrollTable(menu.contextFrame, 3, {
        x = Helper.borderSize,
        y = headerY,
        width = innerWidth,
        maxVisibleHeight = height - headerY - Helper.scaleY(16),
        tabOrder = 1,
        highlightMode = "off",
    })
    -- Keep last column flexible to avoid reserveScrollBar/fixed-width issues.
    GT_UI.setColPercents(listTable, { 8, 62 })

    GT_UI.addHeaderRow(listTable, {
        { text = "#", halign = "center" },
        "Faction",
        { text = "State", halign = "center" },
    })

    if #state.rows == 0 then
        GT_UI.addEmptyRow(listTable, "No active factions available.", 3)
    end

    for _, row in ipairs(state.rows) do
        local r = listTable:addRow(true, { bgColor = GT_UI.COLORS.tabInactiveBg })
        r[1]:createText(tostring(row.index), { halign = "center" })
        r[2]:createText(row.name, { halign = "left" })
        local buttonText = row.selected and "Blocked" or "Allowed"
        local buttonColor = row.selected and GT_UI.COLORS.textNegative or GT_UI.COLORS.textPositive
        r[3]:createButton({ active = true }):setText(buttonText, { halign = "center", color = buttonColor })
        r[3].handlers.onClick = function()
            AddUITriggeredEvent("GT_MK3FactionBlacklist", "ToggleFaction", { index = row.index })
        end
    end

    menu.contextFrame:display()
end

local origCreateCtx = menu.createContextFrame
menu.createContextFrame = function(width, height, xoffset, yoffset, noborder, startanimation, ...)
    if menu.contextMenuMode == "gt_mk3_faction_blacklist" then
        return menu.contextFrame
    end
    if origCreateCtx then
        return origCreateCtx(width, height, xoffset, yoffset, noborder, startanimation, ...)
    end
end

local origRefreshCtx = menu.refreshContextFrame
menu.refreshContextFrame = function(setrow, setcol, noborder, ...)
    if menu.contextMenuMode == "gt_mk3_faction_blacklist" then
        if menu.contextFrame then
            menu.contextFrame:display()
        end
        return
    end
    if origRefreshCtx then
        origRefreshCtx(setrow, setcol, noborder, ...)
    end
end

RegisterEvent("gt.openMK3FactionBlacklist", function()
    readBlackboard()
    createFrame()
end)

RegisterEvent("gt.refreshMK3FactionBlacklist", function()
    if menu.contextMenuMode == "gt_mk3_faction_blacklist" then
        readBlackboard()
        createFrame()
    end
end)
