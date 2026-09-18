-- Opt-in source probe support for generated encounter contacts. This never
-- runs through tests/all.lua: callers supply a local Hades II Scripts path.
local probe = {}
local nativeGame = require("tests.harness.native_game")

local function read(path)
    local handle, errorValue = io.open(path, "r")
    assert(handle, "cannot read native source " .. path .. ": " .. tostring(errorValue))
    local result = handle:read("*a")
    handle:close()
    return result
end

local function body(source, name)
    local startAt = assert(source:find("function " .. name .. "%s*%(", 1),
        "native source does not define " .. name)
    local nextAt = source:find("\nfunction ", startAt + 1)
    return source:sub(startAt, nextAt and nextAt - 1 or #source)
end

function probe.scriptsPath(argument)
    local path = argument or os.getenv("HADES2_SCRIPTS_PATH")
    assert(type(path) == "string" and path ~= "", "supply HADES2_SCRIPTS_PATH or a Scripts directory argument")
    return path:gsub("/$", "")
end

-- Load selected, unmodified top-level native function bodies. Reading source
-- at execution time avoids copying proprietary code into this repository.
function probe.loadBodies(scriptsPath)
    local runPath, rewardPath = scriptsPath .. "/RunLogic.lua", scriptsPath .. "/RewardLogic.lua"
    local runSource, rewardSource = read(runPath), read(rewardPath)
    local function loadBody(source, name, path)
        local chunk, errorValue = load(body(source, name), "@" .. path .. ":" .. name)
        assert(chunk, errorValue)
        chunk()
    end
    for _, name in ipairs({
        "ChooseEncounter", "SetupEncounter", "GenerateEncounter", "FillEnemyTypes",
        "AddToSpawnTable", "CalculateEnemyDifficultyRating", "FillEnemyCounts", "IsEnemyEligible",
    }) do loadBody(runSource, name, runPath) end
    loadBody(rewardSource, "SetupRoomReward", rewardPath)
end

function probe.loadRoomMultipleBody(scriptsPath)
    local path = scriptsPath .. "/RoomLogic.lua"
    local chunk, errorValue = load(body(read(path), "SetupRoomMultipleEncountersData"),
        "@" .. path .. ":SetupRoomMultipleEncountersData")
    assert(chunk, errorValue)
    chunk()
end

function probe.copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[probe.copy(key, seen)] = probe.copy(item, seen) end
    return result
end

probe.restore = nativeGame.install

-- This maps the actual FillEnemyCounts branch before it mutates the wave:
-- its comparison deliberately uses spawn-array index versus generated count,
-- matching the inspected native body (not a generated-entry ordinal).
local function countSampleBranches(wave)
    local generatedCount, result = 0, {}
    for _, spawn in ipairs(wave.Spawns) do
        local fixed = not spawn.Generated and ((spawn.CountMin and spawn.CountMax) or spawn.TotalCount)
        if not fixed then generatedCount = generatedCount + 1 end
    end
    for index, spawn in ipairs(wave.Spawns) do
        local generated = spawn.Generated or not ((spawn.CountMin and spawn.CountMax) or spawn.TotalCount)
        if generated and spawn.TotalCount == nil and index ~= generatedCount then
            result[#result + 1] = { index = index, enemyName = spawn.Name }
        end
    end
    return result
end

-- Test-only boundary instrumentation. A scope starts only at SetupEncounter
-- and follows the copied encounter through GenerateEncounter and its two fill
-- calls. No state survives a synchronous call; raw RNG arguments never select
-- an override without this owner + encounter + wave identity.
function probe.installContacts()
    local native = {}
    for _, name in ipairs({ "SetupEncounter", "GenerateEncounter", "FillEnemyTypes", "FillEnemyCounts", "IsEnemyEligible", "RemoveRandomValue", "RandomNormal" }) do
        native[name] = assert(_G[name], "probe requires " .. name)
    end
    local stack = {}
    local function current() return stack[#stack] end
    local function push(value, action)
        stack[#stack + 1] = value
        local ok, result = pcall(action)
        stack[#stack] = nil
        if not ok then error(result, 0) end
        return result
    end
    local contacts = {}
    function contacts.withOwner(owner, action)
        assert(type(owner) == "table" and owner.occurrence and owner.phase and owner.nativeRoom and owner.encounterKey,
            "probe owner requires occurrence, phase, destination and concrete encounter")
        return push({ kind = "preparation", owner = owner }, action)
    end
    function contacts.current() return current() end
    _G.SetupEncounter = function(encounterData, room)
        local parent = current()
        if parent == nil or parent.kind ~= "preparation" or parent.owner.encounterKey ~= encounterData.Name then
            return push({ kind = "native" }, function() return native.SetupEncounter(encounterData, room) end)
        end
        return push({ kind = "setup", owner = parent.owner }, function()
            return native.SetupEncounter(encounterData, room)
        end)
    end
    _G.GenerateEncounter = function(currentRun, room, encounter)
        local parent = current()
        if parent == nil or parent.kind ~= "setup" or parent.owner.encounterKey ~= encounter.Name then
            return push({ kind = "native" }, function() return native.GenerateEncounter(currentRun, room, encounter) end)
        end
        local owner = parent.owner
        if owner.waveCount then encounter.MinWaves, encounter.MaxWaves = owner.waveCount, owner.waveCount end
        local scope = { kind = "generate", owner = owner, encounter = encounter, nativeRoom = room }
        owner.generations = owner.generations or {}
        owner.generations[#owner.generations + 1] = scope
        return push(scope, function() return native.GenerateEncounter(currentRun, room, encounter) end)
    end
    _G.FillEnemyTypes = function(encounter, wave, room)
        local parent = current()
        if parent == nil or parent.kind ~= "generate" or parent.encounter ~= encounter
            or encounter.SpawnWaves[wave.WaveIndex] ~= wave then
            return push({ kind = "native" }, function() return native.FillEnemyTypes(encounter, wave, room) end)
        end
        local names = (parent.owner.typesByWave or {})[wave.WaveIndex]
        -- Only the unseeded random-count branch accepts a list-sized target;
        -- escalation and preassigned highlight counts remain native.
        if names and not encounter.EscalateTypeCount and wave.TypeCount == nil then
            local named = 0
            for _, spawn in ipairs(wave.Spawns) do if spawn.Name then named = named + 1 end end
            wave.TypeCount = named + #names
        end
        return push({ kind = "types", owner = parent.owner, encounter = encounter, wave = wave }, function()
            return native.FillEnemyTypes(encounter, wave, room)
        end)
    end
    _G.FillEnemyCounts = function(encounter, wave, room)
        local parent = current()
        if parent == nil or parent.kind ~= "generate" or parent.encounter ~= encounter
            or encounter.SpawnWaves[wave.WaveIndex] ~= wave then
            return push({ kind = "native" }, function() return native.FillEnemyCounts(encounter, wave, room) end)
        end
        return push({
            kind = "counts", owner = parent.owner, encounter = encounter, wave = wave,
            samples = countSampleBranches(wave), sampleIndex = 0,
        }, function() return native.FillEnemyCounts(encounter, wave, room) end)
    end
    _G.IsEnemyEligible = function(enemyName, encounter, wave)
        local result = native.IsEnemyEligible(enemyName, encounter, wave)
        local scope = current()
        if scope and scope.kind == "generate" and scope.encounter == encounter
            and wave == encounter.SpawnWaves[1] and wave.TypeCount == 1 and #wave.Spawns == 0 then
            scope.highlightReady = true
        end
        return result
    end
    _G.RemoveRandomValue = function(values)
        local scope, owner = current(), current() and current().owner
        local requested
        if scope and scope.kind == "generate" and scope.highlightReady then
            requested, scope.highlightReady = owner.highlight, false
        elseif scope and scope.kind == "types" then
            scope.typeIndex = (scope.typeIndex or 0) + 1
            local names = (owner.typesByWave or {})[scope.wave.WaveIndex]
            requested = names and names[scope.typeIndex]
        end
        if requested == nil then return native.RemoveRandomValue(values) end
        for index, candidate in ipairs(values) do
            if candidate == requested then
                table.remove(values, index)
                owner.removes = owner.removes or {}
                owner.removes[#owner.removes + 1] = {
                    occurrenceId = owner.occurrence.id, phase = owner.phase.slotKey,
                    wave = scope.wave and scope.wave.WaveIndex or 0, enemyName = requested,
                }
                return requested
            end
        end
        if owner.onIneligible then owner.onIneligible(scope, requested) end
        return native.RemoveRandomValue(values)
    end
    _G.RandomNormal = function(mean, deviation)
        local scope, owner = current(), current() and current().owner
        if scope == nil or scope.kind ~= "counts" then return native.RandomNormal(mean, deviation) end
        scope.sampleIndex = scope.sampleIndex + 1
        local branch = scope.samples[scope.sampleIndex]
        if branch == nil then return native.RandomNormal(mean, deviation) end
        local requested = owner.slicesByEnemy and owner.slicesByEnemy[branch.enemyName]
        if requested == nil then return native.RandomNormal(mean, deviation) end
        owner.samples = owner.samples or {}
        owner.samples[#owner.samples + 1] = {
            occurrenceId = owner.occurrence.id, phase = owner.phase.slotKey, wave = scope.wave.WaveIndex,
            spawnIndex = branch.index, enemyName = branch.enemyName, mean = mean, deviation = deviation,
            requested = requested,
        }
        return requested
    end
    function contacts.restore() for name, value in pairs(native) do _G[name] = value end end
    return contacts
end

return probe
