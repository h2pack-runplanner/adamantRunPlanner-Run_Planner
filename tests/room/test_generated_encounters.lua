-- Direct-installation witnesses use the shipped callbacks, not the retired
-- steering probe, and retain native count initialization.
local lu = require("luaunit")
local generatedDefinition = require("mods.room.timeline.encounters.generated")
local support = require("tests.harness.hook_composition")

TestGeneratedEncounters = {}

local function decision()
    return { kind = "generated", decisionKey = "generatedComposition", waveCount = 1, baseRoll = 42,
        fangs = { type = { choiceKey = "Elite", nativeId = "Elite" }, perks = { "Blink" } },
        waves = {{ waveIndex = 1, types = {
            { choiceKey = "Elite", nativeId = "Elite", source = "addition" },
            { choiceKey = "Cinder", nativeId = "Cinder", source = "addition" },
        }, counts = { Elite = 2, Cinder = 3 } }}, }
end

local function fixture()
    local module, _, callbacks = support.capture()
    local instance = generatedDefinition.create()
    local occurrence = { id = "generated" }
    local state = { state = "synchronized" }
    local phase = { slotKey = "Combat", encounterKey = "Generated", customization = { decision() } }
    local room = {
        occurrence = function() return occurrence end,
        encounterPhase = function(_, encounter)
            return encounter.__runPlannerGeneratedComposition and phase or nil
        end,
    }
    local diagnostics = {}
    instance.attach(module, { diagnostic = function(_, _, value) diagnostics[#diagnostics + 1] = value end },
        function() return state end, room)
    return callbacks, instance, state, room, phase, diagnostics
end

function TestGeneratedEncounters.testPriorRunBlacklistDelegatesWholeCompositionIncludingFangsAndMenace()
    local callbacks, instance, state, room, phase, diagnostics = fixture()
    local previous = _G.game
    _G.game = { EnemyData = {
        Elite = {}, Cinder = { BlacklistAfterFirstAppearance = true },
    } }
    local encounter = { Name = "Generated", MinWaves = 2, MaxWaves = 3,
        WaveTemplate = { Spawns = {} } }
    local run = { Blacklist = { Cinder = true } }
    local nativeTypes, nativeFangs, nativeSpawns = 0, 0, 0
    instance.withPhase(state, room, phase, {}, function()
        callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
            return callbacks.GenerateEncounter(nil, {}, function()
                lu.assertEquals({ data.MinWaves, data.MaxWaves }, { 2, 3 })
                lu.assertNil(data.BlockHighlightEncounter)
                lu.assertNil(data.BaseDifficultyMin)
                local wave = { WaveIndex = 1, Spawns = {} }
                data.SpawnWaves = { wave }
                callbacks.FillEnemyTypes(nil, {}, function()
                    nativeTypes = nativeTypes + 1
                    wave.Spawns = { { Name = "NativeChoice", TotalCount = 4 } }
                end, data, wave, nativeRoom)
                return data
            end, run, nativeRoom, data)
        end, encounter, {})
    end)
    callbacks.PickEncounterEliteAttributes(nil, {}, function() nativeFangs = nativeFangs + 1 end, encounter)
    local args = {}
    callbacks.HandleNextSpawn(nil, {}, function(_, _, _, _, actual)
        nativeSpawns = nativeSpawns + 1
        lu.assertIs(actual, args)
        lu.assertNil(actual.IgnoreShrineOverrides)
    end, encounter, false, nil, nil, args)
    lu.assertEquals({ nativeTypes, nativeFangs, nativeSpawns }, { 1, 1, 1 })
    lu.assertEquals(encounter.SpawnWaves[1].Spawns, { { Name = "NativeChoice", TotalCount = 4 } })
    lu.assertNil(encounter.__runPlannerGeneratedComposition)
    lu.assertEquals(diagnostics, {
        { kind = "generated-preflight", reason = "run-blacklisted-enemy", enemy = "Cinder" },
    })
    _G.game = previous
end

function TestGeneratedEncounters.testInstallsCompleteTypesCountsFangsAndZeroMenaceAtNativeContacts()
    local callbacks, instance, state, room, phase = fixture()
    local previous = _G.game
    _G.game = { EnemyData = {
        Elite = { IsElite = true, GeneratorData = { DifficultyRating = 4 } },
        Cinder = { BlacklistAfterFirstAppearance = true, GeneratorData = {
            DifficultyRating = 5, BlockEnemyTypes = { "Blocked" }, ActiveEnemyCapBonus = 2,
        } },
    } }
    local encounter = { Name = "Generated", MinWaves = 1, MaxWaves = 2,
        BaseDifficultyMin = 1, BaseDifficultyMax = 9, BlockTypesAcrossWaves = true,
        WaveTemplate = { Spawns = {} }, Blacklist = {} }
    local run, countInitialization = { Blacklist = {} }, 0
    local result = instance.withPhase(state, room, phase, {}, function()
        return callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
            callbacks.GenerateEncounter(nil, {}, function(currentRun, _, generated)
                generated.SpawnWaves = { { WaveIndex = 1, Spawns = {} } }
                local wave = generated.SpawnWaves[1]
                callbacks.FillEnemyTypes(nil, {}, function() error("types must not redraw") end,
                    generated, wave, nativeRoom)
                callbacks.FillEnemyTypes(nil, {}, function() error("types must not redraw") end,
                    generated, wave, nativeRoom)
                countInitialization = countInitialization + 1
                for _, spawn in ipairs(wave.Spawns) do
                    lu.assertNotNil(spawn.TotalCount)
                    spawn.Generated, spawn.GeneratorData = true, _G.game.EnemyData[spawn.Name].GeneratorData
                end
                return generated
            end, run, nativeRoom, data)
            return data
        end, encounter, nativeRoom)
    end)
    lu.assertEquals(result, encounter)
    lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves, encounter.BaseDifficultyMin }, { 1, 1, 42 })
    lu.assertEquals(encounter.SpawnWaves[1].Spawns[1].TotalCount, 2)
    lu.assertEquals(encounter.SpawnWaves[1].Spawns[2].TotalCount, 3)
    lu.assertEquals(countInitialization, 1)
    lu.assertTrue(run.Blacklist.Cinder)
    lu.assertTrue(encounter.Blacklist.Blocked)
    lu.assertEquals(encounter.ActiveEnemyCapBonus, 2)
    callbacks.PickEncounterEliteAttributes(nil, {}, function() error("Fangs must not redraw") end, encounter)
    lu.assertEquals(encounter.EliteAttributes, { Elite = { "Blink" } })
    local original, observed = {}, nil
    callbacks.HandleNextSpawn(nil, {}, function(_, _, _, _, args) observed = args end,
        encounter, false, nil, nil, original)
    lu.assertTrue(observed.IgnoreShrineOverrides)
    lu.assertNil(original.IgnoreShrineOverrides)
    _G.game = previous
end

function TestGeneratedEncounters.testUnsupportedTemplateFallsBackWithoutInstallingAMarker()
    local callbacks, instance, state, room, phase = fixture()
    local previous = _G.game
    _G.game = { EnemyData = { Elite = {}, Cinder = {} } }
    local encounter = { Name = "Generated", WaveTemplate = { Spawns = {} }, SpawnWaves = { {} },
        __runPlannerGeneratedComposition = { occurrenceId = "old" } }
    local nativeCalls = 0
    instance.withPhase(state, room, phase, {}, function()
        callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
            return callbacks.GenerateEncounter(nil, {}, function() nativeCalls = nativeCalls + 1; return data end,
                {}, nativeRoom, data)
        end, encounter, nativeRoom)
    end)
    lu.assertEquals(nativeCalls, 1)
    lu.assertNil(encounter.__runPlannerGeneratedComposition)
    _G.game = previous
end

function TestGeneratedEncounters.testLiveDeclarationDriftFallsBackBeforeMutation()
    local previous = _G.game
    for _, case in ipairs({
        { enemies = { Elite = {} }, spawns = {} },
        { enemies = { Elite = {}, Cinder = {} }, spawns = { { Name = "Unowned", TotalCount = 1 } } },
        { enemies = { Elite = {}, Cinder = {} }, spawns = { { Name = "Elite", TotalCount = 4 } },
            source = "fixed" },
        { enemies = { Elite = {}, Cinder = {} }, spawns = { { Name = "Elite", Generated = true } },
            source = "template" },
    }) do
        local callbacks, instance, state, room, phase = fixture()
        if case.source then phase.customization[1].waves[1].types[1].source = case.source end
        _G.game = { EnemyData = case.enemies }
        local encounter = { Name = "Generated", MinWaves = 2, MaxWaves = 3,
            WaveTemplate = { Spawns = case.spawns } }
        local nativeCalls = 0
        instance.withPhase(state, room, phase, {}, function()
            callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
                return callbacks.GenerateEncounter(nil, {}, function()
                    nativeCalls = nativeCalls + 1
                    lu.assertEquals({ data.MinWaves, data.MaxWaves }, { 2, 3 })
                    lu.assertNil(data.BlockHighlightEncounter)
                    return data
                end, {}, nativeRoom, data)
            end, encounter, {})
        end)
        lu.assertEquals(nativeCalls, 1)
        lu.assertNil(encounter.__runPlannerGeneratedComposition)
    end
    _G.game = previous
end
