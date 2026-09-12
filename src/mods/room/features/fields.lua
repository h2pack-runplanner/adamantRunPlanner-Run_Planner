-- Mourning Fields realization. Native code remains responsible for creating
-- cages, optional rewards, and encounters; this adapter only steers the
-- published point and reward choices for the active Fields room.
local fields = {}

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then return true end
    end
    return false
end

local function removeExpected(values, wanted)
    for index, value in ipairs(values or {}) do
        if value == wanted then
            table.remove(values, index)
            return wanted
        end
    end
    return nil
end

local function copyArgs(args)
    local result = {}
    for key, value in pairs(type(args) == "table" and args or {}) do result[key] = value end
    return result
end

local function scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return value end
    return nil
end

local function point(id, getLocation)
    local result = { id = scalar(id) }
    if result.id ~= nil then
        local location = getLocation({ Id = result.id })
        if type(location) == "table" then
            result.location = { X = scalar(location.X), Y = scalar(location.Y), Z = scalar(location.Z) }
        end
    end
    return result
end

local function reward(value)
    if type(value) ~= "table" then return { name = scalar(value) } end
    return {
        rewardType = scalar(value.rewardType or value.RewardType),
        source = scalar(value.source or value.ForceLootName),
        name = scalar(value.Name or value.LootName),
    }
end

local function object(id, value, getLocation)
    if type(value) ~= "table" then
        local objectId = scalar(id)
        return objectId ~= nil and { objectId = objectId } or nil
    end
    local objectId = scalar(value.ObjectId) or scalar(id)
    local result = {
        objectId = objectId,
        name = scalar(value.Name),
        spawnPointId = scalar(value.SpawnPointId),
        rewardId = scalar(value.RewardId),
    }
    if objectId ~= nil then result.location = point(objectId, getLocation).location end
    return result
end

local function sortedObjects(values, predicate, getLocation)
    local result = {}
    for id, value in pairs(values or {}) do
        if type(value) == "table" and predicate(value) then
            result[#result + 1] = object(id, value, getLocation)
        end
    end
    table.sort(result, function(left, right) return tostring(left.objectId) < tostring(right.objectId) end)
    return result
end

local function completedSnapshot(occurrence, nativeRoom, context)
    local layout = occurrence.overview.fields
    local getLocation = context.getLocation
    local priorRewards = context.cageRewards or {}
    local plannedCages, plannedOptional = {}, {}
    for index, cage in ipairs(layout.cagePoints or {}) do
        plannedCages[#plannedCages + 1] = {
            slotKey = scalar(cage.slotKey), point = point(cage.pointId, getLocation), reward = reward(priorRewards[index]),
        }
    end
    for _, optional in ipairs(layout.optionalRewards or {}) do
        plannedOptional[#plannedOptional + 1] = {
            slotKey = scalar(optional.slotKey), point = point(optional.pointId, getLocation), reward = reward(optional.reward),
        }
    end
    local optional = sortedObjects(context.optionalRewards, function() return true end, getLocation)
    local restores = type(nativeRoom.Encounter) == "table" and nativeRoom.Encounter.RewardsToRestore or {}
    for _, observed in ipairs(optional) do
        local restore = restores[observed.objectId]
        if type(restore) == "table" then
            observed.restore = {
                rewardType = scalar(restore.RewardOverride), spawnPointId = scalar(restore.SpawnRewardOnId),
            }
        end
    end
    local cages = sortedObjects(context.activeObstacles, function(value)
        return value.Name == "FieldsRewardCage"
    end, getLocation)
    for _, cage in ipairs(cages) do
        local nativeReward = (context.lootObjects and context.lootObjects[cage.rewardId])
            or (context.activeObstacles and context.activeObstacles[cage.rewardId])
        cage.reward = object(cage.rewardId, nativeReward, getLocation)
    end
    local nemesis = context.sessionMapState and context.sessionMapState.Nemesis
    return {
        planned = {
            entryPair = {
                startPoint = point(layout.entryPair and layout.entryPair.startPointId, getLocation),
                endPoint = point(layout.entryPair and layout.entryPair.endPointId, getLocation),
            },
            cages = plannedCages, optionalRewards = plannedOptional,
            nemesisPoint = point(layout.nemesisPointId, getLocation),
        },
        observed = {
            entryPair = {
                startPoint = point(nativeRoom.HeroStartPoint, getLocation),
                endPoint = point(nativeRoom.HeroEndPoint, getLocation),
            },
            cages = cages,
            optionalRewards = optional,
            nemesis = object(nemesis and nemesis.ObjectId, nemesis, getLocation),
        },
    }
end

function fields.realize(nativeRoom, layout)
    if type(nativeRoom) ~= "table" or type(layout) ~= "table" then return nativeRoom end
    nativeRoom.HeroStartPoint = layout.entryPair.startPointId
    nativeRoom.HeroEndPoint = layout.entryPair.endPointId
    -- DoUnlockRoomExits normally uses this declaration field to generate a
    -- fresh random CageRewards array for every Fields target. The planned
    -- payload is already installed on the door by navigation, so remove only
    -- this target-local trigger while retaining the native door setup and
    -- reward-store flow.
    nativeRoom.MaxCageRewards = nil
    return nativeRoom
end

function fields.attach(module, session, getState, report, room)
    local active
    local activeNemesis

    local function currentLayout(state, nativeRoom)
        if state == nil or state.state ~= "synchronized" then return nil end
        local current = room.current(state)
        local occurrence = current and current.occurrence
        if occurrence == nil or type(occurrence.overview) ~= "table" then return nil end
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if id ~= nil and id ~= occurrence.id then return nil end
        return occurrence.overview.fields
    end

    local function currentOccurrence(state, nativeRoom)
        if currentLayout(state, nativeRoom) == nil then return nil end
        local current = room.current(state)
        return current and current.occurrence
    end

    local function cageRewards(state, occurrence)
        local prior = state and state.route and state.route.lastExitedOccurrence
        for _, target in ipairs(prior and prior.doors and prior.doors.targets or {}) do
            if target.room and target.room.id == occurrence.id then return target.cageRewards end
        end
        return nil
    end

    module.hooks.wrap("RemoveRandomValue", "run-planner-fields-point-selection", function(_, runtime, base,
        values, ...)
        local scope = active
        if scope == nil then return base(values, ...) end

        local expected
        local cage = scope.cagePoints[scope.cageIndex + 1]
        if cage ~= nil and contains(values, cage.pointId) then
            expected = cage.pointId
            scope.cageIndex = scope.cageIndex + 1
        elseif scope.cageIndex == #scope.cagePoints then
            local optional = scope.optionalRewards[scope.optionalPointIndex + 1]
            if optional ~= nil and contains(values, optional.pointId) then
                expected = optional.pointId
                scope.optionalPointIndex = scope.optionalPointIndex + 1
            end
        end
        if expected == nil then return base(values, ...) end
        local result = removeExpected(values, expected)
        if result == nil then
            session.diagnostic(getState(runtime), "fields-point", { expected = expected, observed = nil })
            return base(values, ...)
        end
        return result
    end)

    module.hooks.wrap("RandomChance", "run-planner-fields-optional-count", function(_, _runtime, base,
        chance, args, ...)
        local scope = active
        local chanceIndex = scope and scope.chanceIndex + 1 or nil
        local expectedChance = chanceIndex and scope.chances[chanceIndex] or nil
        if expectedChance == nil or chance ~= expectedChance then return base(chance, args, ...) end
        scope.chanceIndex = chanceIndex
        scope.optionalChanceResults = scope.optionalChanceResults + 1
        return scope.optionalChanceResults <= #scope.optionalRewards
    end)

    module.hooks.wrap("IsRoomRewardEligible", "run-planner-fields-optional-reward", function(_, _runtime,
        base, run, nativeRoom, candidate, previouslyChosen, args)
        local scope = active
        local expected = scope and scope.expectedReward
        if expected ~= nil and type(candidate) == "table" then
            return (candidate.Name or candidate.RewardType) == expected.reward.rewardType
        end
        return base(run, nativeRoom, candidate, previouslyChosen, args)
    end)

    module.hooks.wrap("ChooseRoomReward", "run-planner-fields-optional-choice", function(_, runtime, base,
        run, nativeRoom, rewardStore, chosen, args)
        local scope = active
        if scope == nil or rewardStore ~= scope.bonusRewardStore then
            return base(run, nativeRoom, rewardStore, chosen, args)
        end
        local expected = scope.optionalRewards[scope.rewardIndex + 1]
        if expected == nil then return base(run, nativeRoom, rewardStore, chosen, args) end
        scope.rewardIndex = scope.rewardIndex + 1
        scope.pendingReward = expected
        local prior = scope.expectedReward
        scope.expectedReward = expected
        local ok, result = pcall(base, run, nativeRoom, rewardStore, chosen, args)
        scope.expectedReward = prior
        if not ok then
            scope.pendingReward = nil
            error(result, 0)
        end
        local observed = type(result) == "table" and (result.Name or result.RewardType) or result
        if observed ~= expected.reward.rewardType then
            session.diagnostic(runtime and getState(runtime), "fields-optional-reward", {
                expected = expected.reward.rewardType, observed = observed,
            })
        end
        return result
    end)

    module.hooks.wrap("SpawnRoomReward", "run-planner-fields-optional-spawn", function(_, _, base,
        eventSource, args)
        local scope = active
        local expected = scope and scope.pendingReward
        local forcedArgs = args
        if expected ~= nil and expected.reward.source ~= nil then
            forcedArgs = copyArgs(args)
            forcedArgs.LootName = expected.reward.source
        end
        local ok, result = pcall(base, eventSource, forcedArgs)
        if scope ~= nil and expected ~= nil then scope.pendingReward = nil end
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("SpawnRewardCages", "run-planner-fields-spawn", function(_, runtime, base, nativeRoom,
        args)
        local state = getState(runtime)
        local layout = currentLayout(state, nativeRoom)
        if layout == nil then return base(nativeRoom, args) end
        local scope = {
            cagePoints = layout.cagePoints or {},
            optionalRewards = layout.optionalRewards or {},
            chances = type(nativeRoom) == "table" and nativeRoom.OptionalRewardChances or {},
            cageIndex = 0,
            optionalPointIndex = 0,
            chanceIndex = 0,
            optionalChanceResults = 0,
            rewardIndex = 0,
            pendingReward = nil,
            bonusRewardStore = type(nativeRoom) == "table" and nativeRoom.BonusRewardStoreName or nil,
        }
        local prior = active
        active = scope
        local ok, result = pcall(base, nativeRoom, args)
        active = prior
        if not ok then error(result, 0) end
        if scope.cageIndex ~= #scope.cagePoints
            or scope.optionalPointIndex ~= #scope.optionalRewards
            or scope.rewardIndex ~= #scope.optionalRewards then
            session.diagnostic(state, "fields-spawn", {
                expected = { cages = #scope.cagePoints, optional = #scope.optionalRewards },
                observed = {
                cages = scope.cageIndex, optionalPoints = scope.optionalPointIndex,
                optionalRewards = scope.rewardIndex,
                },
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnNemesisForRandomEvents", "run-planner-fields-nemesis-scope", function(_, runtime,
        base, source, args)
        local state = getState(runtime)
        local layout = currentLayout(state, _G.CurrentRun and _G.CurrentRun.CurrentRoom)
        if layout == nil or layout.nemesisPointId == nil then return base(source, args) end
        local prior = activeNemesis
        activeNemesis = { pointId = layout.nemesisPointId, used = false }
        local ok, result = pcall(base, source, args)
        local used = activeNemesis.used
        activeNemesis = prior
        if not ok then error(result, 0) end
        if not used then
            session.diagnostic(state, "fields-nemesis-point", {
                expected = layout.nemesisPointId, observed = nil,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SelectSpawnPoint", "run-planner-fields-nemesis-point", function(_, _runtime, base,
        currentRoom, unit, source, args, depth)
        local scope = activeNemesis
        if scope == nil or scope.pointId == nil then
            return base(currentRoom, unit, source, args, depth)
        end
        if scope.used then return base(currentRoom, unit, source, args, depth) end
        scope.used = true
        return scope.pointId
    end)

    module.hooks.wrap("StartRoomPresentation", "run-planner-fields-completed-product", function(_, runtime,
        base, currentRun, nativeRoom, ...)
        local state = getState(runtime)
        local occurrence = currentOccurrence(state, nativeRoom)
        if occurrence ~= nil then
            session.diagnostic(state, "fields-completed-product", completedSnapshot(occurrence, nativeRoom, {
                cageRewards = cageRewards(state, occurrence),
                activeObstacles = _G.MapState and _G.MapState.ActiveObstacles,
                optionalRewards = _G.MapState and _G.MapState.OptionalRewards,
                lootObjects = _G.LootObjects,
                sessionMapState = _G.SessionMapState,
                getLocation = _G.GetLocation,
            }))
            report(runtime)
        end
        return base(currentRun, nativeRoom, ...)
    end)
end

return fields
