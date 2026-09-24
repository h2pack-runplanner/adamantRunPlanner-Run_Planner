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

local function ownedSpawnProbe(conversions, roster, fangs)
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
    _G.MetaUpgradeData.NextBiomeEnemyShrineUpgrade = { SwapMap = {
        Brine = { Name = "Ash", RequiredSpawnPoint = "MappedPoint", ActiveCapWeight = 3 },
        Cinder = { Name = "Ash" },
    }, BiomeEnemySets = {} }
    local occurrence, destination = { id = "menace" }, { Name = "menace", __runPlannerExecutionRoomId = "menace" }
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
    lu.assertEquals(spawned[4].RequiredSpawnPoint, "nil")
    restore()
end

function TestGeneratedEncounterNative.testMappedGroupRecursionConsumesOneSourceRequestAndPreservesMetadata()
    local encounter, spawned, _, selections, restore = ownedSpawnProbe({ conversion("Brine", "Group", 1) })
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
    lu.assertEquals(spawned[1].RequiredSpawnPoint, "nil")
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

function TestGeneratedEncounterNative.testLiveAdmissionRejectsWholeCompositionBeforeAnyMutation()
    local cases = {
        function() _G.EnemyData.Brine.GameStateRequirements = { Never = true } end,
        function() _G.CurrentRun.Blacklist.Brine = true end,
        function(source) source.Blacklist = { Brine = true } end,
        function(source) source.EnemySet = { "Ash", "Cinder" } end,
        function(source)
            _G.EnemyData.Brine.IsElite = true
            source.WaveTemplate.BlockEliteTypes = true
        end,
        function()
            _G.EnemyData.Brine.IntroEncounterName = "Unseen"
            _G.EnemyData.Brine.IneligibleIfUncompletedIntroEncounter = true
            _G.HasEncounterBeenCompleted = function() return false end
        end,
        function() _G.game.IsEnemyEligible = function() error("predicate failed") end end,
        function(source)
            source.MaxEliteTypes = 1
            _G.EnemyData.Brine.IsElite, _G.EnemyData.Cinder.IsElite = true, true
        end,
        function(source)
            source.MaxTypesPerGroup = { cinder = 1 }
            _G.EnemyData.Brine.Groups = { "cinder" }
        end,
        function(source, decision)
            source.BlockTypesAcrossWaves = true
            decision.waveCount = 2
            decision.waves[1] = { waveIndex = 1, types = {
                { nativeId = "Cinder", source = "addition" },
            }, counts = { Cinder = 1 } }
            decision.waves[2] = { waveIndex = 2, types = {
                { nativeId = "Ash", source = "addition" },
            }, counts = { Ash = 1 } }
        end,
        function(_, decision)
            decision.waveCount = 2
            decision.waves[2] = probe.copy(decision.waves[1])
            decision.waves[2].waveIndex = 2
        end,
    }
    for _, configure in ipairs(cases) do
        local _, instance, callbacks, restore = configuredProduction()
        _G.game.EnemyData = _G.EnemyData
        local source, decision = declaration(), fullDecision()
        configure(source, decision)
        local original, blacklist = same(source), same(_G.CurrentRun.Blacklist)
        local state, occurrence = { state = "synchronized" }, { id = "rejection" }
        local calls = 0
        instance.withPhase(state, { occurrence = function() return occurrence end }, phase("Combat", decision), {}, function()
            callbacks.SetupEncounter(nil, {}, function(data, room)
                return callbacks.GenerateEncounter(nil, {}, function(_, _, encounter)
                    calls = calls + 1
                    lu.assertEquals(same(encounter), original)
                    lu.assertEquals(same(_G.CurrentRun.Blacklist), blacklist)
                    return encounter
                end, _G.CurrentRun, room, data)
            end, source, {})
        end)
        lu.assertEquals(calls, 1)
        lu.assertEquals(state.state, "synchronized")
        lu.assertEquals(#state.diagnostics, 1)
        lu.assertEquals(state.diagnostics[1].observed.kind, "generated-preflight")
        lu.assertNil(source.__runPlannerGeneratedComposition)
        restore()
    end
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
