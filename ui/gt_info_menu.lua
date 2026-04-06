-- GalaxyTrader MK3 Info Menu
-- Phase 1: Basic Display with Sorting

local menu = {}
local gtMenu = {
    isCreated = false,
    currentSort = { column = "pilotProfit", descending = true },  -- Default sort by pilot profit
    currentTab = "overview",  -- Current tab: "overview", "control", or "renaming"
    selectedShipId = nil,     -- Track selected ship across tabs (shipId string)
    renamingShipId = nil,     -- Track which ship is currently being renamed (to show editbox)
    lastRefreshTime = 0,      -- Track last refresh to prevent rapid updates
    refreshCooldown = 3,      -- Minimum seconds between auto-refreshes (prevents row jumping)
    lastDataRequestTime = 0,  -- Throttle MD refresh requests when bridge not initialized
    dataRequestCooldown = 2,  -- Seconds between initialization refresh requests
    isBuildingInfoFrame = false, -- Guard against re-entrant refresh during frame build
    rowHeight = Helper.standardTextHeight,
    fontSize = Helper.standardFontSize,
}

-- Fetch all pilot data from Lua bridge (populated by MD)
function gtMenu.getPilotData()
    local pilots = {}
    
    -- Check if pilot data bridge is loaded
    if not Mods or not Mods.GalaxyTrader or not Mods.GalaxyTrader.PilotData then
        DebugError("[GT Menu] Pilot data bridge not loaded yet")
        return pilots
    end
    
    local pilotBridge = Mods.GalaxyTrader.PilotData
    
    -- Request fresh data from MD if not initialized
    if not pilotBridge.isInitialized() then
        local now = getElapsedTime()
        if (now - gtMenu.lastDataRequestTime) >= gtMenu.dataRequestCooldown then
            DebugError("[GT Menu] Requesting initial pilot data from MD")
            pilotBridge.requestRefresh()
            gtMenu.lastDataRequestTime = now
        end
        return pilots
    end
    
    -- Get pilots from bridge
    pilots = pilotBridge.getPilots()
    
    -- local dataAge = getElapsedTime() - pilotBridge.getLastUpdate()
    -- DebugError(string.format("[GT Menu] Retrieved %d pilots from bridge (last update: %.1fs ago)", 
    --     #pilots, dataAge))
    
    return pilots
end

-- Called by pilot data bridge when new data arrives (event-driven refresh)
function gtMenu.onDataUpdate()
    -- Only refresh if the menu is currently open and showing our info
    if menu and menu.infoTableMode == "galaxytraderinfo" then
        -- X4 9 UI can throw rowgroup/cell overwrite errors when refreshInfoFrame
        -- is triggered asynchronously during an active frame build. Avoid
        -- event-driven refresh here; data is pulled on the next normal redraw.
        if gtMenu.isBuildingInfoFrame then
            return
        end
    end
end

-- Format money - delegate to GT_UI library (single source of truth)
function gtMenu.formatMoney(amount)
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

-- Safe string comparison that handles special characters
local function safeStringCompare(a, b)
    -- Normalize strings to lowercase
    local aStr = string.lower(tostring(a or ""))
    local bStr = string.lower(tostring(b or ""))
    
    -- Simple string comparison
    if aStr == bStr then
        return false  -- Equal strings
    end
    return aStr < bStr
end

-- Sort pilot data by current sort configuration
function gtMenu.sortPilots(pilots)
    if not pilots or #pilots == 0 then
        return
    end
    
    local sortColumn = gtMenu.currentSort.column
    local descending = gtMenu.currentSort.descending
    
    -- Use pcall to protect against sort failures
    local success, err = pcall(function()
        table.sort(pilots, function(a, b)
            -- Safety check: ensure both objects are valid
            if not a then return false end
            if not b then return true end
            
            -- Get primary sort values with explicit type conversion
            local aVal, bVal
            local isNumeric = false
            
            if sortColumn == "shipId" then
                aVal = tostring(a.shipId or "")
                bVal = tostring(b.shipId or "")
            elseif sortColumn == "pilot" then
                aVal = tostring(a.pilotName or "")
                bVal = tostring(b.pilotName or "")
            elseif sortColumn == "ship" then
                aVal = tostring(a.shipType or "")
                bVal = tostring(b.shipType or "")
            elseif sortColumn == "status" then
                aVal = tostring(a.status or "")
                bVal = tostring(b.status or "")
            elseif sortColumn == "rank" then
                aVal = tonumber(a.rankIndex) or 1
                bVal = tonumber(b.rankIndex) or 1
                isNumeric = true
            elseif sortColumn == "level" then
                aVal = tonumber(a.level) or 1
                bVal = tonumber(b.level) or 1
                isNumeric = true
            elseif sortColumn == "xp" then
                aVal = tonumber(a.xp) or 0
                bVal = tonumber(b.xp) or 0
                isNumeric = true
            elseif sortColumn == "pilotProfit" then
                aVal = tonumber(a.pilotProfit) or 0
                bVal = tonumber(b.pilotProfit) or 0
                isNumeric = true
            elseif sortColumn == "shipProfit" then
                aVal = tonumber(a.shipProfit) or 0
                bVal = tonumber(b.shipProfit) or 0
                isNumeric = true
            elseif sortColumn == "sector" then
                aVal = tostring(a.location or "")
                bVal = tostring(b.location or "")
            else
                -- Default: sort by pilot name
                aVal = tostring(a.pilotName or "")
                bVal = tostring(b.pilotName or "")
            end
            
            -- Primary comparison
            if aVal ~= bVal then
                local result
                if isNumeric then
                    result = aVal < bVal
                else
                    result = safeStringCompare(aVal, bVal)
                end
                -- Fix: Proper strict weak ordering - when descending, invert result
                if descending then
                    return not result
                else
                    return result
                end
            end
            
            -- Secondary sort by pilot name (always ascending for stability)
            local aName = tostring(a.pilotName or "")
            local bName = tostring(b.pilotName or "")
            if aName ~= bName then
                return safeStringCompare(aName, bName)
            end
            
            -- Tertiary sort by ship ID if names are also equal
            local aShip = tostring(a.shipId or "")
            local bShip = tostring(b.shipId or "")
            return safeStringCompare(aShip, bShip)
        end)
    end)
    
    if not success then
        DebugError("[GT Menu] Sort failed: " .. tostring(err))
    end
end

-- Handle column header click for sorting
function gtMenu.onHeaderClick(sortColumn)
    -- DebugError(string.format("[GT Menu] onHeaderClick called: column='%s', currentColumn='%s', currentDesc=%s", 
    --     sortColumn, gtMenu.currentSort.column, tostring(gtMenu.currentSort.descending)))
    
    -- Toggle sort direction if clicking same column, otherwise default to descending
    if gtMenu.currentSort.column == sortColumn then
        gtMenu.currentSort.descending = not gtMenu.currentSort.descending
    else
        gtMenu.currentSort.column = sortColumn
        gtMenu.currentSort.descending = true
    end
    
    -- DebugError(string.format("[GT Menu] New sort state: column='%s', descending=%s", 
    --     gtMenu.currentSort.column, tostring(gtMenu.currentSort.descending)))
    
    -- User-initiated refresh bypasses cooldown and updates lastRefreshTime
    gtMenu.lastRefreshTime = getElapsedTime()
    
    -- Refresh the info frame to show new sort
    if menu and menu.refreshInfoFrame then
        menu.refreshInfoFrame()
        -- DebugError("[GT Menu] refreshInfoFrame called successfully")
    else
        DebugError("[GT Menu] ERROR: menu.refreshInfoFrame not available!")
    end
end

-- Display pilot table in info frame
function gtMenu.displayPilotTable(frame, instance, yOffset)
    -- DebugError(string.format("[GT Menu] displayPilotTable called - current sort: '%s' %s", 
    --     gtMenu.currentSort.column, gtMenu.currentSort.descending and "DESC" or "ASC"))
    
    -- Fetch pilot data
    local pilots = gtMenu.getPilotData()
    gtMenu.sortPilots(pilots)
    
    -- Create table with 10 columns - make it wider for better readability
    -- Position below tabs if yOffset is provided
    local pilotTable = frame:addTable(10, { 
        tabOrder = 2, 
        reserveScrollBar = false,  -- Disable for now - causes column width issues
        width = Helper.standardTextWidth * 4,
        y = yOffset or 0,
        maxVisibleHeight = Helper.viewHeight
    })
    pilotTable:setDefaultCellProperties("text", { minRowHeight = gtMenu.rowHeight, fontsize = gtMenu.fontSize })
    
    -- Set column widths (percentages add up to 100%)
    pilotTable:setColWidthPercent(1, 8)   -- Ship ID
    pilotTable:setColWidthPercent(2, 12)  -- Pilot
    pilotTable:setColWidthPercent(3, 10)  -- Ship
    pilotTable:setColWidthPercent(4, 13)  -- Status
    pilotTable:setColWidthPercent(5, 10)  -- Rank
    pilotTable:setColWidthPercent(6, 5)   -- Level
    pilotTable:setColWidthPercent(7, 11)  -- XP
    pilotTable:setColWidthPercent(8, 11)  -- Pilot Profit
    pilotTable:setColWidthPercent(9, 11)  -- Ship Profit
    pilotTable:setColWidthPercent(10, 9)  -- Sector
    
    -- Header row with click handlers for sorting
    local headerRow = pilotTable:addRow(false, { bgColor = Color["row_title_background"], fixed = true })
    
    -- Helper function to create sortable header (must use buttons, not text!)
    local function createSortableHeader(cell, textId, sortColumn)
        local text = ReadText(77000, textId)
        local displayText = text
        
        -- Add arrow indicator for currently sorted column
        if gtMenu.currentSort.column == sortColumn then
            displayText = text .. (gtMenu.currentSort.descending and " ▼" or " ▲")
        end
        
        -- Create button (text cells are not clickable)
        cell:createButton({ height = gtMenu.rowHeight }):setText(displayText, { halign = "center" })
        
        -- Set click handler on the cell
        cell.handlers.onClick = function()
            DebugError("[GT Menu] Header clicked: " .. sortColumn)
            return gtMenu.onHeaderClick(sortColumn)
        end
    end
    
    createSortableHeader(headerRow[1], 8100, "shipId")      -- Ship ID
    createSortableHeader(headerRow[2], 8101, "pilot")       -- Pilot
    createSortableHeader(headerRow[3], 8102, "ship")        -- Ship
    createSortableHeader(headerRow[4], 8103, "status")      -- Status
    createSortableHeader(headerRow[5], 8104, "rank")        -- Rank
    createSortableHeader(headerRow[6], 8105, "level")       -- Level
    createSortableHeader(headerRow[7], 8106, "xp")          -- XP
    createSortableHeader(headerRow[8], 8111, "pilotProfit") -- Pilot Profit
    createSortableHeader(headerRow[9], 8112, "shipProfit")  -- Ship Profit
    createSortableHeader(headerRow[10], 8114, "sector")     -- Sector
    
    -- Check if we have any pilots
    if #pilots == 0 then
        local emptyRow = pilotTable:addRow(nil, {})
        emptyRow[1]:setColSpan(10):createText(ReadText(77000, 8600), { halign = "center" })
        local emptyRow2 = pilotTable:addRow(nil, {})
        emptyRow2[1]:setColSpan(10):createText(ReadText(77000, 8601), { halign = "center", fontsize = Helper.standardFontSize * 0.8 })
        return
    end
    
    -- FIX: Limit rows to prevent X4's 50 shield/hull bar limit from being exceeded
    -- X4 automatically creates shield/hull bars for selectable rows, and has a global limit of 50
    -- Limit display to 50 rows to stay under the limit (header + 50 rows = 51 total, but header doesn't count)
    local maxRows = 50
    local pilotsToDisplay = pilots
    if #pilots > maxRows then
        pilotsToDisplay = {}
        for i = 1, maxRows do
            pilotsToDisplay[i] = pilots[i]
        end
        DebugError(string.format("[GT Menu] Limiting display to %d rows (out of %d total) to prevent shield/hull bar limit", maxRows, #pilots))
    end
    
    -- Add pilot rows as regular rows (non-selectable) to avoid rowgroup conflicts in X4 9 UI.
    for i, pilot in ipairs(pilotsToDisplay) do
        -- Highlight selected row
        local isSelected = (pilot.shipId == gtMenu.selectedShipId)
        local cellBgColor = isSelected and Color["row_background_selected"] or nil
        
        local row = pilotTable:addRow(false, {})
        
        -- Column order MUST match headers: Ship ID, Pilot, Ship, Status, Rank, Level, XP, Pilot Profit, Ship Profit, Sector
        row[1]:createText(pilot.shipId or "???", { cellBGColor = cellBgColor })
        row[2]:createText(pilot.pilotName or "Unknown", { cellBGColor = cellBgColor })
        row[3]:createText(pilot.shipType or "Unknown Ship", { cellBGColor = cellBgColor })
        row[4]:createText(pilot.status or "[UNKNOWN]", { cellBGColor = cellBgColor })
        row[5]:createText(pilot.rank or "Apprentice", { cellBGColor = cellBgColor })
        row[6]:createText(tostring(pilot.level or 1), { halign = "center", cellBGColor = cellBgColor })
        row[7]:createText(pilot.xpFormatted or "0 / 1000", { halign = "right", cellBGColor = cellBgColor })
        row[8]:createText(pilot.pilotProfitFormatted or "0 Cr", { halign = "right", cellBGColor = cellBgColor })
        row[9]:createText(pilot.shipProfitFormatted or "0 Cr", { halign = "right", cellBGColor = cellBgColor })
        row[10]:createText(pilot.location or "Unknown", { cellBGColor = cellBgColor })
    end
    
    -- Footer row with totals
    local footerRow = pilotTable:addRow(nil, { bgColor = Color["row_title_background"] })
    if #pilots > maxRows then
        footerRow[1]:setColSpan(7):createText(string.format("%s %d (Showing: %d)", ReadText(77000, 8402), #pilots, maxRows), {})  -- "Total Pilots: N (Showing: 50)"
    else
        footerRow[1]:setColSpan(7):createText(string.format("%s %d", ReadText(77000, 8402), #pilots), {})  -- "Total Pilots: N"
    end
    
    -- Calculate total pilot profit and total ship profit
    local totalPilotProfit = 0
    local totalShipProfit = 0
    for _, pilot in ipairs(pilots) do
        totalPilotProfit = totalPilotProfit + (pilot.pilotProfit or 0)
        totalShipProfit = totalShipProfit + (pilot.shipProfit or 0)
    end
    footerRow[8]:createText(gtMenu.formatMoney(totalPilotProfit), { halign = "right" })
    footerRow[9]:createText(gtMenu.formatMoney(totalShipProfit), { halign = "right" })
end

-- Add sidebar button to Map Menu
function gtMenu.createSideBar(_config)
    -- Debug: Log what's being called (commented out to reduce log spam)
    -- DebugError("[GT Menu] createSideBar called - menu.name: " .. tostring(menu and menu.name or "nil"))
    
    -- CRITICAL: Only add button to Map Menu, not other menus
    -- Check the menu object itself, not just the config
    if not menu or menu.name ~= "MapMenu" then
        DebugError("[GT Menu] Skipping - not MapMenu (menu.name=" .. tostring(menu and menu.name or "nil") .. ")")
        return  -- Wrong menu object
    end
    
    -- Only add button once
    if gtMenu.isCreated then
        -- DebugError("[GT Menu] Skipping - button already created")
        return
    end
    
    if not _config or not _config.leftBar then
        DebugError("[GT Menu] Skipping - invalid config")
        return
    end
    
    -- Log existing buttons before we add ours (commented out to reduce log spam)
    -- DebugError("[GT Menu] leftBar has " .. tostring(#_config.leftBar) .. " items before adding GT button")
    -- for i, item in ipairs(_config.leftBar) do
    --     if item.name then
    --         DebugError("[GT Menu]   [" .. i .. "] name=" .. tostring(item.name) .. " mode=" .. tostring(item.mode))
    --     elseif item.spacing then
    --         DebugError("[GT Menu]   [" .. i .. "] (spacing)")
    --     end
    -- end
    
    -- Double-check by looking for Map Menu specific modes
    local hasMapMode = false
    for _, item in ipairs(_config.leftBar) do
        if item.mode and (item.mode == "info" or item.mode == "sectors") then
            hasMapMode = true
            break
        end
    end
    
    if not hasMapMode then
        -- DebugError("[GT Menu] Skipping - no Map Menu modes found")
        return  -- Not Map Menu
    end
    
    -- Add our button to Map Menu - insert right after "Information" button for consistent positioning
    local gtInfoButton = {
        name = ReadText(77000, 8000),  -- "GalaxyTrader Fleet"
        icon = "mapst_cheats",
        mode = "galaxytraderinfo",
        helpOverlayID = "help_sidebar_galaxytraderinfo",
        helpOverlayText = ReadText(77000, 8001)  -- "GalaxyTrader fleet management and pilot statistics"
    }
    
    -- Find the "Information" button position (vanilla button, always present)
    local insertPosition = #_config.leftBar + 1  -- Default: append at end
    for i, item in ipairs(_config.leftBar) do
        if item.mode and item.mode == "info" then
            -- Insert right after "Information" button (after its spacing if present)
            insertPosition = i + 1
            -- Skip spacing if next item is spacing
            if _config.leftBar[insertPosition] and _config.leftBar[insertPosition].spacing then
                insertPosition = insertPosition + 1
            end
            -- DebugError("[GT Menu] Found 'Information' button at position " .. i .. ", inserting at " .. insertPosition)
            break
        end
    end
    
    -- Insert button at fixed position relative to vanilla button
    table.insert(_config.leftBar, insertPosition, { spacing = true })
    table.insert(_config.leftBar, insertPosition + 1, gtInfoButton)
    
    gtMenu.isCreated = true
    -- DebugError("[GT Menu] GT button added successfully at position " .. (insertPosition + 1))
end

-- Render info frame when mode is active
-- Note: Callback passes menu.infoFrame as parameter, but we access it directly from menu
function gtMenu.createInfoFrame()
    if menu.infoTableMode == "galaxytraderinfo" then
        gtMenu.isBuildingInfoFrame = true
        local ok, err = pcall(function()
            -- Clear previously added widgets before rebuilding. In X4 9, repeated
            -- createInfoFrame callbacks can reuse menu.infoFrame; appending tables
            -- without clearing causes cell overwrite/disconnected rowgroup errors.
            if menu.infoFrame and menu.infoFrame.content then
                for _, widget in ipairs(menu.infoFrame.content) do
                    if widget.descriptor then
                        ReleaseDescriptor(widget.descriptor)
                    end
                end
                menu.infoFrame.content = {}
            end

            -- BETA PREVIEW BANNER
            local bannerTable = menu.infoFrame:addTable(1, {
                tabOrder = 0,
                width = Helper.standardTextWidth * 4,
                y = 0
            })
            local bannerRow = bannerTable:addRow(false, { bgColor = Color["text_warning"] })
            bannerRow[1]:createText("⚠ BETA PREVIEW - This feature is under development. Some functionality may be incomplete or change in future versions. ⚠", {
                halign = "center",
                fontsize = Helper.standardFontSize,
                color = Color["text_negative"],
                wordwrap = true
            })
            
            -- Calculate banner height for proper spacing
            local bannerHeight = Helper.standardTextHeight * 2
            
            -- Create tabs with proper width allocation (3 tabs)
            local tabTable = menu.infoFrame:addTable(3, { 
                tabOrder = 1, 
                width = Helper.standardTextWidth * 4,
                y = bannerHeight
            })
            tabTable:setColWidthPercent(1, 33)
            tabTable:setColWidthPercent(2, 34)
            tabTable:setColWidthPercent(3, 33)
            
            local tabRow = tabTable:addRow(false, { fixed = true })
            
            -- Overview Tab
            local overviewBgColor = (gtMenu.currentTab == "overview") and Color["row_background_selected"] or Color["row_background_blue"]
            local overviewBtn = tabRow[1]:createButton({ 
                height = gtMenu.rowHeight,
                bgColor = overviewBgColor 
            })
            overviewBtn:setText(ReadText(77000, 8300), { halign = "center" })
            tabRow[1].handlers.onClick = function()
                -- DebugError("[GT Menu] Overview tab clicked")
                gtMenu.currentTab = "overview"
                menu.refreshInfoFrame()
                return true
            end
            
            -- Control Tab
            local controlBgColor = (gtMenu.currentTab == "control") and Color["row_background_selected"] or Color["row_background_blue"]
            local controlBtn = tabRow[2]:createButton({ 
                height = gtMenu.rowHeight,
                bgColor = controlBgColor 
            })
            controlBtn:setText(ReadText(77000, 8301), { halign = "center" })
            tabRow[2].handlers.onClick = function()
                -- DebugError("[GT Menu] Control tab clicked")
                gtMenu.currentTab = "control"
                menu.refreshInfoFrame()
                return true
            end
            
            -- Renaming Tab
            local renamingBgColor = (gtMenu.currentTab == "renaming") and Color["row_background_selected"] or Color["row_background_blue"]
            local renamingBtn = tabRow[3]:createButton({ 
                height = gtMenu.rowHeight,
                bgColor = renamingBgColor 
            })
            renamingBtn:setText(ReadText(77000, 8302), { halign = "center" })
            tabRow[3].handlers.onClick = function()
                -- DebugError("[GT Menu] Renaming tab clicked")
                gtMenu.currentTab = "renaming"
                menu.refreshInfoFrame()
                return true
            end
            
            -- Calculate total offset: banner + tabs + spacing
            local tabHeight = gtMenu.rowHeight + 10  -- Tab button height + small margin
            local contentYOffset = bannerHeight + tabHeight  -- Banner height + tab height
            
            -- Display content based on current tab (positioned below banner and tabs)
            if gtMenu.currentTab == "overview" then
                gtMenu.displayPilotTable(menu.infoFrame, "left", contentYOffset)
            elseif gtMenu.currentTab == "control" then
                gtMenu.displayPilotControl(menu.infoFrame, "left", contentYOffset)
            elseif gtMenu.currentTab == "renaming" then
                gtMenu.displayRenaming(menu.infoFrame, "left", contentYOffset)
            end
        end)
        gtMenu.isBuildingInfoFrame = false
        if not ok then
            DebugError("[GT Menu] createInfoFrame failed: " .. tostring(err))
        end
    end
end

-- Display ship renaming panel
function gtMenu.displayRenaming(frame, instance, yOffset)
    DebugError(string.format("[GT Menu] displayRenaming called (yOffset=%s)", tostring(yOffset)))
    
    -- Validate parameters
    if not frame then
        DebugError("[GT Menu] ERROR: frame is nil!")
        return
    end
    
    -- Ensure yOffset is a valid number
    yOffset = tonumber(yOffset) or 0
    
    -- Fetch pilot data
    local pilots = gtMenu.getPilotData()
    gtMenu.sortPilots(pilots)
    
    -- Create table with 5 columns: Ship ID, Pilot, Current Name, EditBox/Rename, Set/Cancel
    local renamingTable = frame:addTable(5, { 
        tabOrder = 2, 
        reserveScrollBar = false,  -- Disable for now - causes column width issues
        width = Helper.standardTextWidth * 4,
        y = yOffset,
        maxVisibleHeight = Helper.viewHeight
    })
    renamingTable:setDefaultCellProperties("text", { minRowHeight = gtMenu.rowHeight, fontsize = gtMenu.fontSize })
    
    -- Set column widths (percentages add up to 100%)
    renamingTable:setColWidthPercent(1, 10)  -- Ship ID
    renamingTable:setColWidthPercent(2, 16)  -- Pilot
    renamingTable:setColWidthPercent(3, 30)  -- Current Custom Name (text display)
    renamingTable:setColWidthPercent(4, 30)  -- EditBox or Rename button
    renamingTable:setColWidthPercent(5, 14)  -- Set/Cancel buttons
    
    -- Header row
    local headerRow = renamingTable:addRow(false, { bgColor = Color["row_title_background"], fixed = true })
    headerRow[1]:createText(ReadText(77000, 8100), { halign = "center" })  -- Ship ID
    headerRow[2]:createText(ReadText(77000, 8101), { halign = "center" })  -- Pilot
    headerRow[3]:createText(ReadText(77000, 8321), { halign = "center" })  -- Custom Name
    headerRow[4]:createText("New Name", { halign = "center" })  -- EditBox/Rename
    headerRow[5]:createText(ReadText(77000, 8456), { halign = "center" })  -- Actions
    
    -- Check if we have any pilots
    if #pilots == 0 then
        local emptyRow = renamingTable:addRow(nil, {})
        emptyRow[1]:setColSpan(5):createText(ReadText(77000, 8600), { halign = "center" })
        local emptyRow2 = renamingTable:addRow(nil, {})
        emptyRow2[1]:setColSpan(5):createText(ReadText(77000, 8601), { halign = "center", fontsize = Helper.standardFontSize * 0.8 })
        return
    end
    
    -- FIX: Limit rows to prevent X4's 50 shield/hull bar limit from being exceeded
    local maxRows = 50
    local pilotsToDisplay = pilots
    if #pilots > maxRows then
        pilotsToDisplay = {}
        for i = 1, maxRows do
            pilotsToDisplay[i] = pilots[i]
        end
        DebugError(string.format("[GT Menu] Limiting renaming display to %d rows (out of %d total) to prevent shield/hull bar limit", maxRows, #pilots))
    end
    
    -- Add pilot rows - interactive to allow editbox and buttons
    local selectedRowIndex = nil
    for i, pilot in ipairs(pilotsToDisplay) do
        -- Track which row should be selected
        if pilot.shipId == gtMenu.selectedShipId then
            selectedRowIndex = i
        end
        
        -- Highlight selected row
        local isSelected = (pilot.shipId == gtMenu.selectedShipId)
        local cellBgColor = isSelected and Color["row_background_selected"] or nil
        
        local row = renamingTable:addRow(false, { interactive = true })
        
        -- Ship ID
        row[1]:createText(pilot.shipId or "???", { cellBGColor = cellBgColor })
        
        -- Pilot Name
        row[2]:createText(pilot.pilotName or "Unknown", { cellBGColor = cellBgColor })
        
        -- Current Custom Name (text display)
        local currentName = pilot.customName or "(not set)"
        local nameColor = pilot.customName and nil or Color["text_inactive"]
        row[3]:createText(currentName, { cellBGColor = cellBgColor, color = nameColor })
        
        -- Column 4 & 5 - show editbox+buttons if editing, otherwise show Rename button
        local isEditing = (gtMenu.renamingShipId == pilot.shipId)
        
        if isEditing then
            -- Show editbox for entering new name
            local editBox = row[4]:createEditBox({ 
                height = gtMenu.rowHeight
            })
            editBox:setText(pilot.customName or "")
            
            -- Set button to save the new name
            local setBtn = row[5]:createButton({ 
                height = gtMenu.rowHeight,
                bgColor = Color["button_background_default"]
            })
            setBtn:setText("Set", { halign = "center", fontsize = gtMenu.fontSize * 0.8 })
            row[5].handlers.onClick = function()
                local newName = GetEditBoxText(row[4].id)
                DebugError(string.format("[GT Renaming] Set name for %s: '%s'", pilot.shipId, tostring(newName)))
                
                -- TODO: Send to MD to store custom name
                if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotControl then
                    DebugError("[GT Renaming] Would set custom name: " .. tostring(newName))
                end
                
                -- Clear editing state and refresh
                gtMenu.renamingShipId = nil
                menu.refreshInfoFrame()
                return true
            end
        else
            -- Show Rename button in column 4, empty column 5
            local renameBtn = row[4]:createButton({ 
                height = gtMenu.rowHeight,
                bgColor = Color["button_background_default"]
            })
            renameBtn:setText("Rename", { halign = "center", fontsize = gtMenu.fontSize * 0.8 })
            row[4].handlers.onClick = function()
                -- DebugError("[GT Renaming] Rename button clicked for " .. pilot.shipId)
                gtMenu.renamingShipId = pilot.shipId
                menu.refreshInfoFrame()  -- Refresh to show editbox
                return true
            end
            
            -- Cancel button in column 5 (only shown when editing)
            row[5]:createText("", { cellBGColor = cellBgColor })
        end
    end
    
    -- Restore selection in X4 table system (preserves selection across refreshes/tab switches)
    if selectedRowIndex then
        renamingTable:setSelectedRow(selectedRowIndex)
        -- DebugError(string.format("[GT Menu] Renaming tab: Restored selection to row %d", selectedRowIndex))
    end
    
    -- Footer row
    local footerRow = renamingTable:addRow(nil, { bgColor = Color["row_title_background"] })
    if #pilots > maxRows then
        footerRow[1]:setColSpan(5):createText(string.format("%s %d (Showing: %d)", ReadText(77000, 8402), #pilots, maxRows), { halign = "center" })
    else
        footerRow[1]:setColSpan(5):createText(string.format("%s %d", ReadText(77000, 8402), #pilots), { halign = "center" })
    end
end

-- Display pilot control panel
function gtMenu.displayPilotControl(frame, instance, yOffset)
    DebugError(string.format("[GT Menu] displayPilotControl called (yOffset=%s)", tostring(yOffset)))
    
    -- Validate parameters
    if not frame then
        DebugError("[GT Menu] ERROR: frame is nil!")
        return
    end
    
    -- Ensure yOffset is a valid number
    yOffset = tonumber(yOffset) or 0
    
    -- Fetch pilot data and settings
    local pilots = gtMenu.getPilotData()
    gtMenu.sortPilots(pilots)
    
    -- Get settings from data bridge with safe access
    local settings = {
        autoTraining = true,
        autoRepair = true,
        autoResupply = true
    }
    
    local bridgeAvailable = Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData
    if bridgeAvailable and Mods.GalaxyTrader.PilotData.settings then
        DebugError("[GT Menu] Reading settings from bridge")
        settings.autoTraining = Mods.GalaxyTrader.PilotData.settings.autoTraining
        settings.autoRepair = Mods.GalaxyTrader.PilotData.settings.autoRepair
        settings.autoResupply = Mods.GalaxyTrader.PilotData.settings.autoResupply
    else
        DebugError("[GT Menu] WARNING: Bridge settings not available, using defaults")
    end
    
    DebugError(string.format("[GT Menu] Settings: AutoTraining=%s, AutoRepair=%s, AutoResupply=%s",
        tostring(settings.autoTraining), tostring(settings.autoRepair), tostring(settings.autoResupply)))
    
    -- Count how many action buttons to show (based on settings)
    local actionCount = 0
    if not settings.autoTraining then actionCount = actionCount + 1 end  -- Show training button if auto-training is OFF
    if not settings.autoRepair then actionCount = actionCount + 1 end    -- Show repair button if auto-repair is OFF
    actionCount = actionCount + 2  -- Always show: Force Sell Cargo + Deregister
    
    DebugError(string.format("[GT Menu] Action buttons to display: %d", actionCount))
    
    -- Calculate column count: 5 info columns + actionCount action columns
    local columnCount = 5 + actionCount
    
    -- Safety check
    if columnCount < 6 then
        DebugError("[GT Menu] ERROR: Column count too low: " .. columnCount)
        columnCount = 7  -- Minimum: 5 info + 2 actions
    end
    
    DebugError(string.format("[GT Menu] Creating table with %d columns", columnCount))
    
    -- Create table with dynamic column count
    -- Position below tabs if yOffset is provided
    local controlTable = frame:addTable(columnCount, { 
        tabOrder = 2, 
        reserveScrollBar = false,  -- Disable for now - causes column width issues
        width = Helper.standardTextWidth * 4,
        y = yOffset or 0,
        maxVisibleHeight = Helper.viewHeight
    })
    controlTable:setDefaultCellProperties("text", { minRowHeight = gtMenu.rowHeight, fontsize = gtMenu.fontSize })
    
    -- Set column widths (percentages add up to 100%)
    -- Info columns take 60%, action columns share remaining 40%
    local infoColumnTotal = 60
    local actionColumnTotal = 40
    local perActionColumn = actionColumnTotal / math.max(actionCount, 1)  -- Prevent division by zero
    
    DebugError(string.format("[GT Menu] Column width per action: %.2f%%", perActionColumn))
    
    controlTable:setColWidthPercent(1, 10)  -- Ship ID
    controlTable:setColWidthPercent(2, 15)  -- Pilot
    controlTable:setColWidthPercent(3, 15)  -- Ship
    controlTable:setColWidthPercent(4, 12)  -- Status
    controlTable:setColWidthPercent(5, 8)   -- Rank
    
    -- Set action column widths dynamically
    for i = 1, actionCount do
        local colIndex = 5 + i
        controlTable:setColWidthPercent(colIndex, perActionColumn)
        DebugError(string.format("[GT Menu] Set column %d width to %.2f%%", colIndex, perActionColumn))
    end
    
    -- Header row
    local headerRow = controlTable:addRow(false, { bgColor = Color["row_title_background"], fixed = true })
    headerRow[1]:createText(ReadText(77000, 8100), { halign = "center" })  -- Ship ID
    headerRow[2]:createText(ReadText(77000, 8101), { halign = "center" })  -- Pilot
    headerRow[3]:createText(ReadText(77000, 8102), { halign = "center" })  -- Ship
    headerRow[4]:createText(ReadText(77000, 8103), { halign = "center" })  -- Status
    headerRow[5]:createText(ReadText(77000, 8104), { halign = "center" })  -- Rank
    headerRow[6]:setColSpan(actionCount):createText(ReadText(77000, 8456), { halign = "center" })  -- Actions
    
    -- Check if we have any pilots
    if #pilots == 0 then
        local emptyRow = controlTable:addRow(nil, {})
        emptyRow[1]:setColSpan(columnCount):createText(ReadText(77000, 8600), { halign = "center" })
        local emptyRow2 = controlTable:addRow(nil, {})
        emptyRow2[1]:setColSpan(columnCount):createText(ReadText(77000, 8601), { halign = "center", fontsize = Helper.standardFontSize * 0.8 })
        return
    end
    
    -- FIX: Limit rows to prevent X4's 50 shield/hull bar limit from being exceeded
    local maxRows = 50
    local pilotsToDisplay = pilots
    if #pilots > maxRows then
        pilotsToDisplay = {}
        for i = 1, maxRows do
            pilotsToDisplay[i] = pilots[i]
        end
        DebugError(string.format("[GT Menu] Limiting control display to %d rows (out of %d total) to prevent shield/hull bar limit", maxRows, #pilots))
    end
    
    -- Add pilot rows - interactive rows allow buttons.
    for i, pilot in ipairs(pilotsToDisplay) do
        -- Highlight selected row
        local isSelected = (pilot.shipId == gtMenu.selectedShipId)
        local cellBgColor = isSelected and Color["row_background_selected"] or nil
        
        -- Use interactive = true to allow buttons in the row (non-selectable row to avoid rowgroup issues).
        local row = controlTable:addRow(false, { interactive = true })
        
        -- Info columns
        row[1]:createText(pilot.shipId or "???", { cellBGColor = cellBgColor })
        row[2]:createText(pilot.pilotName or "Unknown", { cellBGColor = cellBgColor })
        row[3]:createText(pilot.shipType or "Unknown Ship", { cellBGColor = cellBgColor })
        row[4]:createText(pilot.status or "[UNKNOWN]", { cellBGColor = cellBgColor })
        row[5]:createText(pilot.rank or "Apprentice", { cellBGColor = cellBgColor })
        
        -- Action buttons - added dynamically based on settings
        local currentCol = 6
        
        -- Training button (only if automatic training is disabled)
        if not settings.autoTraining then
            if pilot.trainingBlocked then
                local trainingBtn = row[currentCol]:createButton({ 
                    height = gtMenu.rowHeight, 
                    bgColor = Color["button_background_default"] 
                })
                trainingBtn:setText(ReadText(77000, 8450), { halign = "center", fontsize = gtMenu.fontSize * 0.8 })
                row[currentCol].handlers.onClick = function()
                    -- DebugError("[GT Control] Training button clicked for pilot: " .. pilot.pilotName .. " (Ship: " .. pilot.shipId .. ")")
                    if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotControl and Mods.GalaxyTrader.PilotControl.sendToTraining then
                        Mods.GalaxyTrader.PilotControl.sendToTraining(pilot.shipId)
                    else
                        DebugError("[GT Control] ERROR: PilotControl bridge not available!")
                    end
                    return true
                end
            else
                row[currentCol]:createText("-", { halign = "center", cellBGColor = cellBgColor, color = Color["text_inactive"] })
            end
            currentCol = currentCol + 1
        end
        
        -- Repair button (only if automatic repair is disabled)
        if not settings.autoRepair then
            local repairBtn = row[currentCol]:createButton({ 
                height = gtMenu.rowHeight, 
                bgColor = Color["button_background_default"] 
            })
            repairBtn:setText(ReadText(77000, 8453), { halign = "center", fontsize = gtMenu.fontSize * 0.8 })
            row[currentCol].handlers.onClick = function()
                -- DebugError("[GT Control] Repair button clicked for pilot: " .. pilot.pilotName .. " (Ship: " .. pilot.shipId .. ")")
                if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotControl and Mods.GalaxyTrader.PilotControl.sendToRepair then
                    Mods.GalaxyTrader.PilotControl.sendToRepair(pilot.shipId)
                else
                    DebugError("[GT Control] ERROR: PilotControl bridge not available!")
                end
                return true
            end
            currentCol = currentCol + 1
        end
        
        -- Force Sell Cargo button (always shown)
        local sellCargoBtn = row[currentCol]:createButton({ 
            height = gtMenu.rowHeight, 
            bgColor = Color["button_background_default"] 
        })
        sellCargoBtn:setText(ReadText(77000, 8452), { halign = "center", fontsize = gtMenu.fontSize * 0.8 })
        row[currentCol].handlers.onClick = function()
            -- DebugError("[GT Control] Force Sell Cargo button clicked for pilot: " .. pilot.pilotName .. " (Ship: " .. pilot.shipId .. ")")
            if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotControl and Mods.GalaxyTrader.PilotControl.forceSellCargo then
                Mods.GalaxyTrader.PilotControl.forceSellCargo(pilot.shipId)
            else
                DebugError("[GT Control] ERROR: PilotControl bridge not available!")
            end
            return true
        end
        currentCol = currentCol + 1
        
        -- Deregister button (always shown) - use red color to indicate danger
        local deregisterBtn = row[currentCol]:createButton({ 
            height = gtMenu.rowHeight, 
            bgColor = Color["button_background_default"]
        })
        deregisterBtn:setText(ReadText(77000, 8451), { halign = "center", fontsize = gtMenu.fontSize * 0.8, color = Color["text_warning"] })
        row[currentCol].handlers.onClick = function()
            -- DebugError("[GT Control] Deregister button clicked for pilot: " .. pilot.pilotName .. " (Ship: " .. pilot.shipId .. ")")
            if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotControl and Mods.GalaxyTrader.PilotControl.deregisterShip then
                Mods.GalaxyTrader.PilotControl.deregisterShip(pilot.shipId)
            else
                DebugError("[GT Control] ERROR: PilotControl bridge not available!")
            end
            return true
        end
    end
    
    -- Footer row with totals
    local footerRow = controlTable:addRow(nil, { bgColor = Color["row_title_background"] })
    if #pilots > maxRows then
        footerRow[1]:setColSpan(columnCount):createText(string.format("%s %d (Showing: %d)", ReadText(77000, 8402), #pilots, maxRows), { halign = "center" })
    else
        footerRow[1]:setColSpan(columnCount):createText(string.format("%s %d", ReadText(77000, 8402), #pilots), { halign = "center" })
    end
end

-- Initialize and register callbacks
local function init()
    DebugError("GalaxyTrader MK3 Info Menu - Phase 1: Basic Display with Sorting")
    
    menu = Helper.getMenu("MapMenu")
    if menu then
        menu.registerCallback("createSideBar_on_start", gtMenu.createSideBar)
        menu.registerCallback("createInfoFrame_on_menu_infoTableMode", gtMenu.createInfoFrame)
    end
    
    -- Export to global scope for pilot data bridge to trigger refreshes
    if not Mods then Mods = {} end
    if not Mods.GalaxyTrader then Mods.GalaxyTrader = {} end
    Mods.GalaxyTrader.InfoMenu = gtMenu
end

-- Start initialization
init()
