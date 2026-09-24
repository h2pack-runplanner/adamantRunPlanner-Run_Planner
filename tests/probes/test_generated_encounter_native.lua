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
        GetNumShrineUpgrades = function() return 0 end, GetConfigOptionValue = function() return 0 end,
        GetShrineUpgradeChangeValue = function() return 0 end, NextRoomSets = {}, IsEmpty = function(values) return next(values) == nil end,
        TableLength = function(values) local count = 0 for _ in pairs(values) do count = count + 1 end return count end,
        CollapseTable = function() end,
        RemoveValue = function(values, value) for i, item in ipairs(values) do if item == value then table.remove(values, i); return end end end,
        RemoveAllValues = function(values, value) for i = #values, 1, -1 do if values[i] == value then table.remove(values, i) end end end,
        Contains = function(values, value) for _, item in pairs(values or {}) do if item == value then return true end end return false end,
        IsGameStateEligible = function(_, requirements) return not (requirements and requirements.Never) end,
        HasEncounterBeenCompleted = function() return true end,
        RunEventsGeneric = function() end, CheckPreviousReward = function() return {} end, RecordEncounter = function() end,
        GetInteractedGodThisRun = function() return "Apollo" end, GetInteractedGodsThisRun = function() return {} end,
        GetEligibleLootNames = function() return { "Apollo", "Hera" } end, CallFunctionName = function() end,
        CurrentRun = {
            Blacklist = {}, BannedEliteAttributes = {}, Hero = { Traits = {} }, BiomeDepthCache = 2, RunDepthCache = 3,
            EncountersOccurredCache = {}, EncountersOccurredBiomeCache = {}, EncountersDepthCache = {},
        },
        GameState = { EncountersOccurredCache = {}, BiomeVisits = {} }, EncounterData = {}, RewardData = {}, game = {},
        MetaUpgradeData = { EnemyCountShrineUpgrade = { ChangeValue = 1 } }, ConstantsData = { MinimumDifficulty = 1, MaxActiveEnemyCount = 12 },
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
    for _, name in ipairs({ "SetupEncounter", "GenerateEncounter", "CalculateActiveEnemyCap", "FillEnemyTypes" }) do
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
        kind = "generated", decisionKey = "generatedComposition", expectedBudget = 40, waveCount = 1,
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

local function ownedSpawnProbe(conversions, roster, fangs, swapMap)
    local extraGlobals = { "GetNextSpawn", "HandleNextSpawn", "SpawnUnitGroup", "ShallowCopyTable", "GetIds", "IsAlive", "SelectSpawnPoint", "Destroy", "SpawnUnit", "SpawnObstacle", "CalcOffset", "thread", "SetupUnit", "NextRoomSets", "wait" }
    local prior = {}
    for _, key in ipairs(extraGlobals) do prior[key] = _G[key] end
    local _, instance, callbacks, restoreNative = configuredProduction()
    local function restore()
        restoreNative()
        for _, key in ipairs(extraGlobals) do _G[key] = prior[key] end
    end
    _G.game.EnemyData = _G.EnemyData
    for name, enemy in pairs(_G.EnemyData) do enemy.Name = name end
    _G.EnemyData.Group = { Name = "Group", IsUnitGroup = true, UnitGroup = { "Ash", "Brine" }, GroupAI = "ProbeAI", GeneratorData = {} }
    _G.MetaUpgradeData.NextBiomeEnemyShrineUpgrade = { SwapMap = swapMap or {
        Brine = { Name = "Ash", RequiredSpawnPoint = "MappedPoint", ActiveCapWeight = 3 },
        Cinder = { Name = "Ash" },
    }, BiomeEnemySets = { F = { "Ash" } } }
    _G.GetShrineUpgradeChangeValue = function() return 1 end
    if fangs then
        local enemy = _G.EnemyData[fangs.type.nativeId]
        enemy.EliteAttributeOptions, enemy.EliteAttributeData = {}, {}
        for index, perk in ipairs(fangs.perks) do
            enemy.EliteAttributeOptions[index], enemy.EliteAttributeData[perk] = perk, {}
        end
    end
    local occurrence = { id = "menace" }
    local destination = { Name = "menace", RoomSetName = "F", __runPlannerExecutionRoomId = "menace" }
    local state = { state = "synchronized" }
    local decision = fullDecision({ menace = { { waveIndex = 1, conversions = conversions } }, fangs = fangs })
    if roster then decision.waves = { roster } end
    local selected = phase("Combat", decision)
    local encounter = install(instance, state, occurrence, selected, destination,
        declaration({ EnemySet = { "Ash", "Brine", "Cinder", "Group" } }))
    encounter.ActiveSpawns = {}
    for _, source in ipairs(encounter.SpawnWaves[1].Spawns) do source.RemainingSpawns = source.TotalCount end
    local function bind(value)
        runtime.__generatedProbeState = state
        runtime.__generatedProbeOccurrences[state] = occurrence
        runtime.__generatedProbePhases[value] = selected
    end
    bind(encounter)
    callbacks.PickEncounterEliteAttributes(nil, runtime, function() error("owned Fangs must not draw") end, encounter)
    _G.CurrentRun.CurrentRoom = { RoomSetName = "F", SpawnOnIds = {} }
    _G.NextRoomSets, _G.GameState.BiomeVisits = {}, {}
    local spawned, selections = {}, 0
    _G.ShallowCopyTable = probe.copy
    _G.GetIds = function() return {} end
    _G.IsAlive = function() return true end
    _G.SelectSpawnPoint = function() return 7 end
    _G.Destroy = function() end
    _G.SpawnUnit = function() return #spawned + 100 end
    _G.SpawnObstacle = function() return 7 end
    _G.CalcOffset = function() return { X = 0, Y = 0 } end
    _G.wait = function() end
    _G.thread = function(_, enemy) spawned[#spawned + 1] = enemy end
    _G.SetupUnit = function() end
    _G.RandomChance = function() error("owned Menace must not draw native RNG") end
    _G.GetNextSpawn = function(value)
        selections = selections + 1
        for _, source in ipairs(value.SpawnWaves[1].Spawns) do
            if source.RemainingSpawns > 0 then return source end
        end
    end
    probe.loadNextSpawnBody(scriptsPath)
    local raw = _G.HandleNextSpawn
    _G.HandleNextSpawn = function(...)
        return callbacks.HandleNextSpawn(nil, runtime, raw, ...)
    end
    return encounter, spawned, bind, function() return selections end, restore
end

local function conversion(source, target, count)
    return { source = { choiceKey = source, nativeId = source },
        target = { choiceKey = target, nativeId = target }, count = count }
end

function TestGeneratedEncounterNative.testShippedMenacePartialAllZeroAndSingleNativeSelection()
    for _, count in ipairs({ 0, 1, 2 }) do
        local encounter, spawned, _, selections, restore = ownedSpawnProbe({ conversion("Brine", "Ash", count) })
        local source = encounter.SpawnWaves[1].Spawns[1]
        source.SpawnOverrides = { CustomWitness = "kept" }
        _G.HandleNextSpawn(encounter, false, nil, nil, {})
        _G.HandleNextSpawn(encounter, false, source, nil, {})
        lu.assertEquals(selections(), 1)
        lu.assertEquals(source.Name, "Brine")
        lu.assertEquals(source.RemainingSpawns, 0)
        lu.assertEquals(source.SpawnOverrides, { CustomWitness = "kept" })
        for index, enemy in ipairs(spawned) do
            lu.assertEquals(enemy.Name, index <= count and "Ash" or "Brine")
            lu.assertEquals(enemy.CustomWitness, "kept")
            if index <= count then
                lu.assertTrue(enemy.IsFromNextBiomeEnemyShrineUpgrade)
                lu.assertEquals(enemy.RequiredSpawnPoint, "MappedPoint")
                lu.assertEquals(enemy.ActiveCapWeight, 3)
            else lu.assertNil(enemy.IsFromNextBiomeEnemyShrineUpgrade) end
        end
        restore()
    end
end

function TestGeneratedEncounterNative.testFailedAttemptAndReloadReconstructSuccessfulProgressWithoutReplay()
    local encounter, spawned, bind, _, restore = ownedSpawnProbe({ conversion("Brine", "Ash", 1) })
    local source = encounter.SpawnWaves[1].Spawns[1]
    _G.SelectSpawnPoint = function() return nil end
    lu.assertNil(_G.HandleNextSpawn(encounter, false, source, nil, {}))
    lu.assertEquals(source.RemainingSpawns, 2)
    lu.assertEquals(#spawned, 0)
    _G.SelectSpawnPoint = function() return 7 end
    _G.HandleNextSpawn(encounter, false, source, nil, {})
    lu.assertEquals(spawned[1].Name, "Ash")
    local restored = probe.copy(encounter)
    bind(restored)
    _G.HandleNextSpawn(restored, false, restored.SpawnWaves[1].Spawns[1], nil, {})
    lu.assertEquals(spawned[2].Name, "Brine")
    lu.assertEquals(restored.SpawnWaves[1].Spawns[1].RemainingSpawns, 0)
    lu.assertEquals(source.RemainingSpawns, 1)
    restore()
end

function TestGeneratedEncounterNative.testDistinctSourcesSharingTargetAndOriginalTargetRemainSeparate()
    local roster = { waveIndex = 1, types = {}, counts = { Ash = 1, Brine = 2, Cinder = 1 } }
    for _, name in ipairs({ "Ash", "Brine", "Cinder" }) do
        roster.types[#roster.types + 1] = { choiceKey = name, nativeId = name, source = "addition" }
    end
    local encounter, spawned, _, _, restore = ownedSpawnProbe({ conversion("Brine", "Ash", 1), conversion("Cinder", "Ash", 1) }, roster)
    for _, source in ipairs(encounter.SpawnWaves[1].Spawns) do
        while source.RemainingSpawns > 0 do _G.HandleNextSpawn(encounter, false, source, nil, {}) end
    end
    lu.assertEquals(#encounter.SpawnWaves[1].Spawns, 3)
    lu.assertEquals({ spawned[1].Name, spawned[2].Name, spawned[3].Name, spawned[4].Name }, { "Ash", "Ash", "Brine", "Ash" })
    lu.assertNil(spawned[1].IsFromNextBiomeEnemyShrineUpgrade)
    lu.assertNil(spawned[4].RequiredSpawnPoint)
    restore()
end

function TestGeneratedEncounterNative.testMappedGroupRecursionConsumesOneSourceRequestAndPreservesMetadata()
    local encounter, spawned, _, selections, restore = ownedSpawnProbe({ conversion("Brine", "Group", 1) }, nil, nil,
        { Brine = { Name = "Group", RequiredSpawnPoint = "MappedPoint", ActiveCapWeight = 3 } })
    local source = encounter.SpawnWaves[1].Spawns[1]
    lu.assertEquals(_G.HandleNextSpawn(encounter, false, source, nil, {}), 1)
    lu.assertEquals(source.Name, "Brine")
    lu.assertEquals(source.RemainingSpawns, 1)
    lu.assertEquals(selections(), 0)
    lu.assertEquals(#spawned, 2)
    lu.assertEquals({ spawned[1].Name, spawned[2].Name }, { "Ash", "Brine" })
    for _, enemy in ipairs(spawned) do
        lu.assertTrue(enemy.IsFromNextBiomeEnemyShrineUpgrade)
        lu.assertEquals(enemy.RequiredSpawnPoint, "MappedPoint")
        lu.assertEquals(enemy.ActiveCapWeight, 3)
    end
    _G.HandleNextSpawn(encounter, false, source, nil, {})
    lu.assertEquals(spawned[3].Name, "Brine")
    lu.assertNil(spawned[3].IsFromNextBiomeEnemyShrineUpgrade)
    lu.assertEquals(source.RemainingSpawns, 0)
    restore()
end

function TestGeneratedEncounterNative.testNativeSetupUsesActualReplacementNameForFangsAndDreamScaling()
    local encounter, spawned, _, _, restore = ownedSpawnProbe({ conversion("Brine", "Ash", 1) }, nil,
        { type = { choiceKey = "Brine", nativeId = "Brine" }, perks = { "SourcePerk" } })
    local extra = probe.restore({
        IsCharmed = function() return false end, ActiveEnemies = {}, SurroundEnemiesAttacking = {},
        AttachLua = function() end, AddToGroup = function() end, SetThingProperty = function() end,
        ApplyEnemyModifiers = function() end, ApplyEnemyTraits = function() end, CreateLevelDisplay = function() end,
        SessionMapState = { SpawnPointsUsed = {} }, GameData = { FullRunBiomeCount = 4 },
    })
    _G.MetaUpgradeData.EnemyHealthShrineUpgrade = { ChangeValue = 1 }
    _G.CurrentRun.SpawnRecord, _G.GameState.SpawnRecord = {}, {}
    _G.CurrentRun.IsDreamRun, _G.CurrentRun.EnteredBiomes = true, 1
    _G.CurrentRun.CurrentRoom.EliteAttributes = { Ash = { "TargetPerk" } }
    for _, name in ipairs({ "Ash", "Brine" }) do
        _G.EnemyData[name].IsElite = true
        _G.EnemyData[name].EliteAttributeData = { SourcePerk = {}, TargetPerk = {} }
        _G.EnemyData[name].DreamBiomeData = {
            { DataOverrides = { DreamWitness = 1 } }, { DataOverrides = { DreamWitness = 2 } },
        }
    end
    probe.loadSetupUnitBody(scriptsPath)
    probe.loadEliteApplicationBody(scriptsPath)
    _G.thread = function(fn, enemy)
        if fn == _G.SetupUnit then
            spawned[#spawned + 1] = enemy
            fn(enemy, _G.CurrentRun, { SkipAISetup = true, SkipPresentation = true, IgnorePackages = true })
        end
    end
    local source = encounter.SpawnWaves[1].Spawns[1]
    _G.HandleNextSpawn(encounter, false, source, nil, {})
    _G.HandleNextSpawn(encounter, false, source, nil, {})
    lu.assertEquals(spawned[1].Name, "Ash")
    lu.assertEquals(spawned[1].EliteAttributes, { "TargetPerk" })
    lu.assertEquals(spawned[1].DreamWitness, 2)
    lu.assertEquals(spawned[2].Name, "Brine")
    lu.assertEquals(spawned[2].EliteAttributes, { "SourcePerk" })
    lu.assertEquals(spawned[2].DreamWitness, 1)
    extra()
    restore()
end

function TestGeneratedEncounterNative.testGroupSourceConversionCountsRequestsNotItsMembers()
    local roster = { waveIndex = 1, types = { { choiceKey = "Group", nativeId = "Group", source = "addition" } }, counts = { Group = 2 } }
    local encounter, spawned, _, _, restore = ownedSpawnProbe({ conversion("Group", "Ash", 1) }, roster)
    local source = encounter.SpawnWaves[1].Spawns[1]
    source.SpawnOverrides = {}
    _G.HandleNextSpawn(encounter, false, source, nil, {})
    lu.assertEquals(source.RemainingSpawns, 1)
    lu.assertEquals(#spawned, 1)
    lu.assertNil(spawned[1].RequiredSpawnPoint)
    _G.HandleNextSpawn(encounter, false, source, nil, {})
    lu.assertEquals(source.RemainingSpawns, 0)
    lu.assertEquals(#spawned, 3)
    lu.assertEquals({ spawned[1].Name, spawned[2].Name, spawned[3].Name }, { "Ash", "Ash", "Brine" })
    lu.assertNil(spawned[2].IsFromNextBiomeEnemyShrineUpgrade)
    restore()
end

function TestGeneratedEncounterNative.testUnownedWrapperLeavesRawNativeConversionEnabled()
    local encounter, spawned, _, _, restore = ownedSpawnProbe({ conversion("Brine", "Ash", 0) })
    encounter.__runPlannerGeneratedComposition = nil
    _G.GetShrineUpgradeChangeValue = function() return 1 end
    _G.RandomChance = function() return true end
    _G.HandleNextSpawn(encounter, false, encounter.SpawnWaves[1].Spawns[1], nil, {})
    lu.assertEquals(spawned[1].Name, "Ash")
    lu.assertTrue(spawned[1].IsFromNextBiomeEnemyShrineUpgrade)
    restore()
end

-- Raw native contact witness for Gate D. It proves that HandleNextSpawn
-- captures the source entry before its shrine copy, copies conversion metadata
-- only to the spawned request, and decrements the source only after success.
function TestGeneratedEncounterNative.testRawNextSpawnKeepsSourceAccountingAndCopiedMenaceMetadata()
    local restore = probe.restore(native({}))
    _G.ShallowCopyTable = function(value) local result = {}; for k, v in pairs(value) do result[k] = v end; return result end
    _G.GetShrineUpgradeChangeValue = function() return 1 end
    _G.RandomChance = function() return true end
    _G.NextRoomSets, _G.GameState.BiomeVisits = {}, {}
    _G.EnemyData.Ash.Name, _G.EnemyData.Brine.Name = "Ash", "Brine"
    _G.MetaUpgradeData.NextBiomeEnemyShrineUpgrade = { SwapMap = { Ash = { Name = "Brine", RequiredSpawnPoint = "NativePoint", ActiveCapWeight = 3 } }, BiomeEnemySets = {} }
    _G.CurrentRun.CurrentRoom = { RoomSetName = "F", SpawnOnIds = { 7 } }
    _G.GetIds, _G.RemoveRandomValue, _G.IsAlive = function() return { 7 } end, function(values) return table.remove(values) end, function() return true end
    _G.SelectSpawnPoint, _G.Destroy, _G.SpawnUnit = function() return 7 end, function() end, function() return 99 end
    local observed
    _G.thread = function(fn, enemy) observed = enemy end
    _G.SetupUnit = function() end
    probe.loadNextSpawnBody(scriptsPath)
    local source = { Name = "Ash", TotalCount = 2, RemainingSpawns = 2 }
    local result = HandleNextSpawn({ Name = "Probe", ActiveSpawns = {} }, false, source, nil, {})
    lu.assertEquals(result, 99)
    lu.assertEquals(source.Name, "Ash")
    lu.assertEquals(source.RemainingSpawns, 1)
    lu.assertEquals(observed.Name, "Brine")
    lu.assertTrue(observed.IsFromNextBiomeEnemyShrineUpgrade)
    lu.assertEquals(observed.RequiredSpawnPoint, "NativePoint")
    lu.assertEquals(observed.ActiveCapWeight, 3)
    restore()
end

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
        kind = "generated", decisionKey = "generatedComposition", expectedBudget = 40, waveCount = 2,
        highlight = { choiceKey = "Brine", nativeId = "Brine" },
        waves = {
            { waveIndex = 1, types = { { choiceKey = "Brine", nativeId = "Brine", source = "highlight" } }, counts = { Brine = 1 } },
            { waveIndex = 2, types = {
                { choiceKey = "Brine", nativeId = "Brine", source = "highlight" },
                { choiceKey = "Cinder", nativeId = "Cinder", source = "addition" },
            }, counts = { Brine = 1, Cinder = 1 } },
        },
    })
    local hard = declaration({ MaxWaves = 2, IsHardEncounter = true, HardEncounterOverrideValues = {
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
        kind = "generated", decisionKey = "generatedComposition", expectedBudget = 40, waveCount = 1,
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
    local source = declaration({ EnemySet = { "Brine", "Cinder" } })
    _G.EnemyData.Brine.IntroEncounterName = "Introduction"
    _G.HasEncounterBeenCompleted = function(name) return name ~= "Introduction" end
    _G.EncounterData.Introduction = declaration({ Name = "Introduction", EnemySet = { "Ash" } })
    local intro = install(generated, state, occurrence, selected, destination, source)
    lu.assertEquals(#state.diagnostics, 1)
    lu.assertEquals(state.diagnostics[1].observed, { kind = "generated-admission", reason = "intro-substitution",
        wave = 1, enemy = "Brine", observed = "Introduction" })
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

function TestGeneratedEncounterNative.testAllWaveRejectionPrecedesInstallationAndNativeContinues()
    local cases = {
        { reason = "native-enemy-ineligible", configure = function() _G.EnemyData.Brine.GameStateRequirements = { Never = true } end },
        { reason = "native-enemy-ineligible", configure = function() _G.CurrentRun.Blacklist.Brine = true end },
        { reason = "native-enemy-ineligible", configure = function(source) source.Blacklist = { Brine = true } end },
        { reason = "enemy-set-changed", configure = function(source) source.EnemySet = { "Ash", "Cinder" } end },
        { reason = "native-enemy-ineligible", configure = function(source)
            _G.EnemyData.Brine.IsElite = true
            source.WaveTemplate.BlockEliteTypes = true
        end },
        { reason = "native-enemy-ineligible", configure = function()
            _G.EnemyData.Brine.IntroEncounterName = "Unseen"
            _G.EnemyData.Brine.IneligibleIfUncompletedIntroEncounter = true
            _G.HasEncounterBeenCompleted = function() return false end
        end },
        { reason = "native-enemy-check-error", configure = function() _G.game.IsEnemyEligible = function() error("predicate failed") end end },
        { reason = "native-enemy-ineligible", configure = function(source)
            source.MaxEliteTypes = 1
            _G.EnemyData.Brine.IsElite, _G.EnemyData.Cinder.IsElite = true, true
        end },
        { reason = "native-enemy-ineligible", configure = function(source)
            source.MaxTypesPerGroup = { cinder = 1 }
            _G.EnemyData.Brine.Groups = { "cinder" }
        end },
        -- Wave 1's addition blocks wave 2's published member across waves.
        { reason = "native-enemy-ineligible", configure = function(source, decision)
            source.BlockTypesAcrossWaves, source.MaxWaves = true, 2
            decision.waveCount = 2
            decision.waves[1] = { waveIndex = 1, types = {
                { nativeId = "Cinder", source = "addition" },
            }, counts = { Cinder = 1 } }
            decision.waves[2] = { waveIndex = 2, types = {
                { nativeId = "Ash", source = "addition" },
            }, counts = { Ash = 1 } }
        end },
        -- Wave 1's BlacklistAfterFirstAppearance member cannot recur in wave 2.
        { reason = "native-enemy-ineligible", configure = function(source, decision)
            source.MaxWaves = 2
            decision.waveCount = 2
            decision.waves[2] = probe.copy(decision.waves[1])
            decision.waves[2].waveIndex = 2
        end },
        { reason = "wave-count-out-of-range", configure = function(_, decision)
            decision.waveCount = 2
            decision.waves[2] = probe.copy(decision.waves[1])
            decision.waves[2].waveIndex = 2
        end },
    }
    for _, case in ipairs(cases) do
        local rawDraws, _, _, rawRestore = configuredProduction()
        local rawSource = declaration()
        case.configure(rawSource, fullDecision())
        local raw = SetupEncounter(rawSource, { Name = "rejection" })
        local rawRoster, rawBlacklist = same(raw.SpawnWaves), same(_G.CurrentRun.Blacklist)
        rawRestore()

        local draws, instance, _, restore = configuredProduction()
        _G.game.EnemyData = _G.EnemyData
        local source, decision = declaration(), fullDecision()
        case.configure(source, decision)
        local state = { state = "synchronized", diagnostics = {} }
        local realized = install(instance, state, { id = "rejection" }, phase("Combat", decision), { Name = "rejection" }, source)
        lu.assertEquals(state.state, "synchronized")
        lu.assertEquals(#state.diagnostics, 1)
        lu.assertEquals(state.diagnostics[1].observed.kind, "generated-admission")
        lu.assertEquals(state.diagnostics[1].observed.reason, case.reason)
        lu.assertNil(realized.__runPlannerGeneratedComposition)
        lu.assertEquals(same(realized.SpawnWaves), rawRoster)
        lu.assertEquals(same(_G.CurrentRun.Blacklist), rawBlacklist)
        lu.assertEquals(same(draws), same(rawDraws))
        restore()
    end
end

local function ownedRun(decision, source, destination)
    local draws, instance, callbacks, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local state = { state = "synchronized", diagnostics = {} }
    local target = destination or { Name = "probe", RoomSetName = "F" }
    local realized = install(instance, state, { id = "probe" }, phase("Combat", decision), target, source)
    local observed = {}
    for index, entry in ipairs(state.diagnostics) do observed[index] = entry.observed end
    return realized, draws, observed, restore, callbacks
end

local function rawRun(source)
    local draws, _, _, restore = configuredProduction()
    local realized = SetupEncounter(source, { Name = "probe" })
    return realized, draws, restore
end

function TestGeneratedEncounterNative.testVariableBaseRollUsesTheEffectiveRangeAndLeavesOtherDrawsNative()
    local variable = { BaseDifficultyMin = 10, BaseDifficultyMax = 30, MoneyDropCapMin = 3, MoneyDropCapMax = 5,
        ActiveEnemyCapMin = 4, ActiveEnemyCapMax = 6 }
    local raw, rawDraws, rawRestore = rawRun(declaration(variable))
    local rawCap = raw.ActiveEnemyCap
    rawRestore()
    lu.assertEquals({ rawDraws[1], rawDraws[2], rawDraws[3], rawDraws[4] },
        { { "int", 3, 5 }, { "int", 10, 30 }, { "int", 4, 6 }, { "int", 1, 1 } })

    local realized, draws, observed, restore = ownedRun(fullDecision({ baseRoll = 15, expectedBudget = 35 }),
        declaration(variable))
    lu.assertEquals(observed[1].kind, "generated-installed")
    lu.assertEquals(realized.DifficultyRating, 35)
    lu.assertEquals(realized.ActiveEnemyCap, rawCap)
    lu.assertEquals({ draws[1], draws[2], draws[3], draws[4] },
        { { "int", 3, 5 }, { "int", 15, 15 }, { "int", 4, 6 }, { "int", 1, 1 } })
    lu.assertEquals({ realized.BaseDifficultyMin, realized.BaseDifficultyMax }, { 10, 30 })
    restore()

    -- A nested native generation inside the owned scope keeps its own native roll.
    local draws2, instance, _, restoreNested = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local pending, nested = true, nil
    _G.GetTotalHeroTraitValue = function()
        if pending then
            pending = false
            nested = SetupEncounter(declaration(variable), { Name = "nested" })
        end
        return 1
    end
    local state = { state = "synchronized", diagnostics = {} }
    local outer = install(instance, state, { id = "outer" }, phase("Combat", fullDecision({ baseRoll = 15, expectedBudget = 35 })),
        { Name = "outer" }, declaration(variable))
    lu.assertEquals(nested.DifficultyRating, 30)
    lu.assertNil(nested.__runPlannerGeneratedComposition)
    lu.assertEquals(outer.DifficultyRating, 35)
    lu.assertNotNil(outer.__runPlannerGeneratedComposition)
    local rolls = {}
    for _, draw in ipairs(draws2) do
        if draw[1] == "int" and (draw[2] == 10 or draw[2] == 15) then rolls[#rolls + 1] = draw[2] .. ":" .. draw[3] end
    end
    lu.assertEquals(rolls, { "10:30", "15:15" })
    restoreNested()

    -- Declined after a valid roll: native continues from that retained legal input.
    local continued, continuedDraws, declined, restoreDeclined = ownedRun(fullDecision({ baseRoll = 15, expectedBudget = 99 }),
        declaration(variable))
    local continuedRoster, continuedList = same(continued.SpawnWaves), same(continuedDraws)
    lu.assertEquals(declined, { { kind = "generated-admission", reason = "budget-mismatch", expected = 99, observed = 35 } })
    lu.assertEquals(continued.DifficultyRating, 35)
    lu.assertNil(continued.__runPlannerGeneratedComposition)
    restoreDeclined()
    local fixedRoll = probe.copy(variable)
    fixedRoll.BaseDifficultyMin, fixedRoll.BaseDifficultyMax = 15, 15
    local native15, native15Draws, restore15 = rawRun(declaration(fixedRoll))
    lu.assertEquals(continuedRoster, same(native15.SpawnWaves))
    lu.assertEquals(continuedList, same(native15Draws))
    restore15()

    -- Hard overrides own the effective range and cannot erase an in-range roll.
    local hardValues = probe.copy(variable)
    hardValues.IsHardEncounter, hardValues.HardEncounterOverrideValues = true, { BaseDifficultyMin = 100, BaseDifficultyMax = 120 }
    local hardRaw, hardRawDraws, hardRawRestore = rawRun(declaration(hardValues))
    local hardRawList = same(hardRawDraws)
    lu.assertEquals(hardRaw.DifficultyRating, 120)
    hardRawRestore()
    local outside, outsideDraws, outsideObserved, restoreOutside = ownedRun(fullDecision({ baseRoll = 15, expectedBudget = 35 }),
        declaration(hardValues))
    lu.assertEquals(outsideObserved, { { kind = "generated-admission", reason = "base-roll-out-of-range",
        expected = { min = 100, max = 120 }, observed = 15 } })
    lu.assertEquals(same(outsideDraws), hardRawList)
    lu.assertEquals(outside.DifficultyRating, 120)
    restoreOutside()
    -- Native OverwriteTableKeys clears a "nil" hard range, so BaseDifficulty applies.
    local cleared = probe.copy(variable)
    cleared.IsHardEncounter, cleared.HardEncounterOverrideValues = true, { BaseDifficultyMin = "nil", BaseDifficultyMax = "nil" }
    local clearedRaw, clearedRawDraws, clearedRawRestore = rawRun(declaration(cleared))
    local clearedRawList = same(clearedRawDraws)
    lu.assertEquals(clearedRaw.DifficultyRating, 40)
    clearedRawRestore()
    local clearedOwned, clearedDraws, clearedObserved, restoreCleared = ownedRun(
        fullDecision({ baseRoll = 15, expectedBudget = 35 }), declaration(cleared))
    lu.assertEquals(clearedObserved, { { kind = "generated-admission", reason = "base-roll-out-of-range",
        expected = { min = "nil", max = "nil" }, observed = 15 } })
    lu.assertEquals(same(clearedDraws), clearedRawList)
    lu.assertEquals(clearedOwned.DifficultyRating, 40)
    restoreCleared()
    local inside, _, insideObserved, restoreInside = ownedRun(fullDecision({ baseRoll = 110, expectedBudget = 130 }),
        declaration(hardValues))
    lu.assertEquals(insideObserved[1].kind, "generated-installed")
    lu.assertEquals(inside.DifficultyRating, 130)
    lu.assertEquals(inside.HardEncounterOverrideValues, { BaseDifficultyMin = 100, BaseDifficultyMax = 120 })
    restoreInside()
end

function TestGeneratedEncounterNative.testAdmissionReadsTheNativeFinalBudget()
    for _, case in ipairs({
        { overrides = { DifficultyModifier = 5 }, hordes = 1.5, budget = 67.5 },
        { overrides = { MinimumDifficulty = 100 }, budget = 100 },
    }) do
        for _, expected in ipairs({ case.budget, 40 }) do
            local _, instance, _, restore = configuredProduction()
            _G.game.EnemyData = _G.EnemyData
            _G.MetaUpgradeData.EnemyCountShrineUpgrade.ChangeValue = case.hordes or 1
            local state = { state = "synchronized", diagnostics = {} }
            local realized = install(instance, state, { id = "budget" }, phase("Combat", fullDecision({ expectedBudget = expected })),
                { Name = "budget" }, declaration(case.overrides))
            local observed = { state.diagnostics[1].observed }
            lu.assertEquals(realized.DifficultyRating, case.budget)
            if expected == case.budget then
                lu.assertEquals(observed[1].kind, "generated-installed")
            else
                lu.assertEquals(observed[1], { kind = "generated-admission", reason = "budget-mismatch",
                    expected = 40, observed = case.budget })
            end
            restore()
        end
    end
end

function TestGeneratedEncounterNative.testAdmittedDecisionMountsEveryWaveWithoutReevaluation()
    local _, instance, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local eligibility, atFirstFill = 0, nil
    local nativeEligible, installedFill = _G.IsEnemyEligible, _G.FillEnemyTypes
    _G.IsEnemyEligible = function(...) eligibility = eligibility + 1; return nativeEligible(...) end
    _G.FillEnemyTypes = function(...)
        atFirstFill = atFirstFill or eligibility
        return installedFill(...)
    end
    local decision = {
        kind = "generated", decisionKey = "generatedComposition", expectedBudget = 40, waveCount = 3,
        highlight = { choiceKey = "Brine", nativeId = "Brine" },
        waves = {},
    }
    for index = 1, 3 do
        decision.waves[index] = { waveIndex = index, types = { { choiceKey = "Brine", nativeId = "Brine", source = "highlight" } },
            counts = { Brine = index } }
    end
    decision.waves[3].types[2] = { choiceKey = "Ash", nativeId = "Ash", source = "addition" }
    decision.waves[3].counts.Ash = 2
    local state = { state = "synchronized", diagnostics = {} }
    local realized = install(instance, state, { id = "mount" }, phase("Combat", decision), { Name = "mount" },
        declaration({ MaxWaves = 3 }))
    lu.assertEquals(state.diagnostics[1].observed.kind, "generated-installed")
    lu.assertTrue(eligibility > 0)
    lu.assertEquals(eligibility, atFirstFill)
    lu.assertEquals(#realized.SpawnWaves, 3)
    for index = 1, 3 do lu.assertEquals(realized.SpawnWaves[index].Spawns[1].TotalCount, index) end
    lu.assertEquals(realized.SpawnWaves[3].Spawns[2].Name, "Ash")
    lu.assertNil(realized.BlockHighlightEncounter)
    restore()
end

function TestGeneratedEncounterNative.testFangsAdmissionUsesNativeOrderedPerkEligibility()
    local fangs = { type = { choiceKey = "Brine", nativeId = "Brine" }, perks = { "Blink" } }
    for _, case in ipairs({
        {},
        { reason = "fangs-perk-unavailable", configure = function() _G.CurrentRun.BannedEliteAttributes.Blink = true end },
        { reason = "fangs-perk-unavailable", configure = function(source) source.BannedEliteAttributes = { "Blink" } end },
        { reason = "fangs-perk-unavailable", configure = function()
            _G.EnemyData.Brine.IsSuperElite = true
            _G.EnemyData.Brine.EliteAttributeData.Blink.RequiresFalseSuperElite = true
        end },
        { reason = "fangs-perk-unavailable", perks = { "Fog", "Blink" } },
        { perks = { "Blink", "Fog" } },
    }) do
        local _, instance, _, restore = configuredProduction()
        _G.game.EnemyData = _G.EnemyData
        _G.EnemyData.Brine.EliteAttributeOptions = { "Blink", "Fog" }
        _G.EnemyData.Brine.EliteAttributeData = { Blink = {}, Fog = { BlockAttributes = { "Blink" } } }
        local source = declaration()
        if case.configure then case.configure(source) end
        local selected = probe.copy(fangs)
        if case.perks then selected.perks = case.perks end
        local state = { state = "synchronized", diagnostics = {} }
        local realized = install(instance, state, { id = "fangs" }, phase("Combat", fullDecision({ fangs = selected })),
            { Name = "fangs" }, source)
        local observed = state.diagnostics[1].observed
        if case.reason then
            lu.assertEquals({ observed.kind, observed.reason, observed.perk }, { "generated-admission", case.reason, "Blink" })
            lu.assertNil(realized.__runPlannerGeneratedComposition)
        else
            lu.assertEquals(observed.kind, "generated-installed")
        end
        restore()
    end
end

function TestGeneratedEncounterNative.testPositiveMenaceAdmissionUsesNativeGatesAndMapping()
    local function menace(target, count)
        return { { waveIndex = 1, conversions = { conversion("Brine", target, count or 1) } } }
    end
    for _, case in ipairs({
        { target = "Ash" },
        { target = "Dawn", reason = "menace-target-unmapped" },
        { target = "Dawn", unmapped = true },
        { target = "Elite", unmapped = true, reason = "menace-target-unmapped" },
        { target = "Dawn", count = 0, vow = 0 },
        { target = "Ash", vow = 0, reason = "menace-vow-inactive" },
        { target = "Ash", visits = {}, reason = "menace-next-biome-unvisited" },
        { target = "Ash", visits = { G = 1 } },
        { target = "Ash", encounterBlock = true, reason = "menace-encounter-blocked" },
        { target = "Ash", sourceBlock = true, reason = "menace-source-blocked" },
    }) do
        local _, instance, _, restore = configuredProduction()
        _G.game.EnemyData = _G.EnemyData
        _G.MetaUpgradeData.NextBiomeEnemyShrineUpgrade = {
            SwapMap = case.unmapped and {} or { Brine = { Name = "Ash" } },
            BiomeEnemySets = { F = { "Dawn" } },
        }
        _G.GetShrineUpgradeChangeValue = function() return case.vow or 0.3 end
        if case.visits then _G.NextRoomSets, _G.GameState.BiomeVisits = { F = "G" }, case.visits end
        if case.encounterBlock then _G.EncounterData.ProbeGenerated = { BlockNextBiomeEnemyShrineUpgrade = true } end
        if case.sourceBlock then _G.EnemyData.Brine.BlockNextBiomeEnemyShrineUpgrade = true end
        local state = { state = "synchronized", diagnostics = {} }
        local realized = install(instance, state, { id = "menace" },
            phase("Combat", fullDecision({ menace = menace(case.target, case.count) })),
            { Name = "menace", RoomSetName = "F" }, declaration())
        local observed = state.diagnostics[1].observed
        if case.reason then
            lu.assertEquals({ observed.kind, observed.reason }, { "generated-admission", case.reason })
            lu.assertNil(realized.__runPlannerGeneratedComposition)
        else
            lu.assertEquals(observed.kind, "generated-installed")
        end
        restore()
    end
end

function TestGeneratedEncounterNative.testRepeatedCagePhasesAdmitAgainstTheLiveRunBlacklist()
    local _, instance, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    local state = { state = "synchronized", diagnostics = {} }
    local occurrence, destination = { id = "cages" }, { Name = "cages" }
    local first = install(instance, state, occurrence, phase("Cage01", fullDecision()), destination, declaration())
    lu.assertEquals(first.__runPlannerGeneratedComposition.slotKey, "Cage01")
    lu.assertTrue(_G.CurrentRun.Blacklist.Cinder)
    local repeated = install(instance, state, occurrence, phase("Cage02", fullDecision()), destination, declaration())
    lu.assertEquals({ state.diagnostics[2].observed.reason, state.diagnostics[2].observed.enemy },
        { "native-enemy-ineligible", "Cinder" })
    lu.assertNil(repeated.__runPlannerGeneratedComposition)
    local distinct = fullDecision({ waves = { { waveIndex = 1, types = {
        { choiceKey = "Ash", nativeId = "Ash", source = "addition" },
        { choiceKey = "Brine", nativeId = "Brine", source = "addition" },
    }, counts = { Ash = 1, Brine = 2 } } } })
    local second = install(instance, state, occurrence, phase("Cage02", distinct), destination, declaration())
    lu.assertEquals(second.__runPlannerGeneratedComposition.slotKey, "Cage02")
    lu.assertEquals(first.__runPlannerGeneratedComposition.slotKey, "Cage01")
    restore()
end

function TestGeneratedEncounterNative.testFixedSeedsBypassSamplingAndUniquePlaceholdersObservePriorSeeds()
    local _, instance, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    _G.CurrentRun.Blacklist.Ash = true
    local decision = fullDecision({ waves = { { waveIndex = 1, types = {
        { nativeId = "Ash", source = "fixed" }, { nativeId = "Brine", source = "template" },
    }, counts = { Ash = 1, Brine = 1 } } } })
    local source = declaration({ WaveTemplate = { Spawns = {
        { Name = "Ash", TotalCount = 1 }, { Generated = true, EnemySet = { "Brine" } },
    } } })
    local state = { state = "synchronized" }
    local realized = install(instance, state, { id = "fixed" }, phase("Combat", decision), {}, source)
    lu.assertNotNil(realized.__runPlannerGeneratedComposition)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[2].Name, "Brine")
    restore()
end

function TestGeneratedEncounterNative.testNativePostAdditionCapsAdmitValidPublishedMembers()
    local _, instance, _, restore = configuredProduction()
    _G.game.EnemyData = _G.EnemyData
    _G.EnemyData.Brine.IsElite, _G.EnemyData.Cinder.IsElite = true, true
    _G.EnemyData.Brine.Groups = { "cinder" }
    local source = declaration({ MaxEliteTypes = 2, MaxTypesPerGroup = { cinder = 2 } })
    local realized = install(instance, { state = "synchronized" }, { id = "caps" },
        phase("Combat", fullDecision()), {}, source)
    lu.assertNotNil(realized.__runPlannerGeneratedComposition)
    lu.assertEquals(#realized.SpawnWaves[1].Spawns, 2)
    restore()
end

os.exit(lu.LuaUnit.run())
