-- GalaxyTrader - Crew Name Highlight Override
--
-- Colors crew list names in MapMenu when the person belongs to GT pilot registry.
-- Matching: PilotIdMap keys only — seed / StableIdentity / idcode, plus int64 aliases from gt_pilot_data_bridge (NPCSeed uint64).
-- This is UI-only and does not modify vanilla/MD name fields.

local DEBUG_RECOLOR = false
local REFRESH_THROTTLE_SECONDS = 2
local MISS_DIAG_THROTTLE_SECONDS = 6
local lastRefreshRequestTime = -1000
local lastMissDiagTime = -1000
local recolorPassCounter = 0
local missingMenuLogged = false

local function resolveMapMenu()
    if Helper and Helper.getMenu then
        local m = Helper.getMenu("MapMenu")
        if m then
            return m
        end
    end
    if Menus then
        return Menus["MapMenu"]
    end
    return nil
end

local function logRecolor(message)
    if DEBUG_RECOLOR then
        DebugError("[GT Crew Highlight] " .. tostring(message))
    end
end

local function getGTPilotIdMap()
    if Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData and Mods.GalaxyTrader.PilotData.getGTPilotIdMap then
        return Mods.GalaxyTrader.PilotData.getGTPilotIdMap()
    end
    return {}
end

local function isCrewHighlightEnabledBySettings()
    local bridge = Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData
    if not bridge or not bridge.settings then
        return false
    end
    return bridge.settings.pilotRenamingEnabled == true
end

local function getPersonIdCode(person)
    -- personentry.person in MapMenu is an NPCSeed, not a component.
    -- Calling GetComponentData(person, "idcode") causes runtime errors.
    return nil
end

local function getPersonRefKey(person)
    if not person then
        return nil
    end
    local ref = tostring(person)
    if ref == "" or ref == "0" then
        return nil
    end
    return ref
end

local function normalizeUniquePilotKey(key)
    if not key then
        return nil
    end
    local s = tostring(key)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("[Uu][Ll][Ll]$", "")
    s = s:gsub("[Ll][Ll]$", "")
    s = s:gsub("[Uu][Ll]$", "")
    s = s:gsub("[Uu]$", "")
    if s == "" or s == "0" then
        return nil
    end
    return s
end

local function requestGTRefreshIfNeeded(reason)
    if not (Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData and Mods.GalaxyTrader.PilotData.requestRefresh) then
        return
    end

    local now = getElapsedTime()
    if (now - lastRefreshRequestTime) >= REFRESH_THROTTLE_SECONDS then
        lastRefreshRequestTime = now
        Mods.GalaxyTrader.PilotData.requestRefresh()
        logRecolor("requested pilot refresh: reason=" .. tostring(reason))
    end
end

local function installCrewHighlightHook()
    local menu = resolveMapMenu()
    if not menu then
        if not missingMenuLogged then
            missingMenuLogged = true
            DebugError("[GT Crew Highlight] MapMenu not found - deferring crew highlight hook")
        end
        return
    end
    missingMenuLogged = false

    if menu.__gtCrewHighlightHookInstalled
        and menu.__gtCrewHighlightWrappedCombine
        and menu.infoSubmenuCombineCrewTables ~= menu.__gtCrewHighlightWrappedCombine then
        -- Another script / reload replaced the function after we hooked it.
        menu.__gtCrewHighlightHookInstalled = nil
        menu.__gtCrewHighlightWrappedCombine = nil
        DebugError("[GT Crew Highlight] Detected combine hook replacement - reinstalling")
    end

    if menu.__gtCrewHighlightHookInstalled then
        return
    end

    local orig_infoSubmenuCombineCrewTables = menu.infoSubmenuCombineCrewTables
    if type(orig_infoSubmenuCombineCrewTables) ~= "function" then
        DebugError("[GT Crew Highlight] infoSubmenuCombineCrewTables not found - deferring crew highlight hook")
        return
    end

    local wrappedCombine = function(instance)
        local result = orig_infoSubmenuCombineCrewTables(instance)
        if type(result) ~= "table" then
            return result
        end

        -- Keep GT pilot-id cache fresh while crew menu is open (newly swapped pilots).
        requestGTRefreshIfNeeded("periodic_refresh")

        -- Strict behavior: crew highlight is enabled only when pilot renaming is enabled in GT settings.
        if not isCrewHighlightEnabledBySettings() then
            return result
        end

        local gtPilotIdMap = getGTPilotIdMap()
        recolorPassCounter = recolorPassCounter + 1
        local passId = recolorPassCounter

        if not next(gtPilotIdMap) then
            DebugError("[GT Crew Highlight] pass=" .. tostring(passId) .. " skip: GT pilot-id map empty")
            requestGTRefreshIfNeeded("empty_pilot_id_map")
            return result
        end

        local checked = 0
        local matched = 0
        local missingPersonRef = 0
        local missingPilotId = 0
        local noMapEntry = 0
        local missingTaggedName = 0
        local missDiagDone = false

        local bridge = Mods and Mods.GalaxyTrader and Mods.GalaxyTrader.PilotData
        local lookupTagged = bridge and bridge.lookupPilotIdMapTaggedName
        local diagnoseMiss = bridge and bridge.diagnosePilotIdMapMiss

        for _, personentry in ipairs(result) do
            checked = checked + 1

            local personRef = personentry and personentry.person
            if not personRef then
                missingPersonRef = missingPersonRef + 1
                logRecolor("pass=" .. tostring(passId) .. " row=" .. tostring(checked) .. " missing person reference; uiName='" .. tostring(personentry and personentry.name) .. "'")
            else
                local pilotId = getPersonIdCode(personRef)
                local personRefKey = getPersonRefKey(personRef)
                local personRefKeyNormalized = normalizeUniquePilotKey(personRefKey)
                local taggedName = nil
                local matchedKey = nil

                if pilotId and gtPilotIdMap[pilotId] and gtPilotIdMap[pilotId] ~= "" then
                    taggedName = gtPilotIdMap[pilotId]
                    matchedKey = pilotId
                elseif lookupTagged then
                    taggedName, matchedKey = lookupTagged(gtPilotIdMap, personRef)
                elseif personRefKey and gtPilotIdMap[personRefKey] and gtPilotIdMap[personRefKey] ~= "" then
                    -- Legacy fallback path if bridge helper is unavailable.
                    taggedName = gtPilotIdMap[personRefKey]
                    matchedKey = personRefKey
                elseif personRefKeyNormalized and gtPilotIdMap[personRefKeyNormalized] and gtPilotIdMap[personRefKeyNormalized] ~= "" then
                    taggedName = gtPilotIdMap[personRefKeyNormalized]
                    matchedKey = personRefKeyNormalized
                end

                if taggedName and taggedName ~= "" then
                    personentry.name = ColorText["text_positive"] .. taggedName .. "\27X"
                    matched = matched + 1
                    logRecolor(
                        "pass=" .. tostring(passId) ..
                        " row=" .. tostring(checked) ..
                        " match key=" .. tostring(matchedKey) ..
                        " idcode=" .. tostring(pilotId) ..
                        " personRef=" .. tostring(personRefKey) ..
                        " personRefNormalized=" .. tostring(personRefKeyNormalized) ..
                        " tagged='" .. tostring(taggedName) .. "'"
                    )
                elseif (not pilotId) and (not personRefKey) then
                    missingPilotId = missingPilotId + 1
                    logRecolor("pass=" .. tostring(passId) .. " row=" .. tostring(checked) .. " no idcode for person=" .. tostring(personRef) .. " uiName='" .. tostring(personentry and personentry.name) .. "'")
                else
                    if pilotId and gtPilotIdMap[pilotId] ~= nil and gtPilotIdMap[pilotId] == "" then
                        missingTaggedName = missingTaggedName + 1
                        DebugError("[GT Crew Highlight] pass=" .. tostring(passId) .. " row=" .. tostring(checked) .. " idcode key in map but tagged name empty: " .. tostring(pilotId))
                    elseif personRefKey and gtPilotIdMap[personRefKey] ~= nil and gtPilotIdMap[personRefKey] == "" then
                        missingTaggedName = missingTaggedName + 1
                        DebugError("[GT Crew Highlight] pass=" .. tostring(passId) .. " row=" .. tostring(checked) .. " personRef key in map but tagged name empty: " .. tostring(personRefKey))
                    elseif personRefKeyNormalized and gtPilotIdMap[personRefKeyNormalized] ~= nil and gtPilotIdMap[personRefKeyNormalized] == "" then
                        missingTaggedName = missingTaggedName + 1
                        DebugError("[GT Crew Highlight] pass=" .. tostring(passId) .. " row=" .. tostring(checked) .. " normalized personRef key in map but tagged name empty: " .. tostring(personRefKeyNormalized))
                    else
                        noMapEntry = noMapEntry + 1
                        logRecolor(
                            "pass=" .. tostring(passId) ..
                            " row=" .. tostring(checked) ..
                            " no map entry idcode=" .. tostring(pilotId) ..
                            " personRef=" .. tostring(personRefKey) ..
                            " personRefNormalized=" .. tostring(personRefKeyNormalized) ..
                            " uiName='" .. tostring(personentry and personentry.name) .. "'"
                        )
                        local now = getElapsedTime()
                        if (not missDiagDone) and diagnoseMiss and ((now - lastMissDiagTime) >= MISS_DIAG_THROTTLE_SECONDS) then
                            missDiagDone = true
                            lastMissDiagTime = now
                            diagnoseMiss(
                                gtPilotIdMap,
                                personRef,
                                "crew row=" .. tostring(checked) .. " uiName=" .. tostring(personentry and personentry.name)
                            )
                        end
                    end
                end
            end
        end

        DebugError(
            "[GT Crew Highlight] pass=" .. tostring(passId) ..
            " complete checked=" .. tostring(checked) ..
            " matched=" .. tostring(matched) ..
            " missingPersonRef=" .. tostring(missingPersonRef) ..
            " missingPilotId=" .. tostring(missingPilotId) ..
            " noMapEntry=" .. tostring(noMapEntry) ..
            " missingTaggedName=" .. tostring(missingTaggedName) ..
            " mapSizeKnown=" .. tostring(next(gtPilotIdMap) ~= nil)
        )

        if matched == 0 and checked > 0 then
            DebugError("[GT Crew Highlight] pass=" .. tostring(passId) .. " WARNING: zero matches in crew table; requesting refresh for diagnostics")
            requestGTRefreshIfNeeded("zero_matches")
        end

        return result
    end
    menu.infoSubmenuCombineCrewTables = wrappedCombine

    menu.__gtCrewHighlightHookInstalled = true
    menu.__gtCrewHighlightWrappedCombine = wrappedCombine
    DebugError("[GT Crew Highlight] MapMenu crew name highlight hook installed (strict pilot-id mode)")
end

local function installCrewHighlightUpdateGuard()
    local menu = resolveMapMenu()
    if not menu then
        return
    end
    if menu.__gtCrewHighlightUpdateGuardInstalled then
        return
    end
    if type(menu.update) ~= "function" then
        return
    end

    local originalUpdate = menu.update
    menu.update = function(...)
        installCrewHighlightHook()
        return originalUpdate(...)
    end
    menu.__gtCrewHighlightUpdateGuardInstalled = true
    DebugError("[GT Crew Highlight] MapMenu update guard installed")
end

installCrewHighlightHook()
installCrewHighlightUpdateGuard()

if RegisterEvent then
    RegisterEvent("showMapMenu", function()
        installCrewHighlightHook()
        installCrewHighlightUpdateGuard()
    end)
    RegisterEvent("GT_PilotIdMap.Update", function()
        installCrewHighlightHook()
        installCrewHighlightUpdateGuard()
    end)
end
