-- luacheck: globals TestGeneratedEncounters
-- Direct-installation witnesses use the shipped callbacks and a scripted native
-- generation order: base roll, DifficultyRating, cap contact, waves, fill contacts.
local lu = require("luaunit")
local generatedDefinition = require("mods.room.timeline.encounters.generated")
local support = require("tests.harness.hook_composition")

TestGeneratedEncounters = {}

local function decision()
    return { kind = "generated", decisionKey = "generatedComposition", expectedBudget = 42, waveCount = 1, baseRoll = 42,
        fangs = { type = { choiceKey = "Elite", nativeId = "Elite" }, perks = { "Blink" } },
        waves = {{ waveIndex = 1, types = {
            { choiceKey = "Elite", nativeId = "Elite", source = "addition" },
            { choiceKey = "Cinder", nativeId = "Cinder", source = "addition" },
        }, counts = { Elite = 2, Cinder = 3 } }}, }
end

local function enemies()
    return {
        Elite = { IsElite = true, GeneratorData = { DifficultyRating = 4 },
            EliteAttributeOptions = { "Blink", "Fog" }, EliteAttributeData = { Blink = {}, Fog = {} } },
        Cinder = { BlacklistAfterFirstAppearance = true, GeneratorData = {
            DifficultyRating = 5, BlockEnemyTypes = { "Blocked" }, ActiveEnemyCapBonus = 2,
        } },
    }
end

local function encounterData(overrides)
    local result = { Name = "Generated", MinWaves = 1, MaxWaves = 2, BaseDifficultyMin = 1, BaseDifficultyMax = 99,
        EnemySet = { "Elite", "Cinder" }, WaveTemplate = { Spawns = {} } }
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

local function fixture(value)
    local module, _, callbacks = support.capture()
    local instance = generatedDefinition.create()
    local occurrence = { id = "generated" }
    local state = { state = "synchronized" }
    local phase = { slotKey = "Combat", encounterKey = "Generated", customization = { value or decision() } }
    local room = {
        occurrence = function() return occurrence end,
        encounterPhase = function(_, encounter)
            return encounter.__runPlannerGeneratedComposition and phase or nil
        end,
    }
    local diagnostics = {}
    instance.attach(module, { diagnostic = function(_, _, observed) diagnostics[#diagnostics + 1] = observed end },
        function() return state end, room)
    return callbacks, instance, state, room, phase, diagnostics
end

-- Scripted native GenerateEncounter: the roll feeds DifficultyRating, the cap
-- contact follows, then the wave-count draw and one fill contact per wave.
local function generate(context, encounter, run, observe)
    local callbacks, instance, state, room, phase = table.unpack(context)
    local trace = { nativeFills = 0 }
    instance.withPhase(state, room, phase, {}, function()
        callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
            return callbacks.GenerateEncounter(nil, {}, function(currentRun, generationRoom, generated)
                trace.roll = { generated.BaseDifficultyMin, generated.BaseDifficultyMax }
                generated.DifficultyRating = generated.DifficultyRating or generated.BaseDifficultyMin
                callbacks.CalculateActiveEnemyCap(nil, {}, function() trace.capCalls = (trace.capCalls or 0) + 1; return 7 end,
                    currentRun, generationRoom, generated)
                generated.Blacklist = generated.Blacklist or {}
                trace.waves = { generated.MinWaves, generated.MaxWaves }
                trace.blockHighlight = generated.BlockHighlightEncounter
                generated.SpawnWaves = {}
                for index = 1, generated.MinWaves do
                    local wave = { WaveIndex = index, Spawns = {} }
                    generated.SpawnWaves[index] = wave
                    if not (observe and observe.skipFill) then
                        callbacks.FillEnemyTypes(nil, {}, function()
                            trace.nativeFills = trace.nativeFills + 1
                            wave.Spawns = { { Name = "NativeChoice", TotalCount = 4 } }
                        end, generated, wave, generationRoom)
                    end
                end
                if observe and observe.after then observe.after(generated) end
                return generated
            end, run, nativeRoom, data)
        end, encounter, {})
    end)
    return trace
end

local function withGame(value, action)
    local previous = _G.game
    _G.game = value
    local ok, errorValue = pcall(action)
    _G.game = previous
    if not ok then error(errorValue, 0) end
end

local function eligibleGame(overrides)
    local value = { IsEnemyEligible = function(name, encounter) return not encounter.Blacklist[name] end,
        IsEliteAttributeEligible = function() return true end, EnemyData = enemies() }
    for key, entry in pairs(overrides or {}) do value[key] = entry end
    return value
end

function TestGeneratedEncounters.testPriorRunBlacklistDeclinesAtTheCapContactAndNativeContinues()
    withGame(eligibleGame(), function()
        local context = { fixture() }
        local encounter, run = encounterData(), { Blacklist = { Cinder = true } }
        local trace = generate(context, encounter, run)
        local callbacks, diagnostics = context[1], context[6]
        local nativeFangs, nativeSpawns = 0, 0
        callbacks.PickEncounterEliteAttributes(nil, {}, function() nativeFangs = nativeFangs + 1 end, encounter)
        local args = {}
        callbacks.HandleNextSpawn(nil, {}, function(_, _, _, _, actual)
            nativeSpawns = nativeSpawns + 1
            lu.assertIs(actual, args)
            lu.assertNil(actual.IgnoreShrineOverrides)
        end, encounter, false, nil, nil, args)
        -- The legal authored roll is retained; wave bounds and highlight stay native.
        lu.assertEquals(trace.roll, { 42, 42 })
        lu.assertEquals(trace.waves, { 1, 2 })
        lu.assertNil(trace.blockHighlight)
        lu.assertEquals({ trace.nativeFills, nativeFangs, nativeSpawns }, { 1, 1, 1 })
        lu.assertEquals(encounter.SpawnWaves[1].Spawns, { { Name = "NativeChoice", TotalCount = 4 } })
        lu.assertEquals({ encounter.BaseDifficultyMin, encounter.BaseDifficultyMax }, { 1, 99 })
        lu.assertNil(encounter.__runPlannerGeneratedComposition)
        lu.assertEquals(diagnostics, {
            { kind = "generated-admission", reason = "native-enemy-ineligible", wave = 1, enemy = "Cinder" },
        })
    end)
end

function TestGeneratedEncounters.testAdmittedDecisionInstallsEveryWaveWithoutReevaluation()
    local eligibility = 0
    withGame(eligibleGame({ IsEnemyEligible = function() eligibility = eligibility + 1; return true end }), function()
        local value = decision()
        value.waveCount = 2
        value.waves[2] = { waveIndex = 2, types = { { choiceKey = "Elite", nativeId = "Elite", source = "addition" } },
            counts = { Elite = 1 } }
        local context = { fixture(value) }
        local encounter, run = encounterData({ BlockTypesAcrossWaves = true, Blacklist = {} }), { Blacklist = {} }
        local atAdmission
        local trace = generate(context, encounter, run, { after = function() atAdmission = eligibility end })
        local callbacks, diagnostics = context[1], context[6]
        lu.assertEquals(trace.capCalls, 1)
        lu.assertEquals(trace.waves, { 2, 2 })
        lu.assertTrue(trace.blockHighlight)
        lu.assertNil(encounter.BlockHighlightEncounter)
        lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves }, { 1, 2 })
        lu.assertEquals(trace.nativeFills, 0)
        lu.assertEquals(eligibility, atAdmission)
        lu.assertEquals(encounter.SpawnWaves[1].Spawns[1].TotalCount, 2)
        lu.assertEquals(encounter.SpawnWaves[1].Spawns[2].TotalCount, 3)
        lu.assertEquals(encounter.SpawnWaves[2].Spawns, { { Name = "Elite", Generated = true, TotalCount = 1 } })
        lu.assertTrue(run.Blacklist.Cinder)
        lu.assertTrue(encounter.Blacklist.Blocked)
        lu.assertEquals(encounter.ActiveEnemyCapBonus, 2)
        lu.assertEquals(diagnostics[1].kind, "generated-installed")
        callbacks.PickEncounterEliteAttributes(nil, {}, function() error("Fangs must not redraw") end, encounter)
        lu.assertEquals(encounter.EliteAttributes, { Elite = { "Blink" } })
        local original, observed = {}, nil
        callbacks.HandleNextSpawn(nil, {}, function(_, _, _, _, args) observed = args end,
            encounter, false, nil, nil, original)
        lu.assertTrue(observed.IgnoreShrineOverrides)
        lu.assertNil(original.IgnoreShrineOverrides)
    end)
end

function TestGeneratedEncounters.testCapOutsideGenerationScopeIsUntouched()
    local callbacks = fixture()
    local encounter = encounterData()
    lu.assertEquals(callbacks.CalculateActiveEnemyCap(nil, {}, function(_, _, received)
        lu.assertIs(received, encounter)
        return 9
    end, {}, {}, encounter), 9)
    lu.assertNil(encounter.BlockHighlightEncounter)
    lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves }, { 1, 2 })
end

function TestGeneratedEncounters.testInvalidBaseRollLeavesGenerationUncustomized()
    withGame(eligibleGame(), function()
        local context = { fixture() }
        local encounter = encounterData({ IsHardEncounter = true,
            HardEncounterOverrideValues = { BaseDifficultyMin = 50, BaseDifficultyMax = 60 } })
        local trace = generate(context, encounter, { Blacklist = {} })
        lu.assertEquals(trace.roll, { 1, 99 })
        lu.assertEquals(trace.nativeFills, 1)
        lu.assertEquals(context[6], { { kind = "generated-admission", reason = "base-roll-out-of-range",
            expected = { min = 50, max = 60 }, observed = 42 } })
    end)
end

function TestGeneratedEncounters.testHardOverridesCannotEraseAValidSuppliedRoll()
    withGame(eligibleGame(), function()
        local context = { fixture() }
        local hard = { BaseDifficultyMin = 40, BaseDifficultyMax = 45, Marker = true }
        local encounter = encounterData({ IsHardEncounter = true, HardEncounterOverrideValues = hard })
        local observedHard
        local callbacks, instance, state, room, phase = table.unpack(context)
        instance.withPhase(state, room, phase, {}, function()
            callbacks.SetupEncounter(nil, {}, function(data)
                return callbacks.GenerateEncounter(nil, {}, function(_, _, generated)
                    observedHard = generated.HardEncounterOverrideValues
                    return generated
                end, { Blacklist = {} }, {}, data)
            end, encounter, {})
        end)
        lu.assertEquals(observedHard, { BaseDifficultyMin = 42, BaseDifficultyMax = 42, Marker = true })
        lu.assertIs(encounter.HardEncounterOverrideValues, hard)
        lu.assertEquals({ encounter.BaseDifficultyMin, encounter.BaseDifficultyMax }, { 40, 45 })
    end)
end

function TestGeneratedEncounters.testBudgetAndWaveBoundsDeclineBeforeNarrowing()
    for _, case in ipairs({
        { configure = function(_, encounter) encounter.DifficultyRating = 42.5 end, reason = "budget-mismatch",
            evidence = { expected = 42, observed = 42.5 } },
        { configure = function(value) value.expectedBudget = 42 + 1e-12 end },
        { configure = function(_, encounter) encounter.MinWaves, encounter.MaxWaves = 2, 3 end,
            reason = "wave-count-out-of-range", evidence = { expected = { min = 2, max = 3 }, observed = 1 } },
    }) do
        withGame(eligibleGame(), function()
            local value, encounter = decision(), encounterData()
            case.configure(value, encounter)
            local context = { fixture(value) }
            local trace = generate(context, encounter, { Blacklist = {} })
            local diagnostic = context[6][1]
            if case.reason == nil then
                lu.assertEquals(diagnostic.kind, "generated-installed")
            else
                lu.assertEquals(trace.nativeFills, encounter.MinWaves)
                lu.assertNil(trace.blockHighlight)
                lu.assertEquals(diagnostic.reason, case.reason)
                lu.assertEquals({ diagnostic.expected, diagnostic.observed }, { case.evidence.expected, case.evidence.observed })
            end
        end)
    end
end

function TestGeneratedEncounters.testUnsupportedEffectiveDeclarationsDecline()
    for _, case in ipairs({
        { overrides = { SpawnWaves = { {} } }, reason = "preexisting-waves" },
        { overrides = { InfiniteSpawns = true }, reason = "unsupported-infinite-spawns" },
        { overrides = { BuildCustomEnemySet = "Custom" }, reason = "unsupported-custom-enemy-set" },
        { enemies = { Elite = {} }, reason = "missing-enemy" },
        { overrides = { WaveTemplate = { Spawns = { { Name = "Unowned", TotalCount = 1 } } } }, reason = "unowned-template-entry" },
        { overrides = { WaveTemplate = { Spawns = { { Name = "Elite", TotalCount = 4 } } } }, source = "fixed",
            reason = "fixed-template-changed" },
        { overrides = { WaveTemplate = { Spawns = { { Name = "Elite", Generated = true } } } }, source = "template",
            reason = "unsupported-placeholder" },
    }) do
        local game = eligibleGame()
        if case.enemies then game.EnemyData = case.enemies end
        withGame(game, function()
            local value = decision()
            if case.source then value.waves[1].types[1].source = case.source end
            local context = { fixture(value) }
            local encounter = encounterData(case.overrides)
            encounter.__runPlannerGeneratedComposition = { occurrenceId = "old" }
            local captured = encounter.SpawnWaves
            local callbacks, instance, state, room, phase = table.unpack(context)
            instance.withPhase(state, room, phase, {}, function()
                callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
                    return callbacks.GenerateEncounter(nil, {}, function(currentRun, generationRoom, generated)
                        generated.DifficultyRating = 42
                        callbacks.CalculateActiveEnemyCap(nil, {}, function() return 1 end, currentRun, generationRoom, generated)
                        lu.assertEquals({ generated.MinWaves, generated.MaxWaves }, { 1, 2 })
                        lu.assertNil(generated.BlockHighlightEncounter)
                        return generated
                    end, { Blacklist = {} }, nativeRoom, data)
                end, encounter, {})
            end)
            lu.assertIs(encounter.SpawnWaves, captured)
            lu.assertNil(encounter.__runPlannerGeneratedComposition)
            lu.assertEquals(context[6][1].reason, case.reason)
        end)
    end
end

function TestGeneratedEncounters.testFangsOrderedPerkCompatibilityDeclines()
    for _, case in ipairs({
        { configure = function(_, encounter) encounter.BannedEliteAttributes = { "Blink" } end },
        { configure = function(game) game.IsEliteAttributeEligible = function(_, perk) return perk ~= "Blink" end end },
        { configure = function(game, _, value)
            value.fangs.perks = { "Fog", "Blink" }
            game.EnemyData.Elite.EliteAttributeData.Fog.BlockAttributes = { "Blink" }
        end, position = 2 },
        { configure = function(_, _, value) value.fangs.perks = { "Unknown" } end, perk = "Unknown" },
    }) do
        local game, value, encounter = eligibleGame(), decision(), encounterData()
        case.configure(game, encounter, value)
        withGame(game, function()
            local context = { fixture(value) }
            local trace = generate(context, encounter, { Blacklist = {} })
            lu.assertEquals(trace.nativeFills, 1)
            lu.assertEquals(context[6], { { kind = "generated-admission", reason = "fangs-perk-unavailable",
                enemy = "Elite", perk = case.perk or "Blink", position = case.position or 1 } })
        end)
    end
end

local function menaceGame(overrides)
    local game = eligibleGame({
        GetShrineUpgradeChangeValue = function() return 0.2 end,
        NextRoomSets = { F = "G" }, GameState = { BiomeVisits = { G = 1 } },
        MetaUpgradeData = { NextBiomeEnemyShrineUpgrade = { SwapMap = { Cinder = { Name = "Cinder2" } },
            BiomeEnemySets = { F = { "Elite2" } } } },
    })
    game.EnemyData.Cinder2, game.EnemyData.Elite2 = {}, {}
    for key, value in pairs(overrides or {}) do game[key] = value end
    return game
end

local function menaceDecision(source, target, count)
    local value = decision()
    value.fangs = nil
    value.menace = { { waveIndex = 1, conversions = {
        { source = { choiceKey = source, nativeId = source }, target = { choiceKey = target, nativeId = target }, count = count },
    } } }
    return value
end

function TestGeneratedEncounters.testPositiveMenaceRequiresNativeGatesAndTargetMapping()
    local room = { RoomSetName = "F" }
    for _, case in ipairs({
        { value = menaceDecision("Cinder", "Cinder2", 1) },
        { value = menaceDecision("Elite", "Elite2", 1) },
        { value = menaceDecision("Cinder", "Elite2", 0) , game = { GetShrineUpgradeChangeValue = function() return 0 end } },
        { value = menaceDecision("Cinder", "Elite2", 1), reason = "menace-target-unmapped" },
        { value = menaceDecision("Elite", "Cinder2", 1), reason = "menace-target-unmapped" },
        { value = menaceDecision("Cinder", "Cinder2", 1), reason = "menace-vow-inactive",
            game = { GetShrineUpgradeChangeValue = function() return 0 end } },
        { value = menaceDecision("Cinder", "Cinder2", 1), reason = "menace-next-biome-unvisited",
            game = { GameState = { BiomeVisits = {} } } },
        { value = menaceDecision("Cinder", "Cinder2", 1), reason = "menace-encounter-blocked",
            encounter = { BlockNextBiomeEnemyShrineUpgrade = true } },
        { value = menaceDecision("Cinder", "Cinder2", 1), reason = "menace-source-blocked",
            source = true },
    }) do
        local game = menaceGame(case.game)
        if case.source then game.EnemyData.Cinder.BlockNextBiomeEnemyShrineUpgrade = true end
        withGame(game, function()
            local context = { fixture(case.value) }
            local callbacks, instance, state, fixtureRoom, phase, diagnostics = table.unpack(context)
            local encounter = encounterData(case.encounter)
            instance.withPhase(state, fixtureRoom, phase, room, function()
                callbacks.SetupEncounter(nil, {}, function(data)
                    return callbacks.GenerateEncounter(nil, {}, function(currentRun, generationRoom, generated)
                        generated.DifficultyRating = 42
                        callbacks.CalculateActiveEnemyCap(nil, {}, function() return 1 end, currentRun, generationRoom, generated)
                        generated.Blacklist = generated.Blacklist or {}
                        generated.SpawnWaves = { { WaveIndex = 1, Spawns = {} } }
                        callbacks.FillEnemyTypes(nil, {}, function() end, generated, generated.SpawnWaves[1], generationRoom)
                        return generated
                    end, { Blacklist = {} }, room, data)
                end, encounter, room)
            end)
            lu.assertEquals(diagnostics[1].kind, case.reason and "generated-admission" or "generated-installed")
            lu.assertEquals(diagnostics[1].reason, case.reason)
        end)
    end
end

function TestGeneratedEncounters.testIntroductionSubstitutionHonorsNativeConditions()
    for _, case in ipairs({
        { reason = "intro-substitution" },
        { completed = true },
        { skip = true },
        { requirements = { Never = true } },
    }) do
        local game = eligibleGame({
            HasEncounterBeenCompleted = function() return case.completed == true end,
            IsGameStateEligible = function(_, requirements) return not requirements.Never end,
            EncounterData = { CinderIntro = { GameStateRequirements = case.requirements } },
        })
        game.EnemyData.Cinder.IntroEncounterName = "CinderIntro"
        withGame(game, function()
            local context = { fixture() }
            generate(context, encounterData({ SkipIntroEncounterCheck = case.skip }), { Blacklist = {} })
            local diagnostic = context[6][1]
            if case.reason then
                lu.assertEquals(diagnostic, { kind = "generated-admission", reason = "intro-substitution",
                    wave = 1, enemy = "Cinder", observed = "CinderIntro" })
            else
                lu.assertEquals(diagnostic.kind, "generated-installed")
            end
        end)
    end
end

function TestGeneratedEncounters.testMissingContactsAreReportedAsRealizationFailures()
    withGame(eligibleGame(), function()
        local context = { fixture() }
        local callbacks, instance, state, room, phase, diagnostics = table.unpack(context)
        instance.withPhase(state, room, phase, {}, function()
            callbacks.SetupEncounter(nil, {}, function(data)
                return callbacks.GenerateEncounter(nil, {}, function(_, _, generated) return generated end,
                    { Blacklist = {} }, {}, data)
            end, encounterData(), {})
        end)
        lu.assertEquals(diagnostics, { { kind = "generated-not-realized", reason = "missing-admission-contact" } })

        context = { fixture() }
        local encounter = encounterData()
        generate(context, encounter, { Blacklist = {} }, { skipFill = true })
        lu.assertEquals(context[6], { { kind = "generated-not-realized", reason = "missing-fill-contact",
            admitted = true, missingWaves = { 1 } } })
        lu.assertNil(encounter.__runPlannerGeneratedComposition)
    end)
end

function TestGeneratedEncounters.testNativeGenerationErrorPropagatesWithDiagnostic()
    withGame(eligibleGame(), function()
        local callbacks, instance, state, room, phase, diagnostics = fixture()
        lu.assertErrorMsgContains("native failure", function()
            instance.withPhase(state, room, phase, {}, function()
                callbacks.SetupEncounter(nil, {}, function(data)
                    return callbacks.GenerateEncounter(nil, {}, function() error("native failure", 0) end,
                        { Blacklist = {} }, {}, data)
                end, encounterData(), {})
            end)
        end)
        lu.assertEquals(diagnostics[1].reason, "generation-error")
    end)
end
