-- Execution-protocol root composition. Long-lived runtime identities are
-- constructed once here and retained in lexical scope.
local composition = {}

function composition.bind(root)
    if type(root) ~= "string" or root == "" then error("executor config path is required", 2) end
    local json = import("mods/protocol/json.lua")
    local protocol = import("mods/protocol/decoder.lua")
    local inbox = import("mods/host/inbox.lua").create(root, function(raw)
        local value, errorMessage = json.decode(raw)
        if value == nil then return nil, "malformed-json: " .. tostring(errorMessage) end
        return protocol.decode(value)
    end, rom.path)
    local route = import("mods/route/session.lua")
    local ephyra = import("mods/navigation/ephyra.lua")
    local room = import("mods/room/coordinator.lua")
    local session = import("mods/runtime/session.lua")
    local loadout = import("mods/loadout/session.lua")
    local executionState = session.create()

    -- Imported chunks are stateless definitions. This explicit instance spans
    -- both owners that participate in Hex-tree realization.
    local hexTree = import("mods/spells/hex_tree.lua").create()
    local shipCombat = import("mods/room/timeline/encounters/thessaly.lua").create()
    local generatedEncounter = import("mods/room/timeline/encounters/generated.lua").create()
    local highlights = import("mods/guidance/highlights.lua").create(route)
    local loadoutHooks = import("mods/loadout/hooks.lua")
    local acquisitionHooks = import("mods/room/timeline/acquisitions/hooks.lua")
    local loadoutRuntime = {
        inbox = inbox,
        session = session,
        loadout = loadout,
        activePlanSlot = function(runtime)
            return runtime.data.read("ActivePlanSlot")
        end,
    }

    local bound = {
        inboxInspection = {
            activeSlot = inbox.activeSlot,
            select = inbox.select,
            load = inbox.load,
            plan = inbox.plan,
            status = inbox.status,
        },
    }

    -- Read-only inspection of the admitted session, independent of inbox previews.
    function bound.sessionInspection()
        local snapshot = session.status(executionState)
        local routeState = executionState.route
        snapshot.plan = executionState.plan
        snapshot.slot = executionState.planSlot
        snapshot.index = routeState and routeState.index
        snapshot.current = routeState and routeState.currentOccurrence
        snapshot.lastExited = routeState and routeState.lastExitedOccurrence
        snapshot.restoredRoom = routeState and routeState.transparentNativeRoom
        snapshot.issue = executionState.firstMismatch or executionState.firstFault or executionState.admissionError
        snapshot.postbossAdmission = executionState.postbossAdmission
        return snapshot
    end

    function bound.roomGuideInspection()
        if executionState.state ~= "synchronized" then return nil end
        local active = room.guide(executionState)
        local currentRun = _G.CurrentRun
        local navigation = route.guideNavigation(executionState.route,
            ephyra.hubFountainUsed(currentRun and currentRun.CurrentRoom))
        if active ~= nil then
            return {
                kind = "room",
                occurrence = active.occurrence,
                isCompleted = active.isCompleted,
                navigation = navigation,
            }
        end
        local routeState = executionState.route
        if routeState and routeState.transparentNativeRoom ~= nil then
            return {
                kind = "navigation",
                nativeRoomName = routeState.transparentNativeRoom,
                navigation = navigation,
            }
        end
        return nil
    end

    function bound.attach(module)
        local roomHooks = import("mods/room/hooks.lua")
        local encounterHooks = import("mods/room/timeline/encounters/hooks.lua")
        local roomFeatureHooks = import("mods/room/features/hooks.lua")
        local navigationHooks = import("mods/navigation/hooks.lua")
        local featureInventory = import("mods/room/features/inventory/attach.lua")
        local interactionHooks = import("mods/room/timeline/interactions/hooks.lua")
        local transformationHooks = import("mods/room/timeline/transformations/hooks.lua")

        local function getState() return executionState end
        local function diagnosticValue(value, ancestors)
            if type(value) == "number" then return string.format("%.17g", value) end
            if type(value) ~= "table" then return tostring(value) end
            ancestors = ancestors or {}
            if ancestors[value] then return "<cycle>" end
            ancestors[value] = true
            local parts = {}
            for key, nested in pairs(value) do
                parts[#parts + 1] = tostring(key) .. "=" .. diagnosticValue(nested, ancestors)
            end
            ancestors[value] = nil
            return "{" .. table.concat(parts, ",") .. "}"
        end
        local function fieldsPoint(value)
            if type(value) ~= "table" then return "missing" end
            local location = value.location
            local suffix = type(location) == "table" and "@(" .. tostring(location.X) .. ","
                .. tostring(location.Y) .. ")" or ""
            return tostring(value.id) .. suffix
        end
        local function fieldsReward(value)
            if type(value) ~= "table" then return "missing" end
            return tostring(value.rewardType or value.name) .. "/" .. tostring(value.source)
        end
        local function fieldsObject(value)
            if type(value) ~= "table" then return "missing" end
            local location = type(value.location) == "table" and "@(" .. tostring(value.location.X) .. ","
                .. tostring(value.location.Y) .. ")" or ""
            return tostring(value.objectId) .. ":" .. tostring(value.name) .. "#"
                .. tostring(value.spawnPointId) .. location
        end
        local function fieldsCage(value)
            return fieldsObject(value) .. "=" .. fieldsObject(value and value.reward)
        end
        local function fieldsOptional(value)
            local restore = value and value.restore
            return fieldsObject(value) .. "=" .. fieldsReward(restore) .. "#"
                .. tostring(restore and restore.spawnPointId)
        end
        local function fieldsList(values, format)
            local parts = {}
            for _, value in ipairs(values or {}) do parts[#parts + 1] = format(value) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local function fieldsSnapshot(snapshot)
            local planned = snapshot and snapshot.planned or {}
            local observed = snapshot and snapshot.observed or {}
            local plannedCages, plannedOptional = {}, {}
            for _, cage in ipairs(planned.cages or {}) do
                plannedCages[#plannedCages + 1] = tostring(cage.slotKey) .. ":"
                    .. fieldsPoint(cage.point) .. ":" .. fieldsReward(cage.reward)
            end
            for _, optional in ipairs(planned.optionalRewards or {}) do
                plannedOptional[#plannedOptional + 1] = tostring(optional.slotKey) .. ":"
                    .. fieldsPoint(optional.point) .. ":" .. fieldsReward(optional.reward)
            end
            return "fields planned={entry=" .. fieldsPoint(planned.entryPair and planned.entryPair.startPoint)
                .. "->" .. fieldsPoint(planned.entryPair and planned.entryPair.endPoint)
                .. ",cages=" .. fieldsList(plannedCages, tostring)
                .. ",optional=" .. fieldsList(plannedOptional, tostring)
                .. ",nemesis=" .. fieldsPoint(planned.nemesisPoint) .. "} observed={entry="
                .. fieldsPoint(observed.entryPair and observed.entryPair.startPoint) .. "->"
                .. fieldsPoint(observed.entryPair and observed.entryPair.endPoint) .. ",cages="
                .. fieldsList(observed.cages, fieldsCage) .. ",optional="
                .. fieldsList(observed.optionalRewards, fieldsOptional) .. ",nemesis="
                .. fieldsObject(observed.nemesis) .. "}"
        end
        local function report(runtime)
            local state = getState(runtime)
            if state == nil then return end
            if runtime.status and runtime.status.write then
                local status = session.status(state)
                runtime.status.write("ExecutionSessionStatus", status.state .. ": " .. status.reason)
            end
            if state.firstMismatch and state.loggedMismatch ~= state.firstMismatch then
                state.loggedMismatch = state.firstMismatch
                if rom and rom.log and rom.log.info then
                    local mismatch = state.firstMismatch
                    local nearby = {}
                    for _, diagnostic in ipairs(state.diagnostics or {}) do
                        nearby[#nearby + 1] = diagnosticValue(diagnostic)
                    end
                    rom.log.info("[RunPlanner] first-mismatch checkpoint="
                        .. tostring(mismatch.checkpoint or mismatch.kind) .. " expected="
                        .. diagnosticValue(mismatch.expected) .. " observed="
                        .. diagnosticValue(mismatch.observed) .. " diagnostics="
                        .. table.concat(nearby, ";"))
                end
            end
            for _, diagnostic in ipairs(state.diagnostics or {}) do
                local fields = diagnostic.checkpoint == "fields-completed-product"
                local encounter = diagnostic.checkpoint == "encounter-eligibility"
                    or diagnostic.checkpoint == "encounter-composition"
                if (fields or encounter) and diagnostic.logged ~= true then
                    diagnostic.logged = true
                    if rom and rom.log and rom.log.info then
                        rom.log.info("[RunPlanner] diagnostic occurrence=" .. tostring(diagnostic.occurrenceId)
                            .. " " .. (fields and fieldsSnapshot(diagnostic.observed)
                                or diagnostic.checkpoint .. " " .. diagnosticValue(diagnostic.observed)))
                    end
                end
            end
            if state.firstFault and state.loggedFault ~= state.firstFault then
                state.loggedFault = state.firstFault
                if rom and rom.log and rom.log.info then
                    local fault = state.firstFault
                    rom.log.info("[RunPlanner] executor-fault checkpoint="
                        .. tostring(fault.checkpoint) .. " expected="
                        .. diagnosticValue(fault.expected) .. " observed="
                        .. diagnosticValue(fault.observed) .. " context="
                        .. diagnosticValue(fault.context))
                    for line in (fault.traceback or ""):gmatch("[^\r\n]+") do
                        rom.log.info("[RunPlanner] executor-fault trace " .. line)
                    end
                end
            end
            if state.admissionError and state.loggedAdmission ~= state.admissionError then
                state.loggedAdmission = state.admissionError
                if rom and rom.log and rom.log.info then
                    local admission = state.admissionError
                    rom.log.info("[RunPlanner] admission-rejected checkpoint="
                        .. tostring(admission.checkpoint) .. " expected="
                        .. diagnosticValue(admission.expected) .. " observed="
                        .. diagnosticValue(admission.observed))
                end
            end
            if state.postbossAdmission
                and state.loggedPostbossAdmission ~= state.postbossAdmission then
                state.loggedPostbossAdmission = state.postbossAdmission
                if rom and rom.log and rom.log.info then
                    local admission = state.postbossAdmission
                    rom.log.info("[RunPlanner] postboss-resynchronized room="
                        .. tostring(admission.gameName) .. " occurrence="
                        .. tostring(admission.occurrenceId) .. " index="
                        .. tostring(admission.index) .. " slot="
                        .. tostring(admission.slot))
                end
            end
            highlights.refresh(runtime, state)
        end

        hexTree.attach(module)
        local loadoutScope = loadoutHooks.attach(module, loadoutRuntime, getState, report, room, hexTree)

        acquisitionHooks.attach(module, session, getState, report, room, hexTree,
            shipCombat.takeRewardProducer, highlights)
        local transformationScope = transformationHooks.attach(module, session, getState, report, room)
        local featureScope = roomFeatureHooks.attach(module, session, getState, report, room)
        local navigation = navigationHooks.attach(module, session, getState, report, route, room,
            transformationScope, shipCombat.rewardContext, generatedEncounter, highlights)
        highlights.attach(module, getState)
        roomHooks.attach(module, session, getState, report, route, room, featureScope, navigation,
            loadoutScope, {
                inbox = inbox,
                activePlanSlot = loadoutRuntime.activePlanSlot,
            })
        encounterHooks.attach(module, session, getState, report, room, shipCombat, generatedEncounter, highlights)
        featureInventory.attach(module, session, getState, report, room, route)
        interactionHooks.attach(module, session, getState, report, room, route)
        if module.overlays then
            module.overlays.onCommit(function(_, runtime) highlights.refresh(runtime, getState(runtime)) end)
        end
    end

    return bound
end

return composition
