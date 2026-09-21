-- D1 encounter ownership and identity witnesses.
-- luacheck: globals TestEncounters
local lu = require("luaunit")
local bindings = require("mods.room.timeline.bindings")
local lifecycle = require("mods.room.timeline.lifecycle")
local phases = require("mods.room.timeline.encounters.phases").create()
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local boss = require("mods.room.timeline.encounters.boss")

TestEncounters = {}

local function capture()
    local callbacks = {}
    return {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }, callbacks
end

function TestEncounters.testNativeEncounterObjectsBindDuplicateNamesToDifferentPhases()
    local first, second = {}, {}
    local occurrence = {
        id = "room",
        overview = { encounterPhases = {
            { slotKey = "first", encounterKey = "SameEncounter" },
            { slotKey = "second", encounterKey = "SameEncounter" },
        } },
    }
    lu.assertEquals(phases.bind(occurrence, first, "first").slotKey, "first")
    lu.assertEquals(phases.bind(occurrence, second, "second").slotKey, "second")
    lu.assertEquals(phases.forNative(first).phase.slotKey, "first")
    lu.assertEquals(phases.forNative(second).phase.slotKey, "second")
    lu.assertNotEquals(phases.forNative(first).phase, phases.forNative(second).phase)
end

function TestEncounters.testCreatedPhaseRegistriesDoNotShareNativeBindings()
    local other = require("mods.room.timeline.encounters.phases").create()
    local native = {}
    local occurrence = {
        id = "room",
        overview = { encounterPhases = { { slotKey = "first", encounterKey = "Encounter" } } },
    }
    lu.assertNotNil(phases.bind(occurrence, native, "first"))
    lu.assertNil(other.forNative(native))
end

function TestEncounters.testUnmodeledCarrierProofUsesPublishedNativeIdentity()
    local occurrence = { overview = { unmodeledEncounterKeys = { "Empty" }, encounterPhases = {} } }
    lu.assertTrue(phases.prove(occurrence, { Encounter = { Name = "Empty" } }))

    local result, mismatch = phases.prove(occurrence, { Encounter = { Name = "Shop" } })
    lu.assertNil(result)
    lu.assertEquals(mismatch, { kind = "encounter", expected = "Empty", observed = "Shop" })
end

function TestEncounters.testNoPublishedNativeCarrierRequiresNoNativeEncounter()
    local occurrence = { overview = { encounterPhases = {} } }
    lu.assertTrue(phases.prove(occurrence, {}))

    local result, mismatch = phases.prove(occurrence, { Encounter = { Name = "Empty" } })
    lu.assertNil(result)
    lu.assertEquals(mismatch, { kind = "encounterCount", expected = 0, observed = 1 })
end

function TestEncounters.testEncounterPhaseSurfaceMismatchesRemainDistinctFromBindingFaults()
    local occurrence = {
        id = "room",
        overview = { encounterPhases = {
            { slotKey = "first", encounterKey = "First" },
            { slotKey = "second", encounterKey = "Second" },
        } },
    }
    local registry = require("mods.room.timeline.encounters.phases").create()
    local countOk, countError = registry.prove(occurrence, { Encounter = { Name = "First" } })
    lu.assertNil(countOk)
    lu.assertEquals(countError.kind, "encounterCount")
    lu.assertNil(countError.outcome)

    local native = { Name = "First" }
    lu.assertNotNil(registry.bind(occurrence, native, "first"))
    local bound, bindingError = registry.bind(occurrence, native, "second")
    lu.assertNil(bound)
    lu.assertEquals(bindingError.outcome, "fault")
    lu.assertEquals(bindingError.checkpoint, "encounter-binding")
end

function TestEncounters.testPublishedEmptyPhaseRemainsAnExactNativeEncounter()
    local occurrence = {
        overview = {
            encounterPhases = { { slotKey = "Encounter", encounterKey = "Empty" } },
        },
    }
    lu.assertTrue(phases.prove(occurrence, { Encounter = { Name = "Empty" } }))

    local result, mismatch = phases.prove(occurrence, {})
    lu.assertNil(result)
    lu.assertEquals(mismatch, { kind = "encounterCount", expected = 1, observed = 0 })
end

function TestEncounters.testRoomEntryProofRebindsTheCanonicalEncounterAfterMapLoad()
    local registry = require("mods.room.timeline.encounters.phases").create()
    local occurrence = {
        id = "room",
        overview = {
            encounterPhases = { { slotKey = "Encounter", encounterKey = "GeneratedN_Bigger" } },
        },
    }
    local selectedBeforeTransition = { Name = "GeneratedN_Bigger" }
    local canonicalAfterLoad = { Name = "GeneratedN_Bigger" }

    lu.assertNotNil(registry.bind(occurrence, selectedBeforeTransition, "Encounter"))
    lu.assertTrue(registry.prove(occurrence, { Encounter = canonicalAfterLoad }))
    lu.assertEquals(registry.forNative(canonicalAfterLoad), {
        occurrenceId = "room",
        phase = occurrence.overview.encounterPhases[1],
    })
end

function TestEncounters.testFieldsEntryBindsPassiveAndCagesAfterMapLoad()
    local registry = require("mods.room.timeline.encounters.phases").create()
    local occurrence = {
        id = "fields", overview = { encounterPhases = {
            { slotKey = "Passive", encounterKey = "GeneratedH_PassiveSmall" },
            { slotKey = "Cage01", encounterKey = "GeneratedH" },
            { slotKey = "Cage02", encounterKey = "GeneratedH" },
        } },
    }
    local native = {
        Encounter = { Name = "GeneratedH_PassiveSmall" },
        CageRewards = {
            { Encounter = { Name = "GeneratedH" } },
            { Encounter = { Name = "GeneratedH" } },
        },
    }
    for _, phase in ipairs(occurrence.overview.encounterPhases) do
        lu.assertNotNil(registry.bind(occurrence, { Name = phase.encounterKey }, phase.slotKey))
    end
    -- Entry and completed-setup proofs must both bind the restored carriers.
    for _ = 1, 2 do
        lu.assertTrue(registry.prove(occurrence, native))
        lu.assertEquals(registry.forNative(native.Encounter).phase.slotKey, "Passive")
        for index, reward in ipairs(native.CageRewards) do
            lu.assertIs(registry.forNative(reward.Encounter).phase, occurrence.overview.encounterPhases[index + 1])
        end
    end
    lu.assertNil(native.Encounters)
    native.CageRewards[2].Encounter = { Name = "WrongEncounter" }
    local ok, mismatch = registry.prove(occurrence, native)
    lu.assertNil(ok)
    lu.assertEquals(mismatch.kind, "encounter")
    lu.assertEquals(mismatch.observed, "WrongEncounter")
    native.CageRewards[2].Encounter = nil
    ok, mismatch = registry.prove(occurrence, native)
    lu.assertNil(ok)
    lu.assertEquals(mismatch.kind, "encounter")
end

function TestEncounters.testBossArcanaAdmitsAnExactEternityOutcome()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local phase = { slotKey = "phase", encounterKey = "BossEncounter" }
    local active = { occurrence = { overview = { encounterPhases = { phase } } } }
    local handle = {}
    local completed = 0
    local room = {
        current = function() return active end,
        encounterPhase = function() return phase end,
        window = function() return true end,
        resolve = function(_, _, contact)
            if contact.kind == "automatic" and contact.effect == "judgment" then return handle end
        end,
        begin = function()
            return { transaction = { arcanaKeys = { "CastCount" } } }
        end,
    }
    local session = {
        mismatch = function() error("unexpected mismatch") end,
        complete = function(_, observed)
            lu.assertEquals(observed, handle)
            completed = completed + 1
        end,
    }
    boss.attach(module, session, function() return state end, function() end, room)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = {} } }
    local selected
    local nativeChanceCalls = 0
    callbacks.Kill(nil, {}, function()
        callbacks.AddRandomMetaUpgrades(nil, {}, function()
            local candidates = { "ChanneledCast" }
            if callbacks.RandomChance(nil, {}, function()
                nativeChanceCalls = nativeChanceCalls + 1
                return false
            end, 0.1) then
                candidates[#candidates + 1] = "CastCount"
            end
            selected = callbacks.RemoveRandomValue(nil, {}, function(values)
                return table.remove(values, 1)
            end, candidates)
        end, 1, {})
    end, { IsBoss = true }, {})
    _G.CurrentRun = priorRun
    lu.assertEquals(selected, "CastCount")
    lu.assertEquals(nativeChanceCalls, 0)
    lu.assertEquals(completed, 1)
end

function TestEncounters.testRewardSetupTrialsBindAtEntryWithoutChooseEncounter()
    for _, biome in ipairs({ "F", "G", "I" }) do
        local registry = require("mods.room.timeline.encounters.phases").create()
        local phase = { slotKey = "Encounter", encounterKey = "DevotionTest" .. biome, kind = "combat" }
        local occurrence = { id = "trial-" .. biome, overview = { encounterPhases = { phase } } }
        -- SetupRoomReward creates this encounter directly, outside ChooseEncounter.
        local native = { Name = phase.encounterKey }
        lu.assertTrue(registry.prove(occurrence, { Encounter = native }))
        lu.assertEquals(registry.forNative(native).phase, phase)

        local module, callbacks = capture()
        local state = { state = "synchronized" }
        local windows = {}
        local room = {
            encounterPhase = function(_, encounter)
                local bound = registry.forNative(encounter)
                return bound and bound.phase
            end,
            encounterIsFinal = function(_, encounter)
                return registry.isFinal(occurrence, registry.forNative(encounter).phase)
            end,
            window = function(_, key) windows[#windows + 1] = key end,
        }
        encounterHooks.attach(module, {}, function() return state end, function() end, room)
        lu.assertEquals(callbacks.EndEncounterEffects(nil, {}, function() return "native" end,
            {}, { Encounter = native }, native), "native")
        lu.assertEquals(windows, { "encounterEnd:Encounter", "afterCombat" })
    end
end

function TestEncounters.testPhaseIsNotAStandaloneTimelineContactNamespace()
    local occurrence = {
        overview = { encounterPhases = {} },
        transactionsByOwner = {
            interaction = {
                owner = "interaction", kind = "encounterInteraction", phaseKey = "phase",
                window = { kind = "encounterEnd", phaseKey = "phase" },
            },
            automatic = {
                owner = "automatic", kind = "automatic", effect = "steadyGrowth", phaseKey = "phase",
                window = { kind = "encounterEnd", phaseKey = "phase" },
            },
        },
    }
    local index = assert(bindings.index(occurrence))
    lu.assertNil(index.phase)
    lu.assertNotNil(bindings.resolve(index, { kind = "encounterInteraction", phaseKey = "phase" }))
    lu.assertNotNil(bindings.resolve(index, {
        kind = "automatic", effect = "steadyGrowth", phaseKey = "phase",
    }))
    lu.assertNil(bindings.resolve(index, { kind = "phase", phaseKey = "phase" }))
end

function TestEncounters.testEncounterLifecycleUsesExactNativeIdentity()
    local module, callbacks = capture()
    local occurrence = {
        id = "room",
        overview = { encounterPhases = {
            { slotKey = "first", encounterKey = "SameEncounter" },
            { slotKey = "second", encounterKey = "SameEncounter" },
        } },
    }
    local active = { occurrence = occurrence }
    local state = { state = "synchronized" }
    local nativeRoom = {}
    local selected = {}
    local opened = {}
    local events = {}
    local capabilities = lifecycle.new()
    local started = {}
    local room = {
        current = function() return active end,
        encounterAt = function(_, index) return occurrence.overview.encounterPhases[index] end,
        bindEncounter = function(_, native, slotKey)
            phases.bind(occurrence, native, slotKey)
            selected[#selected + 1] = native
            return occurrence.overview.encounterPhases[slotKey == "first" and 1 or 2]
        end,
        encounterPhase = function(_, native)
            local binding = phases.forNative(native)
            return binding and binding.phase
        end,
        encounterIsFinal = function(_, native)
            local binding = phases.forNative(native)
            return binding ~= nil and phases.isFinal(occurrence, binding.phase)
        end,
        startEncounter = function(_, native)
            started[#started + 1] = native
            lifecycle.startEncounter(capabilities)
            events[#events + 1] = "start"
            return true
        end,
        window = function(_, window)
            opened[#opened + 1] = window
            events[#events + 1] = "window:" .. window
            return lifecycle.open(capabilities, window)
        end,
    }
    local session = {}
    local priorGame = _G.game
    _G.game = { EncounterData = { SameEncounter = { Name = "SameEncounter" } } }
    encounterHooks.attach(module, session, function() return state end, function() end, room)

    local run = {}
    local first, second = {}, {}
    local index = 0
    local function choose()
        index = index + 1
        return callbacks.ChooseEncounter(nil, {}, function()
            return index == 1 and first or second
        end, run, nativeRoom, {})
    end
    callbacks.SetupRoomMultipleEncountersData(nil, {}, function()
        first = { Name = "SameEncounter" }
        second = { Name = "SameEncounter" }
        choose()
        choose()
        return true
    end, nativeRoom, {})
    callbacks.StartEncounter(nil, {}, function() return true end, run, nativeRoom, first)
    callbacks.EndEncounterEffects(nil, {}, function()
        events[#events + 1] = "native-end:first"
        return true
    end, run, nativeRoom, first)
    lu.assertTrue(lifecycle.accepts(capabilities, { kind = "encounterEnd", phaseKey = "first" }))
    callbacks.StartEncounter(nil, {}, function() return true end, run, nativeRoom, second)
    lu.assertFalse(lifecycle.accepts(capabilities, { kind = "encounterEnd", phaseKey = "first" }))
    callbacks.EndEncounterEffects(nil, {}, function()
        events[#events + 1] = "native-end:second"
        return true
    end, run, nativeRoom, second)
    _G.game = priorGame

    lu.assertEquals(selected, { first, second })
    lu.assertEquals(started, { first, second })
    lu.assertEquals(opened, { "encounterEnd:first", "encounterEnd:second", "afterCombat" })
    lu.assertEquals(events, {
        "start", "window:encounterEnd:first", "native-end:first", "start",
        "window:encounterEnd:second", "native-end:second", "window:afterCombat",
    })
end

function TestEncounters.testUnboundEncounterDoesNotOpenPlannedAfterCombat()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local opened = {}
    local room = {
        encounterPhase = function() return nil end,
        encounterIsFinal = function() return false end,
        window = function(_, window) opened[#opened + 1] = window; return true end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local result = callbacks.EndEncounterEffects(nil, {}, function() return "native-result" end,
        {}, {}, {})

    lu.assertEquals(result, "native-result")
    lu.assertEquals(opened, {})
end

function TestEncounters.testDirectEncounterChoicesAreBoundToOnePublishedSequence()
    local module, callbacks = capture()
    local phasesForRoom = require("mods.room.timeline.encounters.phases").create()
    local occurrence = {
        id = "fields",
        overview = { encounterPhases = {
            { slotKey = "Passive", encounterKey = "PassiveEncounter" },
            { slotKey = "Cage01", encounterKey = "CageEncounter" },
            { slotKey = "Cage02", encounterKey = "CageEncounter" },
        } },
    }
    local state = { state = "synchronized" }
    local nativeRoom = { __runPlannerExecutionRoomId = "fields" }
    local bound = {}
    local room = {
        encounterAt = function(_, index)
            return occurrence.overview.encounterPhases[index]
        end,
        bindEncounter = function(_, native, slotKey)
            bound[#bound + 1] = { native = native, slotKey = slotKey }
            return phasesForRoom.bind(occurrence, native, slotKey)
        end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local run = {}
    local nativeEncounters = {}
    local function choose()
        local native = {}
        nativeEncounters[#nativeEncounters + 1] = native
        return callbacks.ChooseEncounter(nil, {}, function() return native end,
            run, nativeRoom, {})
    end

    local first = choose()
    local second = choose()
    local third = choose()
    local fourth = choose()
    local fifth = choose()

    lu.assertEquals(bound, {
        { native = first, slotKey = "Passive" },
        { native = second, slotKey = "Cage01" },
        { native = third, slotKey = "Cage02" },
    })
    lu.assertEquals(fourth, nativeEncounters[4])
    lu.assertEquals(fifth, nativeEncounters[5])
    lu.assertNil(phasesForRoom.forNative(fourth))
    lu.assertNil(phasesForRoom.forNative(fifth))
end

function TestEncounters.testGeneratedCompositionUsesTheExistingExactPhaseCarrier()
    local module, callbacks = capture()
    local occurrence = { id = "same-generated", overview = { encounterPhases = {
        { slotKey = "Combat1", encounterKey = "SameGenerated", customization = {
            { kind = "generated", decisionKey = "generatedComposition", waveCount = 2 },
        } },
        { slotKey = "Combat2", encounterKey = "SameGenerated", customization = {
            { kind = "generated", decisionKey = "generatedComposition", waveCount = 3 },
        } },
    } } }
    local state = { state = "synchronized" }
    local nativeRoom = { __runPlannerExecutionRoomId = occurrence.id }
    local scoped, bound = {}, {}
    local generated = {
        attach = function() end,
        withPhase = function(receivedState, roomContact, phase, destination, action)
            scoped[#scoped + 1] = {
                state = receivedState, room = roomContact, phase = phase, destination = destination,
            }
            return action()
        end,
    }
    local room = {
        occurrence = function(receivedState, destination)
            lu.assertEquals(receivedState, state)
            lu.assertEquals(destination, nativeRoom)
            return occurrence
        end,
        encounterAt = function(_, index) return occurrence.overview.encounterPhases[index] end,
        bindEncounter = function(_, native, slotKey)
            bound[#bound + 1] = { native = native, slotKey = slotKey }
            return true
        end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room, nil, generated)
    local priorGame = _G.game
    _G.game = { EncounterData = { SameGenerated = { Name = "SameGenerated" } } }
    local run = {}
    local function choose()
        return callbacks.ChooseEncounter(nil, {}, function(currentRun)
            return { Name = currentRun.ForceNextEncounterData.Name }
        end, run, nativeRoom, {})
    end
    local first, second = choose(), choose()
    _G.game = priorGame

    lu.assertEquals(scoped, {
        { state = state, room = room, phase = occurrence.overview.encounterPhases[1], destination = nativeRoom },
        { state = state, room = room, phase = occurrence.overview.encounterPhases[2], destination = nativeRoom },
    })
    lu.assertEquals(bound, { { native = first, slotKey = "Combat1" }, { native = second, slotKey = "Combat2" } })
    lu.assertNil(run.ForceNextEncounterData)
end

function TestEncounters.testPEncounterSequenceLeavesHeraclesNativeSuffixTerminationIntact()
    local module, callbacks = capture()
    local occurrence = {
        id = "p-combat",
        overview = { encounterPhases = {
            { slotKey = "Intro", encounterKey = "GeneratedP_PreCombat" },
            { slotKey = "Combat", encounterKey = "GeneratedP" },
        } },
    }
    local state = { state = "synchronized" }
    local nativeRoom = {
        __runPlannerExecutionRoomId = occurrence.id,
        MultipleEncountersData = { {}, {} },
    }
    local selected = {}
    local bound = {}
    local room = {
        encounterAt = function(_, index, destination)
            lu.assertEquals(destination, nativeRoom)
            return occurrence.overview.encounterPhases[index]
        end,
        bindEncounter = function(_, native, slotKey)
            bound[#bound + 1] = { native = native, slotKey = slotKey }
            return phases.bind(occurrence, native, slotKey)
        end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local priorGame = _G.game
    _G.game = {
        EncounterData = {
            GeneratedP_PreCombat = { Name = "GeneratedP_PreCombat" },
            GeneratedP = { Name = "GeneratedP" },
            HeraclesCombatP = { Name = "HeraclesCombatP", BlockMultipleEncounters = true },
        },
    }
    local run = {}
    local function choose(base)
        local encounter = callbacks.ChooseEncounter(nil, {}, base, run, nativeRoom, {})
        selected[#selected + 1] = encounter
        return encounter
    end

    callbacks.SetupRoomMultipleEncountersData(nil, {}, function()
        local preCombat = choose(function(currentRun)
            return currentRun.ForceNextEncounterData
        end)
        if not preCombat.BlockMultipleEncounters then
            choose(function(currentRun)
                return currentRun.ForceNextEncounterData
            end)
        end
        return true
    end, nativeRoom, {})
    lu.assertEquals(#selected, 2)
    lu.assertEquals(selected[1].Name, "GeneratedP_PreCombat")
    lu.assertEquals(selected[2].Name, "GeneratedP")
    lu.assertEquals(bound[1].slotKey, "Intro")
    lu.assertEquals(bound[2].slotKey, "Combat")

    selected = {}
    bound = {}
    occurrence.overview.encounterPhases[1].encounterKey = "HeraclesCombatP"
    callbacks.SetupRoomMultipleEncountersData(nil, {}, function()
        local heracles = choose(function(currentRun)
            return currentRun.ForceNextEncounterData
        end)
        if not heracles.BlockMultipleEncounters then
            choose(function(currentRun)
                return currentRun.ForceNextEncounterData
            end)
        end
        return true
    end, nativeRoom, {})
    _G.game = priorGame

    lu.assertEquals(#selected, 1)
    lu.assertEquals(bound[1].slotKey, "Intro")
    lu.assertEquals(selected[1].BlockMultipleEncounters, true)
end
