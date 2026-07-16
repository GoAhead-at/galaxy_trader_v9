-- GalaxyTrader MK3 Sector Blacklist Diagnose
-- Light single-panel report for sector right-click GT Diagnose.
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

local gtSectorBL = {
    sections    = {},
    sectorId    = "",
    sectorName  = "",
    timestamp   = 0,
    currentPage = 1,
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

    gtSectorBL.currentPage = 1

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
    }

    gtSectorBL.createAndDisplayFrame()
end

function gtSectorBL.createAndDisplayFrame()
    local contextLayer = 2
    Helper.removeAllWidgetScripts(menu, contextLayer)

    menu.contextFrame = Helper.createFrameHandle(menu, {
        x                     = menu.contextMenuData.xoffset,
        y                     = menu.contextMenuData.yoffset,
        width                 = gtSectorBL.frameWidth,
        height                = gtSectorBL.frameHeight,
        layer                 = contextLayer,
        standardButtons       = { close = true },
        closeOnUnhandledClick = false,
    })
    menu.contextFrame:setBackground("solid", { color = GT_UI.COLORS.frameBg })

    gtSectorBL.populateFrame(menu.contextFrame)
    menu.contextFrame:display()
end

function gtSectorBL.populateFrame(frame)
    local width = gtSectorBL.frameWidth - 2 * Helper.borderSize

    local titleTable = frame:addTable(1, {
        tabOrder         = 0,
        x                = Helper.borderSize,
        y                = Helper.borderSize,
        width            = width,
        highlightMode    = "off",
        reserveScrollBar = false,
    })
    local titleRow = titleTable:addRow(nil, {
        fixed   = true,
        bgColor = GT_UI.COLORS.headerBg,
    })
    titleRow[1]:createText(
        string.format("GT Sector Blacklist: %s (%s)",
            tostring(gtSectorBL.sectorName), tostring(gtSectorBL.sectorId)),
        {
            halign   = "center",
            font     = Helper.headerRow1Font,
            fontsize = Helper.headerRow1FontSize,
        }
    )
    local titleHeight = Helper.headerRow1FontSize + 10
    local contentY = titleHeight + Helper.borderSize + 8

    -- Action/footer table sits below content. Keep it out of the scroll table:
    -- X4 computes full table min-height even with maxVisibleHeight, and an extra
    -- button row already overflowed by ~37px (empty window) at 60 flat rows.
    local rowH = GT_UI.DEFAULTS.rowHeight or Helper.standardTextHeight
    local actionHeight = (rowH + 6) * 3 + Helper.borderSize
    local contentBottomPad = actionHeight + Helper.borderSize + 8

    local allRows = gtSectorBL.flatRows or {}
    local totalRows = #allRows
    -- Leave headroom vs ship diagnose (38): pagination chrome + dense tracked lists.
    local pageInfo = GT_UI.paginate(totalRows, gtSectorBL.currentPage, 28)
    gtSectorBL.currentPage = pageInfo.currentPage

    local detailFontSize = pageInfo.isPaginated
        and (GT_UI.DEFAULTS.fontSize * 0.75)
        or (GT_UI.DEFAULTS.fontSize * 0.85)

    local contentTable = GT_UI.createScrollTable(frame, 3, {
        tabOrder         = 2,
        x                = Helper.borderSize,
        y                = contentY,
        width            = width,
        maxVisibleHeight = gtSectorBL.frameHeight - contentY - contentBottomPad,
    })
    GT_UI.setColPercents(contentTable, { 22, 8 })

    GT_UI.addHeaderRow(contentTable, { "Check", "Status", "Detail" })
    GT_UI.addPaginationHeader(contentTable, pageInfo, 3)

    if totalRows == 0 then
        GT_UI.addEmptyRow(contentTable, "No data.", 3)
    else
        for i = pageInfo.startIdx, pageInfo.endIdx do
            local row = allRows[i]
            if not row then break end

            local checkName = row.check or "?"
            local status    = row.status or "INFO"
            local detail    = row.detail or ""
            local statusColor = GT_UI.getStatusColor(status)
            local isSeparator = row.isHeader or (string.sub(checkName, 1, 3) == "---")
            local rowBg = isSeparator and GT_UI.COLORS.headerBg or nil

            -- Never wordwrap here: wrapped detail rows inflate min-height and blank the frame.
            GT_UI.addDataRow(contentTable, {
                { text = checkName, fontsize = detailFontSize, wordwrap = false },
                { text = isSeparator and "" or status, halign = "center", fontsize = GT_UI.DEFAULTS.fontSize * 0.85, color = statusColor },
                { text = detail, fontsize = detailFontSize, wordwrap = false,
                  color = (status == "FAIL") and GT_UI.COLORS.textNegative or nil },
            }, { bgColor = rowBg })
        end
    end

    GT_UI.addPaginationNav(contentTable, pageInfo, function(newPage)
        gtSectorBL.currentPage = newPage
        gtSectorBL.createAndDisplayFrame()
    end)

    local actionY = gtSectorBL.frameHeight - actionHeight
    local actionTable = frame:addTable(1, {
        tabOrder         = 3,
        x                = Helper.borderSize,
        y                = actionY,
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

    local footerRow = actionTable:addRow(nil, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    footerRow[1]:createText(
        string.format("Game time %.0fs  |  %d rows  |  %d sections",
            gtSectorBL.timestamp or 0, totalRows, #gtSectorBL.sections),
        { halign = "center", fontsize = GT_UI.DEFAULTS.fontSize * 0.8 }
    )
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

DebugError("[GT SectorBL] Sector blacklist diagnose UI loaded")
