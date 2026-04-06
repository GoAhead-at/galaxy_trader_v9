-- Personal Management display-name override for GT pilots.
-- Uses the same identity-only PilotIdMap lookup as crew highlighting.

local MENU_NAME = "PlayerInfoMenu"

local function resolveMenu()
    if Helper and Helper.getMenu then
        local menu = Helper.getMenu(MENU_NAME)
        if menu then
            return menu
        end
    end
    if Menus then
        return Menus[MENU_NAME]
    end
    return nil
end

local function getPilotData()
    return Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData
end

local function lookupTaggedName(personRef)
    local pilotData = getPilotData()
    if not pilotData or not pilotData.getGTPilotIdMap or not pilotData.lookupPilotIdMapTaggedName then
        return nil
    end

    local idMap = pilotData.getGTPilotIdMap()
    if not idMap then
        return nil
    end

    local tagged = pilotData.lookupPilotIdMapTaggedName(idMap, personRef)
    if tagged and tagged ~= "" then
        return tagged
    end

    -- Some UI ids stringify as "ID: <number>" in this menu.
    local raw = tostring(personRef)
    local extracted = string.match(raw, "ID:%s*(%d+)")
    if extracted then
        tagged = pilotData.lookupPilotIdMapTaggedName(idMap, extracted)
        if tagged and tagged ~= "" then
            return tagged
        end
    end

    return nil
end

local function applyPersonnelTaggedNames(menu)
    if not menu or not menu.empireData or not menu.empireData.employees then
        return
    end

    for _, employee in ipairs(menu.empireData.employees) do
        if employee and employee.type == "person" and employee.id then
            local tagged = lookupTaggedName(employee.id)
            if tagged then
                employee.name = tagged
            end
        end
    end

    if menu.empireData.filteredemployees then
        for _, employee in ipairs(menu.empireData.filteredemployees) do
            if employee and employee.type == "person" and employee.id then
                local tagged = lookupTaggedName(employee.id)
                if tagged then
                    employee.name = tagged
                end
            end
        end
    end

    if menu.personnelData and menu.personnelData.curEntry and menu.personnelData.curEntry.type == "person" and menu.personnelData.curEntry.id then
        local tagged = lookupTaggedName(menu.personnelData.curEntry.id)
        if tagged then
            menu.personnelData.curEntry.name = tagged
        end
    end
end

local function install()
    local menu = resolveMenu()
    if not menu or menu.__gtPersonnelNameOverrideInstalled then
        return
    end

    if type(menu.getEmployeeList) == "function" then
        local original = menu.getEmployeeList
        menu.getEmployeeList = function(...)
            local result = original(...)
            applyPersonnelTaggedNames(menu)
            return result
        end
    end

    if type(menu.refreshInfoFrame) == "function" then
        local originalRefresh = menu.refreshInfoFrame
        menu.refreshInfoFrame = function(...)
            applyPersonnelTaggedNames(menu)
            return originalRefresh(...)
        end
    end

    menu.__gtPersonnelNameOverrideInstalled = true
    DebugError("[GT Personnel Name Override] PlayerInfoMenu hook installed")
end

install()

if RegisterEvent then
    RegisterEvent("show" .. MENU_NAME, function()
        install()
    end)
    RegisterEvent("GT_PilotIdMap.Update", function()
        local menu = resolveMenu()
        if not menu then
            return
        end
        install()
        applyPersonnelTaggedNames(menu)
    end)
end

