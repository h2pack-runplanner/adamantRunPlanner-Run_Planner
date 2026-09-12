-- Exact Fig Leaf phase-result steering. Native spawn handlers retain the
-- skip lifecycle, use consumption, and biome latch; this module only fixes
-- the one RandomChance call belonging to the named handler.
local figLeaf = {}
local unpackValues = table.unpack

local function packValues(...)
    return { n = select("#", ...), ... }
end

local function decision(room, state, encounter)
    if state == nil or state.state ~= "synchronized" or type(encounter) ~= "table" then return nil end
    local current = room.current(state)
    if current == nil or type(room.encounterPhase) ~= "function" then return nil end
    local phase = room.encounterPhase(state, encounter)
    if phase == nil or phase.figLeafSkip == nil then return nil end
    return { skip = phase.figLeafSkip }
end

function figLeaf.attach(module, getState, report, room)
    local mainThread = {}
    local active = setmetatable({}, { __mode = "k" })

    local function currentThread()
        return coroutine.running() or mainThread
    end

    local function currentScope()
        return active[currentThread()]
    end

    local function attachSpawnHandler(functionName, hookId)
        module.hooks.wrap(functionName, hookId, function(_, runtime, base, ...)
            local encounter = select(1, ...)
            local thread = currentThread()
            local prior = active[thread]
            active[thread] = decision(room, getState(runtime), encounter)
            local results = packValues(pcall(base, ...))
            local ok = results[1]
            active[thread] = prior
            if not ok then error(results[2], 0) end
            report(runtime)
            return unpackValues(results, 2, results.n)
        end)
    end

    attachSpawnHandler("HandleEncounterPreSpawns", "run-planner-fig-leaf-pre-spawns")
    attachSpawnHandler("HandleEnemySpawns", "run-planner-fig-leaf-enemy-spawns")

    module.hooks.wrap("IsTraitActive", "run-planner-fig-leaf-readiness", function(_, _, base, trait)
        local scope = currentScope()
        local results = packValues(base(trait))
        if scope ~= nil and type(trait) == "table" and trait.Name == "PersistentDionysusSkipKeepsake" then
            scope.pending = results[1] == true
            scope.armed = nil
        end
        return unpackValues(results, 1, results.n)
    end)

    module.hooks.wrap("GetTotalHeroTraitValue", "run-planner-fig-leaf-luck", function(_, _, base,
        propertyName, args)
        local scope = currentScope()
        local pending = scope ~= nil and scope.pending == true
        if scope ~= nil then scope.pending = nil end
        local results = packValues(base(propertyName, args))
        if pending and propertyName == "LuckMultiplier"
            and type(args) == "table" and args.IsMultiplier == true then
            scope.armed = true
        end
        return unpackValues(results, 1, results.n)
    end)

    module.hooks.wrap("RandomChance", "run-planner-fig-leaf-decision", function(_, _, base,
        chance, args, ...)
        local scope = currentScope()
        if scope ~= nil and scope.armed == true then
            local result = scope.skip
            scope.armed = false
            scope.pending = nil
            return result
        end
        if scope ~= nil then scope.pending = nil end
        return base(chance, args, ...)
    end)
end

return figLeaf
