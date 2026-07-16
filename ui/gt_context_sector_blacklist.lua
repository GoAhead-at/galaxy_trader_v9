-- GalaxyTrader MK3 Sector Blacklist Diagnose
-- Light single-panel report for sector right-click GT Diagnose.
-- Scrollable content table (pilot-exchange / vanilla playerinfo pattern). No pagination.
-- Data: player.entity.$GT_SectorBL_Report (@@ / ;; / || same as ship diagnose)

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    UniverseID GetPlayerID(void);
    bool CopyToClipboard(const char*const text);
]]

local menu = Helper.getMenu("MapMenu")
if not menu then
    DebugError("[GT SectorBL] MapMenu not found - sector blacklist diagnose UI unavailable")
    return
end

if not GT_UI then
    DebugError("[GT SectorBL] ERROR: GT_UI library not loaded - check ui.xml load order")
    return
end

local CONTEXT_LAYER = 2

local gtSectorBL = {
    sections    = {},
    sectorId    = "",
    sectorName  = "",
    timestamp   = 0,
    frameWidth  = 0,
    frameHeight = 0,
    flatRows    = {},
}

function gtSectorBL.parseReport()
    local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

    local reportStr = GetNPCBlackboard(playerId, "$GT_SectorBL_Report")
    gtSectorBL.sectorId   = GetNPCBlackboard(playerId, "$GT_SectorBL_SectorId") or "???"
    gtSectorBL.sectorName = GetNPCBlackboard(playerId, "$GT_SectorBL_SectorName") or "Unknown"
    gtSectorBL.timestamp  = GetNPCBlackboard(playerId, "$GT_SectorBL_Timestamp") or 0

    if not reportStr or reportStr == "" then
        DebugError("[GT SectorBL] No report data on blackboard")
        return false
    end

    local sectionChunks = GT_UI.split(reportStr, "@@")
    gtSectorBL.sections = {}
    gtSectorBL.flatRows = {}

    for _, chunk in ipairs(sectionChunks) do
        local rowParts = GT_UI.split(chunk, ";;")
        if #rowParts > 0 then
            local section = {
                name = rowParts[1],
                rows = {},
            }
            table.insert(gtSectorBL.flatRows, {
                status = "INFO",
                check  = "--- " .. tostring(rowParts[1]) .. " ---",
                detail = "",
                isHeader = true,
            })
            for i = 2, #rowParts do
                local fields = GT_UI.split(rowParts[i], "||")
                local row = {
                    status = fields[1] or "INFO",
                    check  = fields[2] or "",
                    detail = fields[3] or "",
                }
                table.insert(section.rows, row)
                table.insert(gtSectorBL.flatRows, row)
            end
            table.insert(gtSectorBL.sections, section)
        end
    end

    DebugError(string.format("[GT SectorBL] Parsed %d sections / %d flat rows for %s",
        #gtSectorBL.sections, #gtSectorBL.flatRows, tostring(gtSectorBL.sectorId)))
    return #gtSectorBL.sections > 0
end

function gtSectorBL.buildPlainTextReport()
    local lines = {}
    table.insert(lines, string.format(
        "GT Sector Blacklist Report: %s (%s)",
        tostring(gtSectorBL.sectorName), tostring(gtSectorBL.sectorId)))
    table.insert(lines, string.format("Game time: %.0fs", gtSectorBL.timestamp or 0))
    table.insert(lines, "")

    for _, section in ipairs(gtSectorBL.sections) do
        table.insert(lines, "=== " .. tostring(section.name or "?") .. " ===")
        for _, row in ipairs(section.rows or {}) do
            table.insert(lines, string.format(
                "%s | %s | %s",
                tostring(row.check or ""),
                tostring(row.status or ""),
                tostring(row.detail or "")))
        end
        table.insert(lines, "")
    end

    return table.concat(lines, "\n")
end

function gtSectorBL.copyReportToClipboard()
    if #gtSectorBL.sections == 0 and not gtSectorBL.parseReport() then
        DebugError("[GT SectorBL] Copy failed: no report data")
        return false
    end
    local text = gtSectorBL.buildPlainTextReport()
    local success = C.CopyToClipboard(text)
    if success then
        DebugError(string.format("[GT SectorBL] Report copied (%d chars)", #text))
    else
        DebugError("[GT SectorBL] CopyToClipboard failed")
    end
    return success
end

function gtSectorBL.openReport(component)
    if not gtSectorBL.parseReport() then
        DebugError("[GT SectorBL] ERROR: Could not parse report data")
        return
    end

    local frameWidth  = math.min(Helper.viewWidth * 0.75, Helper.scaleX(1100))
    local frameHeight = math.min(Helper.viewHeight * 0.8, Helper.scaleY(800))
    gtSectorBL.frameWidth  = frameWidth
    gtSectorBL.frameHeight = frameHeight

    local xpos = (Helper.viewWidth - frameWidth) / 2
    local ypos = (Helper.viewHeight - frameHeight) / 2

    menu.contextMenuMode = "gt_sector_blacklist"
    menu.contextMenuData = {
        component = component,
        xoffset   = xpos,
        yoffset   = ypos,
        width     = frameWidth,
        frameHeight = frameHeight,
    }

    gtSectorBL.createAndDisplayFrame()
end

function gtSectorBL.createAndDisplayFrame()
    Helper.removeAllWidgetScripts(menu, CONTEXT_LAYER)

    menu.contextFrame = Helper.createFrameHandle(menu, {
        x                     = menu.contextMenuData.xoffset,
        y                     = menu.contextMenuData.yoffset,
        width                 = gtSectorBL.frameWidth,
        height                = gtSectorBL.frameHeight,
        layer                 = CONTEXT_LAYER,
        standardButtons       = { close = true },
        closeOnUnhandledClick = false,
    })
    menu.contextFrame:setBackground("solid", { color = GT_UI.COLORS.frameBg })

    gtSectorBL.populateFrame(menu.contextFrame)
    menu.contextFrame:display()
end

function gtSectorBL.populateFrame(frame)
    local width = gtSectorBL.frameWidth - 2 * Helper.borderSize
    local maxFrameHeight = gtSectorBL.frameHeight

    -- Title (separate table - not part of scroll min-height)
    local titleTable = frame:addTable(1, {
        tabOrder         = 1,
        x                = Helper.borderSize,
        y                = Helper.borderSize,
        width            = width,
        highlightMode    = "off",
        reserveScrollBar = false,
    })
    titleTable:addRow(true, {
        fixed   = true,
        bgColor = GT_UI.COLORS.headerBg,
    })[1]:createText(
        string.format("GT Sector Blacklist: %s (%s)",
            tostring(gtSectorBL.sectorName), tostring(gtSectorBL.sectorId)),
        {
            halign   = "center",
            font     = Helper.headerRow1Font,
            fontsize = Helper.headerRow1FontSize,
        }
    )

    -- Action/footer pinned to bottom first so scroll budget can fill the middle
    local actionTable = frame:addTable(1, {
        tabOrder         = 3,
        x                = Helper.borderSize,
        y                = 0,
        width            = width,
        highlightMode    = "off",
        reserveScrollBar = false,
    })

    local copyRow = actionTable:addRow(true, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    GT_UI.createButton(copyRow[1], "Copy Report", {
        fontSize = Helper.standardFontSize * 0.85,
        onClick  = function()
            gtSectorBL.copyReportToClipboard()
        end,
    })

    local clearRow = actionTable:addRow(true, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    GT_UI.createButton(clearRow[1], "Clear Orphans + Resync", {
        fontSize = Helper.standardFontSize * 0.85,
        onClick  = function()
            gtSectorBL.requestClearOrphans()
        end,
    })

    local allRows = gtSectorBL.flatRows or {}
    local totalRows = #allRows
    local footerRow = actionTable:addRow(true, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    footerRow[1]:createText(
        string.format("Game time %.0fs  |  %d rows  |  %d sections",
            gtSectorBL.timestamp or 0, totalRows, #gtSectorBL.sections),
        { halign = "center", fontsize = GT_UI.DEFAULTS.fontSize * 0.8 }
    )

    actionTable.properties.y = maxFrameHeight - actionTable:getFullHeight() - Helper.borderSize

    local scrollTableY = titleTable.properties.y + titleTable:getFullHeight() + Helper.borderSize
    local scrollBudget = actionTable.properties.y - scrollTableY - Helper.borderSize
    if scrollBudget < Helper.scaleY(Helper.standardTextHeight) * 4 then
        scrollBudget = Helper.scaleY(Helper.standardTextHeight) * 4
    end

    -- Interactive rows (addRow(true)) make mintableheight use the scroll viewport,
    -- not full content height - same pattern as pilot exchange planner.
    local contentTable = GT_UI.createScrollTable(frame, 3, {
        tabOrder         = 2,
        x                = Helper.borderSize,
        y                = scrollTableY,
        width            = width,
        maxVisibleHeight = scrollBudget,
        reserveScrollBar = false,
        highlightMode    = "off",
    })
    GT_UI.setColPercents(contentTable, { 22, 8 })

    GT_UI.addHeaderRow(contentTable, { "Check", "Status", "Detail" })

    local detailFontSize = GT_UI.DEFAULTS.fontSize * 0.85
    if totalRows == 0 then
        -- Must stay interactive so scroll min-height still uses the viewport.
        GT_UI.addDataRow(contentTable, {
            { text = "No data.", colSpan = 3, fontsize = detailFontSize, wordwrap = false },
        })
    else
        for _, row in ipairs(allRows) do
            local checkName = row.check or "?"
            local status    = row.status or "INFO"
            local detail    = row.detail or ""
            local statusColor = GT_UI.getStatusColor(status)
            local isSeparator = row.isHeader or (string.sub(checkName, 1, 3) == "---")
            local rowBg = isSeparator and GT_UI.COLORS.headerBg or nil

            GT_UI.addDataRow(contentTable, {
                { text = checkName, fontsize = detailFontSize, wordwrap = false },
                { text = isSeparator and "" or status, halign = "center",
                  fontsize = GT_UI.DEFAULTS.fontSize * 0.85, color = statusColor },
                { text = detail, fontsize = detailFontSize, wordwrap = false,
                  color = (status == "FAIL") and GT_UI.COLORS.textNegative or nil },
            }, { bgColor = rowBg })
        end
    end

    contentTable.properties.maxVisibleHeight = scrollBudget

    titleTable:addConnection(1, 2, true)
    contentTable:addConnection(2, 2)
    actionTable:addConnection(3, 2)

    frame.properties.height = maxFrameHeight

    if frame.properties.y + frame.properties.height + Helper.frameBorder > Helper.viewHeight then
        menu.contextMenuData.yoffset = Helper.viewHeight - frame.properties.height - Helper.frameBorder
        frame.properties.y = menu.contextMenuData.yoffset
    end

    DebugError(string.format(
        "[GT SectorBL] populate rows=%d scrollBudget=%d frameHeight=%d contentHeight=%d",
        totalRows, scrollBudget, maxFrameHeight, contentTable:getFullHeight()))
end

function gtSectorBL.requestClearOrphans()
    local playerSignalId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    local playerBbId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    local macro = gtSectorBL.sectorId or GetNPCBlackboard(playerBbId, "$GT_SectorBL_SectorId") or ""
    SetNPCBlackboard(playerBbId, "$GT_SectorBL_ClearOrphansMacro", tostring(macro))
    DebugError(string.format("[GT SectorBL] Clear Orphans + Resync requested for macro=%s", tostring(macro)))
    SignalObject(playerSignalId, "gt_sector_bl_clear_orphans")
end

-- Keep MapMenu from wiping our custom context frame (same pattern as ship diagnose).
local origCreateCtx = menu.createContextFrame
menu.createContextFrame = function(width, height, xoffset, yoffset, noborder, startanimation, ...)
    if menu.contextMenuMode == "gt_sector_blacklist" then
        return menu.contextFrame
    end
    if origCreateCtx then
        return origCreateCtx(width, height, xoffset, yoffset, noborder, startanimation, ...)
    end
end

local origRefreshCtx = menu.refreshContextFrame
menu.refreshContextFrame = function(setrow, setcol, noborder, ...)
    if menu.contextMenuMode == "gt_sector_blacklist" then
        if menu.contextFrame then
            menu.contextFrame:display()
        end
        return
    end
    if origRefreshCtx then
        origRefreshCtx(setrow, setcol, noborder, ...)
    end
end

RegisterEvent("gt.openSectorBlacklistReport", function(_, component)
    DebugError("[GT SectorBL] Lua: Event gt.openSectorBlacklistReport received")
    gtSectorBL.openReport(component)
end)

DebugError("[GT SectorBL] Sector blacklist diagnose UI loaded (scrollable)")
