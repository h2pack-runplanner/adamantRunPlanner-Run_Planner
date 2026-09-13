-- ShipCombat phase and wheel realization. Native code owns wheel creation,
-- input, combat, pickup spawning, and between-phase readiness; this instance
-- only supplies the planner's resolved RNG outcomes and observes the click.
local thessaly = {}

local function wheelForPhase(active, phaseKey)
    for _, wheel in ipairs(active.occurrence.overview.rewardWheels or {}) do
        if wheel.phaseKey == phaseKey then return wheel end
    end
    return nil
end

local function wheelForKey(active, wheelKey)
    for _, wheel in ipairs(active.occurrence.overview.rewardWheels or {}) do
        if wheel.wheelKey == wheelKey then return wheel end
    end
end

function thessaly.create()
    local instance = {}
    local wheelScope
    local selectedRewardByState = setmetatable({}, { __mode = "k" })

    -- Navigation owns ChooseRoomReward/SetupRoomReward. This narrow context
    -- tells that existing reward boundary when the nested Ship wheel, rather
    -- than the room's incoming reward, is the active source.
    function instance.rewardContext() return wheelScope end

    -- The selected wheel remains the exact producer context until native
    -- SpawnRoomReward materializes its pickup after combat.
    function instance.takeRewardProducer(state, active)
        local selected = selectedRewardByState[state]
        if selected == nil or selected.active ~= active then return nil end
        selectedRewardByState[state] = nil
        return selected
    end

    -- SetupRoomMultipleEncountersData runs while CreateRoom is constructing
    -- the stamped destination, before any wheel or active-room session exists.
    -- The generic encounter hook asks for this one temporary declaration edit.
    function instance.preparePhases(state, room, nativeRoom)
        local data = type(nativeRoom) == "table" and nativeRoom.MultipleEncountersData or nil
        local first = state ~= nil and room.encounterAt(state, 1, nativeRoom) or nil
        local second = state ~= nil and room.encounterAt(state, 2, nativeRoom) or nil
        if state == nil or state.state ~= "synchronized" or first == nil or second == nil
            or type(data) ~= "table" or data[3] == nil then
            return function() end
        end
        local phaseCount = room.encounterAt(state, 3, nativeRoom) == nil and 2 or 3
        local third = data[3]
        local priorRequirements = third.GameStateRequirements
        if phaseCount == 2 then data[3] = nil else third.GameStateRequirements = nil end
        return function()
            data[3] = third
            third.GameStateRequirements = priorRequirements
        end
    end

    function instance.attach(module, session, getState, report, room)
        module.hooks.wrap("ShipsEncounterSetup", "run-planner-ship-wheel-realization", function(_, runtime,
            base, encounter, args)
            local state = getState(runtime)
            local active = room.current(state)
            local phase = active and room.encounterPhase(state, encounter)
            local wheel = phase and wheelForPhase(active, phase.slotKey) or nil
            if state == nil or state.state ~= "synchronized" or wheel == nil then
                return base(encounter, args)
            end
            room.window(state, "shipPreCombat:" .. wheel.wheelKey)
            local prior = wheelScope
            wheelScope = {
                prior = prior, state = state, active = active, wheel = wheel, offerIndex = 0,
                offerCountPending = true, currentOffer = nil,
            }
            local ok, result = pcall(base, encounter, args)
            wheelScope = prior
            if not ok then error(result, 0) end
            report(runtime)
            return result
        end)

        module.hooks.wrap("RandomChance", "run-planner-ship-wheel-count", function(_, _, base, chance, args)
            local scope = wheelScope
            if scope == nil or not scope.offerCountPending then return base(chance, args) end
            scope.offerCountPending = false
            return scope.wheel.offerCount == 2
        end)

        module.hooks.wrap("ChooseNextRewardStore", "run-planner-ship-wheel-store", function(_, _, base, ...)
            if wheelScope ~= nil then return wheelScope.wheel.storeKey end
            return base(...)
        end)

        module.hooks.wrap("CreateDoorRewardPreview", "run-planner-bind-ship-wheel", function(_, _, base,
            wheelObstacle, ...)
            local scope = wheelScope
            if scope ~= nil and type(wheelObstacle) == "table" and scope.currentOffer ~= nil then
                wheelObstacle.__runPlannerWheelKey = scope.wheel.wheelKey
                wheelObstacle.__runPlannerOfferKey = scope.currentOffer.offerKey
            end
            local result = base(wheelObstacle, ...)
            if wheelScope == scope and scope ~= nil and scope.offerIndex == #scope.wheel.offers then
                wheelScope = scope.prior
            end
            return result
        end)

        module.hooks.wrap("UseShipWheel", "run-planner-observe-ship-wheel", function(_, runtime, base, wheel)
            local state = getState(runtime)
            local active = state and room.current(state) or nil
            local wheelKey = type(wheel) == "table" and wheel.__runPlannerWheelKey or nil
            local selected = active and wheelKey and wheelForKey(active, wheelKey) or nil
            if state ~= nil and state.state == "synchronized" and selected ~= nil then
                local handle = room.resolve(state, active, {
                    kind = "rewardWheel", wheelKey = selected.wheelKey,
                })
                handle = handle and room.bind(state, active, handle, wheel) or nil
                local payload = handle and room.begin(state, handle) or nil
                local expected = payload and payload.transaction.pickedOfferKey
                local observed = type(wheel) == "table" and wheel.__runPlannerOfferKey or nil
                if handle ~= nil and payload ~= nil then
                    if expected ~= observed then
                        session.diagnostic(state, "ship-wheel-selection", observed)
                    end
                    session.complete(state, handle)
                    -- Publish before native notification can synchronously
                    -- resume the waiting ShipsEncounterSetup coroutine.
                    if room.window(state, "shipPostCombat:" .. selected.wheelKey) then
                        selectedRewardByState[state] = {
                            active = active, wheelKey = selected.wheelKey,
                        }
                    end
                end
            end
            local result = base(wheel)
            if selected ~= nil then report(runtime) end
            return result
        end)
    end

    return instance
end

return thessaly
