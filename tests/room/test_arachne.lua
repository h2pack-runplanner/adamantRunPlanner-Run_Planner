-- luacheck: globals TestArachne
local lu = require("luaunit")
local arachne = require("mods.room.timeline.encounters.arachne")

TestArachne = {}

local function attach(phase, encounter, state)
    local callbacks, diagnostics = {}, {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local session = {
        diagnostic = function(_, checkpoint, observed)
            diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed }
        end,
    }
    arachne.attach(module, session, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks, diagnostics
end

local function combatPhase(count)
    return {
        slotKey = "Encounter", encounterKey = "ArachneCombatF", kind = "combat",
        customization = count and { { decisionKey = "cocoonCount", kind = "cocoonCount", count = count } } or nil,
    }
end

local function nativeArgs()
    return {
        CocoonCountMin = 8, CocoonCountMax = 14, RequiredSpawnPointType = "EnemyPoint",
        CocoonOptions = { "ArachneCocoon_G", "ArachneCocoonMedium_G", "ArachneCocoonLarge_G" },
    }
end

-- Mirrors SetupArachneCombatEncounter/SpawnArachneCocoons: one RandomInt draw from the
-- supplied bounds, native placement up to the available points, then reward selection.
local function nativeSetup(draws, points, rewardPicks)
    return function(eventSource, args)
        local function randomInt(minimum, maximum)
            draws[#draws + 1] = { minimum = minimum, maximum = maximum, args = args }
            return maximum
        end
        local count = randomInt(args.CocoonCountMin or eventSource.CocoonCountMin,
            args.CocoonCountMax or eventSource.CocoonCountMax)
        local ids = {}
        for index = 1, math.min(count, points) do
            ids[index] = 100 + index
            _G.CurrentRun.CurrentRoom.CoocoonIds = ids
        end
        rewardPicks[#rewardPicks + 1] = { options = args.CocoonOptions, ids = _G.CurrentRun.CurrentRoom.CoocoonIds }
        if _G.CurrentRun.CurrentRoom.CoocoonIds == nil then error("native reward cocoon missing", 0) end
        return "native"
    end
end

local function withRoom(callback)
    local prior = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Name = "G_Combat10" } }
    local ok, result = pcall(callback)
    _G.CurrentRun = prior
    if not ok then error(result, 0) end
    return result
end

function TestArachne.testOnlyCombatSetupIsWrapped()
    local callbacks = attach(combatPhase(11), {}, { state = "synchronized" })
    local names = {}
    for name in pairs(callbacks) do names[#names + 1] = name end
    -- Story cocoons call SpawnArachneCocoons directly and never reach this setup.
    lu.assertEquals(names, { "SetupArachneCombatEncounter" })
end

function TestArachne.testRequestedCountDrawsWithEqualBoundsFromAPrivateCopy()
    withRoom(function()
        local encounter = {}
        local callbacks, diagnostics = attach(combatPhase(11), encounter, { state = "synchronized" })
        local draws, picks, args = {}, {}, nativeArgs()
        local result = callbacks.SetupArachneCombatEncounter(nil, {}, nativeSetup(draws, 20, picks), encounter, args)
        lu.assertEquals(result, "native")
        lu.assertEquals(#draws, 1)
        lu.assertEquals({ draws[1].minimum, draws[1].maximum }, { 11, 11 })
        lu.assertFalse(rawequal(draws[1].args, args))
        lu.assertTrue(rawequal(draws[1].args.CocoonOptions, args.CocoonOptions))
        lu.assertEquals(draws[1].args.RequiredSpawnPointType, "EnemyPoint")
        lu.assertEquals({ args.CocoonCountMin, args.CocoonCountMax }, { 8, 14 })
        lu.assertEquals(#picks[1].ids, 11)
        lu.assertEquals(diagnostics, {})
    end)
end

function TestArachne.testDefaultAndUnsynchronizedSetupStayNative()
    withRoom(function()
        for _, case in ipairs({
            { phase = combatPhase(nil), state = { state = "synchronized" } },
            { phase = combatPhase(11), state = { state = "desynchronized" } },
            { phase = combatPhase(11), state = nil },
        }) do
            local encounter = {}
            local callbacks, diagnostics = attach(case.phase, encounter, case.state)
            local draws, picks, args = {}, {}, nativeArgs()
            callbacks.SetupArachneCombatEncounter(nil, {}, nativeSetup(draws, 20, picks), encounter, args)
            lu.assertTrue(rawequal(draws[1].args, args))
            lu.assertEquals({ draws[1].minimum, draws[1].maximum }, { 8, 14 })
            lu.assertEquals(diagnostics, {})
        end
    end)
end

function TestArachne.testUnboundEncounterStaysNative()
    withRoom(function()
        local callbacks = attach(combatPhase(11), {}, { state = "synchronized" })
        local draws, picks, args = {}, {}, nativeArgs()
        callbacks.SetupArachneCombatEncounter(nil, {}, nativeSetup(draws, 20, picks), {}, args)
        lu.assertTrue(rawequal(draws[1].args, args))
    end)
end

function TestArachne.testCountOutsideNativeBoundsDeclinesWithDiagnostic()
    withRoom(function()
        local encounter = {}
        local callbacks, diagnostics = attach(combatPhase(15), encounter, { state = "synchronized" })
        local draws, picks, args = {}, {}, nativeArgs()
        callbacks.SetupArachneCombatEncounter(nil, {}, nativeSetup(draws, 20, picks), encounter, args)
        lu.assertTrue(rawequal(draws[1].args, args))
        lu.assertEquals(diagnostics, { {
            checkpoint = "arachne-cocoon-count",
            observed = {
                reason = "outside-native-range", encounterKey = "ArachneCombatF",
                requested = 15, minimum = 8, maximum = 14,
            },
        } })
    end)
end

function TestArachne.testPlacementShortfallStaysNativeWithDiagnostic()
    withRoom(function()
        local encounter = {}
        local callbacks, diagnostics = attach(combatPhase(12), encounter, { state = "synchronized" })
        local draws, picks = {}, {}
        callbacks.SetupArachneCombatEncounter(nil, {}, nativeSetup(draws, 9, picks), encounter, nativeArgs())
        lu.assertEquals(#picks[1].ids, 9)
        lu.assertEquals(diagnostics, { {
            checkpoint = "arachne-cocoon-count",
            observed = { reason = "placement-shortfall", encounterKey = "ArachneCombatF", requested = 12, placed = 9 },
        } })
    end)
end

function TestArachne.testZeroPlacementKeepsNativeErrorAfterDiagnostic()
    withRoom(function()
        local encounter = {}
        local callbacks, diagnostics = attach(combatPhase(8), encounter, { state = "synchronized" })
        local ok, errorValue = pcall(callbacks.SetupArachneCombatEncounter, nil, {},
            nativeSetup({}, 0, {}), encounter, nativeArgs())
        lu.assertFalse(ok)
        lu.assertEquals(errorValue, "native reward cocoon missing")
        lu.assertEquals(diagnostics, { {
            checkpoint = "arachne-cocoon-count",
            observed = {
                reason = "setup-error", encounterKey = "ArachneCombatF", requested = 8, placed = 0,
                error = "native reward cocoon missing",
            },
        } })
    end)
end
