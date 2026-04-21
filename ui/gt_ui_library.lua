--[[
==============================================================================
GalaxyTrader MK3 - UI Element Library
==============================================================================
Reusable UI components for consistent styling and behavior across all GT UI.
All patterns are validated against working GT UI code (info menu, context
menus, diagnose report).

IMPORTANT: This file MUST be loaded BEFORE any UI file that uses GT_UI.
           Ensure it appears first in ui.xml.

Usage (files loaded via ui.xml share _G):
    GT_UI.createScrollTable(frame, 3, { ... })
    GT_UI.addHeaderRow(tbl, {"Col1", "Col2", "Col3"})
    GT_UI.formatMoney(150000)


==============================================================================
]]--

local GT_UI = {}

-- =============================================================================
-- CONSTANTS
-- =============================================================================

GT_UI.DEFAULTS = {
    rowHeight       = Helper.standardTextHeight,
    fontSize        = Helper.standardFontSize,
    maxRowsPerPage  = 38,   -- max rows before pagination kicks in
                            -- X4 computes full table min-height even with maxVisibleHeight;
                            -- at ~26px/row + ~130px fixed rows, 38 rows ≈ 1118px which fits
                            -- the ~1192px available in the diagnose frame at 1440p.
}

-- =============================================================================
-- COLORS  (validated against X4 7.x color table)
-- =============================================================================

GT_UI.COLORS = {
    headerBg        = Color["row_title_background"],
    selectedBg      = Color["row_background_selected"],
    buttonBg        = Color["button_background_default"],
    tabActiveBg     = Color["row_background_selected"],
    tabInactiveBg   = Color["row_background_blue"],
    textPositive    = Color["text_positive"],
    textNegative    = Color["text_negative"],
    textWarning     = Color["text_warning"],
    frameBg         = Color["frame_background_semitransparent"],
}

-- =============================================================================
-- STATUS HELPERS
-- =============================================================================

--- Returns the appropriate color for a status string.
--- @param status string  "PASS", "FAIL", "WARN", or anything else (nil = default)
function GT_UI.getStatusColor(status)
    if status == "PASS" then
        return GT_UI.COLORS.textPositive
    elseif status == "FAIL" then
        return GT_UI.COLORS.textNegative
    elseif status == "WARN" then
        return GT_UI.COLORS.textWarning
    end
    return nil  -- default text color
end

-- =============================================================================
-- FORMATTING
-- =============================================================================

--- Format money amount (in cents/centimes) with M/B suffixes.
--- Single source of truth -- do NOT duplicate this in other files.
--- @param amount number  Amount in cents (X4 internal format)
--- @return string  e.g. "1.5M Cr", "2.3B Cr", "42,000 Cr"
function GT_UI.formatMoney(amount)
    local credits = amount / 100
    if credits >= 1000000000 then
        return string.format("%.1fB Cr", credits / 1000000000)
    elseif credits >= 1000000 then
        return string.format("%.1fM Cr", credits / 1000000)
    else
        return ConvertMoneyString(amount, false, false, 0, true)
    end
end

--- Format an EXACT credit amount with thousand separators and "Cr" suffix.
--- No M/B compression -- use when the precise number matters (course costs,
--- transaction receipts, fee breakdowns, ...).
---
--- IMPORTANT - input units: this helper expects WHOLE CREDITS, NOT raw
--- centicredits. GetNPCBlackboard auto-converts money-typed fields from
--- centicredits to credits when reading back from player.entity (verified:
--- MD `player.money` of 427720000 returns 4277200 from the blackboard), so
--- values pulled directly off the blackboard can be passed to this helper
--- as-is. If you instead hold a raw centicredit value (e.g. from `player.money`
--- before any blackboard round-trip), divide by 100 first.
---
--- The thousand separator is implemented in pure Lua to avoid the unit
--- ambiguity in stock `ConvertMoneyString` (which silently divides by 100).
---
--- @param credits number  Whole-credit amount
--- @return string  e.g. "1,500,000 Cr"
function GT_UI.formatCreditsExact(credits)
    local n = math.floor((credits or 0) + 0.5)
    local s = tostring(n)
    local formatted, k = s, 0
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted .. " Cr"
end

--- Format a duration in seconds as "N min" (rounded, minimum 1).
--- @param seconds number
--- @return string  e.g. "10 min"
function GT_UI.formatDurationMin(seconds)
    local minutes = math.floor((seconds or 0) / 60 + 0.5)
    if minutes < 1 then minutes = 1 end
    return tostring(minutes) .. " min"
end

-- =============================================================================
-- LOCALIZATION
-- =============================================================================

--- Read a localized string with pcall protection. Returns the supplied fallback
--- (or a "{page,id}" placeholder) if ReadText errors or returns empty.
--- @param page number      Text page id
--- @param id   number      Text entry id
--- @param fallback string?  Optional fallback text
--- @return string
function GT_UI.safeReadText(page, id, fallback)
    if not page or not id then
        return fallback or "?"
    end
    local ok, txt = pcall(ReadText, page, id)
    if ok and txt and txt ~= "" then
        return txt
    end
    return fallback or string.format("{%d,%d}", page, id)
end

-- =============================================================================
-- STRING HELPERS
-- =============================================================================

--- Split a string by a delimiter (supports multi-char delimiters).
--- @param str string       Input string
--- @param delimiter string Delimiter (e.g. "||", ";;", ",")
--- @return table           Array of substrings
function GT_UI.split(str, delimiter)
    local result = {}
    if not str or str == "" then return result end

    if #delimiter > 1 then
        -- Multi-char delimiter: find-based
        local start = 1
        while true do
            local pos = string.find(str, delimiter, start, true)
            if pos then
                table.insert(result, string.sub(str, start, pos - 1))
                start = pos + #delimiter
            else
                table.insert(result, string.sub(str, start))
                break
            end
        end
    else
        -- Single-char delimiter
        local pattern = "([^" .. delimiter .. "]*)" .. delimiter .. "?"
        for match in string.gmatch(str .. delimiter, pattern) do
            table.insert(result, match)
        end
        -- Remove trailing empty entry
        if #result > 0 and result[#result] == "" then
            table.remove(result)
        end
    end
    return result
end

-- =============================================================================
-- TABLE CREATION
-- =============================================================================

--[[
    Creates a scrollable table with sane defaults.

    Uses reserveScrollBar = false and percentage-based column widths, which
    is the pattern used by ALL working GT UIs.  If you need reserveScrollBar
    = true, use fixed pixel widths via setColWidth() and leave at least one
    column un-set so it becomes the variable-width column.

    Parameters:
        frame       : Parent frame
        columnCount : Number of columns
        options     : {
            tabOrder          = number   (default 2)
            x                 = number   (default Helper.borderSize)
            y                 = number   (default 0)
            width             = number   (default frame usable width)
            maxVisibleHeight  = number   (default Helper.viewHeight)
            reserveScrollBar  = bool     (default false)
            highlightMode     = string   (default nil = normal)
            fontSize          = number   (default GT_UI.DEFAULTS.fontSize)
            rowHeight         = number   (default GT_UI.DEFAULTS.rowHeight)
        }

    Returns: table object
]]
function GT_UI.createScrollTable(frame, columnCount, options)
    options = options or {}

    local tbl = frame:addTable(columnCount, {
        tabOrder         = options.tabOrder or 2,
        x                = options.x or Helper.borderSize,
        y                = options.y or 0,
        width            = options.width,
        maxVisibleHeight = options.maxVisibleHeight or Helper.viewHeight,
        reserveScrollBar = (options.reserveScrollBar == true),  -- default false
        highlightMode    = options.highlightMode,
    })

    tbl:setDefaultCellProperties("text", {
        minRowHeight = options.rowHeight or GT_UI.DEFAULTS.rowHeight,
        fontsize     = options.fontSize or GT_UI.DEFAULTS.fontSize,
    })

    return tbl
end

--[[
    Add a lightweight floating text label to a frame.
    Designed for non-interactive overlays that must not participate in tab flow.

    Parameters:
        frame   : parent frame
        options : {
            x          = number (required)
            y          = number (required)
            width      = number (required)
            height     = number (required)
            text       = string OR function() -> string
            halign     = string (default "left")
            fontsize   = number (default GT_UI.DEFAULTS.fontSize)
            color      = color (optional)
            tabOrder   = number (default 0)
        }

    Returns: table object
]]
function GT_UI.addFloatingLabel(frame, options)
    options = options or {}

    local rowHeight = options.height or GT_UI.DEFAULTS.rowHeight

    local tbl = frame:addTable(1, {
        tabOrder         = options.tabOrder or 0,
        x                = options.x or 0,
        y                = options.y or 0,
        width            = options.width or 300,
        height           = rowHeight,
        scaling          = false,
        highlightMode    = "off",
        reserveScrollBar = false,
        skipTabChange    = true,
    })

    tbl:setDefaultCellProperties("text", {
        minRowHeight = rowHeight,
        fontsize     = options.fontsize or GT_UI.DEFAULTS.fontSize,
    })

    local labelText = options.text or ""
    if type(labelText) == "function" then
        labelText = labelText() or ""
    end

    local row = tbl:addRow(nil, { fixed = true })
    row[1]:createText(labelText, {
        halign   = options.halign or "left",
        fontsize = options.fontsize or GT_UI.DEFAULTS.fontSize,
        color    = options.color,
        wordwrap = false,
        x        = 0,
        y        = 0,
    })

    return tbl
end

--[[
    Set column widths using percentages.
    Leave one column UN-set to act as the flexible column (required when
    reserveScrollBar = true, harmless when false).

    Parameters:
        tbl     : table object
        widths  : array of {colIndex, percent} or just array of percents
                  e.g. {22, 8} sets columns 1=22%, 2=8%, rest flexible

    Example:
        GT_UI.setColPercents(tbl, {22, 8})
        -- Column 1 = 22%, Column 2 = 8%, Column 3+ = flexible
]]
function GT_UI.setColPercents(tbl, widths)
    if not widths then return end
    for i, pct in ipairs(widths) do
        if pct and pct > 0 then
            tbl:setColWidthPercent(i, pct)
        end
    end
end

-- =============================================================================
-- HEADER / ROW / FOOTER CREATION
-- =============================================================================

--[[
    Add a fixed header row with text labels.

    Parameters:
        tbl         : table object
        headers     : array of strings or tables:
                      string -> simple centered text
                      table  -> { text=, halign=, sortColumn=, currentSort=, onSort= }
        options     : { bgColor=, font= }

    Returns: row object
]]
function GT_UI.addHeaderRow(tbl, headers, options)
    options = options or {}

    local row = tbl:addRow(true, {
        fixed   = true,
        bgColor = options.bgColor or GT_UI.COLORS.headerBg,
    })

    for i, hdr in ipairs(headers) do
        local cell = row[i]
        if not cell then break end

        if type(hdr) == "string" then
            cell:createText(hdr, {
                halign = "center",
                font   = options.font or Helper.headerRow1Font,
            })
        else
            -- Table config: sortable header
            local text    = hdr.text or ""
            local halign  = hdr.halign or "center"

            if hdr.sortColumn and hdr.onSort then
                -- Sortable: use button
                local displayText = text
                if hdr.currentSort and hdr.currentSort.column == hdr.sortColumn then
                    displayText = displayText .. (hdr.currentSort.descending and " \xe2\x96\xbc" or " \xe2\x96\xb2")
                end
                local btn = cell:createButton({ height = GT_UI.DEFAULTS.rowHeight })
                btn:setText(displayText, { halign = halign })
                local sortCol = hdr.sortColumn
                local sortFn  = hdr.onSort
                cell.handlers.onClick = function()
                    sortFn(sortCol)
                    return true
                end
            else
                cell:createText(text, {
                    halign = halign,
                    font   = options.font or Helper.headerRow1Font,
                })
            end
        end
    end

    return row
end

--[[
    Add a data row.

    Parameters:
        tbl          : table object
        cells        : array of strings or tables:
                       string -> left-aligned text
                       table  -> { text=, halign=, color=, cellBGColor=, wordwrap=,
                                   fontsize=, colSpan=, onClick= }
        options      : { selectable=bool (default true), bgColor=, interactive= }

    Returns: row object
]]
function GT_UI.addDataRow(tbl, cells, options)
    options = options or {}
    local selectable = (options.selectable ~= false)  -- default true

    local rowOpts = {}
    if options.bgColor then rowOpts.bgColor = options.bgColor end
    if options.interactive then rowOpts.interactive = true end

    local row = tbl:addRow(selectable, rowOpts)

    for i, cellCfg in ipairs(cells) do
        local cell = row[i]
        if not cell then break end

        if type(cellCfg) == "string" then
            cell:createText(cellCfg, { halign = "left" })
        else
            if cellCfg.colSpan then
                cell:setColSpan(cellCfg.colSpan)
            end

            local textOpts = {
                halign      = cellCfg.halign or "left",
                fontsize    = cellCfg.fontsize,
                color       = cellCfg.color,
                cellBGColor = cellCfg.cellBGColor,
                wordwrap    = cellCfg.wordwrap,
            }
            cell:createText(cellCfg.text or "", textOpts)

            if cellCfg.onClick then
                local fn = cellCfg.onClick
                cell.handlers.onClick = function()
                    fn()
                    return true
                end
            end
        end
    end

    return row
end

--[[
    Add an empty-state row spanning all columns.

    Parameters:
        tbl         : table object
        message     : string
        columnCount : number of columns to span (REQUIRED - X4 has no getColumnCount)
        options     : { halign=, fontsize= }

    Returns: row object
]]
function GT_UI.addEmptyRow(tbl, message, columnCount, options)
    options = options or {}

    local row = tbl:addRow(nil, {})
    row[1]:setColSpan(columnCount):createText(message, {
        halign   = options.halign or "center",
        fontsize = options.fontsize or GT_UI.DEFAULTS.fontSize,
    })
    return row
end

--[[
    Add a small caption row (centered, muted color, word-wrapped). Useful as
    an explanatory note beneath a disabled button or section header.

    Cramming "label\n(reason)" into a single fixed-height row makes the second
    line overflow into the next row visually -- always render the caption on
    its own row instead.

    Parameters:
        tbl         : table object
        message     : string  (will be rendered verbatim; caller adds parens)
        options     : { halign=, fontsize=, color=, wordwrap=, colSpan= }

    Returns: row object
]]
function GT_UI.addCaptionRow(tbl, message, options)
    options = options or {}

    local row = tbl:addRow(nil, { fixed = true })
    if options.colSpan then
        row[1]:setColSpan(options.colSpan)
    end
    row[1]:createText(message, {
        halign   = options.halign or "center",
        wordwrap = (options.wordwrap ~= false),
        color    = options.color or Color["text_inactive"],
        fontsize = options.fontsize or GT_UI.DEFAULTS.fontSize,
    })
    return row
end

--[[
    Add a footer row spanning all columns.

    Parameters:
        tbl         : table object
        message     : string
        columnCount : number of columns to span (REQUIRED - X4 has no getColumnCount)
        options     : { halign=, fontsize=, bgColor= }

    Returns: row object
]]
function GT_UI.addFooterRow(tbl, message, columnCount, options)
    options = options or {}

    local row = tbl:addRow(nil, {
        fixed   = true,
        bgColor = options.bgColor or GT_UI.COLORS.headerBg,
    })
    row[1]:setColSpan(columnCount):createText(message, {
        halign   = options.halign or "center",
        fontsize = options.fontsize or GT_UI.DEFAULTS.fontSize * 0.85,
    })
    return row
end

-- =============================================================================
-- BUTTONS
-- =============================================================================

--[[
    Create a button in a table cell.

    Parameters:
        cell    : cell object (row[n])
        text    : button label
        options : {
            active   = bool    (default true; pass false for a disabled button)
            height   = number  (default GT_UI.DEFAULTS.rowHeight)
            bgColor  = color   (default GT_UI.COLORS.buttonBg)
            fontSize = number  (default GT_UI.DEFAULTS.fontSize * 0.85)
            halign   = string  (default "center")
            color    = color   (text color, optional)
            onClick  = function (ignored when active == false)
        }

    Returns: button object
]]
function GT_UI.createButton(cell, text, options)
    options = options or {}

    local btnConfig = {
        height  = options.height or GT_UI.DEFAULTS.rowHeight,
        bgColor = options.bgColor or GT_UI.COLORS.buttonBg,
    }
    if options.active == false then
        btnConfig.active = false
    end

    local btn = cell:createButton(btnConfig)

    local textOpts = {
        halign   = options.halign or "center",
        fontsize = options.fontSize or (GT_UI.DEFAULTS.fontSize * 0.85),
    }
    if options.color then textOpts.color = options.color end
    btn:setText(text, textOpts)

    if options.onClick and options.active ~= false then
        local fn = options.onClick
        cell.handlers.onClick = function()
            fn()
            return true
        end
    end

    return btn
end

-- =============================================================================
-- TAB BAR
-- =============================================================================

--[[
    Create a tab bar row.

    Parameters:
        frame       : parent frame
        tabs        : array of { name=string, sectionIdx=number }
        activeIdx   : currently active section index
        options     : {
            x        = number
            y        = number
            width    = number
            maxTabs  = number  (default 14)
            fontSize = number  (default GT_UI.DEFAULTS.fontSize * 0.75)
            truncLen = number  (default 12, tab names longer than this get truncated)
            onClick  = function(sectionIdx)  -- called when a tab is clicked
        }

    Returns: tabTable object, tabHeight (pixels)
]]
function GT_UI.createTabBar(frame, tabs, activeIdx, options)
    options = options or {}

    local maxTabs  = math.min(#tabs, options.maxTabs or 14)
    local truncLen = options.truncLen or 12
    local fontSize = options.fontSize or (GT_UI.DEFAULTS.fontSize * 0.75)

    local tabTable = frame:addTable(maxTabs, {
        tabOrder         = 1,
        x                = options.x or Helper.borderSize,
        y                = options.y or 0,
        width            = options.width,
        highlightMode    = "off",
        reserveScrollBar = false,
    })

    -- Equal column widths
    local colPct = math.floor(100 / maxTabs)
    for i = 1, maxTabs do
        tabTable:setColWidthPercent(i, colPct)
    end

    local tabRow = tabTable:addRow(true, { fixed = true })

    for i = 1, maxTabs do
        local tab = tabs[i]
        if not tab then break end

        local label = tab.name or ("Tab " .. i)
        if #label > truncLen then
            label = string.sub(label, 1, truncLen - 2) .. ".."
        end

        local isActive = (tab.sectionIdx == activeIdx)
        local bgColor  = isActive and GT_UI.COLORS.tabActiveBg or GT_UI.COLORS.tabInactiveBg

        local btn = tabRow[i]:createButton({
            height  = GT_UI.DEFAULTS.rowHeight,
            bgColor = bgColor,
        })
        btn:setText(label, { halign = "center", fontsize = fontSize })

        if options.onClick then
            local idx = tab.sectionIdx
            local fn  = options.onClick
            tabRow[i].handlers.onClick = function()
                fn(idx)
                return true
            end
        end
    end

    local tabHeight = GT_UI.DEFAULTS.rowHeight + 8
    return tabTable, tabHeight
end

-- =============================================================================
-- PAGINATION
-- =============================================================================

--[[
    Paginate a row set: determine page bounds and whether pagination is needed.

    Parameters:
        totalRows   : number of total rows
        currentPage : current page (1-based)
        maxPerPage  : max rows per page (default GT_UI.DEFAULTS.maxRowsPerPage)

    Returns: table {
        startIdx    = first row index (1-based)
        endIdx      = last row index (1-based)
        totalRows   = total number of rows
        totalPages  = total number of pages
        currentPage = clamped current page
        isPaginated = bool (totalRows > maxPerPage)
    }
]]
function GT_UI.paginate(totalRows, currentPage, maxPerPage)
    maxPerPage = maxPerPage or GT_UI.DEFAULTS.maxRowsPerPage

    local totalPages = math.max(1, math.ceil(totalRows / maxPerPage))
    currentPage = math.max(1, math.min(currentPage, totalPages))

    local startIdx = (currentPage - 1) * maxPerPage + 1
    local endIdx   = math.min(currentPage * maxPerPage, totalRows)

    return {
        startIdx    = startIdx,
        endIdx      = endIdx,
        totalRows   = totalRows,
        totalPages  = totalPages,
        currentPage = currentPage,
        isPaginated = (totalRows > maxPerPage),
    }
end

--[[
    Add a pagination info header row (e.g. "Page 2/7 (rows 81-160 of 500)").
    Only adds the row if pagination is active.

    Parameters:
        tbl         : table object
        pageInfo    : result from GT_UI.paginate()
        columnCount : number of columns to span

    Returns: row object or nil
]]
function GT_UI.addPaginationHeader(tbl, pageInfo, columnCount)
    if not pageInfo.isPaginated then return nil end

    local row = tbl:addRow(nil, {
        fixed   = true,
        bgColor = GT_UI.COLORS.headerBg,
    })
    row[1]:setColSpan(columnCount):createText(
        string.format("Page %d / %d  (rows %d - %d of %d total)",
            pageInfo.currentPage, pageInfo.totalPages,
            pageInfo.startIdx, pageInfo.endIdx,
            pageInfo.totalRows),
        { halign = "center", fontsize = GT_UI.DEFAULTS.fontSize * 0.8 }
    )
    return row
end

--[[
    Add pagination navigation buttons (Prev / page indicator / Next).
    Only adds the row if pagination is active and there are multiple pages.

    Parameters:
        tbl         : table object (must have at least 3 columns)
        pageInfo    : result from GT_UI.paginate()
        onPageChange: function(newPage) - called when prev/next is clicked

    Returns: row object or nil
]]
function GT_UI.addPaginationNav(tbl, pageInfo, onPageChange)
    if not pageInfo.isPaginated or pageInfo.totalPages <= 1 then
        return nil
    end

    local row = tbl:addRow(true, {
        fixed   = true,
        bgColor = GT_UI.COLORS.headerBg,
    })

    -- Prev button (column 1)
    if pageInfo.currentPage > 1 then
        GT_UI.createButton(row[1], "<< Prev", {
            bgColor  = GT_UI.COLORS.tabInactiveBg,
            fontSize = GT_UI.DEFAULTS.fontSize * 0.85,
            onClick  = function()
                onPageChange(pageInfo.currentPage - 1)
            end,
        })
    else
        row[1]:createText("", {})
    end

    -- Page indicator (column 2)
    row[2]:createText(
        string.format("%d / %d", pageInfo.currentPage, pageInfo.totalPages),
        { halign = "center", fontsize = GT_UI.DEFAULTS.fontSize * 0.8 }
    )

    -- Next button (column 3)
    if pageInfo.currentPage < pageInfo.totalPages then
        GT_UI.createButton(row[3], "Next >>", {
            bgColor  = GT_UI.COLORS.tabInactiveBg,
            fontSize = GT_UI.DEFAULTS.fontSize * 0.85,
            onClick  = function()
                onPageChange(pageInfo.currentPage + 1)
            end,
        })
    else
        row[3]:createText("", {})
    end

    return row
end

-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

-- Export as global for X4 ui.xml loading (files loaded via ui.xml share _G)
_G.GT_UI = GT_UI

return GT_UI
