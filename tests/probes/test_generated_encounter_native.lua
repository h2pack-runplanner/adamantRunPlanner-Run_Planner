-- Manual only: HADES2_SCRIPTS_PATH=/path/to/Scripts lua tests/probes/test_generated_encounter_native.lua
-- luacheck: globals TestGeneratedEncounterNative CurrentRun EnemyData EncounterData RewardData
-- luacheck: globals MetaUpgradeData ConstantsData RoomData WaveDifficultyPatterns SetupEncounter SetupRoomReward
-- luacheck: globals FillEnemyCounts RandomInt RandomNormal RemoveRandomValue SetupRoomMultipleEncountersData
-- luacheck: globals PickEncounterEliteAttributes PickEliteAttributes
local lu = require("luaunit")
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path
local probe = require("tests.probes.generated_encounter_native")
local coordinator = require("mods.room.coordinator")
local runtime = require("mods.runtime.session")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local generatedEncounter = require("mods.room.timeline.encounters.generated")
local scriptsPath = probe.scriptsPath(arg[1])
if arg[1] then table.remove(arg, 1) end -- The source path is not a LuaUnit test selector.

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
        GameState = { EncountersOccurredCache = {} },
        EncounterData = {}, RewardData = {}, game = {},
        MetaUpgradeData = { EnemyCountShrineUpgrade = { ChangeValue = 1 } }, ConstantsData = { MinimumDifficulty = 1 },
        RoomData = { BaseRoom = { MinDepthBeforeIntros = 0 } },
        WaveDifficultyPatterns = { [1] = { 1 }, [2] = { .5, .5 }, [3] = { .3, .15, .55 }, [4] = { .3, .1, .2, .4 } },
        EnemyData = {
            Ash = { GeneratorData = { DifficultyRating = 2 } }, Brine = { GeneratorData = { DifficultyRating = 3 } },
            Cinder = {
                BlacklistAfterFirstAppearance = true, Groups = { "cinder" },
                GeneratorData = { DifficultyRating = 5, BlockEnemyTypes = { "Ash" }, ActiveEnemyCapBonus = 2 },
            },
            Dawn = { Groups = { "cinder" }, GeneratorData = { DifficultyRating = 4 } },
            Elite = { IsElite = true, GeneratorData = { DifficultyRating = 4, MaxCount = 2 } },
        },
    }
end

local function declaration(overrides)
    local result = {
        Name = "ProbeGenerated", Generated = true, MoneyDropCapMin = 0, MoneyDropCapMax = 0,
        BaseDifficulty = 20, MinWaves = 2, MaxWaves = 2, MaxTypes = 3, MaxTypesCap = 3,
        TypeCountDepthRamp = 0, EnemySet = { "Ash", "Brine", "Cinder" }, WaveTemplate = { Spawns = {} },
    }
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

local function configured()
    local draws = {}
    local restore = probe.restore(native(draws))
    probe.loadBodies(scriptsPath)
    local contacts = probe.installContacts()
    return draws, contacts, restore
end

local function owner(id, slot, nativeRoom, overrides)
    local result = {
        occurrence = { id = id }, phase = { slotKey = slot }, nativeRoom = nativeRoom,
        encounterKey = "ProbeGenerated",
    }
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

local function close(contacts, restore) contacts.restore(); restore() end

-- Exercise the shipped scoped hooks against the same unmodified native bodies
-- as Gate A. The production helper is attached alone here so each intercepted
-- global has its real native base, rather than a probe-only selection adapter.
local function configuredProduction()
    local draws = {}
    local restore = probe.restore(native(draws))
    probe.loadBodies(scriptsPath)
    local callbacks, nativeBodies = {}, {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local instance = generatedEncounter.create()
    instance.attach(module, runtime)
    for _, name in ipairs({
        "SetupEncounter", "GenerateEncounter", "FillEnemyTypes", "FillEnemyCounts", "IsEnemyEligible",
        "RemoveRandomValue", "RandomNormal",
    }) do
        nativeBodies[name] = _G[name]
        _G[name] = function(...)
            return callbacks[name](nil, {}, nativeBodies[name], ...)
        end
    end
    return draws, instance, restore
end

TestGeneratedEncounterNative = {}

function TestGeneratedEncounterNative.testDefaultParityAndScopedCopiedWaveHighlightAndTypeContacts()
    local rawDraws, rawContacts, rawRestore = configured()
    rawContacts.restore()
    local raw = SetupEncounter(declaration(), { Name = "raw" })
    local rawRoster, rawBlacklist = same(raw.SpawnWaves), same(raw.Blacklist)
    rawRestore()

    local defaultDraws, defaultContacts, defaultRestore = configured()
    local defaultOwner = owner("occ-default", "O-1", { Name = "default" }, { encounterKey = "ProbeGenerated" })
    local default = defaultContacts.withOwner(defaultOwner, function()
        return SetupEncounter(declaration(), defaultOwner.nativeRoom)
    end)
    lu.assertEquals(same(default.SpawnWaves), rawRoster)
    lu.assertEquals(same(default.Blacklist), rawBlacklist)
    lu.assertEquals(same(defaultDraws), same(rawDraws))
    close(defaultContacts, defaultRestore)

    local draws, contacts, restore = configured()
    local destination = { Name = "destination" }
    local scoped = owner("occ-o", "O-2", destination, {
        encounterKey = "ProbeGenerated", waveCount = 3, highlight = "Brine", typesByWave = { [2] = { "Cinder" } },
    })
    local realized = contacts.withOwner(scoped, function() return SetupEncounter(declaration(), destination) end)
    lu.assertEquals(realized.WaveCount, 3)
    lu.assertNotEquals(same(realized.SpawnWaves), rawRoster)
    lu.assertNotEquals(same(realized.Blacklist), rawBlacklist)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[2].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[2].Spawns[2].Name, "Cinder")
    lu.assertEquals(scoped.generations[1].encounter, realized)
    lu.assertEquals(scoped.generations[1].nativeRoom, destination)
    lu.assertEquals(scoped.removes, {
        { occurrenceId = "occ-o", phase = "O-2", wave = 0, enemyName = "Brine" },
        { occurrenceId = "occ-o", phase = "O-2", wave = 2, enemyName = "Cinder" },
    })
    lu.assertTrue(#draws > 0)
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testDevotionScopeUsesStampedDestinationAndNativePredecessor()
    local _, contacts, restore = configured()
    local occurrence = { id = "destination-devotion", overview = { encounterPhases = { { slotKey = "Devotion", encounterKey = "DevotionProbe" } } } }
    local destination = { Name = "Destination", __runPlannerExecutionRoomId = occurrence.id, ChosenRewardType = "Devotion", DevotionEncounters = { "DevotionProbe" } }
    local predecessor = { Name = "Predecessor" }
    local state = {
        state = "synchronized", room = coordinator.new({ occurrencesById = { [occurrence.id] = occurrence } }),
        plan = { occurrencesById = { [occurrence.id] = occurrence } },
    }
    lu.assertEquals(coordinator.occurrence(state, destination), occurrence)
    lu.assertEquals(coordinator.encounterAt(state, 1, destination), occurrence.overview.encounterPhases[1])
    _G.CurrentRun.CurrentRoom = predecessor
    _G.EncounterData, _G.RewardData = { DevotionProbe = declaration({ Name = "DevotionProbe", MinTypes = 1 }) }, {}
    local scoped = owner(occurrence.id, "Devotion", destination, { encounterKey = "DevotionProbe", waveCount = 3, highlight = "Cinder" })
    scoped.occurrence = coordinator.occurrence(state, destination)
    scoped.phase = coordinator.encounterAt(state, 1, destination)
    contacts.withOwner(scoped, function() SetupRoomReward(_G.CurrentRun, destination, nil, {}) end)
    lu.assertEquals(scoped.generations[1].nativeRoom, predecessor)
    lu.assertEquals(destination.Encounter.WaveCount, 3)
    lu.assertEquals(destination.Encounter.SpawnWaves[1].Spawns[1].Name, "Cinder")
    lu.assertEquals(scoped.generations[1].owner.occurrence.id, occurrence.id)
    lu.assertEquals(scoped.removes[1].occurrenceId, occurrence.id)
    lu.assertEquals(scoped.removes[1].phase, "Devotion")
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testNativeCountBranchesMapSamplesToSpawnIdentityAndKeepRemainderCaps()
    local _, contacts, restore = configured()
    local destination = { Name = "destination" }
    local scoped = owner("occ-h", "H-2", destination, {
        slicesByEnemy = { Brine = 12, Elite = 4 },
    })
    local data = declaration({ MinWaves = 1, MaxWaves = 1, MaxTypesCap = 4 })
    data.EnemySet = { "Ash", "Brine", "Cinder", "Elite", "Dawn" }
    data.WaveTemplate = { MinTypes = 4, MaxTypes = 4, Spawns = {
        { Name = "Ash", TotalCount = 2 }, -- fixed index one
        { Name = "Brine" },               -- sampled: index two ~= generated count three
        { Name = "Cinder" },              -- native remainder: index three == generated count
        { Name = "Elite" },               -- sampled: index four ~= generated count three
    } }
    local realized = contacts.withOwner(scoped, function() return SetupEncounter(data, destination) end)
    local wave = realized.SpawnWaves[1]
    lu.assertEquals(scoped.samples, {
        { occurrenceId = "occ-h", phase = "H-2", wave = 1, spawnIndex = 2, enemyName = "Brine", mean = 40 / 3, deviation = 40 / 9, requested = 12 },
        { occurrenceId = "occ-h", phase = "H-2", wave = 1, spawnIndex = 4, enemyName = "Elite", mean = 40 / 3, deviation = 40 / 9, requested = 4 },
    })
    lu.assertEquals(wave.Spawns[1].TotalCount, 2)
    lu.assertEquals(wave.Spawns[2].TotalCount, 4) -- requested 12 / native rating 3
    lu.assertEquals(wave.Spawns[3].TotalCount, 5) -- native remainder after fixed/sample cost
    lu.assertEquals(wave.Spawns[4].TotalCount, 1) -- requested 4 / cap/min stay native
    local cappedOwner = owner("occ-o", "Combat1", destination, { slicesByEnemy = { Elite = 34, Brine = 4 } })
    local cappedData = declaration({ MinWaves = 1, MaxWaves = 1, EnemySet = { "Elite", "Brine", "Ash", "Dawn" } })
    cappedData.WaveTemplate = { Spawns = {}, MinTypes = 3, MaxTypes = 3 }
    local capped = contacts.withOwner(cappedOwner, function() return SetupEncounter(cappedData, destination) end)
    lu.assertEquals(capped.SpawnWaves[1].Spawns[1].TotalCount, 2) -- MaxCount, not requested 34 / 4
    lu.assertEquals(capped.SpawnWaves[1].Spawns[2].TotalCount, 2) -- native ceiling of 4 / 3
    lu.assertEquals(capped.SpawnWaves[1].Spawns[3].TotalCount, 13) -- native remainder, not an exact 5% share
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testExactOrdinaryTypesPreserveNativePostAddEffects()
    local _, contacts, restore = configured()
    local room = { Name = "ordinary" }
    local scoped = owner("ordinary", "Encounter", room, { typesByWave = { [1] = { "Cinder", "Brine" } } })
    local data = declaration({
        MinWaves = 1, MaxWaves = 1, MinTypes = 1, MaxTypes = 3,
        EnemySet = { "Ash", "Cinder", "Dawn", "Brine" }, BlockTypesAcrossWaves = true,
        MaxTypesPerGroup = { cinder = 1 },
    })
    local realized = contacts.withOwner(scoped, function() return SetupEncounter(data, room) end)
    lu.assertEquals(realized.SpawnWaves[1].TypeCount, 2)
    lu.assertEquals(#realized.SpawnWaves[1].Spawns, 2)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Cinder")
    lu.assertEquals(realized.SpawnWaves[1].Spawns[2].Name, "Brine")
    lu.assertTrue(_G.CurrentRun.Blacklist.Cinder)
    lu.assertTrue(realized.Blacklist.Ash)
    lu.assertEquals(realized.ActiveEnemyCapBonus, 2)
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testHFixedMemberAndNativeGeneratedPlaceholderRemainMixed()
    local _, contacts, restore = configured()
    local room = { Name = "H_Combat" }
    local scoped = owner("occ-h-mixed", "H-1", room, { typesByWave = { [1] = { "Dawn" } } })
    local data = declaration({ BlockHighlightEncounter = true, MinWaves = 1, MaxWaves = 1 })
    data.WaveTemplate = {
        MinTypes = 2, MaxTypes = 2,
        Spawns = { { Name = "Ash", TotalCount = 2 }, { Generated = true, EnemySet = { "Brine", "Dawn" } } },
    }
    local realized = contacts.withOwner(scoped, function() return SetupEncounter(data, room) end)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].TotalCount, 2)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[2].Name, "Dawn")
    lu.assertTrue(realized.SpawnWaves[1].Spawns[2].TotalCount >= 1)
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testNativeIntroReplacementCannotInheritCustomization()
    local _, contacts, restore = configured()
    local room = { Name = "intro" }
    local scoped = owner("intro", "Encounter", room, { waveCount = 3, highlight = "Brine" })
    _G.EnemyData.Brine.IntroEncounterName = "Introduction"
    _G.HasEncounterBeenCompleted = function(name) return name ~= "Introduction" end
    _G.EncounterData.Introduction = declaration({ Name = "Introduction", MinWaves = 1, MaxWaves = 1, MinTypes = 1 })
    local realized = contacts.withOwner(scoped, function() return SetupEncounter(declaration(), room) end)
    lu.assertEquals(realized.Name, "Introduction")
    lu.assertEquals(realized.WaveCount, 1)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Ash")
    lu.assertEquals(#scoped.generations, 1)
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testIneligibleRequestRecordsDestinationDiagnosticAndDelegatesNativePool()
    local _, contacts, restore = configured()
    local occurrence = { id = "destination-p", diagnostics = { ["encounter-composition"] = "requested type" } }
    local destination = { Name = "destination", __runPlannerExecutionRoomId = occurrence.id }
    local state = { state = "synchronized", diagnostics = {} }
    local scoped = owner(occurrence.id, "P-2", destination, { encounterKey = "ProbeGenerated", typesByWave = { [1] = { "Ash" } } })
    _G.EnemyData.Ash.GameStateRequirements = { Never = true }
    scoped.onIneligible = function(scope, requested)
        runtime.diagnostic(state, "encounter-composition", {
            phase = scoped.phase.slotKey, wave = scope.wave.WaveIndex, requested = requested, reason = "native-ineligible",
        }, occurrence)
    end
    local data = declaration({ BlockHighlightEncounter = true, MinWaves = 1, MaxWaves = 1 })
    data.WaveTemplate = { Spawns = {}, MinTypes = 1, MaxTypes = 1 }
    local realized = contacts.withOwner(scoped, function() return SetupEncounter(data, destination) end)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.diagnostics[1], {
        occurrenceId = occurrence.id, checkpoint = "encounter-composition", expected = "requested type",
        observed = { phase = "P-2", wave = 1, requested = "Ash", reason = "native-ineligible" },
    })
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testNestedGenerationAndErrorsRestoreNativeDraws()
    local draws, contacts, restore = configured()
    local outer = owner("outer", "O-1", { Name = "outer" }, { waveCount = 3, highlight = "Brine" })
    local inner = owner("inner", "P-1", { Name = "inner" }, { encounterKey = "ProbeGenerated", waveCount = 2 })
    local incidental
    _G.RunEventsGeneric = function()
        incidental = SetupEncounter(declaration(), outer.nativeRoom)
        lu.assertEquals(RandomNormal(9, 3), 9)
    end
    contacts.withOwner(outer, function()
        contacts.withOwner(inner, function() SetupEncounter(declaration(), inner.nativeRoom) end)
        local realized = SetupEncounter(declaration({ SetupEvents = {} }), outer.nativeRoom)
        lu.assertEquals(realized.WaveCount, 3)
    end)
    lu.assertEquals(incidental.WaveCount, 2)
    lu.assertEquals(incidental.SpawnWaves[1].Spawns[1].Name, "Ash")
    lu.assertEquals(inner.generations[1].owner.phase.slotKey, "P-1")
    local generator = _G.EnemyData.Brine.GeneratorData
    _G.EnemyData.Brine.GeneratorData = nil
    lu.assertErrorMsgContains("GeneratorData", function()
        contacts.withOwner(outer, function() SetupEncounter(declaration(), outer.nativeRoom) end)
    end)
    _G.EnemyData.Brine.GeneratorData = generator
    lu.assertNil(contacts.current())
    lu.assertEquals(RandomNormal(9, 3), 9)
    lu.assertEquals(RemoveRandomValue({ "Ash", "Brine" }), "Ash")
    lu.assertTrue(#draws > 0)
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testNativeMultipleAssemblyUsesProposedPhaseCarrierForSameNameAdjacentPhases()
    local _, contacts, restore = configured()
    probe.loadRoomMultipleBody(scriptsPath)
    local nativeChoose, nativeMultiple = _G.ChooseEncounter, _G.SetupRoomMultipleEncountersData
    local function assemble(roomName, slots, counts, multiple)
        local occurrence = { id = roomName, overview = { encounterPhases = {} } }
        local bySlot = {}
        local nativeRoom = { Name = roomName, __runPlannerExecutionRoomId = roomName, MultipleEncountersData = {} }
        for i, slot in ipairs(slots) do
            local phase = { slotKey = slot, encounterKey = "SameGenerated" }
            occurrence.overview.encounterPhases[i] = phase
            nativeRoom.MultipleEncountersData[i] = {}
            bySlot[slot] = { count = counts[i], target = ({ "Ash", "Brine", "Dawn" })[i] }
        end
        local plan = { occurrencesById = { [roomName] = occurrence } }
        local state = { state = "synchronized", plan = plan, room = coordinator.new(plan) }
        local selectedPhase, generated = nil, {}
        -- Observe the existing hook's phase resolution, not a second cursor.
        -- Production will pass its local `phase` explicitly at this same base call.
        local roomContact = setmetatable({ encounterAt = function(...)
            local phase = coordinator.encounterAt(...)
            if phase then selectedPhase = phase end
            return phase
        end }, { __index = coordinator })
        local callbacks = {}
        local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
        encounterHooks.attach(module, runtime, function() return state end, function() end, roomContact, {
            preparePhases = function() return function() end end, attach = function() end,
        })
        _G.game.EncounterData = { SameGenerated = declaration({
            Name = "SameGenerated", MinWaves = 1, MaxWaves = 3, MinTypes = 1,
            EnemySet = { "Ash", "Brine", "Dawn" },
        }) }
        _G.ChooseEncounter = function(run, room, args)
            return callbacks.ChooseEncounter(nil, {}, function(innerRun, innerRoom, innerArgs)
                local phase = assert(selectedPhase)
                local request = bySlot[phase.slotKey]
                local scoped = owner(occurrence.id, phase.slotKey, innerRoom, {
                    encounterKey = phase.encounterKey, waveCount = request.count, highlight = request.target,
                    typesByWave = request.count == 1 and { [1] = { request.target } } or nil,
                })
                scoped.occurrence, scoped.phase = coordinator.occurrence(state, innerRoom), phase
                local result = contacts.withOwner(scoped, function() return nativeChoose(innerRun, innerRoom, innerArgs) end)
                lu.assertEquals(scoped.generations[1].owner.phase, phase)
                generated[#generated + 1] = result
                return result
            end, run, room, args)
        end
        if multiple then
            callbacks.SetupRoomMultipleEncountersData(nil, {}, nativeMultiple, nativeRoom, {})
        else
            for _ = 1, #slots do _G.ChooseEncounter(_G.CurrentRun, nativeRoom, {}) end
        end
        lu.assertEquals(#generated, #slots)
        for i, result in ipairs(generated) do
            lu.assertEquals(result.Name, "SameGenerated")
            lu.assertEquals(result.WaveCount, counts[i])
            lu.assertEquals(result.SpawnWaves[1].Spawns[1].Name, bySlot[slots[i]].target)
            local binding = state.room.encounterPhases.forNative(result)
            lu.assertEquals(binding.occurrenceId, roomName)
            lu.assertEquals(binding.phase.slotKey, slots[i])
            if i > 1 then lu.assertFalse(rawequal(result, generated[i - 1])) end
        end
        lu.assertNil(_G.CurrentRun.ForceNextEncounterData)
    end
    assemble("O_Combat", { "Intro", "Combat1", "Combat2" }, { 1, 2, 2 }, true)
    assemble("P_Combat", { "Intro", "Combat" }, { 1, 2 }, true)
    assemble("H_Combat", { "Passive", "Cage1", "Cage2" }, { 1, 1, 1 }, false)
    _G.ChooseEncounter = nativeChoose
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testNpcAndHardCapNativeShapedContacts()
    local _, contacts, restore = configured()
    local room = { Name = "npc" }
    local npc = owner("npc-o", "O-3", room, { highlight = "Brine" })
    local data = declaration({ MinWaves = 3, MaxWaves = 3, BlockHighlightEliteTypes = true, UseEncounterDepthForTypes = true, EscalateTypeCount = true, TypeCountDepthRamp = 1 })
    _G.CurrentRun.BiomeEncounterDepth = 2
    data.EnemySet = { "Ash", "Brine", "Elite" }
    local realized = contacts.withOwner(npc, function() return SetupEncounter(data, room) end)
    lu.assertEquals(realized.WaveCount, 3)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    for _, spawn in ipairs(realized.SpawnWaves[1].Spawns) do lu.assertNotEquals(spawn.Name, "Elite") end
    local hard = owner("hard-o", "O-4", room, {})
    local capped = contacts.withOwner(hard, function()
        return SetupEncounter(declaration({ IsHardEncounter = true, EscalateTypeCount = true, TypeCountDepthRamp = 1, HardEncounterOverrideValues = { MaxTypesCap = 1 } }), room)
    end)
    lu.assertEquals(capped.SpawnWaves[1].TypeCount, 1)
    close(contacts, restore)
end

function TestGeneratedEncounterNative.testProductionScopedHooksKeepDefaultsAndSteerPublishedOperands()
    local rawDraws, _, rawRestore = configuredProduction()
    local raw = SetupEncounter(declaration({ MinWaves = 1, MaxWaves = 1, MinTypes = 1 }), { Name = "raw" })
    local rawRoster = same(raw.SpawnWaves)
    rawRestore()

    local defaultDraws, defaultGenerated, defaultRestore = configuredProduction()
    local defaultOccurrence = { id = "production-default" }
    local defaultDestination = { Name = "default", __runPlannerExecutionRoomId = defaultOccurrence.id }
    local defaultState = { state = "synchronized" }
    local default = defaultGenerated.withPhase(defaultState, {}, {
        slotKey = "Combat1", encounterKey = "ProbeGenerated",
    }, defaultDestination, function()
        return SetupEncounter(declaration({ MinWaves = 1, MaxWaves = 1, MinTypes = 1 }), defaultDestination)
    end)
    lu.assertEquals(same(default.SpawnWaves), rawRoster)
    lu.assertEquals(same(defaultDraws), same(rawDraws))
    defaultRestore()

    local draws, generated, restore = configuredProduction()
    local occurrence = { id = "production", diagnostics = { ["encounter-composition"] = "published" } }
    local destination = { Name = "destination", __runPlannerExecutionRoomId = occurrence.id }
    local state = { state = "synchronized", diagnostics = {} }
    local phase = {
        slotKey = "Combat2", encounterKey = "ProbeGenerated",
        customization = { {
            kind = "generated", decisionKey = "generatedComposition", waveCount = 3,
            highlight = { choiceKey = "Brine", nativeId = "Brine" },
            waves = {
                { waveIndex = 1, types = { { choiceKey = "Brine", nativeId = "Brine" } } },
                { waveIndex = 2, types = {
                    { choiceKey = "Brine", nativeId = "Brine" }, { choiceKey = "Cinder", nativeId = "Cinder" },
                }, shares = { .75, .25 } },
            },
        } },
    }
    local roomContact = {
        occurrence = function(receivedState, receivedRoom)
            lu.assertEquals(receivedState, state)
            lu.assertEquals(receivedRoom, destination)
            return occurrence
        end,
    }
    local source = declaration({ MinWaves = 1, MaxWaves = 1, MinTypes = 1, MaxTypes = 2, MaxTypesCap = 2 })
    source.WaveTemplate = { Spawns = {}, MinTypes = 1, MaxTypes = 2 }
    local realized = generated.withPhase(state, roomContact, phase, destination, function()
        return SetupEncounter(source, destination)
    end)
    lu.assertEquals(source.MinWaves, 1) -- native declaration remains shared/default.
    lu.assertEquals(realized.WaveCount, 3)
    lu.assertEquals(realized.SpawnWaves[1].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[2].Spawns[1].Name, "Brine")
    lu.assertEquals(realized.SpawnWaves[2].Spawns[2].Name, "Cinder")
    lu.assertNotEquals(same(realized.SpawnWaves), rawRoster)
    -- The requested unequal shares steer the native sample; native rounding,
    -- caps and final remainder still decide the realized counts.
    lu.assertNotEquals(realized.SpawnWaves[2].Spawns[1].TotalCount,
        realized.SpawnWaves[2].Spawns[2].TotalCount)
    lu.assertTrue(#draws > 0)
    lu.assertTrue(#rawDraws > 0)
    restore()
end

function TestGeneratedEncounterNative.testProductionHooksRetainFixedEntriesAndNativeHordesCaps()
    local _, generated, restore = configuredProduction()
    local occurrence = { id = "production-fixed" }
    local destination = { Name = "fixed", __runPlannerExecutionRoomId = occurrence.id }
    local state = { state = "synchronized" }
    local phase = {
        slotKey = "Cage", encounterKey = "ProbeGenerated",
        customization = { { kind = "generated", decisionKey = "generatedComposition", waves = {
            { waveIndex = 1, types = {
                { choiceKey = "Brine", nativeId = "Brine" },
                { choiceKey = "Cinder", nativeId = "Cinder" },
                { choiceKey = "Elite", nativeId = "Elite" },
            }, shares = { .2, .4, .4 } },
        } } },
    }
    local source = declaration({
        BlockHighlightEncounter = true, MinWaves = 1, MaxWaves = 1, MinTypes = 3, MaxTypes = 4, MaxTypesCap = 4,
        EnemySet = { "Ash", "Brine", "Cinder", "Elite", "Dawn" },
    })
    source.WaveTemplate = { MinTypes = 3, MaxTypes = 4, Spawns = {
        { Name = "Ash", TotalCount = 2 }, { Name = "Brine" }, { Name = "Cinder" }, { Name = "Elite" },
    } }
    _G.MetaUpgradeData.EnemyCountShrineUpgrade.ChangeValue = 1.6
    local realized = generated.withPhase(state, { occurrence = function() return occurrence end }, phase, destination,
        function() return SetupEncounter(source, destination) end)
    local wave = realized.SpawnWaves[1]
    lu.assertEquals(wave.Spawns[1].TotalCount, 2)
    lu.assertTrue(realized.DifficultyRating > 40) -- Hordes remains native input to the copied encounter.
    lu.assertEquals(wave.Spawns[2].TotalCount, 5)
    lu.assertEquals(wave.Spawns[3].TotalCount, 9) -- full-index native remainder branch.
    lu.assertEquals(wave.Spawns[4].TotalCount, 1)

    probe.loadEliteAttributeBody(scriptsPath)
    local priorPick, picked = _G.PickEliteAttributes, nil
    _G.PickEliteAttributes = function(_, name) picked = name end
    PickEncounterEliteAttributes(realized)
    _G.PickEliteAttributes = priorPick
    lu.assertEquals(picked, "Elite") -- Fangs remains a later native contact, after scoped generation.
    restore()
end

function TestGeneratedEncounterNative.testProductionHooksKeepNativeEliteCountCap()
    local _, generated, restore = configuredProduction()
    local occurrence = { id = "production-cap" }
    local destination = { Name = "cap", __runPlannerExecutionRoomId = occurrence.id }
    local state = { state = "synchronized" }
    local phase = {
        slotKey = "CageCap", encounterKey = "ProbeGenerated",
        customization = { { kind = "generated", decisionKey = "generatedComposition", waves = {
            { waveIndex = 1, types = {
                { choiceKey = "Elite", nativeId = "Elite" },
                { choiceKey = "Brine", nativeId = "Brine" },
                { choiceKey = "Dawn", nativeId = "Dawn" },
            }, shares = { .85, .1, .05 } },
        } } },
    }
    local source = declaration({
        BlockHighlightEncounter = true, MinWaves = 1, MaxWaves = 1, MinTypes = 3, MaxTypes = 3, MaxTypesCap = 3,
        EnemySet = { "Elite", "Brine", "Dawn" },
    })
    source.WaveTemplate = { MinTypes = 3, MaxTypes = 3, Spawns = {} }
    _G.MetaUpgradeData.EnemyCountShrineUpgrade.ChangeValue = 1.6
    local capped = generated.withPhase(state, { occurrence = function() return occurrence end }, phase, destination,
        function() return SetupEncounter(source, destination) end)
    lu.assertEquals(capped.SpawnWaves[1].Spawns[1].TotalCount, 2) -- native Elite MaxCount.
    restore()
end

os.exit(lu.LuaUnit.run())
