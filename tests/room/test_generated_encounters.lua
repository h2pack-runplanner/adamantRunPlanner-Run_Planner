-- Scoped realization witnesses for optional generated encounter operands.
-- luacheck: globals TestGeneratedEncounters
local lu = require("luaunit")
local runtime = require("mods.runtime.session")
local generatedDefinition = require("mods.room.timeline.encounters.generated")
local support = require("tests.harness.hook_composition")

TestGeneratedEncounters = {}

local function fixture()
    local module, _, callbacks = support.capture()
    local generated = generatedDefinition.create()
    generated.attach(module, runtime)
    local occurrence = { id = "generated", diagnostics = { ["encounter-composition"] = "published" } }
    local state = { state = "synchronized", diagnostics = {} }
    local room = { occurrence = function() return occurrence end }
    local destination = { __runPlannerExecutionRoomId = occurrence.id }
    return callbacks, generated, state, room, destination
end

local function phase(decision)
    return { slotKey = "Combat", encounterKey = "Generated", customization = decision and { decision } or nil }
end

local function decision(values)
    values = values or {}
    values.kind, values.decisionKey = "generated", "generatedComposition"
    return values
end

function TestGeneratedEncounters.testGeneratedResultSnapshotsAllocationWithoutTrackingSpawns()
    local callbacks, generated, state, room, destination = fixture()
    local encounter = { Name = "Generated" }
    local authored = phase(decision({ waveCount = 1, waves = {
        { waveIndex = 1, types = { { nativeId = "Ash" } } },
    } }))
    local result = generated.withPhase(state, room, authored, destination, function()
        return callbacks.SetupEncounter(nil, {}, function()
            return callbacks.GenerateEncounter(nil, {}, function()
                encounter.SpawnWaves = { { Spawns = {
                    { Name = "Ash", TotalCount = 4 },
                    { Name = "Template", CountMin = 1, CountMax = 2 },
                } } }
                return "native-result"
            end, {}, destination, encounter)
        end, encounter, destination)
    end)
    encounter.SpawnWaves[1].Spawns[1].TotalCount = 99
    lu.assertEquals(result, "native-result")
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.diagnostics[1].observed, {
        kind = "generated-result", phase = "Combat", encounterKey = "Generated",
        requestedWaveCount = 1, baseRollUsed = false, nativeHardEncounter = false, waveCount = 1, waves = {
            { wave = 1, requested = { { name = "Ash" } }, spawns = {
                { name = "Ash", count = 4 }, { name = "Template", countMin = 1, countMax = 2 },
            } },
        },
    })
end

function TestGeneratedEncounters.testDefaultAndNestedSameNameCallsDelegateWithoutAStaleOverride()
    local callbacks, generated, state, room, destination = fixture()
    local defaultCalls, nestedCalls, outerCalls = 0, 0, 0
    generated.withPhase(state, room, phase(nil), destination, function()
        return callbacks.SetupEncounter(nil, {}, function()
            callbacks.GenerateEncounter(nil, {}, function(_, _, encounter)
                defaultCalls = defaultCalls + 1
                lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves }, { 1, 2 })
            end, {}, destination, { Name = "Generated", MinWaves = 1, MaxWaves = 2 })
        end, { Name = "Generated" }, destination)
    end)
    local outer = phase(decision({ waveCount = 3 }))
    generated.withPhase(state, room, outer, destination, function()
        generated.withPhase(state, room, phase(nil), destination, function()
            callbacks.SetupEncounter(nil, {}, function()
                callbacks.GenerateEncounter(nil, {}, function(_, _, encounter)
                    nestedCalls = nestedCalls + 1
                    lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves }, { 1, 2 })
                end, {}, destination, { Name = "Generated", MinWaves = 1, MaxWaves = 2 })
            end, { Name = "Generated" }, destination)
        end)
        callbacks.SetupEncounter(nil, {}, function()
            callbacks.GenerateEncounter(nil, {}, function(_, _, encounter)
                outerCalls = outerCalls + 1
                lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves }, { 3, 3 })
            end, {}, destination, { Name = "Generated", MinWaves = 1, MaxWaves = 2 })
        end, { Name = "Generated" }, destination)
    end)
    lu.assertEquals(defaultCalls, 1)
    lu.assertEquals(nestedCalls, 1)
    lu.assertEquals(outerCalls, 1)
end

function TestGeneratedEncounters.testInvalidTypeIsDiagnosticAndScopeRestoresAfterAnError()
    local callbacks, generated, state, room, destination = fixture()
    local selected = phase(decision({ waves = {
        { waveIndex = 1, types = { { choiceKey = "Ash", nativeId = "Ash" } } },
    } }))
    local encounter = { Name = "Generated", EscalateTypeCount = false, SpawnWaves = {} }
    local wave = { WaveIndex = 1, Spawns = {} }
    encounter.SpawnWaves[1] = wave
    generated.withPhase(state, room, selected, destination, function()
        callbacks.SetupEncounter(nil, {}, function()
            callbacks.GenerateEncounter(nil, {}, function()
                callbacks.FillEnemyTypes(nil, {}, function()
                    return callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
                        { "Brine" })
                end, encounter, wave, destination)
            end, {}, destination, encounter)
        end, { Name = "Generated" }, destination)
    end)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.diagnostics[1].observed, {
        phase = "Combat", encounterKey = "Generated", wave = 1, kind = "type",
        requested = "Ash", reason = "native-ineligible",
    })
    lu.assertError(function()
        generated.withPhase(state, room, selected, destination, function()
            callbacks.SetupEncounter(nil, {}, function() error("native setup fault") end,
                { Name = "Generated" }, destination)
        end)
    end)
    lu.assertEquals(callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
        { "native" }), "native")
end

function TestGeneratedEncounters.testFixedFirstSpawnMapsAllocationByGeneratedIdentityAtTheNativeSampleBranch()
    local callbacks, generated, state, room, destination = fixture()
    local selected = phase(decision({ waves = {
        { waveIndex = 1, types = {
            { choiceKey = "Brine", nativeId = "Brine" }, { choiceKey = "Cinder", nativeId = "Cinder" },
        }, allocations = { Cinder = 16 } },
    } }))
    local wave = { WaveIndex = 1, Spawns = {
        { Name = "Ash", TotalCount = 2 }, { Name = "Brine" }, { Name = "Cinder" },
    } }
    local encounter = { Name = "Generated", SpawnWaves = { wave } }
    local requested
    generated.withPhase(state, room, selected, destination, function()
        callbacks.SetupEncounter(nil, {}, function()
            callbacks.GenerateEncounter(nil, {}, function()
                callbacks.FillEnemyCounts(nil, {}, function()
                    requested = callbacks.RandomNormal(nil, {}, function(mean) return mean end, 10, 1)
                end, encounter, wave, destination)
            end, {}, destination, encounter)
        end, { Name = "Generated" }, destination)
    end)
    -- Spawn index three is the proven sample branch here; it maps to Cinder's
    -- explicit identity allocation, not a full-array position.
    lu.assertEquals(requested, 16)
end

function TestGeneratedEncounters.testBaseRollSteersOnlyTheBoundEncounterBaseRange()
    local callbacks, generated, state, room, destination = fixture()
    local selected = phase(decision({ baseRoll = 412 }))
    local encounter = { Name = "Generated", BaseDifficultyMin = 340, BaseDifficultyMax = 500,
        SpawnWaves = {} }
    local value, incidental
    generated.withPhase(state, room, selected, destination, function()
        callbacks.SetupEncounter(nil, {}, function()
            callbacks.GenerateEncounter(nil, {}, function()
                incidental = callbacks.RandomInt(nil, {}, function() return 7 end, 1, 10)
                value = callbacks.RandomInt(nil, {}, function() return 340 end, 340, 500)
            end, {}, destination, encounter)
        end, encounter, destination)
    end)
    lu.assertEquals(incidental, 7)
    lu.assertEquals(value, 412)
    lu.assertEquals(state.diagnostics[1].observed.baseRoll, 412)
    lu.assertTrue(state.diagnostics[1].observed.baseRollUsed)
end
