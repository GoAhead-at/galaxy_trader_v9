-- GalaxyTrader Ship Diagnosis popup
-- Opens on gt.openDiagnoseReport (md/gt_context_diagnose.xml). Two data sources on the player
-- blackboard, both flat strings because GetNPCBlackboard cannot read nested MD tables:
--   $GT_DiagOverview  player summary, rows ";;", fields "||":
--                     Tone||good|warn|bad|info, Headline||..., Doing||..., Why||...,
--                     Tip||... (repeated), Fact||label||value (repeated)
--   $GT_DiagReport    technical sections "@@", rows ";;", fields "||":
--                     SectionName;;STATUS||CHECK||DETAIL[||COL4||COL5||COL6];;...
--
-- Layout: title band on top, button band pinned to the bottom, and between them a section list
-- (Overview + Technical details) next to one scrolling content table. Every vertical position is
-- chained from getFullHeight() of the table above, so the layout follows the UI scale setting.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    bool CopyToClipboard(const char*const text);
]]

local menu = Helper.getMenu("MapMenu")
if not menu then
    DebugError("[GT Diagnose] MapMenu not found - diagnostic display will not be available")
    return
end

if not GT_UI then
    DebugError("[GT Diagnose] ERROR: GT_UI library not loaded - check ui.xml load order")
    return
end

if not (_G.GT_PlayerBridge and _G.GT_PlayerBridge.GetPlayerBlackboardId) then
    DebugError("[GT Diagnose] ERROR: GT_PlayerBridge not loaded - check ui.xml load order")
    return
end

local CONTEXT_LAYER = 2
local OVERVIEW_TAB  = 0
-- Rows per technical page. Interactive tables scroll, so this only bounds the widget row pool
-- (170 rows shared by every table of the frame), not the visible height.
local ROWS_PER_PAGE = 100

local TONE_COLORS = {
    good = Color["text_positive"],
    warn = Color["text_warning"],
    bad  = Color["text_negative"],
    info = Color["text_normal"],
}

local STATUS_LABELS = {
    PASS = "OK",
    FAIL = "FAIL",
    WARN = "WARN",
    INFO = "",
}

-- One line per technical page so a player knows what the page is about before reading rows.
local SECTION_HELP = {
    ["Ship State"]                  = "Ship data, current activity, training and route status. The first rows repeat the diagnosis result in technical form.",
    ["Ship Modifications"]          = "Ship upgrades GalaxyTrader manages for this pilot.",
    ["Miner Coordination"]          = "How this miner shares stations and wares with your other miners.",
    ["Configuration"]               = "The order settings as the ship uses them right now, after pilot level limits.",
    ["Miner Resource Scan"]         = "Minable wares the ship can reach and how rich the fields are.",
    ["Scheduler State"]             = "Queue and timing of the shared trade search.",
    ["Cache State"]                 = "The shared list of trades your ships found, and whether this ship can use it.",
    ["Cache Validation"]            = "Every entry of the shared trade list checked again against this ship.",
    ["Search Summary"]              = "Offers found in each sector within range.",
    ["Search Summary (Buyer Side)"] = "Buyers found in each sector within range.",
    ["Pair Details"]                = "Every buy/sell combination the ship could fly, and why it passed or failed.",
    ["Miner Sell Offer Details"]    = "Stations that buy mined wares, and whether they fit your settings.",
    ["Clearance"]                   = "Buyers for the cargo that is in the hold right now.",
    ["Reservations and Fleet"]      = "Deliveries your ships have reserved, so two ships do not deliver the same thing.",
    ["Failed Sector Pairs"]         = "Routes that failed recently and are skipped for a while.",
}

-- Column layouts for sections whose rows carry six fields. Percentages leave the last column
-- flexible (required by reserveScrollBar).
local SECTION_COLUMNS = {
    ["Search Summary"] = {
        percents = { 8, 28, 10, 10, 10 },
        headers  = { "Status", "Sector / Check", "Sell", "Buy", "Total", "" },
        align    = { "center", "left", "right", "right", "right", "left" },
    },
    ["Reservations and Fleet"] = {
        percents = { 8, 18, 28, 15, 14 },
        headers  = { "Status", "Entry", "Ship / Detail", "Ware", "Info", "Extra" },
        align    = { "center", "left", "left", "left", "left", "left" },
    },
    ["Pair Details"] = {
        percents = { 8, 12, 28, 12, 10 },
        headers  = { "Status", "Ware", "Route", "Profit (ROI)", "Score", "Reason" },
        align    = { "center", "left", "left", "right", "right", "left" },
    },
    ["Cache Validation"] = {
        percents = { 8, 12, 28, 12, 10 },
        headers  = { "Status", "Ware", "Route", "Amount", "Score", "Reason" },
        align    = { "center", "left", "left", "right", "right", "left" },
    },
    ["Clearance"] = {
        percents = { 8, 14, 24, 14, 12 },
        headers  = { "Status", "Ware", "Station (Sector)", "Price / Demand", "Revenue", "Reason" },
        align    = { "center", "left", "left", "left", "right", "left" },
    },
    ["Miner Resource Scan"] = {
        percents = { 8, 22, 12, 12, 10 },
        headers  = { "Status", "Ware (* = active)", "Best Yield", "Reachable", "Sectors", "Notes" },
        align    = { "center", "left", "right", "center", "right", "left" },
    },
}
SECTION_COLUMNS["Search Summary (Buyer Side)"] = SECTION_COLUMNS["Search Summary"]

local GENERIC_SIX_COLUMNS = {
    percents = { 8, 18, 18, 14, 14 },
    headers  = { "Status", "Item", "Detail", "", "", "" },
    align    = { "center", "left", "left", "left", "left", "left" },
}

local THREE_COLUMNS = {
    percents = { 8, 30 },
    headers  = { "Status", "Check", "Detail" },
    align    = { "center", "left", "left" },
}

local gtDiagnose = {
    sections    = {},   -- { { name=string, numCols=3|6, rows={ {status, check, detail, col4?, col5?, col6?} } } }
    overview    = nil,  -- { tone, headline, doing, why, tips = {}, facts = { {label, value} } }
    shipId      = "",
    shipName    = "",
    timestamp   = 0,
    currentTab  = OVERVIEW_TAB,
    currentPage = 1,
    frameWidth  = 0,
    frameHeight = 0,
    copyNotice  = "",
}

-- =============================================================================
-- PARSING
-- =============================================================================

function gtDiagnose.parseOverview(playerId)
    local str = GetNPCBlackboard(playerId, "$GT_DiagOverview")
    if not str or str == "" then
        gtDiagnose.overview = nil
        return
    end
    local ov = { tone = "warn", headline = "", doing = "", why = "", tips = {}, facts = {} }
    for _, rowStr in ipairs(GT_UI.split(str, ";;")) do
        local f = GT_UI.split(rowStr, "||")
        local kind = f[1]
        if kind == "Tone" then
            ov.tone = f[2] or "warn"
        elseif kind == "Headline" then
            ov.headline = f[2] or ""
        elseif kind == "Doing" then
            ov.doing = f[2] or ""
        elseif kind == "Why" then
            ov.why = f[2] or ""
        elseif kind == "Tip" and f[2] and f[2] ~= "" then
            table.insert(ov.tips, f[2])
        elseif kind == "Fact" and f[2] then
            table.insert(ov.facts, { label = f[2], value = f[3] or "" })
        end
    end
    gtDiagnose.overview = ov
end

function gtDiagnose.parseReport()
    local playerId = GT_PlayerBridge.GetPlayerBlackboardId()

    local reportStr      = GetNPCBlackboard(playerId, "$GT_DiagReport")
    gtDiagnose.shipId    = GetNPCBlackboard(playerId, "$GT_DiagShipId") or "???"
    gtDiagnose.shipName  = GetNPCBlackboard(playerId, "$GT_DiagShipName") or "Unknown"
    gtDiagnose.timestamp = GetNPCBlackboard(playerId, "$GT_DiagTimestamp") or 0
    gtDiagnose.parseOverview(playerId)

    if not reportStr or reportStr == "" then
        DebugError("[GT Diagnose] No report data found on blackboard")
        return false
    end

    gtDiagnose.sections = {}
    for _, chunk in ipairs(GT_UI.split(reportStr, "@@")) do
        local rowParts = GT_UI.split(chunk, ";;")
        if #rowParts > 0 then
            local section = { name = rowParts[1], rows = {}, numCols = 3 }
            for i = 2, #rowParts do
                local fields = GT_UI.split(rowParts[i], "||")
                if #fields >= 2 then
                    local row = {
                        status = fields[1] or "INFO",
                        check  = fields[2] or "",
                        detail = fields[3] or "",
                    }
                    if #fields >= 6 then
                        row.col4 = fields[4] or ""
                        row.col5 = fields[5] or ""
                        row.col6 = fields[6] or ""
                        section.numCols = 6
                    end
                    table.insert(section.rows, row)
                end
            end
            table.insert(gtDiagnose.sections, section)
        end
    end

    DebugError(string.format("[GT Diagnose] Parsed %d sections for %s (overview: %s)",
        #gtDiagnose.sections, tostring(gtDiagnose.shipId), gtDiagnose.overview and "yes" or "no"))
    return #gtDiagnose.sections > 0
end

-- =============================================================================
-- COPY REPORT (plain text for bug reports - keeps every raw status and field)
-- =============================================================================

function gtDiagnose.buildPlainTextReport()
    local lines = {}
    table.insert(lines, string.format("GalaxyTrader Diagnostic Report: %s (%s)",
        tostring(gtDiagnose.shipName), tostring(gtDiagnose.shipId)))
    table.insert(lines, string.format("Game time: %.0fs", gtDiagnose.timestamp or 0))
    table.insert(lines, "")

    local ov = gtDiagnose.overview
    if ov then
        table.insert(lines, "=== Overview ===")
        table.insert(lines, string.format("Status [%s]: %s", ov.tone, ov.headline))
        table.insert(lines, "Doing now: " .. ov.doing)
        table.insert(lines, "Why: " .. ov.why)
        for i, tip in ipairs(ov.tips) do
            table.insert(lines, string.format("Tip %d: %s", i, tip))
        end
        for _, fact in ipairs(ov.facts) do
            table.insert(lines, fact.label .. ": " .. fact.value)
        end
        table.insert(lines, "")
    end

    for _, section in ipairs(gtDiagnose.sections) do
        table.insert(lines, "=== " .. tostring(section.name or "?") .. " ===")
        for _, row in ipairs(section.rows or {}) do
            if row.col4 then
                table.insert(lines, string.format("%s | %s | %s | %s | %s | %s",
                    row.status, row.check, row.detail, row.col4, row.col5, row.col6))
            else
                table.insert(lines, string.format("%s | %s | %s", row.status, row.check, row.detail))
            end
        end
        table.insert(lines, "")
    end

    return table.concat(lines, "\n")
end

function gtDiagnose.copyReportToClipboard()
    if #gtDiagnose.sections == 0 and not gtDiagnose.parseReport() then
        DebugError("[GT Diagnose] Copy failed: no report data")
        return false
    end
    local text = gtDiagnose.buildPlainTextReport()
    local success = C.CopyToClipboard(text)
    DebugError(string.format("[GT Diagnose] Copy Report %s (%d chars)", success and "ok" or "FAILED", #text))
    return success
end

-- =============================================================================
-- SMALL BUILDERS
-- =============================================================================

--- Full-width section heading inside a content table.
function gtDiagnose.addHeading(tbl, columnCount, text)
    local row = tbl:addRow(true, { bgColor = Color["row_background_container2"] })
    row[1]:setColSpan(columnCount):createText(text, {
        font     = Helper.standardFontBold,
        fontsize = Helper.standardFontSize,
        halign   = "left",
    })
end

--- Full-width wrapped paragraph inside a content table.
function gtDiagnose.addParagraph(tbl, columnCount, text, color)
    local row = tbl:addRow(true, {})
    row[1]:setColSpan(columnCount):createText(text, {
        fontsize = Helper.standardFontSize,
        halign   = "left",
        wordwrap = true,
        color    = color,
    })
end

function gtDiagnose.statusCell(status)
    return {
        text     = STATUS_LABELS[status] or status,
        halign   = "center",
        color    = GT_UI.getStatusColor(status),
    }
end

-- =============================================================================
-- FRAME LIFECYCLE
-- =============================================================================

function gtDiagnose.openReport(component)
    if not gtDiagnose.parseReport() then
        DebugError("[GT Diagnose] ERROR: Could not parse report data")
        return
    end

    gtDiagnose.currentTab  = OVERVIEW_TAB
    gtDiagnose.currentPage = 1
    gtDiagnose.copyNotice  = ""

    gtDiagnose.frameWidth  = math.floor(math.min(Helper.viewWidth * 0.9, Helper.scaleX(1400)))
    gtDiagnose.frameHeight = math.floor(math.min(Helper.viewHeight * 0.9, Helper.scaleY(1000)))

    menu.contextMenuMode = "gt_diagnose"
    menu.contextMenuData = {
        component = component,
        xoffset   = math.floor((Helper.viewWidth - gtDiagnose.frameWidth) / 2),
        yoffset   = math.floor((Helper.viewHeight - gtDiagnose.frameHeight) / 2),
        width     = gtDiagnose.frameWidth,
    }

    gtDiagnose.createAndDisplayFrame()
end

function gtDiagnose.createAndDisplayFrame()
    Helper.removeAllWidgetScripts(menu, CONTEXT_LAYER)

    menu.contextFrame = Helper.createFrameHandle(menu, {
        x                     = menu.contextMenuData.xoffset,
        y                     = menu.contextMenuData.yoffset,
        width                 = gtDiagnose.frameWidth,
        height                = gtDiagnose.frameHeight,
        layer                 = CONTEXT_LAYER,
        standardButtons       = { close = true },
        closeOnUnhandledClick = false,
    })
    menu.contextFrame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

    gtDiagnose.populateFrame(menu.contextFrame)
    menu.contextFrame:display()
end

function gtDiagnose.selectTab(tab)
    gtDiagnose.currentTab  = tab
    gtDiagnose.currentPage = 1
    gtDiagnose.createAndDisplayFrame()
end

-- =============================================================================
-- FRAME CONTENT
-- =============================================================================

function gtDiagnose.populateFrame(frame)
    local border     = Helper.borderSize
    local innerWidth = gtDiagnose.frameWidth - 2 * border

    -- Title band
    local titleTable = frame:addTable(1, {
        tabOrder         = 0,
        x                = border,
        y                = border,
        width            = innerWidth,
        highlightMode    = "off",
        reserveScrollBar = false,
    })
    titleTable:addRow(nil, { fixed = true })[1]:createText(
        string.format("Ship Diagnosis - %s (%s)", tostring(gtDiagnose.shipName), tostring(gtDiagnose.shipId)),
        Helper.tabTitleTextProperties)

    -- Button band, pinned to the bottom first so the body can take the space in between
    local buttonTable = frame:addTable(3, {
        tabOrder         = 3,
        x                = border,
        y                = 0,
        width            = innerWidth,
        highlightMode    = "off",
        reserveScrollBar = false,
    })
    buttonTable:setColWidthPercent(1, 25)
    buttonTable:setColWidthPercent(3, 25)
    local buttonRow = buttonTable:addRow(true, { fixed = true })
    GT_UI.createButton(buttonRow[1], "Copy Report", {
        fontSize = Helper.standardFontSize,
        onClick  = function()
            local ok = gtDiagnose.copyReportToClipboard()
            gtDiagnose.copyNotice = ok and "Report copied to the clipboard - paste it into your bug report." or "Copying failed."
            gtDiagnose.createAndDisplayFrame()
        end,
    })
    buttonRow[2]:createText(gtDiagnose.copyNotice ~= "" and gtDiagnose.copyNotice
        or "Copy Report puts the full technical report on the clipboard.", {
        halign   = "center",
        color    = Color["text_inactive"],
        fontsize = Helper.standardFontSize,
        wordwrap = true,
    })
    GT_UI.createButton(buttonRow[3], "Close", {
        fontSize = Helper.standardFontSize,
        onClick  = function()
            menu.closeContextMenu("close")
        end,
    })
    buttonTable.properties.y = gtDiagnose.frameHeight - buttonTable:getFullHeight() - border

    -- Body: section list + content
    local bodyY      = titleTable.properties.y + titleTable:getFullHeight() + border
    local bodyHeight = buttonTable.properties.y - bodyY - border
    local minBody    = Helper.scaleY(Helper.standardTextHeight) * 6
    if bodyHeight < minBody then
        bodyHeight = minBody
    end

    local navWidth     = math.floor(innerWidth * 0.11)
    local contentX     = border + navWidth + border
    local contentWidth = innerWidth - navWidth - border

    local navTable = gtDiagnose.buildNavigation(frame, border, bodyY, navWidth, bodyHeight)

    local contentTable
    if gtDiagnose.currentTab == OVERVIEW_TAB or not gtDiagnose.sections[gtDiagnose.currentTab] then
        gtDiagnose.currentTab = OVERVIEW_TAB
        contentTable = gtDiagnose.buildOverview(frame, contentX, bodyY, contentWidth, bodyHeight)
    else
        contentTable = gtDiagnose.buildSection(frame, contentX, bodyY, contentWidth, bodyHeight)
    end

    navTable:addConnection(1, 2, true)
    contentTable:addConnection(2, 2)
    buttonTable:addConnection(3, 2)
end

function gtDiagnose.buildNavigation(frame, x, y, width, height)
    local navTable = frame:addTable(1, {
        tabOrder         = 1,
        x                = x,
        y                = y,
        width            = width,
        maxVisibleHeight = height,
        highlightMode    = "off",
        reserveScrollBar = false,
    })

    local fontSize  = Helper.standardFontSize
    local textWidth = width - Helper.scaleX(12)

    local function addNavButton(label, tab)
        local isActive = (gtDiagnose.currentTab == tab)
        local row = navTable:addRow(true, {})
        local text = TruncateText(label, Helper.standardFont, Helper.scaleFont(Helper.standardFont, fontSize), textWidth)
        GT_UI.createButton(row[1], text, {
            height   = Helper.standardButtonHeight,
            bgColor  = isActive and Color["row_background_selected"] or Color["button_background_default"],
            fontSize = fontSize,
            halign   = "left",
            onClick  = function()
                gtDiagnose.selectTab(tab)
            end,
        })
    end

    addNavButton("Overview", OVERVIEW_TAB)

    local caption = navTable:addRow(true, {})
    caption[1]:createText("Technical details", {
        font     = Helper.standardFontBold,
        fontsize = fontSize,
        color    = Color["text_inactive"],
        halign   = "left",
    })

    for i, section in ipairs(gtDiagnose.sections) do
        addNavButton(section.name, i)
    end

    return navTable
end

function gtDiagnose.buildOverview(frame, x, y, width, height)
    local tbl = frame:addTable(2, {
        tabOrder         = 2,
        x                = x,
        y                = y,
        width            = width,
        maxVisibleHeight = height,
        highlightMode    = "off",
        reserveScrollBar = true,
    })
    tbl:setColWidthPercent(1, 26)

    local ov = gtDiagnose.overview
    if not ov then
        gtDiagnose.addParagraph(tbl, 2,
            "No summary available for this report. The pages under Technical details still list every check.")
        return tbl
    end

    -- Status line: the one sentence that answers "is my ship fine?"
    local statusRow = tbl:addRow(true, { bgColor = Color["row_background_container2"] })
    statusRow[1]:setColSpan(2):createText(ov.headline, {
        font     = Helper.standardFontBold,
        fontsize = Helper.headerRow1FontSize,
        color    = TONE_COLORS[ov.tone] or Color["text_normal"],
        halign   = "left",
        wordwrap = true,
    })

    gtDiagnose.addHeading(tbl, 2, "What the ship is doing")
    gtDiagnose.addParagraph(tbl, 2, ov.doing)

    gtDiagnose.addHeading(tbl, 2, "Why")
    gtDiagnose.addParagraph(tbl, 2, ov.why)

    gtDiagnose.addHeading(tbl, 2, "What you can do")
    if #ov.tips == 0 then
        gtDiagnose.addParagraph(tbl, 2, "Nothing to do right now.")
    else
        for _, tip in ipairs(ov.tips) do
            gtDiagnose.addParagraph(tbl, 2, "- " .. tip)
        end
    end

    gtDiagnose.addHeading(tbl, 2, "Ship")
    for _, fact in ipairs(ov.facts) do
        local row = tbl:addRow(true, {})
        row[1]:createText(fact.label, { color = Color["text_inactive"], halign = "left" })
        row[2]:createText(fact.value, { halign = "left", wordwrap = true })
    end

    gtDiagnose.addParagraph(tbl, 2,
        "The pages under Technical details list every check the diagnosis ran. If you report a problem, use Copy Report and paste the text into your report.",
        Color["text_inactive"])

    return tbl
end

function gtDiagnose.buildSection(frame, x, y, width, height)
    local section = gtDiagnose.sections[gtDiagnose.currentTab]
    local layout
    if section.numCols >= 6 or SECTION_COLUMNS[section.name] then
        layout = SECTION_COLUMNS[section.name] or GENERIC_SIX_COLUMNS
    else
        layout = THREE_COLUMNS
    end
    local numCols = #layout.headers

    local tbl = frame:addTable(numCols, {
        tabOrder         = 2,
        x                = x,
        y                = y,
        width            = width,
        maxVisibleHeight = height,
        highlightMode    = "off",
        reserveScrollBar = true,
    })
    GT_UI.setColPercents(tbl, layout.percents)

    local titleRow = tbl:addRow(nil, { fixed = true, bgColor = Color["row_background_container2"] })
    titleRow[1]:setColSpan(numCols):createText(section.name, {
        font     = Helper.standardFontBold,
        fontsize = Helper.headerRow1FontSize,
        halign   = "left",
    })
    local help = SECTION_HELP[section.name]
    if help then
        local helpRow = tbl:addRow(nil, { fixed = true })
        helpRow[1]:setColSpan(numCols):createText(help, {
            color    = Color["text_inactive"],
            halign   = "left",
            wordwrap = true,
        })
    end

    local headerRow = tbl:addRow(nil, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    for c = 1, numCols do
        headerRow[c]:createText(layout.headers[c], {
            font   = Helper.standardFontBold,
            halign = layout.align[c],
        })
    end

    local rows     = section.rows
    local pageInfo = GT_UI.paginate(#rows, gtDiagnose.currentPage, ROWS_PER_PAGE)
    gtDiagnose.currentPage = pageInfo.currentPage
    if pageInfo.totalPages > 1 then
        gtDiagnose.addPageNav(tbl, numCols, pageInfo)
    end

    if #rows == 0 then
        gtDiagnose.addParagraph(tbl, numCols, "No data in this section.")
        return tbl
    end

    local fontSize = Helper.standardFontSize * 0.9
    for i = pageInfo.startIdx, pageInfo.endIdx do
        local row = rows[i]
        if not row then break end

        if string.sub(row.check, 1, 3) == "---" then
            -- "--- Name ---" rows are sub-headings inside a section
            local label = row.check:gsub("^%-+%s*", ""):gsub("%s*%-+$", "")
            gtDiagnose.addHeading(tbl, numCols, label ~= "" and label or " ")
        else
            local status = gtDiagnose.statusCell(row.status)
            status.fontsize = fontSize
            local failColor = (row.status == "FAIL") and Color["text_negative"] or nil
            local cells
            if row.col4 and numCols == 6 then
                cells = {
                    status,
                    { text = row.check,  halign = layout.align[2], fontsize = fontSize, wordwrap = true },
                    { text = row.detail, halign = layout.align[3], fontsize = fontSize, wordwrap = true },
                    { text = row.col4,   halign = layout.align[4], fontsize = fontSize, wordwrap = true },
                    { text = row.col5,   halign = layout.align[5], fontsize = fontSize, wordwrap = true },
                    { text = row.col6,   halign = layout.align[6], fontsize = fontSize, wordwrap = true, color = failColor },
                }
            else
                cells = {
                    status,
                    { text = row.check,  fontsize = fontSize, wordwrap = true },
                    { text = row.detail, fontsize = fontSize, wordwrap = true, colSpan = numCols - 2, color = failColor },
                }
            end
            GT_UI.addDataRow(tbl, cells)
        end
    end

    return tbl
end

function gtDiagnose.addPageNav(tbl, numCols, pageInfo)
    local row = tbl:addRow(true, { fixed = true, bgColor = GT_UI.COLORS.headerBg })
    GT_UI.createButton(row[1], "<", {
        active   = pageInfo.currentPage > 1,
        fontSize = Helper.standardFontSize,
        onClick  = function()
            gtDiagnose.currentPage = gtDiagnose.currentPage - 1
            gtDiagnose.createAndDisplayFrame()
        end,
    })
    row[2]:setColSpan(numCols - 2):createText(
        string.format("Page %d of %d - rows %d to %d of %d",
            pageInfo.currentPage, pageInfo.totalPages, pageInfo.startIdx, pageInfo.endIdx, pageInfo.totalRows),
        { halign = "center" })
    GT_UI.createButton(row[numCols], ">", {
        active   = pageInfo.currentPage < pageInfo.totalPages,
        fontSize = Helper.standardFontSize,
        onClick  = function()
            gtDiagnose.currentPage = gtDiagnose.currentPage + 1
            gtDiagnose.createAndDisplayFrame()
        end,
    })
end

-- =============================================================================
-- MENU HOOKS
-- =============================================================================

local origCreateCtx = menu.createContextFrame
menu.createContextFrame = function(width, height, xoffset, yoffset, noborder, startanimation, ...)
    if menu.contextMenuMode == "gt_diagnose" then
        return menu.contextFrame
    end
    if origCreateCtx then
        return origCreateCtx(width, height, xoffset, yoffset, noborder, startanimation, ...)
    end
end

local origRefreshCtx = menu.refreshContextFrame
menu.refreshContextFrame = function(setrow, setcol, noborder, ...)
    if menu.contextMenuMode == "gt_diagnose" then
        if menu.contextFrame then
            menu.contextFrame:display()
        end
        return
    end
    if origRefreshCtx then
        origRefreshCtx(setrow, setcol, noborder, ...)
    end
end

-- =============================================================================
-- EVENT REGISTRATION
-- =============================================================================

RegisterEvent("gt.openDiagnoseReport", function(_, component)
    local component64 = component and ConvertIDTo64Bit(component) or nil
    if component64 and component64 ~= 0 then
        gtDiagnose.openReport(component64)
    else
        gtDiagnose.openReport(nil)
    end
end)

DebugError("[GT Diagnose] Diagnostic report display loaded")
