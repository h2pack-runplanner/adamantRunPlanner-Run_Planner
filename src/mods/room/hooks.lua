-- Route/room handshake and current-room lifecycle contacts.
local hooks = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

local function reportOutcome(session, state, errorValue)
    if type(errorValue) == "table" and errorValue.outcome == "fault" then
        return session.fault(state, errorValue)
    end
    return session.mismatch(state, errorValue)
end

function hooks.attach(module, session, getState, report, route, room, featureScope, navigation, loadoutScope,
    admissionRuntime)
    assert(type(loadoutScope) == "table"
        and type(loadoutScope.synchronizeStartingRoom) == "function",
        "starting-room loadout scope is required")
    if admissionRuntime ~= nil then
        assert(type(admissionRuntime.inbox) == "table"
            and type(admissionRuntime.activePlanSlot) == "function"
            and type(session.canAttemptPostbossAdmission) == "function"
            and type(session.attemptPostbossAdmission) == "function",
            "Postboss admission dependencies are required")
    end
    module.hooks.wrap("ChooseStartingRoom", "run-planner-starting-room", function(_, runtime, base, currentRun,
        args)
        local state = getState(runtime)
        if state == nil then return base(currentRun, args) end
        local enteringDreamBiome = state.state == "synchronized"
            and state.plan.routeKey == "Dream"
            and type(args) == "table" and args.StartingBiome ~= nil
            and currentRun and currentRun.IsDreamRun == true
        if state.state ~= "starting" and not enteringDreamBiome then
            report(runtime)
            return base(currentRun, args)
        end
        if state.state == "starting" and not loadoutScope.synchronizeStartingRoom(runtime, args) then
            report(runtime)
            return base(currentRun, args)
        end
        local occurrence = enteringDreamBiome and route.next(state.route) or route.expected(state.route)
        if occurrence == nil or room.prepare(state, occurrence) == nil
            or state.state ~= "synchronized" then
            report(runtime)
            return base(currentRun, args)
        end
        local gameValue = _G.game or game
        local data = occurrence and room.realize(state, occurrence, gameValue) or nil
        if data ~= nil then data = navigation.realizeIncomingReward(occurrence, data) end
        if type(data) == "table" then
            local createRoom = gameValue.CreateRoom or _G.CreateRoom
            if type(createRoom) ~= "function" then
                session.fault(state, {
                    outcome = "fault", checkpoint = "native-api", expected = "CreateRoom", observed = "missing",
                })
                report(runtime)
                return base(currentRun, args)
            end
            local value = createRoom(data, args)
            report(runtime)
            return value
        end
        report(runtime)
        return base(currentRun, args)
    end)

    module.hooks.wrap("CreateRoom", "run-planner-create-room", function(_, runtime, base, roomData, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(roomData, args) end
        local additional = featureScope and featureScope.currentAdditional()
        local id = type(roomData) == "table" and roomData.__runPlannerExecutionRoomId or nil
        local occurrence = id and state.plan.occurrencesById[id]
            or additional and additional.occurrence
            or navigation.resolveNativeRoom and navigation.resolveNativeRoom(state, roomData)
        if occurrence ~= nil then
            local realized = room.realize(state, occurrence, _G.game or game, roomData)
            if type(realized) == "table" then
                roomData = navigation.realizeIncomingReward(occurrence, realized)
                if additional ~= nil then
                    roomData = navigation.bindAdditionalRoom(roomData, additional.additional)
                end
            end
        end
        local result = base(roomData, args)
        navigation.applyZagreusContractPresence(roomData, result)
        if type(result) == "table" and occurrence ~= nil then
            room.realizeFeatures(state, occurrence, result)
            result.__runPlannerExecutionRoomId = occurrence.id
            local binding = additional and additional.additional or nil
            if binding == nil and type(roomData) == "table"
                and roomData.__runPlannerExecutionAdditionalOwner ~= nil then
                binding = {
                    owner = roomData.__runPlannerExecutionAdditionalOwner,
                    kind = roomData.__runPlannerExecutionAdditionalKind,
                }
            end
            if binding ~= nil then navigation.bindAdditionalRoom(result, binding) end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("StartRoom", "run-planner-room-entry", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        if state == nil then return base(currentRun, nativeRoom) end
        local liveRun = type(currentRun) == "table" and currentRun or _G.CurrentRun
        if currentRun == nil then currentRun = liveRun end
        if nativeRoom == nil and type(liveRun) == "table" then nativeRoom = liveRun.CurrentRoom end
        if admissionRuntime ~= nil and type(liveRun) == "table"
            and session.canAttemptPostbossAdmission(state) then
            session.attemptPostbossAdmission(
                state,
                admissionRuntime.inbox,
                admissionRuntime.activePlanSlot(runtime),
                nativeRoom
            )
        end
        if state.state ~= "synchronized" then report(runtime); return base(currentRun, nativeRoom) end
        local expected = route.expected(state.route)
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if route.enterTransparent and route.enterTransparent(state.route, roomName(nativeRoom)) then
            return base(currentRun, nativeRoom)
        end
        if id == nil and expected and roomName(nativeRoom) == expected.gameName then id = expected.id end
        -- Native room restoration can discard planner-private fields. Once the
        -- route cursor has resolved the exact occurrence by game name, restore
        -- its identity before any native room lifecycle runs. Peripheral hooks
        -- such as auto-harvest then consult the same occurrence through exit.
        if type(nativeRoom) == "table" and id ~= nil then
            nativeRoom.__runPlannerExecutionRoomId = id
        end
        local occurrence, errorValue = route.enter(state.route, id, roomName(nativeRoom))
        if occurrence == true then
            state.state, state.reason = "inactive", "configured-prefix-complete"
            report(runtime)
            return base(currentRun, nativeRoom)
        end
        if occurrence == nil then reportOutcome(session, state, errorValue) else room.enter(state, occurrence) end
        report(runtime)
        if state.state == "synchronized" then room.bindEntryEncounters(state, nativeRoom) end
        local result = base(currentRun, nativeRoom)
        if state.state == "synchronized" then
            local rewardOk, rewardError = navigation.proveIncomingReward(occurrence, nativeRoom)
            if not rewardOk then reportOutcome(session, state, rewardError) end
        end
        if state.state == "synchronized" then
            room.proveEntry(state, nativeRoom, {
                activeObstacles = _G.MapState and _G.MapState.ActiveObstacles,
                offeredExitDoors = _G.MapState and _G.MapState.OfferedExitDoors,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("RestoreUnlockRoomExits", "run-planner-room-restore", function(_, runtime, base,
        currentRun, nativeRoom)
        local state = getState(runtime)
        if state and state.state == "synchronized" then
            route.enterTransparent(state.route, roomName(nativeRoom))
        end
        return base(currentRun, nativeRoom)
    end)

    module.hooks.wrap("LeaveRoom", "run-planner-room-exit", function(_, runtime, base, currentRun, door)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, door) end
        local nativeRoomName = roomName(currentRun and currentRun.CurrentRoom)
        if route.leaveTransparent and route.leaveTransparent(state.route, nativeRoomName) then
            if navigation.proveHubDeparture then
                local departed, departureError = navigation.proveHubDeparture(state, currentRun)
                if not departed then reportOutcome(session, state, departureError); report(runtime) end
            end
            return base(currentRun, door)
        end
        local proved, errorValue = navigation.proveOutgoingDoors(state, currentRun)
        if not proved then reportOutcome(session, state, errorValue) end
        if state.state == "synchronized" then room.close(state, currentRun, _G.GameState) end
        if state.state == "synchronized" then
            local ok, routeError = route.exit(state.route)
            if not ok then reportOutcome(session, state, routeError) end
        end
        if state.state == "synchronized" and route.expected(state.route) == nil then
            state.reason = "configured-prefix-complete"
        end
        local result = base(currentRun, door)
        report(runtime)
        return result
    end)
end

return hooks
