-- GalaxyTrader - Trading Academy submenu
-- Spec: DOCS/Spec/FEATURE_FLEET_ACADEMY.md
--
-- Renders a custom MapMenu context frame with one button per academy course.
-- Supports multi-ship selection: each course row shows the count of eligible
-- ships, summed cost, and max training duration across eligible pilots.
--
-- Blackboard keys produced by md.GT_Context_Academy.GT_AcademyAction:
--   $GT_Academy_PlayerMoney         (credits)
--   $GT_Academy_ShipEntries         (list: IdCode, PilotLevel, PilotName, ShipName)
--   $GT_Academy_SelectedShipCount    (int)
--   $GT_Academy_Courses              (list of course tables)
--   $GT_Academy_MinCostPercent       (number)
--   $GT_Academy_MinDuration          (seconds)
--   $GT_Academy_CostExponent         (number)
--
-- Blackboard keys consumed by md.GT_Context_Academy.HandleAcademyCourseChosen:
--   $GT_Academy_ChosenIndex
--   $GT_Academy_ChosenLevel
--   $GT_Academy_ChosenEnrollments    (list: IdCode, Cost centi-cr, Duration sec)

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
    DebugError("[GT Academy] MapMenu not found - academy submenu will not be available")
    return
end

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local MENU_WIDTH                   = 500
local LIST_PAGE_TEXT               = 77000
local TOP_LEVEL_TITLE_TEXT_ID      = 9910
local INSUFFICIENT_FUNDS_TEXT_ID   = 9921
local SHIPS_SELECTED_TEXT_ID       = 9925
local ELIGIBLE_SHIPS_TEXT_ID       = 9926
local NO_ELIGIBLE_SHIPS_TEXT_ID    = 9928

local originalCreateContextFrame  = menu.createContextFrame
local originalRefreshContextFrame = menu.refreshContextFrame

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

local function debugLog(msg)
    DebugError("[GT Academy] " .. tostring(msg))
end

local function getPlayerBlackboardId()
    if _G.GT_PlayerBridge and _G.GT_PlayerBridge.GetPlayerBlackboardId then
        return _G.GT_PlayerBridge.GetPlayerBlackboardId()
    end
    return ConvertStringToLuaID(tostring(C.GetPlayerID()))
end

local function getPlayerSignalId()
    if _G.GT_PlayerBridge and _G.GT_PlayerBridge.GetPlayerSignalId then
        return _G.GT_PlayerBridge.GetPlayerSignalId()
    end
    return ConvertStringTo64Bit(tostring(C.GetPlayerID()))
end

local function readBlackboardList(playerId, key)
    local raw = GetNPCBlackboard(playerId, key)
    return (type(raw) == "table") and raw or nil
end

local function readBlackboardNumber(playerId, key, fallback)
    local raw = GetNPCBlackboard(playerId, key)
    return (type(raw) == "number") and raw or fallback
end

local function normalizeShipEntry(raw, index)
    if type(raw) ~= "table" then
        return nil
    end
    local idCode = raw.IdCode or raw["$IdCode"] or raw.idCode
    if not idCode or idCode == "" then
        return nil
    end
    return {
        idCode     = tostring(idCode),
        pilotLevel = tonumber(raw.PilotLevel or raw["$PilotLevel"] or raw.pilotLevel) or 1,
        pilotName  = raw.PilotName  or raw["$PilotName"]  or raw.pilotName  or "Pilot",
        shipName   = raw.ShipName   or raw["$ShipName"]   or raw.shipName   or "Ship",
        index      = index,
    }
end

-- ---------------------------------------------------------------------------
-- Course math
-- ---------------------------------------------------------------------------

local function calculateCost(listedCost, currentLevel, targetLevel, minPercent, exponent)
    if targetLevel <= 1 then
        return listedCost
    end
    local span = targetLevel - 1
    local diff = targetLevel - math.max(1, currentLevel)
    if diff <= 0 then
        return 0
    end
    local ratio = diff / span
    local scale = math.pow(ratio, exponent or 1.5)
    local minScale = minPercent or 0.05
    if scale < minScale then
        scale = minScale
    end
    return math.floor(listedCost * scale + 0.5)
end

local function calculateDuration(listedDuration, currentLevel, targetLevel, minDuration)
    if targetLevel <= 1 then
        return listedDuration
    end
    local span = targetLevel - 1
    local diff = targetLevel - math.max(1, currentLevel)
    if diff <= 0 then
        return minDuration or 300
    end
    local ratio = diff / span
    local scaled = math.floor(listedDuration * ratio + 0.5)
    local floor = minDuration or 300
    if scaled < floor then
        scaled = floor
    end
    return scaled
end

local function buildAggregatedCourseLabel(course, totalCost, maxDuration)
    local template = GT_UI.safeReadText(LIST_PAGE_TEXT, course.textId, nil)
    if template then
        local filled = template
        filled = string.gsub(filled, "%%1", GT_UI.formatCreditsExact(totalCost))
        filled = string.gsub(filled, "%%2", GT_UI.formatDurationMin(maxDuration))
        return filled
    end
    return string.format("Level %d - %s / %s",
        course.targetLevel,
        GT_UI.formatCreditsExact(totalCost),
        GT_UI.formatDurationMin(maxDuration))
end

local function aggregateCourseForShips(course, ships)
    local totalCost = 0
    local maxDuration = 0
    local eligibleShips = {}

    for _, shipInfo in ipairs(ships) do
        if course.targetLevel > shipInfo.pilotLevel then
            local cost = calculateCost(
                course.listedCost,
                shipInfo.pilotLevel,
                course.targetLevel,
                course.minPercent,
                course.costExponent
            )
            local duration = calculateDuration(
                course.listedDuration,
                shipInfo.pilotLevel,
                course.targetLevel,
                course.minDuration
            )
            table.insert(eligibleShips, {
                idCode         = shipInfo.idCode,
                pilotLevel     = shipInfo.pilotLevel,
                pilotName      = shipInfo.pilotName,
                shipName       = shipInfo.shipName,
                scaledCost     = cost,
                scaledDuration = duration,
            })
            totalCost = totalCost + cost
            if duration > maxDuration then
                maxDuration = duration
            end
        end
    end

    return {
        eligibleCount = #eligibleShips,
        totalCost     = totalCost,
        maxDuration   = maxDuration,
        eligibleShips = eligibleShips,
    }
end

-- ---------------------------------------------------------------------------
-- Blackboard snapshot
-- ---------------------------------------------------------------------------

local function snapshotContext()
    local playerId = getPlayerBlackboardId()
    local courses  = readBlackboardList(playerId, "$GT_Academy_Courses")
    if not courses then
        debugLog("snapshotContext: no $GT_Academy_Courses on blackboard")
        return nil
    end

    local shipEntriesRaw = readBlackboardList(playerId, "$GT_Academy_ShipEntries")
    if not shipEntriesRaw or #shipEntriesRaw < 1 then
        debugLog("snapshotContext: no $GT_Academy_ShipEntries on blackboard")
        return nil
    end

    local playerMoney = readBlackboardNumber(playerId, "$GT_Academy_PlayerMoney", 0)
    local minPercent  = readBlackboardNumber(playerId, "$GT_Academy_MinCostPercent", 0.05)
    local minDuration = readBlackboardNumber(playerId, "$GT_Academy_MinDuration", 300)
    local costExponent = readBlackboardNumber(playerId, "$GT_Academy_CostExponent", 1.5)
    local selectedShipCount = readBlackboardNumber(playerId, "$GT_Academy_SelectedShipCount", #shipEntriesRaw)

    local ships = {}
    for i = 1, #shipEntriesRaw do
        local entry = normalizeShipEntry(shipEntriesRaw[i], i)
        if entry then
            table.insert(ships, entry)
        end
    end
    if #ships < 1 then
        debugLog("snapshotContext: ship entries present but none normalized")
        return nil
    end

    local normalizedCourses = {}
    for i = 1, #courses do
        local c = courses[i]
        if type(c) == "table" then
            table.insert(normalizedCourses, {
                index          = c.Index          or c["$Index"]          or c.index          or i,
                targetLevel    = c.TargetLevel    or c["$TargetLevel"]    or c.targetLevel    or 0,
                listedCost     = c.ListedCost     or c["$ListedCost"]     or c.listedCost     or 0,
                listedDuration = c.ListedDuration or c["$ListedDuration"] or c.listedDuration or 0,
                textId         = c.TextId         or c["$TextId"]         or c.textId         or 0,
                minPercent     = minPercent,
                minDuration    = minDuration,
                costExponent   = costExponent,
            })
        end
    end

    return {
        playerId          = playerId,
        playerMoney       = playerMoney,
        ships             = ships,
        selectedShipCount = selectedShipCount,
        courses           = normalizedCourses,
    }
end

-- ---------------------------------------------------------------------------
-- Course click -> write blackboard + signal MD
-- ---------------------------------------------------------------------------

local function chooseCourse(component, course, ctx, aggregate)
    if not course or not aggregate or aggregate.eligibleCount < 1 then
        return
    end

    local playerId = ctx.playerId
    local enrollments = {}
    for _, shipInfo in ipairs(aggregate.eligibleShips) do
        table.insert(enrollments, {
            IdCode   = shipInfo.idCode,
            Cost     = math.floor(shipInfo.scaledCost * 100 + 0.5),
            Duration = shipInfo.scaledDuration,
        })
    end

    SetNPCBlackboard(playerId, "$GT_Academy_ChosenIndex", course.index)
    SetNPCBlackboard(playerId, "$GT_Academy_ChosenLevel", course.targetLevel)
    SetNPCBlackboard(playerId, "$GT_Academy_ChosenEnrollments", enrollments)

    debugLog(string.format(
        "Player chose Level %d course for %d ship(s) (total=%d Cr, maxDuration=%d s)",
        course.targetLevel,
        aggregate.eligibleCount,
        aggregate.totalCost,
        aggregate.maxDuration
    ))

    SignalObject(getPlayerSignalId(), "gt_academy_course_chosen", ConvertStringToLuaID(tostring(component)))
end

-- ---------------------------------------------------------------------------
-- Frame rendering
-- ---------------------------------------------------------------------------

local function fillPlaceholders(template, ...)
    local args = { ... }
    return (string.gsub(template, "%%(%d)", function(n)
        local v = args[tonumber(n)]
        return v ~= nil and tostring(v) or ("%" .. n)
    end))
end

local function renderCourseRow(tbl, course, ctx, component)
    local aggregate = aggregateCourseForShips(course, ctx.ships)
    local label = buildAggregatedCourseLabel(course, aggregate.totalCost, aggregate.maxDuration)

    local shipsCaptionTemplate = GT_UI.safeReadText(
        LIST_PAGE_TEXT, ELIGIBLE_SHIPS_TEXT_ID, "(%1 ships)")
    local shipsCaption = fillPlaceholders(shipsCaptionTemplate, aggregate.eligibleCount)

    if aggregate.eligibleCount < 1 then
        local row = tbl:addRow(true, { fixed = true })
        GT_UI.createButton(row[1], label, { active = false })
        local noShipsTemplate = GT_UI.safeReadText(
            LIST_PAGE_TEXT, NO_ELIGIBLE_SHIPS_TEXT_ID, "No eligible ships for this course")
        GT_UI.addCaptionRow(tbl, "(" .. noShipsTemplate .. ")")
        return
    end

    if ctx.playerMoney < aggregate.totalCost then
        local row = tbl:addRow(true, { fixed = true })
        GT_UI.createButton(row[1], label, { active = false })
        GT_UI.addCaptionRow(tbl, shipsCaption)
        local template = GT_UI.safeReadText(
            LIST_PAGE_TEXT, INSUFFICIENT_FUNDS_TEXT_ID,
            "Insufficient funds for this course (need %1, have %2)")
        local note = fillPlaceholders(template,
            GT_UI.formatCreditsExact(aggregate.totalCost),
            GT_UI.formatCreditsExact(ctx.playerMoney))
        GT_UI.addCaptionRow(tbl, "(" .. note .. ")")
        return
    end

    local row = tbl:addRow(true, { fixed = true })
    GT_UI.createButton(row[1], label, {
        onClick = function()
            chooseCourse(component, course, ctx, aggregate)
            menu.noupdate = false
            if menu.refreshInfoFrame then
                menu.refreshInfoFrame()
            end
            menu.closeContextMenu("back")
        end,
    })
    GT_UI.addCaptionRow(tbl, shipsCaption)
end

function menu.createGTAcademyContext(frame)
    local component = menu.contextMenuData and menu.contextMenuData.component
    local ctx       = menu.contextMenuData and menu.contextMenuData.ctx
    if not component or not ctx then
        debugLog("createGTAcademyContext: missing component or context, aborting")
        return
    end

    local tbl = frame:addTable(1, {
        tabOrder      = 2,
        x             = Helper.borderSize,
        y             = Helper.borderSize,
        width         = menu.contextMenuData.width,
        highlightMode = "off",
    })

    local titleRow = tbl:addRow(nil, { fixed = true })
    titleRow[1]:createText(
        GT_UI.safeReadText(LIST_PAGE_TEXT, TOP_LEVEL_TITLE_TEXT_ID, "Trading Academy"),
        Helper.headerRowCenteredProperties)

    local subtitleTemplate = GT_UI.safeReadText(
        LIST_PAGE_TEXT, SHIPS_SELECTED_TEXT_ID, "%1 ships selected")
    GT_UI.addCaptionRow(tbl,
        fillPlaceholders(subtitleTemplate, ctx.selectedShipCount),
        { color = nil })

    if #ctx.courses == 0 then
        GT_UI.addEmptyRow(tbl, "(no academy courses available)", 1)
    else
        for _, course in ipairs(ctx.courses) do
            renderCourseRow(tbl, course, ctx, component)
        end
    end

    local cancelRow = tbl:addRow(true, { fixed = true })
    GT_UI.createButton(cancelRow[1], ReadText(1001, 64), {
        onClick = function() menu.closeContextMenu("back") end,
    })

    local neededheight = tbl.properties.y + tbl:getVisibleHeight()
    if frame.properties.y + neededheight + Helper.frameBorder > Helper.viewHeight then
        menu.contextMenuData.yoffset = Helper.viewHeight - neededheight - Helper.frameBorder
        frame.properties.y = menu.contextMenuData.yoffset
    end
end

-- ---------------------------------------------------------------------------
-- Context-frame open / refresh hooks
-- ---------------------------------------------------------------------------

function menu.openGTAcademyContext(component)
    if not component then
        debugLog("openGTAcademyContext: no component supplied")
        return
    end

    local ctx = snapshotContext()
    if not ctx then
        debugLog("openGTAcademyContext: aborted - blackboard context missing")
        return
    end

    local mousepos = C.GetCenteredMousePos()
    menu.contextMenuMode = "gt_academy"
    menu.contextMenuData = {
        component = component,
        ctx       = ctx,
        xoffset   = mousepos.x + Helper.viewWidth / 2,
        yoffset   = mousepos.y + Helper.viewHeight / 2,
        width     = Helper.scaleX(MENU_WIDTH),
    }
    if menu.contextMenuData.xoffset + menu.contextMenuData.width > Helper.viewWidth then
        menu.contextMenuData.xoffset = Helper.viewWidth - menu.contextMenuData.width - Helper.frameBorder
    end

    menu.createContextFrame(menu.contextMenuData.width, nil,
        menu.contextMenuData.xoffset, menu.contextMenuData.yoffset)
    menu.refreshContextFrame()
end

menu.createContextFrame = function(width, height, xoffset, yoffset, noborder, startanimation, ...)
    if menu.contextMenuMode == "gt_academy" then
        local mousepos = C.GetCenteredMousePos()
        menu.contextMenuData = menu.contextMenuData or {}
        menu.contextMenuData.xoffset = xoffset or (mousepos.x + Helper.viewWidth / 2)
        menu.contextMenuData.yoffset = yoffset or (mousepos.y + Helper.viewHeight / 2)
        menu.contextMenuData.width   = width or Helper.scaleX(MENU_WIDTH)

        if menu.contextMenuData.xoffset + menu.contextMenuData.width > Helper.viewWidth then
            menu.contextMenuData.xoffset = Helper.viewWidth - menu.contextMenuData.width - Helper.frameBorder
        end

        local contextLayer = 2
        Helper.removeAllWidgetScripts(menu, contextLayer)

        menu.contextFrame = Helper.createFrameHandle(menu, {
            x        = menu.contextMenuData.xoffset - (noborder and 0 or 2 * Helper.borderSize),
            y        = menu.contextMenuData.yoffset,
            width    = menu.contextMenuData.width + (noborder and 0 or 2 * Helper.borderSize),
            layer    = contextLayer,
            standardButtons       = { close = true },
            closeOnUnhandledClick = true,
            startAnimation        = startanimation,
        })
        menu.contextFrame:setBackground("solid", { color = GT_UI.COLORS.frameBg })

        menu.createGTAcademyContext(menu.contextFrame)

        menu.contextFrame.properties.height = math.min(
            Helper.viewHeight - menu.contextFrame.properties.y,
            menu.contextFrame:getUsedHeight() + Helper.borderSize
        )

        return menu.contextFrame
    end

    if originalCreateContextFrame then
        return originalCreateContextFrame(width, height, xoffset, yoffset, noborder, startanimation, ...)
    end
end

menu.refreshContextFrame = function(setrow, setcol, noborder, ...)
    if menu.contextMenuMode == "gt_academy" then
        local contextLayer = 2
        Helper.removeAllWidgetScripts(menu, contextLayer)
        if menu.contextFrame then
            menu.contextFrame:display()
        end
        return
    end

    if originalRefreshContextFrame then
        originalRefreshContextFrame(setrow, setcol, noborder, ...)
    end
end

RegisterEvent("gt.openAcademyContext", function(_, component)
    if not component then
        debugLog("gt.openAcademyContext fired without component - ignoring")
        return
    end

    local component64 = ConvertIDTo64Bit(component)
    if not component64 or component64 == 0 then
        debugLog("gt.openAcademyContext: invalid component id")
        return
    end

    menu.openGTAcademyContext(component64)
end)

debugLog("Trading Academy context-menu integration loaded")
