-- GalaxyTrader Context Menu Promote
-- Promotes clicked subordinate to fleet commander only (no pilot swap/crew transfer UI).

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef struct {
        size_t queueidx;
        const char* state;
        const char* statename;
        const char* orderdef;
        size_t actualparams;
        bool enabled;
        bool isinfinite;
        bool issyncpointreached;
        bool istemporder;
    } Order;
    bool IsComponentClass(UniverseID componentid, const char* classname);
    bool IsOrderSelectableFor(const char* orderdefid, UniverseID controllableid);
    bool GetDefaultOrder(Order* result, UniverseID controllableid);
    const char* GetFleetName(UniverseID controllableid);
    float GetEntityCombinedSkill(UniverseID entityid, const char* roleid, const char* postid);
    uint32_t CreateOrder(UniverseID controllableid, const char* orderid, bool defaultorder);
    void EnableOrder(UniverseID controllableid, uint32_t idx);
    bool EnablePlannedDefaultOrder(UniverseID controllableid, bool checkonly);
    void ResetOrderLoop(UniverseID controllableid);
    bool AdjustOrder(UniverseID controllableid, uint32_t idx, uint32_t targetidx, bool begindragdrop, bool immediate, bool removecriticalorder);
    bool RemoveCommander2(UniverseID controllableid);
    void SetFleetName(UniverseID controllableid, const char* fleetname);
]]

local function asComponentId(entry)
    if not entry then
        return nil
    end
    if type(entry) == "table" and entry.component then
        return ConvertIDTo64Bit(entry.component)
    end
    return ConvertIDTo64Bit(entry)
end

local function normalizeAssignment(value)
    local s = value and tostring(value) or ""
    if s == "" or s == "null" then
        return "assist"
    end
    return s
end

local function normalizeGroup(value)
    local n = tonumber(value)
    if n == nil then
        return 0
    end
    return math.floor(n)
end

local function getDefaultOrderId(ship)
    if not ship or ship == 0 then
        return nil
    end
    local buf = ffi.new("Order")
    if C.GetDefaultOrder(buf, ship) and buf.orderdef then
        return ffi.string(buf.orderdef)
    end
    return nil
end

local pendingDefaultApplies = {}
local pendingOldCommanderReattach = {}
local pendingPromotionReassign = {}
local orderAssignCommander -- forward declaration (used by deferred onUpdate path)
local collectFleetSubordinatesRecursive -- forward declaration (used by onUpdate queue finalization)

local function buildDefaultOrderSnapshotFromShip(sourceShip)
    local ship = asComponentId(sourceShip)
    if not ship or ship == 0 then
        return nil
    end
    local orderId = getDefaultOrderId(ship)
    if not orderId then
        return nil
    end

    local params = {}
    local srcParams = GetOrderParams(ship, "default") or {}
    if #srcParams == 0 then
        srcParams = GetOrderParams(ship, "planneddefault") or {}
    end
    for i, param in ipairs(srcParams) do
        if param and param.value ~= nil then
            params[#params + 1] = {
                idx = i,
                name = param.name,
                value = param.value,
            }
        end
    end

    return {
        sourceShip = ship,
        orderId = orderId,
        params = params,
    }
end

-- Reusable default-order capture utility:
-- walks commander chain and snapshots the first available default order with all params.
local function capturePromotionDefaultOrder(startCommander)
    local visited = {}
    local current = startCommander

    for _ = 1, 12 do
        if not current or current == 0 then
            break
        end
        local key = tostring(current)
        if visited[key] then
            break
        end
        visited[key] = true

        local snapshot = buildDefaultOrderSnapshotFromShip(current)
        if snapshot and snapshot.orderId then
            return snapshot
        end

        if not C.IsComponentClass(current, "controllable") then
            break
        end
        local parent = GetCommander(current)
        parent = parent and ConvertIDTo64Bit(parent) or nil
        if not parent or parent == 0 or parent == current then
            break
        end
        current = parent
    end

    return nil
end

local function getPilotLevel(ship)
    local pilot = GetComponentData(ship, "assignedpilot")
    if not pilot or pilot == 0 then
        return nil
    end
    local pilotId = asComponentId(pilot)
    if not pilotId or pilotId == 0 then
        return nil
    end
    local ok, combined = pcall(C.GetEntityCombinedSkill, pilotId, nil, "aipilot")
    if not ok then
        return nil
    end
    local lvl = math.floor((tonumber(combined) or 0) * 15 / 100)
    if lvl < 1 then lvl = 1 end
    if lvl > 15 then lvl = 15 end
    return lvl
end

local function shipClassLabel(ship)
    if not ship or ship == 0 then
        return "UNK"
    end
    if C.IsComponentClass(ship, "ship_xl") then return "XL" end
    if C.IsComponentClass(ship, "ship_l") then return "L" end
    if C.IsComponentClass(ship, "ship_m") then return "M" end
    if C.IsComponentClass(ship, "ship_s") then return "S" end
    if C.IsComponentClass(ship, "ship_xs") then return "XS" end
    return "UNK"
end

local function formatComponentRef(value)
    local cid = asComponentId(value)
    if cid and cid ~= 0 then
        local code = GetComponentData(cid, "idcode") or "NOID"
        return tostring(code) .. " (" .. tostring(cid) .. ")"
    end
    return tostring(value)
end

local function formatParamValue(value)
    local t = type(value)
    if t == "table" then
        if value.component then
            return formatComponentRef(value.component)
        end
        if value.id then
            return tostring(value.id)
        end
        return "<table>"
    end
    if t == "cdata" then
        return formatComponentRef(value)
    end
    return tostring(value)
end

local function captureFleetName(ship)
    local sid = asComponentId(ship)
    if not sid or sid == 0 then
        return nil
    end
    local ok, raw = pcall(C.GetFleetName, sid)
    if ok and raw then
        local s = ffi.string(raw)
        if s and s ~= "" then
            return s
        end
    end
    local fallback = GetComponentData(sid, "fleetname")
    if fallback and tostring(fallback) ~= "" then
        return tostring(fallback)
    end
    return nil
end

local function applyFleetName(ship, fleetName)
    local sid = asComponentId(ship)
    if not sid or sid == 0 or not fleetName or fleetName == "" then
        return false
    end
    local ok = pcall(C.SetFleetName, sid, fleetName)
    if ok then
        DebugError(string.format(
            "[GT Promote] Fleet name reapplied ship=%s fleet=%s",
            formatComponentRef(sid),
            tostring(fleetName)
        ))
        return true
    end
    DebugError(string.format(
        "[GT Promote] Fleet name reapply failed ship=%s fleet=%s",
        formatComponentRef(sid),
        tostring(fleetName)
    ))
    return false
end

local function logDefaultOrderSnapshotDetailed(tag, snapshot)
    if not snapshot then
        DebugError(string.format("[GT Promote] SNAPSHOT[%s] default-order snapshot: <nil>", tostring(tag)))
        return
    end
    DebugError(string.format(
        "[GT Promote] SNAPSHOT[%s] default-order source=%s order=%s params=%d",
        tostring(tag),
        formatComponentRef(snapshot.sourceShip),
        tostring(snapshot.orderId),
        #(snapshot.params or {})
    ))
    for _, entry in ipairs(snapshot.params or {}) do
        if entry then
            DebugError(string.format(
                "[GT Promote] SNAPSHOT[%s] default-order param idx=%s name=%s value=%s",
                tostring(tag),
                tostring(entry.idx),
                tostring(entry.name),
                formatParamValue(entry.value)
            ))
        end
    end
end

local function logFleetSnapshot(label, rootCommander)
    local root = asComponentId(rootCommander)
    if not root or root == 0 then
        DebugError(string.format("[GT Promote] SNAPSHOT[%s] root invalid: %s", tostring(label), tostring(rootCommander)))
        return
    end

    local visited = {}
    local queue = { root }
    local qhead = 1
    local count = 0
    DebugError(string.format("[GT Promote] SNAPSHOT[%s] begin root=%s", tostring(label), formatComponentRef(root)))

    while qhead <= #queue do
        local ship = asComponentId(queue[qhead])
        qhead = qhead + 1
        if ship and ship ~= 0 and not visited[tostring(ship)] then
            visited[tostring(ship)] = true
            count = count + 1

            local idcode, name, assignment, group, pilot = GetComponentData(ship, "idcode", "name", "assignment", "subordinategroup", "assignedpilot")
            local commander = GetCommander(ship)
            commander = commander and ConvertIDTo64Bit(commander) or nil
            local commanderCode = commander and GetComponentData(commander, "idcode") or "NONE"
            local orderId = getDefaultOrderId(ship) or "NONE"
            local subs = GetSubordinates(ship) or {}
            local level = getPilotLevel(ship)
            local pilotRef = pilot and asComponentId(pilot) or nil
            local pilotCode = pilotRef and GetComponentData(pilotRef, "idcode") or "NONE"

            DebugError(string.format(
                "[GT Promote] SNAPSHOT[%s] ship=%s (%s) class=%s commander=%s (%s) assignment=%s group=%s order=%s pilot=%s level=%s directSubs=%d",
                tostring(label),
                tostring(idcode or "NOID"),
                tostring(ship),
                tostring(shipClassLabel(ship)),
                tostring(commanderCode or "NONE"),
                tostring(commander or "NONE"),
                tostring(assignment or "nil"),
                tostring(group or "nil"),
                tostring(orderId),
                tostring(pilotCode),
                tostring(level or "nil"),
                #subs
            ))

            for _, sub in ipairs(subs) do
                local sid = asComponentId(sub)
                if sid and sid ~= 0 and not visited[tostring(sid)] then
                    queue[#queue + 1] = sid
                end
            end
        end
    end

    DebugError(string.format("[GT Promote] SNAPSHOT[%s] end ships=%d", tostring(label), count))
end

local function subordinateIdList(ship)
    local subs = GetSubordinates(ship) or {}
    local out = {}
    for _, sub in ipairs(subs) do
        local sid = asComponentId(sub)
        if sid and sid ~= 0 then
            local code = GetComponentData(sid, "idcode") or tostring(sid)
            out[#out + 1] = tostring(code)
        end
    end
    if #out == 0 then
        return "NONE"
    end
    return table.concat(out, ",")
end

local function isShipAssignedToCommander(ship, commander)
    local sid = asComponentId(ship)
    local cid = asComponentId(commander)
    if not sid or sid == 0 or not cid or cid == 0 then
        return false
    end
    local current = GetCommander(sid)
    current = current and ConvertIDTo64Bit(current) or nil
    return current == cid
end

local function enqueueOldCommanderReattach(oldCommander, newCommander, assignment, group, issuedShips)
    oldCommander = asComponentId(oldCommander)
    newCommander = asComponentId(newCommander)
    if not oldCommander or oldCommander == 0 or not newCommander or newCommander == 0 then
        return
    end
    pendingOldCommanderReattach[tostring(oldCommander)] = {
        oldCommander = oldCommander,
        newCommander = newCommander,
        assignment = normalizeAssignment(assignment),
        group = normalizeGroup(group),
        checks = 0,
        delayFrames = 2,
        maxChecks = 120, -- ~2 seconds at 60fps
        forceIssued = false,
        maxPostForceChecks = 20, -- short post-force settle window
        issuedShips = issuedShips or {},
    }
    DebugError(string.format(
        "[GT Promote] Deferred old commander attach queued old=%s new=%s assignment=%s group=%s",
        formatComponentRef(oldCommander),
        formatComponentRef(newCommander),
        tostring(normalizeAssignment(assignment)),
        tostring(normalizeGroup(group))
    ))
end

local function pilotMaxJumps(level)
    if not level then return 25 end
    if level <= 2 then return 1 end
    if level <= 5 then return 3 end
    if level <= 8 then return 5 end
    if level <= 11 then return 10 end
    if level <= 13 then return 15 end
    return 25
end

local function clampDistanceParamsByPilotCap(orderId, paramsByName, ship)
    if type(paramsByName) ~= "table" then
        return paramsByName
    end
    local level = getPilotLevel(ship)
    local cap = pilotMaxJumps(level)

    local function clamp(name, keepZero)
        if paramsByName[name] == nil then
            return
        end
        local n = tonumber(paramsByName[name])
        if n == nil then
            return
        end
        if keepZero and n == 0 then
            return
        end
        if n > cap then
            paramsByName[name] = cap
        end
    end

    if orderId == "GalaxyTraderMK3" then
        clamp("maxbuy", false)
        clamp("maxsell", false)
    elseif orderId == "GalaxyTraderMK1" then
        clamp("maxsell", false)
    elseif orderId == "GalaxyTraderMK2" then
        clamp("maxDistance", true)
    elseif orderId == "GalaxyMiner" then
        clamp("maxGatherDistance", true)
        clamp("maxSellDistance", true)
    end

    return paramsByName
end

local function applyCapturedDefaultOrder(toShip, snapshot, quiet)
    if not snapshot or not snapshot.orderId then
        if not quiet then
            DebugError(string.format("[GT Promote] Default order apply skipped: no snapshot for ship=%s", tostring(toShip)))
        end
        return false
    end
    if not C.IsOrderSelectableFor(snapshot.orderId, toShip) then
        if not quiet then
            DebugError(string.format("[GT Promote] Default order apply skipped: order not selectable order=%s ship=%s", tostring(snapshot.orderId), tostring(toShip)))
        end
        return false
    end

    -- Vanilla sequence for replacing default orders:
    -- reset loop/planned state first, then create new default order.
    pcall(C.ResetOrderLoop, toShip)

    local orderidx = 0
    local namedParams = {}
    for _, entry in ipairs(snapshot.params or {}) do
        if entry and entry.name and entry.value ~= nil then
            namedParams[entry.name] = entry.value
        end
    end
    namedParams = clampDistanceParamsByPilotCap(snapshot.orderId, namedParams, toShip)

    -- Use vanilla Lua CreateOrder wrapper first so required params are present at creation time.
    if type(CreateOrder) == "function" then
        local ok, created = pcall(CreateOrder, toShip, snapshot.orderId, namedParams, true, false, false)
        if ok and created then
            orderidx = created
        end
    end

    -- Fallback for environments where CreateOrder wrapper is unavailable.
    if not orderidx or orderidx <= 0 then
        orderidx = C.CreateOrder(toShip, snapshot.orderId, true)
    end
    if not orderidx or orderidx <= 0 then
        if not quiet then
            DebugError(string.format("[GT Promote] Default order apply failed: CreateOrder returned %s for order=%s ship=%s", tostring(orderidx), tostring(snapshot.orderId), tostring(toShip)))
        end
        return false
    end

    for _, entry in ipairs(snapshot.params or {}) do
        if entry and entry.idx and entry.value ~= nil then
            local v = entry.value
            if entry.name and namedParams[entry.name] ~= nil then
                v = namedParams[entry.name]
            end
            pcall(SetOrderParam, toShip, orderidx, entry.idx, nil, v)
        end
    end

    C.EnableOrder(toShip, orderidx)
    -- Match vanilla behavior: promote planned default to active default immediately.
    pcall(C.EnablePlannedDefaultOrder, toShip, false)
    DebugError(string.format("[GT Promote] Default order applied: order=%s ship=%s idx=%s params=%d source=%s", tostring(snapshot.orderId), tostring(toShip), tostring(orderidx), #(snapshot.params or {}), tostring(snapshot.sourceShip)))
    return true
end

local function enqueueDefaultOrderApply(ship, snapshot)
    if not ship or ship == 0 or not snapshot then
        return
    end
    pendingDefaultApplies[ship] = {
        ship = ship,
        snapshot = snapshot,
        delayFrames = 2,
    }
end

local function processPendingDefaultApplies()
    for key, entry in pairs(pendingDefaultApplies) do
        local ship = entry.ship
        local snapshot = entry.snapshot

        if (not ship) or ship == 0 or (not C.IsComponentClass(ship, "controllable")) then
            pendingDefaultApplies[key] = nil
        else
            if (entry.delayFrames or 0) > 0 then
                entry.delayFrames = entry.delayFrames - 1
            else
                local currentOrderId = getDefaultOrderId(ship)
                if (not currentOrderId) or (snapshot and snapshot.orderId and currentOrderId ~= snapshot.orderId) then
                    DebugError(string.format("[GT Promote] Pending default-apply trigger ship=%s currentOrder=%s", tostring(ship), tostring(currentOrderId)))
                    logFleetSnapshot("PENDING_APPLY_BEFORE", ship)
                    logDefaultOrderSnapshotDetailed("PENDING_APPLY", snapshot)
                    applyCapturedDefaultOrder(ship, snapshot, false)
                    logFleetSnapshot("PENDING_APPLY_AFTER", ship)
                end
                pendingDefaultApplies[key] = nil
            end
        end
    end
end

local function processPendingPromotionReassign()
    for key, job in pairs(pendingPromotionReassign) do
        local newCommander = job.newCommander
        local oldCommander = job.oldCommander
        if (not newCommander) or newCommander == 0 or (not C.IsComponentClass(newCommander, "controllable")) then
            pendingPromotionReassign[key] = nil
        else
            if (job.delayFrames or 0) > 0 then
                job.delayFrames = job.delayFrames - 1
            else
                local idx = job.index or 1
                local total = #(job.entries or {})
                if idx <= total then
                    local e = job.entries[idx]
                    local ship = e and e.ship or nil
                    if ship and ship ~= 0 and C.IsComponentClass(ship, "controllable") and ship ~= newCommander and ship ~= oldCommander then
                        local beforeCommander = GetCommander(ship)
                        beforeCommander = beforeCommander and ConvertIDTo64Bit(beforeCommander) or nil
                        DebugError(string.format(
                            "[GT Promote] Reassign step [%d/%d] ship=%s beforeCommander=%s targetCommander=%s assignment=%s group=%s",
                            idx,
                            total,
                            formatComponentRef(ship),
                            formatComponentRef(beforeCommander),
                            formatComponentRef(newCommander),
                            tostring(e.assignment),
                            tostring(e.group)
                        ))
                        if beforeCommander == newCommander then
                            DebugError(string.format(
                                "[GT Promote] Reassign skip ship=%s already assigned to target=%s",
                                formatComponentRef(ship),
                                formatComponentRef(newCommander)
                            ))
                        else
                            if orderAssignCommander(ship, newCommander, e.assignment, e.group, false) then
                                job.moved = (job.moved or 0) + 1
                                job.issuedShips = job.issuedShips or {}
                                job.issuedShips[tostring(ship)] = true
                            else
                                job.failed = (job.failed or 0) + 1
                                DebugError(string.format("[GT Promote] Reassign failed ship=%s target=%s", tostring(ship), tostring(newCommander)))
                            end
                        end
                    end
                    job.index = idx + 1
                    job.delayFrames = 2 -- tiny pacing delay to avoid order burst/race
                    pendingPromotionReassign[key] = job
                else
                    -- Subordinate reassignment queue finished: continue remaining promotion phases.
                    logFleetSnapshot("POST_SUBORDINATE_REASSIGN_QUEUE_OLD_TREE", oldCommander)
                    logFleetSnapshot("POST_SUBORDINATE_REASSIGN_QUEUE_NEW_TREE", newCommander)

                    enqueueOldCommanderReattach(oldCommander, newCommander, job.oldAssign, job.oldGroup, job.issuedShips)
                    logFleetSnapshot("POST_OLD_COMMANDER_REASSIGN_DEFERRED_NEW_TREE", newCommander)

                    applyCapturedDefaultOrder(newCommander, job.defaultOrderSnapshot)
                    enqueueDefaultOrderApply(newCommander, job.defaultOrderSnapshot)
                    applyFleetName(newCommander, job.originalFleetName)
                    logFleetSnapshot("POST_FINAL_DEFAULT_APPLY_NEW_TREE", newCommander)
                    local verifySubs = collectFleetSubordinatesRecursive(newCommander)
                    DebugError(string.format("[GT Promote] Post-promote verify commander=%s descendants=%d", tostring(newCommander), #verifySubs))
                    logFleetSnapshot("POST_VERIFY_NEW_TREE", newCommander)
                    local newName = GetComponentData(newCommander, "name") or "ship"
                    DebugError(string.format("[GT Promote] Promotion complete: %s is new commander (moved=%d, failed=%d)", tostring(newName), job.moved or 0, job.failed or 0))

                    pendingPromotionReassign[key] = nil
                end
            end
        end
    end
end

local function processPendingOldCommanderReattach()
    for key, entry in pairs(pendingOldCommanderReattach) do
        local oldCommander = entry.oldCommander
        local newCommander = entry.newCommander
        if (not oldCommander) or oldCommander == 0 or (not newCommander) or newCommander == 0
            or (not C.IsComponentClass(oldCommander, "controllable")) or (not C.IsComponentClass(newCommander, "controllable")) then
            pendingOldCommanderReattach[key] = nil
        else
            if (entry.delayFrames or 0) > 0 then
                entry.delayFrames = entry.delayFrames - 1
            else
                entry.checks = (entry.checks or 0) + 1
                local subs = GetSubordinates(oldCommander) or {}
                local subCount = #subs
                local shouldForce = entry.checks >= (entry.maxChecks or 120)
                local currentCommander = GetCommander(oldCommander)
                currentCommander = currentCommander and ConvertIDTo64Bit(currentCommander) or nil
                local oldAttached = (currentCommander == newCommander)
                if (entry.checks % 10) == 1 or subCount == 0 or shouldForce then
                    DebugError(string.format(
                        "[GT Promote] Deferred attach check old=%s subs=%d list=%s checks=%d/%d force=%s attached=%s",
                        formatComponentRef(oldCommander),
                        subCount,
                        subordinateIdList(oldCommander),
                        entry.checks,
                        entry.maxChecks or 120,
                        tostring(shouldForce),
                        tostring(oldAttached)
                    ))
                end

                if subCount == 0 and oldAttached then
                    DebugError(string.format(
                        "[GT Promote] Deferred attach converged old=%s new=%s",
                        formatComponentRef(oldCommander),
                        formatComponentRef(newCommander)
                    ))
                    pendingOldCommanderReattach[key] = nil
                elseif shouldForce then
                    if not entry.forceIssued then
                        logFleetSnapshot("DEFERRED_OLD_ATTACH_BEFORE_NEW_TREE", newCommander)
                        -- If subordinates are still stuck on old commander at force time, requeue them explicitly.
                        if subCount > 0 then
                            local subsNow = GetSubordinates(oldCommander) or {}
                            for _, sub in ipairs(subsNow) do
                                local sid = asComponentId(sub)
                                if sid and sid ~= 0 and sid ~= newCommander then
                                    local assignment, group = GetComponentData(sid, "assignment", "subordinategroup")
                                    local alreadyIssued = entry.issuedShips and entry.issuedShips[tostring(sid)] or false
                                    if alreadyIssued then
                                        DebugError(string.format(
                                            "[GT Promote] Deferred stuck-subordinate requeue skip ship=%s already had AssignCommander in this promote cycle",
                                            formatComponentRef(sid)
                                        ))
                                    elseif isShipAssignedToCommander(sid, newCommander) then
                                        DebugError(string.format(
                                            "[GT Promote] Deferred stuck-subordinate requeue skip ship=%s already assigned to new=%s",
                                            formatComponentRef(sid),
                                            formatComponentRef(newCommander)
                                        ))
                                    else
                                        local okSub = orderAssignCommander(sid, newCommander, normalizeAssignment(assignment), normalizeGroup(group), true)
                                        if okSub then
                                            entry.issuedShips = entry.issuedShips or {}
                                            entry.issuedShips[tostring(sid)] = true
                                        end
                                        DebugError(string.format(
                                            "[GT Promote] Deferred stuck-subordinate requeue ship=%s old=%s new=%s ok=%s assignment=%s group=%s cancelOrders=true",
                                            formatComponentRef(sid),
                                            formatComponentRef(oldCommander),
                                            formatComponentRef(newCommander),
                                            tostring(okSub),
                                            tostring(assignment),
                                            tostring(group)
                                        ))
                                    end
                                end
                            end
                        end
                        local ok = orderAssignCommander(oldCommander, newCommander, entry.assignment, entry.group, true)
                        DebugError(string.format(
                            "[GT Promote] Deferred old commander attach result old=%s new=%s ok=%s cancelOrders=true",
                            formatComponentRef(oldCommander),
                            formatComponentRef(newCommander),
                            tostring(ok)
                        ))
                        -- Give orders a short settle window before final verdict.
                        entry.forceIssued = true
                        entry.checks = 0
                        entry.delayFrames = 8
                        entry.maxChecks = entry.maxPostForceChecks or 20
                        pendingOldCommanderReattach[key] = entry
                    else
                        local postSubs = GetSubordinates(oldCommander) or {}
                        local postCount = #postSubs
                        local postCommander = GetCommander(oldCommander)
                        postCommander = postCommander and ConvertIDTo64Bit(postCommander) or nil
                        local postAttached = (postCommander == newCommander)
                        DebugError(string.format(
                            "[GT Promote] Deferred attach final status old=%s new=%s attached=%s remainingSubs=%d list=%s",
                            formatComponentRef(oldCommander),
                            formatComponentRef(newCommander),
                            tostring(postAttached),
                            postCount,
                            subordinateIdList(oldCommander)
                        ))
                        logFleetSnapshot("DEFERRED_OLD_ATTACH_AFTER_NEW_TREE", newCommander)
                        pendingOldCommanderReattach[key] = nil
                    end
                else
                    pendingOldCommanderReattach[key] = entry
                end
            end
        end
    end
end

collectFleetSubordinatesRecursive = function(rootCommander)
    local result = {}
    local visited = {}
    local queue = { rootCommander }
    local qhead = 1

    while qhead <= #queue do
        local current = queue[qhead]
        qhead = qhead + 1
        local cid = asComponentId(current)
        if cid and cid ~= 0 and not visited[tostring(cid)] then
            visited[tostring(cid)] = true
            local subs = GetSubordinates(cid) or {}
            for _, sub in ipairs(subs) do
                local sid = asComponentId(sub)
                if sid and sid ~= 0 and not visited[tostring(sid)] then
                    result[#result + 1] = sid
                    queue[#queue + 1] = sid
                end
            end
        end
    end
    DebugError(string.format("[GT Promote] Recursive collection root=%s count=%d", tostring(rootCommander), #result))
    for _, sid in ipairs(result) do
        local cmd = GetCommander(sid)
        cmd = cmd and ConvertIDTo64Bit(cmd) or nil
        DebugError(string.format("[GT Promote]  - candidate ship=%s currentCommander=%s", tostring(sid), tostring(cmd)))
    end
    return result
end

orderAssignCommander = function(ship, newCommander, assignment, group, cancelOrders)
    if not ship or ship == 0 or not newCommander or newCommander == 0 then
        DebugError(string.format("[GT Promote] AssignCommander skipped invalid args ship=%s newCommander=%s", tostring(ship), tostring(newCommander)))
        return false
    end
    if (not C.IsOrderSelectableFor("AssignCommander", ship)) or (not GetComponentData(ship, "assignedpilot")) then
        DebugError(string.format("[GT Promote] AssignCommander not selectable/no pilot ship=%s selectable=%s hasPilot=%s", tostring(ship), tostring(C.IsOrderSelectableFor("AssignCommander", ship)), tostring(GetComponentData(ship, "assignedpilot") ~= nil)))
        return false
    end

    local orderidx = C.CreateOrder(ship, "AssignCommander", false)
    if orderidx <= 0 then
        DebugError(string.format("[GT Promote] AssignCommander create failed ship=%s target=%s", tostring(ship), tostring(newCommander)))
        return false
    end

    local safeAssignment = normalizeAssignment(assignment)
    local safeGroup = normalizeGroup(group)
    local beforeCommander = GetCommander(ship)
    beforeCommander = beforeCommander and ConvertIDTo64Bit(beforeCommander) or nil

    SetOrderParam(ship, orderidx, 1, nil, ConvertStringToLuaID(tostring(newCommander))) -- commander
    SetOrderParam(ship, orderidx, 2, nil, safeAssignment) -- assignment
    SetOrderParam(ship, orderidx, 3, nil, safeGroup) -- subordinate group
    SetOrderParam(ship, orderidx, 4, nil, true) -- setgroupassignment
    if cancelOrders == nil then
        cancelOrders = false
    end
    SetOrderParam(ship, orderidx, 5, nil, cancelOrders) -- cancelorders
    SetOrderParam(ship, orderidx, 6, nil, true) -- response
    SetOrderParam(ship, orderidx, 8, nil, true) -- informfleetmanager

    C.EnableOrder(ship, orderidx)
    if orderidx ~= 1 then
        -- Try to promote assignment ahead of blocking critical queue entries first,
        -- while keeping cancelorders behavior independent.
        local targetIdx = 1
        if not C.AdjustOrder(ship, orderidx, targetIdx, true, true, true) then
            targetIdx = 2
        end
        C.AdjustOrder(ship, orderidx, targetIdx, true, true, false)
    end
    DebugError(string.format("[GT Promote] AssignCommander immediate ship=%s before=%s target=%s assignment=%s group=%s idx=%s cancelOrders=%s", tostring(ship), tostring(beforeCommander), tostring(newCommander), tostring(safeAssignment), tostring(safeGroup), tostring(orderidx), tostring(cancelOrders)))
    return true
end

local function promoteSubordinateToCommander(subordinateComponent)
    if not subordinateComponent or subordinateComponent == 0 then
        DebugError("[GT Promote] Invalid subordinate component")
        return
    end

    local newCommander = asComponentId(subordinateComponent)
    if not newCommander or newCommander == 0 then
        DebugError("[GT Promote] Failed to convert subordinate component")
        return
    end

    local oldCommander = nil
    if C.IsComponentClass(newCommander, "controllable") then
        oldCommander = GetCommander(newCommander)
        oldCommander = oldCommander and ConvertIDTo64Bit(oldCommander) or nil
    end
    if not oldCommander or oldCommander == 0 then
        DebugError("[GT Promote] Clicked ship is not a subordinate (no commander)")
        return
    end
    DebugError(string.format("[GT Promote] Start promote new=%s old=%s", tostring(newCommander), tostring(oldCommander)))
    logFleetSnapshot("PRE_OLD_COMMANDER_TREE", oldCommander)
    logFleetSnapshot("PRE_PROMOTED_SHIP_TREE", newCommander)

    -- Get full subordinate tree so promotion can flatten hierarchy.
    -- Desired result after promotion:
    --   newCommander
    --    > oldCommander
    --    > all former subordinate ships (directly)
    local fleetShips = collectFleetSubordinatesRecursive(oldCommander)
    local moved = 0
    local failed = 0
    local originalFleetName = captureFleetName(oldCommander)
    local defaultOrderSnapshot = capturePromotionDefaultOrder(oldCommander)
    if defaultOrderSnapshot then
        DebugError(string.format("[GT Promote] Snapshot captured: source=%s order=%s params=%d", tostring(defaultOrderSnapshot.sourceShip), tostring(defaultOrderSnapshot.orderId), #(defaultOrderSnapshot.params or {})))
        logDefaultOrderSnapshotDetailed("CAPTURED", defaultOrderSnapshot)
    else
        DebugError(string.format("[GT Promote] Snapshot missing: no default order found in commander chain starting at %s", tostring(oldCommander)))
    end

    -- 1) Make clicked ship commander first.
    C.RemoveCommander2(newCommander)
    DebugError(string.format("[GT Promote] Detached promoted ship=%s from commander=%s", tostring(newCommander), tostring(oldCommander)))
    logFleetSnapshot("POST_DETACH_OLD_COMMANDER_TREE", oldCommander)
    logFleetSnapshot("POST_DETACH_NEW_COMMANDER_TREE", newCommander)

    -- Prime promoted commander with captured commander default order as early as possible.
    applyCapturedDefaultOrder(newCommander, defaultOrderSnapshot)
    applyFleetName(newCommander, originalFleetName)
    logFleetSnapshot("POST_INITIAL_DEFAULT_APPLY_NEW_COMMANDER_TREE", newCommander)

    -- 2) Reassign all former subordinate ships directly under new commander (flatten tree),
    --    paced one-by-one in onUpdate to avoid burst race conditions.
    local entries = {}
    for _, shipEntry in ipairs(fleetShips) do
        local ship = asComponentId(shipEntry)
        if ship and ship ~= 0 and ship ~= newCommander and ship ~= oldCommander and C.IsComponentClass(ship, "controllable") then
            local assignment, group = GetComponentData(ship, "assignment", "subordinategroup")
            entries[#entries + 1] = {
                ship = ship,
                assignment = normalizeAssignment(assignment),
                group = normalizeGroup(group),
            }
        end
    end

    local oldAssign, oldGroup = GetComponentData(oldCommander, "assignment", "subordinategroup")
    pendingPromotionReassign[tostring(newCommander)] = {
        newCommander = newCommander,
        oldCommander = oldCommander,
        entries = entries,
        index = 1,
        moved = moved,
        failed = failed,
        delayFrames = 0,
        oldAssign = normalizeAssignment(oldAssign),
        oldGroup = normalizeGroup(oldGroup),
        defaultOrderSnapshot = defaultOrderSnapshot,
        issuedShips = {},
        originalFleetName = originalFleetName,
    }
    DebugError(string.format(
        "[GT Promote] Sequential subordinate reassignment queued commander=%s old=%s ships=%d paceFrames=%d",
        formatComponentRef(newCommander),
        formatComponentRef(oldCommander),
        #entries,
        2
    ))
end

RegisterEvent("gt.openPromoteContext", function(_, subordinateComponent)
    promoteSubordinateToCommander(subordinateComponent)
end)

function onUpdate()
    processPendingPromotionReassign()
    processPendingDefaultApplies()
    processPendingOldCommanderReattach()
end
SetScript("onUpdate", onUpdate)

DebugError("[GT Promote] Commander-only promote integration loaded")
