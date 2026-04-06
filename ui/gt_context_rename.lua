-- GalaxyTrader Context Menu Rename
-- Adds "GT Rename" context menu entry to ship overview in map menu

-- FFI setup
local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef struct {
        int x;
        int y;
    } Coord2D;
    const char* GetComponentName(UniverseID componentid);
    bool IsComponentClass(UniverseID componentid, const char* classname);
    Coord2D GetCenteredMousePos(void);
]]

local menu = Helper.getMenu("MapMenu")
if not menu then
    DebugError("[GT Context Rename] MapMenu not found - context menu rename will not be available")
    return
end

-- Store original functions
local originalCreateContextFrame = menu.createContextFrame
local originalRefreshContextFrame = menu.refreshContextFrame
local originalUpdate = menu.update
local originalButtonRenameConfirm = menu.buttonRenameConfirm

-- GT Rename Context Menu Handler
local gtRenameContext = {}

-- Create rename context menu with edit box (following vanilla pattern)
function menu.createGTRenameContext(frame)
    -- Use fallback string directly to avoid ReadText lookup errors
    local title = "GT Rename"
    local component = menu.contextMenuData.component
    
    -- Get original name to display (only use GT original name from blackboard, no fallback)
    local startname = ""
    if menu.contextMenuData.originalName and menu.contextMenuData.originalName ~= "" then
        -- Use GT original name if provided (from NPCBlackboard)
        startname = menu.contextMenuData.originalName
    end
    -- If no GT original name, startname remains empty (let user enter new name)
    
    local shiptable = frame:addTable(2, { 
        tabOrder = 2, 
        x = Helper.borderSize, 
        y = Helper.borderSize, 
        width = menu.contextMenuData.width, 
        highlightMode = "off" 
    })
    
    -- Title row
    local row = shiptable:addRow(nil, { fixed = true })
    row[1]:setColSpan(2):createText(title, Helper.headerRowCenteredProperties)
    
    -- Edit box row - CRITICAL: Store reference in contextMenuData
    -- Use Helper.standardTextHeight directly (vanilla uses config.mapRowHeight which equals Helper.standardTextHeight)
    local row = shiptable:addRow(true, { fixed = true })
    menu.contextMenuData.nameEditBox = row[1]:setColSpan(2):createEditBox({ 
        height = Helper.scaleY(Helper.standardTextHeight), 
        description = title 
    }):setText(startname)
    
    -- Set up text change handler
    row[1].handlers.onTextChanged = function (_, text, textchanged) 
        menu.contextMenuData.newtext = text 
    end
    
    -- Set up deactivation handler (called when edit box loses focus or is confirmed)
    row[1].handlers.onEditBoxDeactivated = function (_, text, textchanged, isconfirmed) 
        return menu.buttonGTRenameConfirm(isconfirmed) 
    end
    
    -- Confirmation buttons
    local row = shiptable:addRow(true, { fixed = true })
    row[1]:createButton({}):setText(ReadText(1001, 2821), { halign = "center" })  -- "OK"
    row[1].handlers.onClick = function () return menu.buttonGTRenameConfirm(true) end
    
    row[2]:createButton({}):setText(ReadText(1001, 64), { halign = "center" })  -- "Cancel"
    row[2].handlers.onClick = function () return menu.closeContextMenu("back") end
    
    -- Adjust frame position if needed
    local neededheight = shiptable.properties.y + shiptable:getVisibleHeight()
    if frame.properties.y + neededheight + Helper.frameBorder > Helper.viewHeight then
        menu.contextMenuData.yoffset = Helper.viewHeight - neededheight - Helper.frameBorder
        frame.properties.y = menu.contextMenuData.yoffset
    end
end

-- Handle rename confirmation
function menu.buttonGTRenameConfirm(isconfirmed)
    if isconfirmed then
        local component = menu.contextMenuData.component
        local newname = menu.contextMenuData.newtext
        
        if component and newname and newname ~= "" then
            -- Get current name to check if it changed
            local currentName = ""
            local namePtr = C.GetComponentName(component)
            if namePtr and namePtr ~= 0 then
                currentName = ffi.string(namePtr)
            end
            
            if newname ~= currentName then
                -- Store rename data in NPCBlackboard for MD to read
                -- Store newName separately to avoid table access issues
                local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
                SetNPCBlackboard(playerId, "$GT_ContextRename_NewName", newname)

                -- Multi-rename support: apply same name to all selected ships.
                -- Non-GT ships are filtered on MD side (GT service guard).
                local targets = {}
                local seen = {}

                if menu.selectedcomponents then
                    for id, _ in pairs(menu.selectedcomponents) do
                        local selectedComponent = ConvertStringTo64Bit(tostring(id))
                        if selectedComponent and selectedComponent ~= 0 and C.IsComponentClass(selectedComponent, "ship") then
                            local key = tostring(selectedComponent)
                            if not seen[key] then
                                seen[key] = true
                                table.insert(targets, selectedComponent)
                            end
                        end
                    end
                end

                -- Fallback to single target if no multi-selection is present.
                if #targets == 0 and component and component ~= 0 then
                    table.insert(targets, component)
                end

                for _, targetComponent in ipairs(targets) do
                    SignalObject(playerId, "gt_context_rename_confirmed", ConvertStringToLuaID(tostring(targetComponent)))
                end
                DebugError(string.format("[GT Context Rename] Signaled MD for %d component(s), newName=%s", #targets, newname))
            end
        end
    end
    menu.noupdate = false
    if menu.refreshInfoFrame then
        menu.refreshInfoFrame()
    end
    menu.closeContextMenu("back")
    return true
end

-- Hook into createContextFrame to add support for "gt_rename" mode
-- Following vanilla pattern: createContextFrame creates frame, refreshContextFrame populates and displays
menu.createContextFrame = function(width, height, xoffset, yoffset, noborder, startanimation, ...)
    -- Check if we're creating our rename context
    if menu.contextMenuMode == "gt_rename" then
        -- Use same pattern as vanilla - create the frame handle immediately
        -- refreshContextFrame will populate it with content
        
        -- Set up data
        local mousepos = C.GetCenteredMousePos()
        menu.contextMenuData = menu.contextMenuData or {}
        menu.contextMenuData.xoffset = xoffset or (mousepos.x + Helper.viewWidth / 2)
        menu.contextMenuData.yoffset = yoffset or (mousepos.y + Helper.viewHeight / 2)
        menu.contextMenuData.width = width or Helper.scaleX(400)
        
        -- Adjust position if needed
        if menu.contextMenuData.xoffset + menu.contextMenuData.width > Helper.viewWidth then
            menu.contextMenuData.xoffset = Helper.viewWidth - menu.contextMenuData.width - Helper.frameBorder
        end
        
        -- CRITICAL: Create frame handle immediately (like vanilla does)
        -- Use standard contextFrameLayer (2) - context menus render on top regardless of layer
        local contextLayer = 2
        Helper.removeAllWidgetScripts(menu, contextLayer)
        
        menu.contextFrame = Helper.createFrameHandle(menu, {
            x = menu.contextMenuData.xoffset - (noborder and 0 or 2 * Helper.borderSize),
            y = menu.contextMenuData.yoffset,
            width = menu.contextMenuData.width + (noborder and 0 or 2 * Helper.borderSize),
            layer = contextLayer,
            standardButtons = { close = true },
            closeOnUnhandledClick = true,
            startAnimation = startanimation,
        })
        menu.contextFrame:setBackground("solid", { color = Color["frame_background_semitransparent"] })
        
        -- CRITICAL: Populate frame content immediately (like vanilla does)
        menu.createGTRenameContext(menu.contextFrame)
        
        -- Adjust frame height
        menu.contextFrame.properties.height = math.min(Helper.viewHeight - menu.contextFrame.properties.y, menu.contextFrame:getUsedHeight() + Helper.borderSize)
        
        return menu.contextFrame
    end
    
    -- Call original for other contexts
    if originalCreateContextFrame then
        return originalCreateContextFrame(width, height, xoffset, yoffset, noborder, startanimation, ...)
    end
end

-- Hook into refreshContextFrame to handle our rename mode AND add button to vanilla rename context
menu.refreshContextFrame = function(setrow, setcol, noborder, ...)
    -- Handle our rename mode BEFORE calling original (so we can override)
    if menu.contextMenuMode == "gt_rename" then
        -- CRITICAL: Remove widget scripts first (like vanilla does)
        local contextLayer = 2
        Helper.removeAllWidgetScripts(menu, contextLayer)
        
        -- Frame was already created and populated in createContextFrame
        -- refreshContextFrame just needs to display it (like vanilla does)
        if menu.contextFrame then
            menu.contextFrame:display()
        end
        return
    end
    
    -- Call original for other contexts
    if originalRefreshContextFrame then
        originalRefreshContextFrame(setrow, setcol, noborder, ...)
    end
    
    -- DO NOT add button to vanilla rename context - user wants to keep vanilla rename untouched
end

-- Hook into update to activate edit box after context menu is shown
menu.update = function(...)
    -- Call original update first
    if originalUpdate then
        originalUpdate(...)
    end
    
    -- Activate edit box if we have one pending (following vanilla pattern)
    if menu.contextMenuData and menu.contextMenuData.nameEditBox then
        ActivateEditBox(menu.contextMenuData.nameEditBox.id)
        menu.contextMenuData.nameEditBox = nil
    end
end

-- Function to open GT Rename context menu (can be called from anywhere)
function menu.openGTRenameContext(component, originalName)
    DebugError("[GT Context Rename] openGTRenameContext called")
    
    if not component then
        DebugError("[GT Context Rename] ERROR: No component provided")
        return
    end
    
    DebugError(string.format("[GT Context Rename] Component: %s", tostring(component)))
    
    local mousepos = C.GetCenteredMousePos()
    DebugError(string.format("[GT Context Rename] Mouse pos: x=%d, y=%d", mousepos.x, mousepos.y))
    
    menu.contextMenuMode = "gt_rename"
    menu.contextMenuData = { 
        component = component,
        originalName = originalName,  -- Store original name for display
        xoffset = mousepos.x + Helper.viewWidth / 2, 
        yoffset = mousepos.y + Helper.viewHeight / 2 
    }
    
    DebugError(string.format("[GT Context Rename] Context menu data: xoffset=%d, yoffset=%d", menu.contextMenuData.xoffset, menu.contextMenuData.yoffset))
    
    local width = Helper.scaleX(400)
    DebugError(string.format("[GT Context Rename] Width: %d", width))
    
    if menu.contextMenuData.xoffset + width > Helper.viewWidth then
        menu.contextMenuData.xoffset = Helper.viewWidth - width - Helper.frameBorder
        DebugError(string.format("[GT Context Rename] Adjusted xoffset: %d", menu.contextMenuData.xoffset))
    end
    
    DebugError("[GT Context Rename] Calling createContextFrame")
    menu.createContextFrame(width, nil, menu.contextMenuData.xoffset, menu.contextMenuData.yoffset)
    DebugError("[GT Context Rename] createContextFrame returned")
    
    DebugError("[GT Context Rename] Calling refreshContextFrame")
    menu.refreshContextFrame()
    DebugError("[GT Context Rename] refreshContextFrame returned")
end

-- DO NOT hook into createRenameContext - user wants to keep vanilla rename untouched

-- Register Lua event to handle MD script callback
RegisterEvent("gt.openRenameContext", function(_, component)
    DebugError("[GT Context Rename] Lua: Event gt.openRenameContext received")
    
    if component then
        local component64 = ConvertIDTo64Bit(component)
        DebugError(string.format("[GT Context Rename] Lua: Component converted: %s", tostring(component64)))
        
        if component64 and component64 ~= 0 then
            -- Get original name from NPCBlackboard (set by MD script)
            -- MD uses: player.entity.$GT_ContextRename_OriginalName
            -- Lua reads: GetNPCBlackboard(playerId, "$GT_ContextRename_OriginalName")
            local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
            local originalName = GetNPCBlackboard(playerId, "$GT_ContextRename_OriginalName")
            
            DebugError(string.format("[GT Context Rename] Lua: Original name from blackboard: %s", tostring(originalName)))
            
            menu.openGTRenameContext(component64, originalName)
        end
    end
end)

-- Hook into onInteractMenuCallback to handle our "gt_renamecontext" event
-- This follows the vanilla pattern for "renamecontext" 
local originalOnInteractMenuCallback = menu.onInteractMenuCallback
if originalOnInteractMenuCallback then
    menu.onInteractMenuCallback = function(type, param, ...)
        -- Handle our "gt_renamecontext" event (similar to vanilla "renamecontext")
        if type == "gt_renamecontext" then
            local mousepos = C.GetCenteredMousePos()
            menu.contextMenuMode = "gt_rename"
            menu.contextMenuData = { 
                component = param[1], 
                xoffset = mousepos.x + Helper.viewWidth / 2, 
                yoffset = mousepos.y + Helper.viewHeight / 2 
            }
            
            local width = Helper.scaleX(400)
            if menu.contextMenuData.xoffset + width > Helper.viewWidth then
                menu.contextMenuData.xoffset = Helper.viewWidth - width - Helper.frameBorder
            end
            
            menu.createContextFrame(width, nil, menu.contextMenuData.xoffset, menu.contextMenuData.yoffset)
            return
        end
        
        -- Call original for other events
        if originalOnInteractMenuCallback then
            return originalOnInteractMenuCallback(type, param, ...)
        end
    end
end

-- Hook into createRenameContext to add our "GT Rename" button to the vanilla rename context
-- This adds a button that opens our floating window instead of the vanilla rename dialog

DebugError("[GT Context Rename] Context menu rename integration loaded")
DebugError("[GT Context Rename] To use: Call menu.openGTRenameContext(component) to open rename dialog")
