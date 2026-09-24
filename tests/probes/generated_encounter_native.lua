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
    local encounterPath, shrinePath = scriptsPath .. "/EncounterLogic.lua", scriptsPath .. "/ShrineLogic.lua"
    loadBody(read(encounterPath), "CalculateActiveEnemyCap", encounterPath)
    loadBody(read(shrinePath), "IsEliteAttributeEligible", shrinePath)
    local utilityPath = scriptsPath .. "/UtilityLogic.lua"
    loadBody(read(utilityPath), "OverwriteTableKeys", utilityPath)
end

function probe.loadRoomMultipleBody(scriptsPath)
    local path = scriptsPath .. "/RoomLogic.lua"
    local chunk, errorValue = load(body(read(path), "SetupRoomMultipleEncountersData"),
        "@" .. path .. ":SetupRoomMultipleEncountersData")
    assert(chunk, errorValue)
    chunk()
end

function probe.loadEliteAttributeBody(scriptsPath)
    local path = scriptsPath .. "/RoomLogic.lua"
    local chunk, errorValue = load(body(read(path), "PickEncounterEliteAttributes"),
        "@" .. path .. ":PickEncounterEliteAttributes")
    assert(chunk, errorValue)
    chunk()
end

function probe.loadEliteApplicationBody(scriptsPath)
    local path = scriptsPath .. "/ShrineLogic.lua"
    local chunk, errorValue = load(body(read(path), "ApplyEliteAttribute"),
        "@" .. path .. ":ApplyEliteAttribute")
    assert(chunk, errorValue)
    chunk()
end

function probe.loadSetupUnitBody(scriptsPath)
    local path = scriptsPath .. "/RoomLogic.lua"
    local chunk, errorValue = load(body(read(path), "SetupUnit"), "@" .. path .. ":SetupUnit")
    assert(chunk, errorValue)
    chunk()
end

function probe.loadNextSpawnBody(scriptsPath)
    local path = scriptsPath .. "/EncounterLogic.lua"
    for _, name in ipairs({ "HandleNextSpawn", "SpawnUnitGroup" }) do
        local chunk, errorValue = load(body(read(path), name), "@" .. path .. ":" .. name)
        assert(chunk, errorValue)
        chunk()
    end
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

return probe
