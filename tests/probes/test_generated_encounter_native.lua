-- Manual only: HADES2_SCRIPTS_PATH=/path/to/Scripts lua tests/probes/test_generated_encounter_native.lua
-- luacheck: globals TestGeneratedEncounterNative CurrentRun EnemyData EncounterData RewardData
-- luacheck: globals MetaUpgradeData ConstantsData RoomData WaveDifficultyPatterns SetupEncounter
local lu = require("luaunit")
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path
local probe = require("tests.probes.generated_encounter_native")
local runtime = require("mods.runtime.session")
local generatedEncounter = require("mods.room.timeline.encounters.generated")
local scriptsPath = probe.scriptsPath(arg[1])
if arg[1] then table.remove(arg, 1) end

local function remove(values) local value = values[1]; table.remove(values, 1); return value end
local function same(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys, result = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do result[#result + 1] = tostring(key) .. "=" .. same(value[key]) end
    return "{" .. table.concat(result, ",") .. "}"
end

local function native(draws)
    return {
        DeepCopyTable = probe.copy, DebugPrint = function() end,
        DebugAssert = function(args) assert(args.Condition, args.Text) end,
        RandomChance = function() return false end,
        RandomInt = function(minimum, maximum) draws[#draws + 1] = { "int", minimum, maximum }; return minimum end,
        RandomNormal = function(mean, deviation) draws[#draws + 1] = { "normal", mean, deviation }; return mean end,
        RemoveRandomValue = function(values) draws[#draws + 1] = { "remove", table.concat(values, "/") }; return remove(values) end,
        GetRandomValue = function(values) return values[1] end, GetTotalHeroTraitValue = function() return 1 end,
        GetHeroTraitValues = function() return {} end, GetBiomeDepth = function() return 2 end,
        CalculateActiveEnemyCap = function() return 5 end, IsEmpty = function(values) return next(values) == nil end,
        TableLength = function(values) local count = 0 for _ in pairs(values) do count = count + 1 end return count end,
        CollapseTable = function() end,
        RemoveValue = function(values, value) for i, item in ipairs(values) do if item == value then table.remove(values, i); return end end end,
        RemoveAllValues = function(values, value) for i = #values, 1, -1 do if values[i] == value then table.remove(values, i) end end end,
        Contains = function(values, value) for _, item in pairs(values or {}) do if item == value then return true end end return false end,
        IsGameStateEligible = function(_, requirements) return not (requirements and requirements.Never) end,
        HasEncounterBeenCompleted = function() return true end, OverwriteTableKeys = function(target, values) for k, v in pairs(values) do target[k] = v end end,
        RunEventsGeneric = function() end, CheckPreviousReward = function() return {} end, RecordEncounter = function() end,
        GetInteractedGodThisRun = function() return "Apollo" end, GetInteractedGodsThisRun = function() return {} end,
        GetEligibleLootNames = function() return { "Apollo", "Hera" } end, CallFunctionName = function() end,
        CurrentRun = {
            Blacklist = {}, Hero = { Traits = {} }, BiomeDepthCache = 2, RunDepthCache = 3,
            EncountersOccurredCache = {}, EncountersOccurredBiomeCache = {}, EncountersDepthCache = {},
        },
        GameState = { EncountersOccurredCache = {} }, EncounterData = {}, RewardData = {}, game = {},
        MetaUpgradeData = { EnemyCountShrineUpgrade = { ChangeValue = 1 } }, ConstantsData = { MinimumDifficulty = 1 },
        RoomData = { BaseRoom = { MinDepthBeforeIntros = 0 } },
        WaveDifficultyPatterns = { [1] = { 1 }, [2] = { .5, .5 }, [3] = { .3, .15, .55 }, [4] = { .3, .1, .2, .4 } },
        EnemyData = {
            Ash = { GeneratorData = { DifficultyRating = 2 } }, Brine = { GeneratorData = { DifficultyRating = 3 } },
            Cinder = { BlacklistAfterFirstAppearance = true, Groups = { "cinder" }, GeneratorData = { DifficultyRating = 5, BlockEnemyTypes = { "Ash" }, ActiveEnemyCapBonus = 2 } },
            Dawn = { Groups = { "cinder" }, GeneratorData = { DifficultyRating = 4 } },
            Elite = { IsElite = true, GeneratorData = { DifficultyRating = 4, MaxCount = 2 } },
        },
    }
end

local function declaration(overrides)
    local result = {
        Name = "ProbeGenerated", Generated = true, MoneyDropCapMin = 0, MoneyDropCapMax = 0,
        BaseDifficulty = 20, MinWaves = 1, MaxWaves = 1, MinTypes = 1, MaxTypes = 2, MaxTypesCap = 2,
        TypeCountDepthRamp = 0, EnemySet = { "Ash", "Brine", "Cinder" }, WaveTemplate = { Spawns = {} },
    }
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

-- The probe wraps only the shipped installation contacts. Random selection and
-- native eligibility remain the bodies read from the installed game scripts.
local function configuredProduction()
    local draws = {}
    local restore = probe.restore(native(draws))
    probe.loadBodies(scriptsPath)
    local callbacks, nativeBodies = {}, {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local instance = generatedEncounter.create()
    runtime.__generatedProbeState, runtime.__generatedProbePhases, runtime.__generatedProbeOccurrences = nil, {}, {}
    instance.attach(module, runtime, function() return runtime.__generatedProbeState end, {
        encounterPhase = function(_, encounter) return runtime.__generatedProbePhases[encounter] end,
        occurrence = function(state) return runtime.__generatedProbeOccurrences[state] end,
    })
    for _, name in ipairs({ "SetupEncounter", "GenerateEncounter", "FillEnemyTypes" }) do
        nativeBodies[name] = _G[name]
        _G[name] = function(...)
            return callbacks[name](nil, {}, nativeBodies[name], ...)
        end
    end
    return draws, instance, callbacks, restore
end

local function phase(slot, customization)
    return { slotKey = slot, encounterKey = "ProbeGenerated", customization = { customization } }
end
local function fullDecision(overrides)
    local result = {
        kind = "generated", decisionKey = "generatedComposition", waveCount = 1,
        waves = { { waveIndex = 1, types = {
            { choiceKey = "Brine", nativeId = "Brine", source = "addition" },
            { choiceKey = "Cinder", nativeId = "Cinder", source = "addition" },
        }, counts = { Brine = 2, Cinder = 1 } } },
    }
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end
local function install(instance, state, occurrence, phaseValue, destination, source)
    return instance.withPhase(state, { occurrence = function(receivedState, receivedRoom)
        lu.assertEquals(receivedState, state)
        lu.assertEquals(receivedRoom, destination)
        return occurrence
    end }, phaseValue, destination, function() return SetupEncounter(source, destination) end)
end

TestGeneratedEncounterNative = {}

function TestGeneratedEncounterNative.testPublishedOperandsInstallThroughRawContactsAndPreserveNativeEffects()
    local rawDraws, _, _, rawRestore = configuredProduction()
    local raw = SetupEncounter(declaration(), { Name = "raw" })
    local rawRoster = same(raw.SpawnWaves)
    rawRestore()

    local draws, generated, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local occurrence, destination = { id = "published" }, { Name = "destination", __runPlannerExecutionRoomId = "published" }
    local state, selected = { state = "synchronized", diagnostics = {} }, phase("Combat2", fullDecision())
    local source = declaration({ BlockTypesAcrossWaves = true })
    local realized = install(generated, state, occurrence, selected, destination, source)
    lu.assertEquals(source.MinWaves, 1)
    lu.assertEquals(realized.WaveCount, 1)
    lu.assertNotEquals(same(realized.SpawnWaves), rawRoster)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].TotalCount, 2)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[2].Name, "Cinder")
    lu.assertEquals(realized.SpawnWaves[1].Spawns[2].TotalCount, 1)
    lu.assertTrue(_G.CurrentRun.Blacklist.Cinder)
    lu.assertTrue(realized.Blacklist.Ash)
    lu.assertEquals(realized.ActiveEnemyCapBonus, 2)
    lu.assertTrue(#draws > 0)
    lu.assertTrue(#rawDraws > 0)
    restore()
end

function TestGeneratedEncounterNative.testOwnershipRequiresRestoredExactPhaseAndSuppressesOnlyOwnedMenaceAndFangs()
    local _, generated, callbacks, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local occurrence, destination = { id = "owned" }, { Name = "owned", __runPlannerExecutionRoomId = "owned" }
    local state = { state = "synchronized" }
    local selected = phase("Cage01", fullDecision({ fangs = { type = { nativeId = "Brine" }, perks = {} } }))
    local realized = install(generated, state, occurrence, selected, destination, declaration())
    lu.assertNotNil(realized.__runPlannerGeneratedComposition)
    runtime.__generatedProbeState = state
    runtime.__generatedProbeOccurrences[state] = occurrence
    runtime.__generatedProbePhases[realized] = selected
    local received
    callbacks.HandleNextSpawn(nil, runtime, function(_, _, _, _, args) received = args; return "owned" end,
        realized, false, nil, nil, { IgnoreShrineOverrides = false })
    lu.assertEquals(received.IgnoreShrineOverrides, true)
    realized.EliteAttributes = { Brine = { "native" } }
    callbacks.PickEncounterEliteAttributes(nil, runtime, function() error("owned fangs must not delegate") end, realized)
    lu.assertEquals(realized.EliteAttributes, {})

    -- The same encounter key at a different cage is not ownership: both native
    -- hooks receive their original arguments and native Fangs remains available.
    runtime.__generatedProbePhases[realized] = phase("Cage02", fullDecision())
    local nativeArgs
    callbacks.HandleNextSpawn(nil, runtime, function(_, _, _, _, args) nativeArgs = args; return "native" end,
        realized, false, nil, nil, { IgnoreShrineOverrides = false })
    lu.assertEquals(nativeArgs.IgnoreShrineOverrides, false)
    local fangsDelegated = false
    callbacks.PickEncounterEliteAttributes(nil, runtime, function() fangsDelegated = true end, realized)
    lu.assertTrue(fangsDelegated)
    restore()
end

function TestGeneratedEncounterNative.testHardManualAndFixedTemplatesKeepNativeMetadataWhileInstallingPublishedSources()
    local _, generated, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local occurrence, destination = { id = "templates" }, { Name = "templates", __runPlannerExecutionRoomId = "templates" }
    local state = { state = "synchronized" }
    local shared = phase("Combat", {
        kind = "generated", decisionKey = "generatedComposition", waveCount = 2,
        highlight = { choiceKey = "Brine", nativeId = "Brine" },
        waves = {
            { waveIndex = 1, types = { { choiceKey = "Brine", nativeId = "Brine", source = "highlight" } }, counts = { Brine = 1 } },
            { waveIndex = 2, types = {
                { choiceKey = "Brine", nativeId = "Brine", source = "highlight" },
                { choiceKey = "Cinder", nativeId = "Cinder", source = "addition" },
            }, counts = { Brine = 1, Cinder = 1 } },
        },
    })
    local hard = declaration({ IsHardEncounter = true, HardEncounterOverrideValues = {
        ManualWaveTemplates = {
            [1] = { Spawns = {}, ForceFirst = true },
            [0] = { Spawns = {}, SkipWait = true },
        },
    } })
    local realized = install(generated, state, occurrence, shared, destination, hard)
    lu.assertTrue(realized.SpawnWaves[1].ForceFirst)
    lu.assertTrue(realized.SpawnWaves[2].SkipWait)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[2].Spawns[2].Name, "Cinder")
    lu.assertTrue(realized.Blacklist.Brine)
    lu.assertTrue(_G.CurrentRun.Blacklist.Cinder)

    local fixed = phase("Cage", {
        kind = "generated", decisionKey = "generatedComposition", waveCount = 1,
        waves = { { waveIndex = 1, types = {
            { choiceKey = "Ash", nativeId = "Ash", source = "fixed" },
            { choiceKey = "Brine", nativeId = "Brine", source = "template" },
        }, counts = { Ash = 1, Brine = 2 } } },
    })
    local source = declaration({ WaveTemplate = { ForceFirst = true, Spawns = {
        { Name = "Ash", TotalCount = 1 }, { Generated = true, SkipWait = true },
    } } })
    local templated = install(generated, state, occurrence, fixed, destination, source)
    lu.assertTrue(templated.SpawnWaves[1].ForceFirst)
    lu.assertEquals(templated.SpawnWaves[1].Spawns[1].TotalCount, 1)
    lu.assertTrue(templated.SpawnWaves[1].Spawns[2].SkipWait)
    lu.assertEquals(templated.SpawnWaves[1].Spawns[2].TotalCount, 2)
    restore()
end

function TestGeneratedEncounterNative.testDevotionRewardDestinationUsesItsBoundPhase()
    local _, generated, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local occurrence = { id = "devotion" }
    local destination = { Name = "O_Devotion", __runPlannerExecutionRoomId = "devotion", ChosenRewardType = "Devotion" }
    local state = { state = "synchronized" }
    local selected = phase("Devotion", fullDecision())
    local room = {
        occurrence = function(receivedState, receivedRoom)
            lu.assertEquals(receivedState, state)
            lu.assertEquals(receivedRoom, destination)
            return occurrence
        end,
        encounterAt = function(receivedState, index, receivedRoom)
            lu.assertEquals(receivedState, state)
            lu.assertEquals(index, 1)
            lu.assertEquals(receivedRoom, destination)
            return selected
        end,
    }
    local realized = generated.withRewardDestination(state, room, destination, function()
        return SetupEncounter(declaration(), destination)
    end)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[1].Spawns[2].Name, "Cinder")
    restore()
end

function TestGeneratedEncounterNative.testIntroReplacementAndGenerationErrorClearOwnershipBeforeLaterNativeCalls()
    local _, generated, callbacks, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local occurrence, destination = { id = "failure" }, { Name = "failure", __runPlannerExecutionRoomId = "failure" }
    local state, selected = { state = "synchronized", diagnostics = {} }, phase("Encounter", fullDecision())
    local source = declaration({ EnemySet = { "Brine" } })
    _G.EnemyData.Brine.IntroEncounterName = "Introduction"
    _G.HasEncounterBeenCompleted = function(name) return name ~= "Introduction" end
    _G.EncounterData.Introduction = declaration({ Name = "Introduction", EnemySet = { "Ash" } })
    local intro = install(generated, state, occurrence, selected, destination, source)
    lu.assertEquals(intro.Name, "Introduction")
    lu.assertNil(intro.__runPlannerGeneratedComposition)
    _G.EnemyData.Brine.IntroEncounterName = nil

    local broken, priorCap = declaration(), _G.CalculateActiveEnemyCap
    _G.CalculateActiveEnemyCap = function() error("probe native generation failure") end
    lu.assertError(function() install(generated, state, occurrence, selected, destination, broken) end)
    _G.CalculateActiveEnemyCap = priorCap
    lu.assertNil(broken.__runPlannerGeneratedComposition)
    runtime.__generatedProbeState = state
    runtime.__generatedProbeOccurrences[state] = occurrence
    runtime.__generatedProbePhases[broken] = selected
    local delegated = false
    callbacks.HandleNextSpawn(nil, runtime, function() delegated = true end, broken, false, nil, nil, {})
    lu.assertTrue(delegated)
    restore()
end

os.exit(lu.LuaUnit.run())
