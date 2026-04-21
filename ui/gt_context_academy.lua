-- GalaxyTrader - Trading Academy submenu
-- Spec: DOCS/Spec/FEATURE_FLEET_ACADEMY.md
--
-- Renders a custom MapMenu context frame with one button per academy course.
-- Reads pilot/player/course state from the player NPC blackboard, computes
-- personalized cost (quadratic curve with floor) and duration (linear scale
-- with floor), and signals the chosen course back to MD via SignalObject.
--
-- Blackboard keys produced by md.GT_Context_Academy.GT_AcademyAction:
--   $GT_Academy_PilotLevel       (int, 1..15)
--   $GT_Academy_PlayerMoney      (raw credits, *100)
--   $GT_Academy_PilotName        (string)
--   $GT_Academy_ShipName         (string)
--   $GT_Academy_Courses          (list of tables)
--     each (MD side):  { $Index, $TargetLevel, $ListedCost, $ListedDuration, $TextId }
--     each (Lua side): {  Index,  TargetLevel,  ListedCost,  ListedDuration,  TextId }
--     (X4 strips the `$` prefix from MD table keys when exposing to Lua.)
--   $GT_Academy_MinCostPercent   (number, e.g. 0.05)
--   $GT_Academy_MinDuration      (seconds, e.g. 300)
--   $GT_Academy_CostExponent     (number, e.g. 1.5)
--
-- Blackboard keys consumed by md.GT_Context_Academy.HandleAcademyCourseChosen:
--   $GT_Academy_ChosenIndex
--   $GT_Academy_ChosenLevel
--   $GT_Academy_ChosenCost      (raw credits, *100)
--   $GT_Academy_ChosenDuration  (seconds)

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

local MENU_WIDTH                = 460
local LIST_PAGE_TEXT            = 77000
local TOP_LEVEL_TITLE_TEXT_ID   = 9910
local INSUFFICIENT_FUNDS_TEXT_ID = 9921
local UNAVAILABLE_TEXT_ID       = 9922

local originalCreateContextFrame  = menu.createContextFrame
local originalRefreshContextFrame = menu.refreshContextFrame

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

local function debugLog(msg)
    DebugError("[GT Academy] " .. tostring(msg))
end

local function getPlayerId64()
    return ConvertStringTo64Bit(tostring(C.GetPlayerID()))
end

-- Blackboard typed accessors with fallbacks. The list reader returns nil if
-- the key is missing or not a table, so callers can short-circuit cleanly.
local function readBlackboardList(playerId, key)
    local raw = GetNPCBlackboard(playerId, key)
    return (type(raw) == "table") and raw or nil
end

local function readBlackboardNumber(playerId, key, fallback)
    local raw = GetNPCBlackboard(playerId, key)
    return (type(raw) == "number") and raw or fallback
end

local function readBlackboardString(playerId, key, fallback)
    local raw = GetNPCBlackboard(playerId, key)
    return (type(raw) == "string") and raw or fallback
end

-- ---------------------------------------------------------------------------
-- Course math
--
-- Cost formula:
--   listedCost is the PRICE for a level-1 pilot (the "headline" price).
--   For a pilot already at $current, scale by ((target - current) / (target - 1))^exponent
--   and floor at minPercent of listedCost.
-- Duration formula:
--   listedDuration scales linearly with the same level-difference ratio,
--   floored at minDuration seconds.
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
    -- Round to whole credits. (Inputs are already in Cr -- GetNPCBlackboard
    -- auto-converts money-typed fields from centicredits when reading from
    -- player.entity. Earlier code snapped to multiples of 100 Cr on the
    -- centicredit assumption, which silently dropped two digits of precision.)
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

local function buildCourseLabel(course, currentLevel)
    local cost = calculateCost(
        course.listedCost,
        currentLevel,
        course.targetLevel,
        course.minPercent,
        course.costExponent
    )
    local duration = calculateDuration(
        course.listedDuration,
        currentLevel,
        course.targetLevel,
        course.minDuration
    )
    course.scaledCost = cost
    course.scaledDuration = duration

    local template = GT_UI.safeReadText(LIST_PAGE_TEXT, course.textId, nil)
    if template then
        local filled = template
        filled = string.gsub(filled, "%%1", GT_UI.formatCreditsExact(cost))
        filled = string.gsub(filled, "%%2", GT_UI.formatDurationMin(duration))
        return filled
    end
    return string.format("Level %d - %s / %s",
        course.targetLevel,
        GT_UI.formatCreditsExact(cost),
        GT_UI.formatDurationMin(duration))
end

-- ---------------------------------------------------------------------------
-- Blackboard snapshot
-- ---------------------------------------------------------------------------

local function snapshotContext()
    local playerId = getPlayerId64()
    local courses  = readBlackboardList(playerId, "$GT_Academy_Courses")
    if not courses then
        debugLog("snapshotContext: no $GT_Academy_Courses on blackboard")
        return nil
    end

    local pilotLevel   = readBlackboardNumber(playerId, "$GT_Academy_PilotLevel",     1)
    local playerMoney  = readBlackboardNumber(playerId, "$GT_Academy_PlayerMoney",    0)
    local pilotName    = readBlackboardString(playerId, "$GT_Academy_PilotName",      "Pilot")
    local shipName     = readBlackboardString(playerId, "$GT_Academy_ShipName",       "Ship")
    local minPercent   = readBlackboardNumber(playerId, "$GT_Academy_MinCostPercent", 0.05)
    local minDuration  = readBlackboardNumber(playerId, "$GT_Academy_MinDuration",    300)
    local costExponent = readBlackboardNumber(playerId, "$GT_Academy_CostExponent",   1.5)

    -- MD `$Field` is exposed to Lua as `Field` (case preserved, `$` stripped).
    -- The legacy `["$Field"]` and lowercase `field` lookups are kept as defensive
    -- fallbacks but should never fire in normal operation.
    local normalized = {}
    for i = 1, #courses do
        local c = courses[i]
        if type(c) == "table" then
            table.insert(normalized, {
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
        playerId    = playerId,
        pilotLevel  = pilotLevel,
        playerMoney = playerMoney,
        pilotName   = pilotName,
        shipName    = shipName,
        courses     = normalized,
    }
end

-- ---------------------------------------------------------------------------
-- Course click → write blackboard + signal MD
-- ---------------------------------------------------------------------------

local function chooseCourse(component, course, ctx)
    if not course then return end

    local playerId = ctx.playerId
    -- Round-trip unit fix: GetNPCBlackboard auto-converts money-typed MD
    -- fields from centi-credits to credits when handing them to Lua, but
    -- SetNPCBlackboard does NOT reverse that conversion - whatever number
    -- Lua writes lands raw on the player.entity blackboard. Every MD code
    -- path downstream (logbook message templates, reward_player, the
    -- insufficient-funds notification, debug texts) assumes the stored
    -- value is in centi-credits and divides by 100 to display credits.
    -- Pre-multiply by 100 here so the round-trip is consistent: the
    -- button shows "272,166 Cr", MD's `$lockedCost / 100` displays
    -- "272,166", and `($lockedCost * 1Cr) / 100` deducts exactly 272,166 Cr.
    -- Without this pre-multiply the player is charged 1/100th of the
    -- promised price (verified empirically: HAW-289's level-4 course
    -- showed 272,166 Cr on the button but only 2,721 Cr in the logbook).
    local centiCredits = math.floor(course.scaledCost * 100 + 0.5)
    SetNPCBlackboard(playerId, "$GT_Academy_ChosenIndex",    course.index)
    SetNPCBlackboard(playerId, "$GT_Academy_ChosenLevel",    course.targetLevel)
    SetNPCBlackboard(playerId, "$GT_Academy_ChosenCost",     centiCredits)
    SetNPCBlackboard(playerId, "$GT_Academy_ChosenDuration", course.scaledDuration)

    debugLog(string.format(
        "Player chose Level %d course (cost=%d Cr -> %d centi-cr raw, duration=%d s) for ship %s",
        course.targetLevel, course.scaledCost, centiCredits, course.scaledDuration, tostring(component)
    ))

    SignalObject(playerId, "gt_academy_course_chosen", ConvertStringToLuaID(tostring(component)))
end

-- ---------------------------------------------------------------------------
-- Frame rendering
-- ---------------------------------------------------------------------------

-- Substitute %1, %2, ... placeholders in a localized template with the
-- supplied positional values. Mirrors X4's `%N`-style substitution rules:
-- only matches a literal `%<digit>`, leaves everything else alone.
local function fillPlaceholders(template, ...)
    local args = { ... }
    return (string.gsub(template, "%%(%d)", function(n)
        local v = args[tonumber(n)]
        return v ~= nil and tostring(v) or ("%" .. n)
    end))
end

-- Renders one course entry: an enabled action button, or a disabled button
-- followed by an explanatory caption row. Splitting the caption onto its own
-- row avoids the visual overlap that "label\n(reason)" inside a single
-- fixed-height button caused in earlier versions.
local function renderCourseRow(tbl, course, ctx, component)
    local label = buildCourseLabel(course, ctx.pilotLevel)

    if course.targetLevel <= ctx.pilotLevel then
        local row = tbl:addRow(true, { fixed = true })
        GT_UI.createButton(row[1], label, { active = false })
        local template = GT_UI.safeReadText(
            LIST_PAGE_TEXT, UNAVAILABLE_TEXT_ID,
            "Course unavailable - pilot %1 is already at or above this level")
        GT_UI.addCaptionRow(tbl, "(" .. fillPlaceholders(template, ctx.pilotName) .. ")")
        return
    end

    if ctx.playerMoney < course.scaledCost then
        local row = tbl:addRow(true, { fixed = true })
        GT_UI.createButton(row[1], label, { active = false })
        local template = GT_UI.safeReadText(
            LIST_PAGE_TEXT, INSUFFICIENT_FUNDS_TEXT_ID,
            "Insufficient funds for this course (need %1, have %2)")
        local note = fillPlaceholders(template,
            GT_UI.formatCreditsExact(course.scaledCost),
            GT_UI.formatCreditsExact(ctx.playerMoney))
        GT_UI.addCaptionRow(tbl, "(" .. note .. ")")
        return
    end

    local row = tbl:addRow(true, { fixed = true })
    GT_UI.createButton(row[1], label, {
        onClick = function()
            chooseCourse(component, course, ctx)
            menu.noupdate = false
            if menu.refreshInfoFrame then
                menu.refreshInfoFrame()
            end
            menu.closeContextMenu("back")
        end,
    })
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

    -- Title
    local titleRow = tbl:addRow(nil, { fixed = true })
    titleRow[1]:createText(
        GT_UI.safeReadText(LIST_PAGE_TEXT, TOP_LEVEL_TITLE_TEXT_ID, "Trading Academy"),
        Helper.headerRowCenteredProperties)

    -- Subtitle: pilot + ship + current level
    GT_UI.addCaptionRow(tbl,
        string.format("%s  -  %s  (Lvl %d)", ctx.pilotName, ctx.shipName, ctx.pilotLevel),
        { color = nil })  -- nil → text_inactive default; explicit for clarity

    -- Course rows
    if #ctx.courses == 0 then
        GT_UI.addEmptyRow(tbl, "(no academy courses available)", 1)
    else
        for _, course in ipairs(ctx.courses) do
            renderCourseRow(tbl, course, ctx, component)
        end
    end

    -- Cancel button
    local cancelRow = tbl:addRow(true, { fixed = true })
    GT_UI.createButton(cancelRow[1], ReadText(1001, 64), {  -- "Cancel"
        onClick = function() menu.closeContextMenu("back") end,
    })

    -- Adjust frame position if needed (mirrors gt_context_rename pattern)
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
