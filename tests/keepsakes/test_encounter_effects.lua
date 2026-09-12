-- luacheck: globals TestKeepsakeEncounterEffects
-- Fig Leaf and Gorgon effect-primary witnesses. Encounter identity and
-- lifecycle integration remain covered by tests/room/test_encounters.lua.
local lu = require("luaunit")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestKeepsakeEncounterEffects = {}

local function capture()
    local callbacks = {}
    return {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }, callbacks
end

function TestKeepsakeEncounterEffects.testFigLeafForcesOnlyTheNativeSkipDecisionAcrossBothSpawnHandlers()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", figLeafSkip = false },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    local sourceTrait = { Name = "PersistentDionysusSkipKeepsake", SkipEncounterChance = 0.37 }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    for _, expected in ipairs({ false, true }) do
        active.occurrence.overview.encounterPhases[1].figLeafSkip = expected
        for _, handler in ipairs({ "HandleEncounterPreSpawns", "HandleEnemySpawns" }) do
            local nativeCalls = 0
            nativeEncounter.CanEncounterSkip = true
            local result, substitution, arity = callbacks[handler](nil, {}, function(encounter)
                lu.assertEquals(encounter, nativeEncounter)
                local sourceTraitCanSkip = true
                local ready = callbacks.IsTraitActive(nil, {}, function() return true end, sourceTrait)
                local chance = callbacks.RandomChance(nil, {}, function()
                    nativeCalls = nativeCalls + 1
                    return "native-skip"
                end, sourceTrait.SkipEncounterChance * callbacks.GetTotalHeroTraitValue(nil, {}, function() return 1 end,
                    "LuckMultiplier", { IsMultiplier = true }), {})
                if ready and chance and sourceTraitCanSkip then return "skipped", nil, "native-arity" end
                -- HandleEncounterPreSpawns clears this flag after the failed
                -- skip; the later Vow substitution remains an ordinary roll.
                encounter.CanEncounterSkip = false
                local vowSubstitution = callbacks.RandomChance(nil, {}, function()
                    nativeCalls = nativeCalls + 1
                    return "native-vow-substitution"
                end, 0.1, {})
                return "ordinary-spawn", vowSubstitution, "native-arity"
            end, nativeEncounter)
            if expected then
                lu.assertEquals(result, "skipped")
                lu.assertNil(substitution)
                lu.assertEquals(nativeCalls, 0)
            else
                lu.assertEquals(result, "ordinary-spawn")
                lu.assertEquals(substitution, "native-vow-substitution")
                lu.assertEquals(nativeCalls, 1)
            end
            lu.assertEquals(arity, "native-arity")
        end
    end
end

function TestKeepsakeEncounterEffects.testFigLeafKeepsTheNativeSkipContactWhenValidationIsFalse()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", figLeafSkip = true },
    } } } }
    local nativeEncounter = { Name = "Encounter", CanEncounterSkip = true }
    local sourceTrait = { Name = "PersistentDionysusSkipKeepsake", SkipEncounterChance = 0.37 }
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local nativeCalls = 0
    local result = callbacks.HandleEncounterPreSpawns(nil, {}, function()
        -- Native computes validation first, but it is the final `and` operand;
        -- readiness and the exact skip chance still run.
        local sourceTraitCanSkip = false
        local ready = callbacks.IsTraitActive(nil, {}, function() return true end, sourceTrait)
        local chance = callbacks.RandomChance(nil, {}, function()
            nativeCalls = nativeCalls + 1
            return "native-skip"
        end, sourceTrait.SkipEncounterChance * callbacks.GetTotalHeroTraitValue(nil, {}, function() return 1 end,
            "LuckMultiplier", { IsMultiplier = true }), {})
        return ready and chance and sourceTraitCanSkip
    end, nativeEncounter)

    lu.assertFalse(result)
    lu.assertEquals(nativeCalls, 0)
end

function TestKeepsakeEncounterEffects.testFigLeafLeavesFreshEnemySpawnSubstitutionNativeAfterPreSpawnFailure()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", figLeafSkip = false },
    } } } }
    local nativeEncounter = { Name = "Encounter", CanEncounterSkip = true }
    local sourceTrait = { Name = "PersistentDionysusSkipKeepsake", SkipEncounterChance = 0.37 }
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local nativeCalls = 0
    local preSpawn = callbacks.HandleEncounterPreSpawns(nil, {}, function(encounter)
        local ready = callbacks.IsTraitActive(nil, {}, function() return true end, sourceTrait)
        local skip = callbacks.RandomChance(nil, {}, function()
            nativeCalls = nativeCalls + 1
            return "native-skip"
        end, sourceTrait.SkipEncounterChance * callbacks.GetTotalHeroTraitValue(nil, {}, function() return 1 end,
            "LuckMultiplier", { IsMultiplier = true }), {})
        if ready and skip then return "skipped" end
        encounter.CanEncounterSkip = false
        return "ordinary-pre-spawn"
    end, nativeEncounter)
    lu.assertEquals(preSpawn, "ordinary-pre-spawn")
    lu.assertFalse(nativeEncounter.CanEncounterSkip)

    local enemySpawn = callbacks.HandleEnemySpawns(nil, {}, function(encounter)
        lu.assertFalse(encounter.CanEncounterSkip)
        return callbacks.RandomChance(nil, {}, function()
            nativeCalls = nativeCalls + 1
            return "native-vow-substitution"
        end, 0.1, {})
    end, nativeEncounter)
    lu.assertEquals(enemySpawn, "native-vow-substitution")
    lu.assertEquals(nativeCalls, 1)
end

function TestKeepsakeEncounterEffects.testFigLeafLeavesAnUnrelatedRandomChanceNativeBeforeLuckAggregation()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", figLeafSkip = true },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local sourceTrait = { Name = "PersistentDionysusSkipKeepsake", SkipEncounterChance = 0.37 }
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local nativeCalls = 0
    local unrelated, later = callbacks.HandleEnemySpawns(nil, {}, function()
        callbacks.IsTraitActive(nil, {}, function() return true end, sourceTrait)
        local incidental = callbacks.RandomChance(nil, {}, function()
            nativeCalls = nativeCalls + 1
            return "native-incidental"
        end, 0.1, {})
        callbacks.GetTotalHeroTraitValue(nil, {}, function() return 1 end, "LuckMultiplier", { IsMultiplier = true })
        local skip = callbacks.RandomChance(nil, {}, function()
            nativeCalls = nativeCalls + 1
            return "native-skip"
        end, sourceTrait.SkipEncounterChance, {})
        return incidental, skip
    end, nativeEncounter)

    lu.assertEquals(unrelated, "native-incidental")
    lu.assertEquals(later, "native-skip")
    lu.assertEquals(nativeCalls, 2)
end

function TestKeepsakeEncounterEffects.testFigLeafScopesYieldedSpawnHandlersByCoroutine()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local phaseA = { slotKey = "phase-a", encounterKey = "EncounterA", figLeafSkip = true }
    local phaseB = { slotKey = "phase-b", encounterKey = "EncounterB", figLeafSkip = false }
    local active = { occurrence = { overview = { encounterPhases = { phaseA, phaseB } } } }
    local encounterA = { Name = "EncounterA" }
    local encounterB = { Name = "EncounterB" }
    local sourceTrait = { Name = "PersistentDionysusSkipKeepsake", SkipEncounterChance = 0.37 }
    local room = {
        current = function() return active end,
        encounterPhase = function(_, encounter) return encounter == encounterA and phaseA or phaseB end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local function yieldedNativeHandler()
        callbacks.IsTraitActive(nil, {}, function() return true end, sourceTrait)
        coroutine.yield("ready")
        local luck = callbacks.GetTotalHeroTraitValue(nil, {}, function() return 1 end,
            "LuckMultiplier", { IsMultiplier = true })
        return callbacks.RandomChance(nil, {}, function() return "native" end, sourceTrait.SkipEncounterChance * luck, {})
    end
    local first = coroutine.create(function()
        return callbacks.HandleEnemySpawns(nil, {}, yieldedNativeHandler, encounterA)
    end)
    local second = coroutine.create(function()
        return callbacks.HandleEnemySpawns(nil, {}, yieldedNativeHandler, encounterB)
    end)

    local ok, marker = coroutine.resume(first)
    lu.assertTrue(ok)
    lu.assertEquals(marker, "ready")
    ok, marker = coroutine.resume(second)
    lu.assertTrue(ok)
    lu.assertEquals(marker, "ready")
    ok, marker = coroutine.resume(second)
    lu.assertTrue(ok)
    lu.assertFalse(marker)
    ok, marker = coroutine.resume(first)
    lu.assertTrue(ok)
    lu.assertTrue(marker)
end

function TestKeepsakeEncounterEffects.testFigLeafRestoresItsScopeAfterANativeFailure()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", figLeafSkip = true },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local sourceTrait = { Name = "PersistentDionysusSkipKeepsake" }
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local ok, message = pcall(callbacks.HandleEncounterPreSpawns, nil, {}, function()
        callbacks.IsTraitActive(nil, {}, function() return true end, sourceTrait)
        error("native failure")
    end, nativeEncounter)
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native failure")
    lu.assertEquals(callbacks.RandomChance(nil, {}, function() return "native-after-error" end, 0.1, {}),
        "native-after-error")
end

function TestKeepsakeEncounterEffects.testFigLeafAbsenceLeavesNativeRandomnessUntouched()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", blocksFigLeaf = true },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local nativeCalls = 0
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)
    local result = callbacks.HandleEnemySpawns(nil, {}, function()
        return callbacks.RandomChance(nil, {}, function() nativeCalls = nativeCalls + 1; return true end,
            0.9, {})
    end, nativeEncounter)
    lu.assertTrue(result)
    lu.assertEquals(nativeCalls, 1)
end

function TestKeepsakeEncounterEffects.testGorgonAthenaHandsItsPublishedOfferToOrdinaryUseLoot()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter" },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local athena = { Name = "NPC_Athena_Field_01" }
    local handle = {}
    local bound = setmetatable({}, { __mode = "k" })
    local payload = {
        transaction = {
            kind = "encounterInteraction",
            resolution = { kind = "traitOffer", offer = {
                kind = "traits", giver = "Athena", selected = "option1",
                options = {
                    { key = "AthenaAttack", rarity = "Rare", effectiveLevel = 2 },
                    { key = "AthenaSpecial", rarity = "Common", effectiveLevel = 1 },
                },
            } },
        },
    }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = nativeEncounter }, Hero = { Traits = {} } }
    local room = {
        current = function() return active end,
        encounterPhase = function(_, encounter)
            return encounter == nativeEncounter and active.occurrence.overview.encounterPhases[1] or nil
        end,
        encounterHandle = function(_, source)
            bound[source] = handle
            return handle
        end,
        resolve = function() return nil end,
        peek = function(_, value) return value == handle and payload or nil end,
        begin = function(_, value) return value == handle and payload or nil end,
        bound = function(_, _, native) return bound[native] end,
        bind = function(_, _, value, native) bound[native] = value; return value end,
        sourceRole = function() return nil end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)
    local result = callbacks.AthenaUse(nil, {}, function() return "native-use" end,
        athena, { value = 1 }, { id = 2 })
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-use")
    lu.assertEquals(bound[athena], handle)
end
