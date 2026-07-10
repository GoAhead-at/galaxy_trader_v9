-- GalaxyTrader - Pilot exchange plan overlay (MapMenu context frame)
-- Single scrollable content table (vanilla playerinfo pattern). No pagination.

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef struct {
        int x;
        int y;
    } Coord2D;
    Coord2D GetCenteredMousePos(void);
]]

local menu = Helper.getMenu("MapMenu")
if not menu then
    DebugError("[GT PilotExchange Plan] MapMenu not found - plan overlay unavailable")
    return
end

GT_PilotExchangePlan = GT_PilotExchangePlan or {}

local LIST_PAGE_TEXT = 77000
local TITLE_TEXT_ID = 31315
local SWAPS_HEADER_TEXT_ID = 31316
local QUEUED_HEADER_TEXT_ID = 31343
local UNCHANGED_HEADER_TEXT_ID = 31324
local MENU_WIDTH = 1024
local CONTEXT_LAYER = 2
local MAX_FRAME_HEIGHT_RATIO = 0.75
local MAX_FRAME_HEIGHT_CAP = 860

local originalCreateContextFrame = menu.createContextFrame
local originalRefreshContextFrame = menu.refreshContextFrame
local originalCloseContextMenu = menu.closeContextMenu
local overlayClosing = false

local function debugLog(msg)
    DebugError("[GT PilotExchange Plan] " .. tostring(msg))
end

local function safeText(textId, fallback)
    if GT_UI and GT_UI.safeReadText then
        return GT_UI.safeReadText(LIST_PAGE_TEXT, textId, fallback)
    end
    return ReadText(LIST_PAGE_TEXT, textId) or fallback
end

local function buildPlanContentRows(plan)
    local rows = {}

    local function addSection(textId, fallback)
        table.insert(rows, { kind = "header", textId = textId, fallback = fallback })
    end

    local function addLines(lines)
        for _, line in ipairs(lines or {}) do
            table.insert(rows, { kind = "detail", text = line })
        end
    end

    if plan.swapLines and #plan.swapLines > 0 then
        addSection(SWAPS_HEADER_TEXT_ID, "Planned swaps:")
        addLines(plan.swapLines)
    end

    if plan.queuedSwapLines and #plan.queuedSwapLines > 0 then
        table.insert(rows, { kind = "spacer" })
        addSection(QUEUED_HEADER_TEXT_ID, "Queued exchanges:")
        addLines(plan.queuedSwapLines)
    end

    if plan.unchangedLines and #plan.unchangedLines > 0 then
        table.insert(rows, { kind = "spacer" })
        addSection(UNCHANGED_HEADER_TEXT_ID, "Unchanged:")
        addLines(plan.unchangedLines)
    end

    return rows
end

local function addPlanRow(scrollTable, entry)
    -- Vanilla pattern: rowdata must be truthy (addRow(true)) so the table is interactive
    -- and mintableheight uses scroll viewport, not full content height (widget_fullscreen.lua).
    if entry.kind == "spacer" then
        scrollTable:addRow(true, { borderBelow = false })[1]:createText("", {
            fontsize = 1,
            minRowHeight = Helper.borderSize,
        })
        return
    end
    if entry.kind == "header" then
        local row = scrollTable:addRow(true, {
            borderBelow = false,
            bgColor = GT_UI.COLORS.headerBg,
        })
        row[1]:createText(safeText(entry.textId, entry.fallback), {
            halign = "left",
            fontsize = Helper.standardFontSize,
            color = Color["text_normal"],
        })
        return
    end
    local row = scrollTable:addRow(true, { borderBelow = false })
    row[1]:createText(entry.text or "", {
        halign = "left",
        wordwrap = false,
        color = Color["text_inactive"],
        fontsize = GT_UI.DEFAULTS.fontSize,
    })
end

local function clearOverlayFrame()
    menu.contextFrame = nil
    Helper.clearFrame(menu, CONTEXT_LAYER)
    Helper.removeAllWidgetScripts(menu, CONTEXT_LAYER)
end

local function finishOverlayClose()
    if overlayClosing then
        return
    end
    overlayClosing = true
    menu.contextMenuMode = nil
    menu.contextMenuData = nil
    menu.noupdate = false
    clearOverlayFrame()
    overlayClosing = false
end

local function onAccept()
    debugLog("Accept clicked")
    if GT_PilotExchangePlan.onAccept then
        GT_PilotExchangePlan.onAccept()
    else
        debugLog("Accept clicked but onAccept handler is missing")
    end
    finishOverlayClose()
end

local function onCancel()
    debugLog("Cancel clicked")
    if GT_PilotExchangePlan.onCancel then
        GT_PilotExchangePlan.onCancel()
    else
        debugLog("Cancel clicked but onCancel handler is missing")
    end
    finishOverlayClose()
end

function menu.populateGTPilotExchangePlanContext(frame)
    local plan = menu.contextMenuData and menu.contextMenuData.plan
    if not plan then
        debugLog("populateGTPilotExchangePlanContext: missing plan data")
        return
    end

    local innerWidth = menu.contextMenuData.width - 2 * Helper.borderSize
    local maxFrameHeight = menu.contextMenuData.frameHeight
        or math.min(Helper.viewHeight * MAX_FRAME_HEIGHT_RATIO, Helper.scaleY(MAX_FRAME_HEIGHT_CAP))

    local titleTable = frame:addTable(1, {
        tabOrder = 1,
        x = Helper.borderSize,
        y = Helper.borderSize,
        width = innerWidth,
        highlightMode = "off",
        reserveScrollBar = false,
    })
    titleTable:addRow(nil, { fixed = true })[1]:createText(
        safeText(TITLE_TEXT_ID, "Pilot Exchange Plan"),
        Helper.headerRowCenteredProperties)

    local buttonTable = frame:addTable(2, {
        tabOrder = 3,
        x = Helper.borderSize,
        y = 0,
        width = innerWidth,
        highlightMode = "off",
        reserveScrollBar = false,
    })
    local buttonRow = buttonTable:addRow(true, { fixed = true })
    if plan.readOnly then
        GT_UI.createButton(buttonRow[1], ReadText(1001, 64), { onClick = onCancel })
    else
        GT_UI.createButton(buttonRow[1], ReadText(1001, 2821), { onClick = onAccept })
        GT_UI.createButton(buttonRow[2], ReadText(1001, 64), { onClick = onCancel })
    end

    -- Pin buttons first so scroll area can fill the remaining frame height.
    buttonTable.properties.y = maxFrameHeight - buttonTable:getFullHeight() - Helper.borderSize

    local allRows = buildPlanContentRows(plan)

    local scrollTableY = titleTable.properties.y + titleTable:getFullHeight() + Helper.borderSize
    local scrollBudget = buttonTable.properties.y - scrollTableY - Helper.borderSize
    if scrollBudget < Helper.scaleY(Helper.standardTextHeight) * 4 then
        scrollBudget = Helper.scaleY(Helper.standardTextHeight) * 4
    end

    local scrollTable = GT_UI.createScrollTable(frame, 1, {
        tabOrder = 2,
        x = Helper.borderSize,
        y = scrollTableY,
        width = innerWidth,
        maxVisibleHeight = scrollBudget,
        reserveScrollBar = false,
        highlightMode = "off",
    })

    for _, entry in ipairs(allRows) do
        addPlanRow(scrollTable, entry)
    end

    -- Always use the full middle band; interactive rows enable scrolling within scrollBudget.
    scrollTable.properties.maxVisibleHeight = scrollBudget

    debugLog(string.format(
        "populate plan totalRows=%d scrollBudget=%d frameHeight=%d contentHeight=%d",
        #allRows, scrollBudget, maxFrameHeight, scrollTable:getFullHeight()))

    titleTable:addConnection(1, 2, true)
    scrollTable:addConnection(2, 2)
    buttonTable:addConnection(3, 2)

    frame.properties.height = maxFrameHeight

    if frame.properties.y + frame.properties.height + Helper.frameBorder > Helper.viewHeight then
        menu.contextMenuData.yoffset = Helper.viewHeight - frame.properties.height - Helper.frameBorder
        frame.properties.y = menu.contextMenuData.yoffset
    end
end

function menu.openGTPilotExchangePlanContext(plan)
    local hasSwaps = plan and plan.swapLines and #plan.swapLines > 0
    local hasUnchanged = plan and plan.unchangedLines and #plan.unchangedLines > 0
    if not plan or (not hasSwaps and not hasUnchanged) then
        debugLog("openGTPilotExchangePlanContext: empty plan")
        return false
    end

    if Helper.closeInteractMenu and Helper.closeInteractMenu() then
        debugLog("closed InteractMenu before opening plan overlay")
    end

    local mousepos = C.GetCenteredMousePos()
    local frameHeight = math.min(Helper.viewHeight * MAX_FRAME_HEIGHT_RATIO, Helper.scaleY(MAX_FRAME_HEIGHT_CAP))
    local frameWidth = Helper.scaleX(MENU_WIDTH)
    menu.contextMenuMode = "gt_pilot_exchange_plan"
    menu.contextMenuData = {
        plan = plan,
        xoffset = mousepos.x + Helper.viewWidth / 2,
        yoffset = mousepos.y + Helper.viewHeight / 2,
        width = frameWidth,
        frameHeight = frameHeight,
    }
    if menu.contextMenuData.xoffset + menu.contextMenuData.width > Helper.viewWidth then
        menu.contextMenuData.xoffset = Helper.viewWidth - menu.contextMenuData.width - Helper.frameBorder
    end

    menu.createContextFrame(menu.contextMenuData.width, nil,
        menu.contextMenuData.xoffset, menu.contextMenuData.yoffset)
    menu.refreshContextFrame()
    return true
end

menu.createContextFrame = function(width, height, xoffset, yoffset, noborder, startanimation, ...)
    if menu.contextMenuMode == "gt_pilot_exchange_plan" then
        local mousepos = C.GetCenteredMousePos()
        menu.contextMenuData = menu.contextMenuData or {}
        menu.contextMenuData.xoffset = xoffset or (mousepos.x + Helper.viewWidth / 2)
        menu.contextMenuData.yoffset = yoffset or (mousepos.y + Helper.viewHeight / 2)
        menu.contextMenuData.width = width or Helper.scaleX(MENU_WIDTH)

        if menu.contextMenuData.xoffset + menu.contextMenuData.width > Helper.viewWidth then
            menu.contextMenuData.xoffset = Helper.viewWidth - menu.contextMenuData.width - Helper.frameBorder
        end

        Helper.removeAllWidgetScripts(menu, CONTEXT_LAYER)
        Helper.clearFrame(menu, CONTEXT_LAYER)

        local frameHeight = menu.contextMenuData.frameHeight
            or math.min(Helper.viewHeight * MAX_FRAME_HEIGHT_RATIO, Helper.scaleY(MAX_FRAME_HEIGHT_CAP))
        menu.contextFrame = Helper.createFrameHandle(menu, {
            x = menu.contextMenuData.xoffset - (noborder and 0 or 2 * Helper.borderSize),
            y = menu.contextMenuData.yoffset,
            width = menu.contextMenuData.width + (noborder and 0 or 2 * Helper.borderSize),
            height = frameHeight + (noborder and 0 or 2 * Helper.borderSize),
            layer = CONTEXT_LAYER,
            standardButtons = { close = true },
            closeOnUnhandledClick = false,
            startAnimation = startanimation,
        })
        menu.contextFrame:setBackground("solid", { color = GT_UI.COLORS.frameBg })

        menu.populateGTPilotExchangePlanContext(menu.contextFrame)
        return menu.contextFrame
    end

    if originalCreateContextFrame then
        return originalCreateContextFrame(width, height, xoffset, yoffset, noborder, startanimation, ...)
    end
end

menu.refreshContextFrame = function(setrow, setcol, noborder, ...)
    if menu.contextMenuMode == "gt_pilot_exchange_plan" then
        Helper.removeAllWidgetScripts(menu, CONTEXT_LAYER)
        if menu.contextFrame then
            menu.contextFrame:display()
        end
        return
    end
    if originalRefreshContextFrame then
        return originalRefreshContextFrame(setrow, setcol, noborder, ...)
    end
end

menu.closeContextMenu = function(dueToClose, ...)
    if menu.contextMenuMode == "gt_pilot_exchange_plan" and not overlayClosing then
        debugLog("overlay closed via frame close: " .. tostring(dueToClose))
        onCancel()
        return true
    end
    if originalCloseContextMenu then
        return originalCloseContextMenu(dueToClose, ...)
    end
end

GT_PilotExchangePlan.openOverlay = function(plan)
    return menu.openGTPilotExchangePlanContext(plan)
end

GT_PilotExchangePlan.hasPending = GT_PilotExchangePlan.hasPending or function()
    return false
end

debugLog("Pilot exchange plan overlay loaded")
