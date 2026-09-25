-- luacheck: globals TestAnomalyRoster
-- Scripted native GeneratedAnomalyB order: cap contact, one manual-template wave,
-- FillEnemyTypes, then native FillEnemyCounts marking generated entries infinite.
local lu = require("luaunit")
local generatedDefinition = require("mods.room.timeline.encounters.generated")
local support = require("tests.harness.hook_composition")

TestAnomalyRoster = {}

local function roster(...)
    local types = {}
    for index, name in ipairs({ ... }) do types[index] = { choiceKey = name, nativeId = name } end
    return { kind = "infiniteRoster", decisionKey = "infiniteRoster", types = types }
end

local function enemies()
    return {
        Swarmer_Elite = { IsElite = true, GeneratorData = { BlockEnemyTypes = { "Swarmer" }, ActiveEnemyCapBonus = 2 } },
        SpreadShotUnit = { GeneratorData = { BlockEnemyTypes = { "SpreadShotUnit_Elite" } } },
        SpreadShotUnit_Elite = { IsElite = true, GeneratorData = { BlockEnemyTypes = { "SpreadShotUnit_Elite" } } },
        BloodlessPitcher = { GeneratorData = { BlockEnemyTypes = { "BloodlessPitcher_Elite" } } },
        BloodlessPitcher_Elite = { IsElite = true, GeneratorData = { BlockEnemyTypes = { "BloodlessPitcher" } } },
    }
end

local function encounterData(overrides)
    local result = { Name = "GeneratedAnomalyB", InfiniteSpawns = true, MinWaves = 1, MaxWaves = 1,
        MinTypes = 2, MaxTypes = 3, MaxTypesCap = 3, TypeCountDepthRamp = 0, MaxEliteTypes = 1,
        EnemySet = { "Swarmer_Elite", "SpreadShotUnit", "SpreadShotUnit_Elite", "BloodlessPitcher",
            "BloodlessPitcher_Elite" },
        SpawnWaves = {}, ManualWaveTemplates = { { Spawns = {} } },
        WaveTemplate = { MinTypes = 1, MaxTypes = 1, Spawns = {} } }
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

-- The native IsEnemyEligible rules this pool reaches: blacklists, duplicates,
-- earlier BlockEnemyTypes and MaxEliteTypes over the wave's existing spawns.
local function nativeEligible(data, gate)
    return function(name, encounter, wave)
        if encounter.Blacklist and encounter.Blacklist[name] then return false end
        if gate and not gate(name) then return false end
        local elites = 0
        for _, spawn in pairs(wave.Spawns) do
            if spawn.Name == name then return false end
            if data[spawn.Name].IsElite then elites = elites + 1 end
            for _, blocked in pairs(data[spawn.Name].GeneratorData.BlockEnemyTypes or {}) do
                if blocked == name then return false end
            end
        end
        return not (data[name].IsElite and elites >= encounter.MaxEliteTypes)
    end
end

local function game(overrides)
    local data = enemies()
    local value = { EnemyData = data, IsEnemyEligible = nativeEligible(data) }
    for key, entry in pairs(overrides or {}) do value[key] = entry end
    return value
end

local function withGame(value, action)
    local previous = _G.game
    _G.game = value
    local ok, errorValue = pcall(action)
    _G.game = previous
    if not ok then error(errorValue, 0) end
end

local function fixture(decision)
    local module, _, callbacks = support.capture()
    local instance = generatedDefinition.create()
    local state = { state = "synchronized" }
    local phase = { slotKey = "Encounter", encounterKey = "GeneratedAnomalyB", customization = { decision } }
    local room = {
        occurrence = function() return { id = "anomaly" } end,
        encounterPhase = function() return phase end,
    }
    local diagnostics = {}
    instance.attach(module, { diagnostic = function(_, _, observed) diagnostics[#diagnostics + 1] = observed end },
        function() return state end, room)
    return { callbacks = callbacks, instance = instance, state = state, room = room, phase = phase,
        diagnostics = diagnostics }
end

local function generate(context, encounter, run, options)
    options = options or {}
    local callbacks, trace = context.callbacks, { nativeFills = 0 }
    context.instance.withPhase(context.state, context.room, options.phase or context.phase, {}, function()
        callbacks.SetupEncounter(nil, {}, function(data, nativeRoom)
            return callbacks.GenerateEncounter(nil, {}, function(currentRun, generationRoom, generated)
                generated.ActiveEnemyCap = callbacks.CalculateActiveEnemyCap(nil, {}, function() return 5 end,
                    currentRun, generationRoom, generated)
                generated.Blacklist = generated.Blacklist or {}
                trace.waves = { generated.MinWaves, generated.MaxWaves }
                local wave = { WaveIndex = 1, Spawns = {} }
                generated.SpawnWaves[1] = wave
                if not options.skipFill then
                    callbacks.FillEnemyTypes(nil, {}, function()
                        trace.nativeFills = trace.nativeFills + 1
                        wave.Spawns = { { Name = "BloodlessPitcher", Generated = true } }
                    end, generated, wave, generationRoom)
                end
                if not options.skipCounts then
                    for _, spawn in ipairs(wave.Spawns) do
                        if spawn.Generated then spawn.InfiniteSpawns = true end
                    end
                end
                if options.after then options.after(generated) end
                return generated
            end, run, nativeRoom, data)
        end, encounter, {})
    end)
    return trace
end

function TestAnomalyRoster.testAdmittedRosterInstallsOrderedGeneratedEntriesLeftInfiniteByNative()
    withGame(game(), function()
        local context = fixture(roster("Swarmer_Elite", "SpreadShotUnit", "BloodlessPitcher"))
        local encounter = encounterData()
        local trace = generate(context, encounter, { Blacklist = {} })
        lu.assertEquals(trace.nativeFills, 0)
        lu.assertEquals(trace.waves, { 1, 1 })
        lu.assertEquals(encounter.ActiveEnemyCap, 5)
        lu.assertEquals(encounter.SpawnWaves[1].TypeCount, 3)
        lu.assertEquals(encounter.SpawnWaves[1].Spawns, {
            { Name = "Swarmer_Elite", Generated = true, InfiniteSpawns = true },
            { Name = "SpreadShotUnit", Generated = true, InfiniteSpawns = true },
            { Name = "BloodlessPitcher", Generated = true, InfiniteSpawns = true },
        })
        -- The native cap bonus is recorded, not converted into extra enemies.
        lu.assertEquals(encounter.ActiveEnemyCapBonus, 2)
        lu.assertNil(encounter.__runPlannerGeneratedComposition)
        lu.assertEquals(context.diagnostics, { { kind = "roster-installed", phase = "Encounter",
            encounterKey = "GeneratedAnomalyB", types = { "Swarmer_Elite", "SpreadShotUnit", "BloodlessPitcher" } } })
    end)
end

function TestAnomalyRoster.testFiniteFangsAndMenaceOverridesDoNotClaimTheRoster()
    withGame(game(), function()
        local context = fixture(roster("SpreadShotUnit_Elite", "SpreadShotUnit"))
        local encounter = encounterData()
        generate(context, encounter, { Blacklist = {} })
        local nativeFangs, observed = 0, nil
        context.callbacks.PickEncounterEliteAttributes(nil, {}, function() nativeFangs = nativeFangs + 1 end, encounter)
        local args = {}
        context.callbacks.HandleNextSpawn(nil, {}, function(_, _, _, _, actual) observed = actual end,
            encounter, false, nil, nil, args)
        lu.assertEquals(nativeFangs, 1)
        lu.assertIs(observed, args)
        lu.assertNil(args.IgnoreShrineOverrides)
    end)
end

function TestAnomalyRoster.testNativeDrawOrderIsAdmittedAndTheReverseDeclines()
    withGame(game(), function()
        local accepted = fixture(roster("SpreadShotUnit_Elite", "SpreadShotUnit"))
        generate(accepted, encounterData(), { Blacklist = {} })
        lu.assertEquals(accepted.diagnostics[1].kind, "roster-installed")
    end)
    for _, case in ipairs({
        { decision = roster("SpreadShotUnit", "SpreadShotUnit_Elite"), position = 2, enemy = "SpreadShotUnit_Elite" },
        { decision = roster("BloodlessPitcher_Elite", "BloodlessPitcher"), position = 2, enemy = "BloodlessPitcher" },
        { decision = roster("Swarmer_Elite", "SpreadShotUnit_Elite"), position = 2, enemy = "SpreadShotUnit_Elite" },
    }) do
        withGame(game(), function()
            local context = fixture(case.decision)
            local encounter = encounterData()
            local trace = generate(context, encounter, { Blacklist = {} })
            lu.assertEquals(trace.nativeFills, 1)
            lu.assertEquals(encounter.SpawnWaves[1].Spawns, { { Name = "BloodlessPitcher", Generated = true,
                InfiniteSpawns = true } })
            lu.assertEquals(context.diagnostics, { { kind = "roster-admission", reason = "native-enemy-ineligible",
                position = case.position, enemy = case.enemy } })
        end)
    end
end

function TestAnomalyRoster.testLiveBlacklistAndIneligibilityDeclineBeforeMutation()
    local depthGate = function(name) return name ~= "SpreadShotUnit_Elite" end
    for _, case in ipairs({
        { run = { Blacklist = { BloodlessPitcher = true } }, reason = "native-enemy-ineligible", position = 2 },
        { gate = depthGate, decision = roster("SpreadShotUnit_Elite", "BloodlessPitcher"),
            reason = "native-enemy-ineligible", position = 1 },
        { error = true, reason = "native-enemy-check-error", position = 1 },
    }) do
        local value = game()
        if case.gate then value.IsEnemyEligible = nativeEligible(value.EnemyData, case.gate) end
        if case.error then value.IsEnemyEligible = function() error("broken", 0) end end
        withGame(value, function()
            local context = fixture(case.decision or roster("SpreadShotUnit", "BloodlessPitcher"))
            local run = case.run or { Blacklist = {} }
            local encounter = encounterData()
            local trace = generate(context, encounter, run)
            lu.assertEquals(trace.nativeFills, 1)
            lu.assertNil(encounter.ActiveEnemyCapBonus)
            lu.assertEquals(context.diagnostics[1].kind, "roster-admission")
            lu.assertEquals(context.diagnostics[1].reason, case.reason)
            lu.assertEquals(context.diagnostics[1].position, case.position)
        end)
    end
end

function TestAnomalyRoster.testUnsupportedEffectiveDeclarationsDecline()
    for _, case in ipairs({
        { overrides = { InfiniteSpawns = false }, reason = "unsupported-finite-spawns" },
        { overrides = { MaxWaves = 2 }, reason = "wave-count-out-of-range" },
        { overrides = { SpawnWaves = { {} } }, reason = "preexisting-waves" },
        { overrides = { ManualWaveTemplates = { { Spawns = { { Name = "Seed" } } } } }, reason = "unowned-template-entry" },
        { overrides = { MaxTypes = 2, MaxTypesCap = 2 }, reason = "type-count-out-of-range" },
        { overrides = { EnemySet = { "SpreadShotUnit" } }, reason = "enemy-set-changed" },
        { overrides = { EscalateTypeCount = true }, reason = "unsupported-type-bounds" },
        { overrides = { ManualWaveTemplates = { { Spawns = {}, TypeCount = 3 } } }, reason = "unsupported-type-bounds" },
        { overrides = { UseEncounterDepthForTypes = true }, reason = "unsupported-type-bounds" },
        { overrides = { TypeCountDepthRamp = 0.2 }, reason = "unsupported-type-bounds" },
    }) do
        withGame(game(), function()
            local context = fixture(roster("SpreadShotUnit", "BloodlessPitcher", "Swarmer_Elite"))
            local encounter = encounterData(case.overrides)
            local spawnWaves = encounter.SpawnWaves
            context.instance.withPhase(context.state, context.room, context.phase, {}, function()
                context.callbacks.SetupEncounter(nil, {}, function(data)
                    return context.callbacks.GenerateEncounter(nil, {}, function(currentRun, generationRoom, generated)
                        context.callbacks.CalculateActiveEnemyCap(nil, {}, function() return 5 end, currentRun,
                            generationRoom, generated)
                        return generated
                    end, { Blacklist = {} }, {}, data)
                end, encounter, {})
            end)
            lu.assertIs(encounter.SpawnWaves, spawnWaves)
            lu.assertEquals({ encounter.MinWaves, encounter.MaxWaves }, { 1, case.overrides.MaxWaves or 1 })
            lu.assertEquals(context.diagnostics[1].kind, "roster-admission")
            lu.assertEquals(context.diagnostics[1].reason, case.reason)
        end)
    end
end

function TestAnomalyRoster.testUncustomizedAnomalyIsUntouched()
    withGame(game({ IsEnemyEligible = function() error("uncustomized generation must not be admitted") end }), function()
        local context = fixture(roster("SpreadShotUnit", "BloodlessPitcher"))
        local encounter = encounterData()
        local trace = generate(context, encounter, { Blacklist = {} },
            { phase = { slotKey = "Encounter", encounterKey = "GeneratedAnomalyB" } })
        lu.assertEquals(trace.nativeFills, 1)
        lu.assertEquals(encounter.SpawnWaves[1].Spawns, { { Name = "BloodlessPitcher", Generated = true,
            InfiniteSpawns = true } })
        lu.assertEquals(context.diagnostics, {})
    end)
end

function TestAnomalyRoster.testFailuresAfterAdmissionAreRealizationFailures()
    withGame(game(), function()
        local context = fixture(roster("SpreadShotUnit", "BloodlessPitcher"))
        generate(context, encounterData(), { Blacklist = {} }, { skipFill = true })
        lu.assertEquals(context.diagnostics, { { kind = "roster-not-realized", reason = "missing-fill-contact",
            admitted = true, missingWaves = { 1 } } })

        context = fixture(roster("SpreadShotUnit", "BloodlessPitcher"))
        generate(context, encounterData(), { Blacklist = {} }, { skipCounts = true })
        lu.assertEquals(context.diagnostics, { { kind = "roster-not-realized", reason = "finite-spawns",
            admitted = true, types = { "SpreadShotUnit", "BloodlessPitcher" },
            finite = { "SpreadShotUnit", "BloodlessPitcher" } } })

        context = fixture(roster("SpreadShotUnit", "BloodlessPitcher"))
        lu.assertErrorMsgContains("native failure", function()
            generate(context, encounterData(), { Blacklist = {} }, { after = function() error("native failure", 0) end })
        end)
        lu.assertEquals(context.diagnostics[1].kind, "roster-not-realized")
        lu.assertEquals(context.diagnostics[1].reason, "generation-error")
        lu.assertTrue(context.diagnostics[1].admitted)
    end)
end

function TestAnomalyRoster.testMissingAdmissionContactIsReported()
    withGame(game(), function()
        local context = fixture(roster("SpreadShotUnit", "BloodlessPitcher"))
        context.instance.withPhase(context.state, context.room, context.phase, {}, function()
            context.callbacks.SetupEncounter(nil, {}, function(data)
                return context.callbacks.GenerateEncounter(nil, {}, function(_, _, generated) return generated end,
                    { Blacklist = {} }, {}, data)
            end, encounterData(), {})
        end)
        lu.assertEquals(context.diagnostics, { { kind = "roster-not-realized", reason = "missing-admission-contact" } })
    end)
end
