-- luacheck: globals TestCerberus
local lu = require("luaunit")
local cerberus = require("mods.room.timeline.encounters.cerberus")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestCerberus = {}

local function capture()
    local callbacks = {}
    return { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }, callbacks
end

local function attach(phase, encounter, state)
    local module, callbacks = capture()
    cerberus.attach(module, {}, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks
end

local function decision(key, nativeId)
    return { decisionKey = key, kind = "single", choiceKey = "chosen", nativeId = nativeId }
end

local function restoreGlobals(values)
    local prior = {}
    for key, value in pairs(values) do
        prior[key] = _G[key]
        _G[key] = value
    end
    return function()
        for key in pairs(values) do _G[key] = prior[key] end
    end
end

local function stages()
    return {
        { RandomAIFunctionNames = { "AttackerAI" } },
        {
            RandomAIFunctionNames = { "AttackerAI" }, TransitionFunction = "CerberusStageExit",
            RandomSpawnEncounter = {
                "CerberusSpawns01", "CerberusSpawns02", "CerberusSpawns03", "CerberusSpawns04", "CerberusSpawns05",
            },
            EMStageDataOverrides = {
                RandomSpawnEncounter = {
                    "CerberusEMSpawns01", "CerberusEMSpawns02", "CerberusEMSpawns03", "CerberusEMSpawns04", "CerberusEMSpawns04",
                },
                KillDumbFireThreads = true,
                AIData = { AIEndWithSpawnedEncounter = true, AIEndWithSpawnedEncounterTimeout = 14 },
            },
            NewVulnerability = false, UnequipAllWeapons = true, EquipWeapons = { "InfestedCerberusHide" },
            AIData = { AIEndWithSpawnedEncounter = true, AIEndWithSpawnedEncounterTimeout = 20 },
        },
        { TransitionFunction = "CerberusStageEnter" },
    }
end

function TestCerberus.testBurrowConstrictsAllNormalAndRivalChoicesBeforeNativeSpawnAndTransition()
    local domains = {
        { encounterKey = "BossInfestedCerberus01", choices = {
            "CerberusSpawns01", "CerberusSpawns02", "CerberusSpawns03", "CerberusSpawns04", "CerberusSpawns05",
        }, rival = false },
        { encounterKey = "BossInfestedCerberus02", choices = {
            "CerberusEMSpawns01", "CerberusEMSpawns02", "CerberusEMSpawns03", "CerberusEMSpawns04",
        }, rival = true },
    }
    for _, domain in ipairs(domains) do
        for _, nativeId in ipairs(domain.choices) do
            local encounter, sourceStages, events = {}, stages(), {}
            local callbacks = attach({ encounterKey = domain.encounterKey,
                customization = { decision("burrow", nativeId) } }, encounter, { state = "synchronized" })
            local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
            local result = callbacks.StagedAI(nil, {}, function(enemy)
                local stage = enemy.AIStages[2]
                if domain.rival then stage.RandomSpawnEncounter = stage.EMStageDataOverrides.RandomSpawnEncounter end
                events[#events + 1] = "spawn:" .. stage.RandomSpawnEncounter[1]
                events[#events + 1] = "transition:" .. stage.TransitionFunction
                return stage
            end, { Name = "InfestedCerberus", AIStages = sourceStages })
            restore()

            lu.assertEquals(events, { "spawn:" .. nativeId, "transition:CerberusStageExit" })
            lu.assertEquals(result.RandomSpawnEncounter, { nativeId })
            lu.assertEquals(result.EMStageDataOverrides.RandomSpawnEncounter, { nativeId })
            lu.assertEquals(result.AIData.AIEndWithSpawnedEncounterTimeout, 20)
            lu.assertEquals(result.EMStageDataOverrides.AIData.AIEndWithSpawnedEncounterTimeout, 14)
            lu.assertEquals(sourceStages[2].RandomSpawnEncounter[1], "CerberusSpawns01")
            lu.assertEquals(sourceStages[2].EMStageDataOverrides.RandomSpawnEncounter[1], "CerberusEMSpawns01")
        end
    end
end

function TestCerberus.testHowlConstrictsOnlyNativeResolvedSelectorForBothDomains()
    local domains = {
        { encounterKey = "BossInfestedCerberus01", choices = {
            "InfestedCerberusHowlSummonShadeSmall", "InfestedCerberusHowlSummonShadeMedium", "InfestedCerberusHowlSummonShadeLarge",
        } },
        { encounterKey = "BossInfestedCerberus02", choices = {
            "InfestedCerberusHowlSummonShadeSmallElite", "InfestedCerberusHowlSummonShadeMediumElite", "InfestedCerberusHowlSummonShadeLargeElite",
        } },
    }
    for _, domain in ipairs(domains) do
        for _, nativeId in ipairs(domain.choices) do
            local encounter = {}
            local callbacks = attach({ encounterKey = domain.encounterKey,
                customization = { decision("howl", nativeId) } }, encounter, { state = "synchronized" })
            local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
            local nativeData = { SkipFireWeapon = true, ChainedWeaponOptions = { "native-first", "native-second" } }
            local result = callbacks.GetWeaponAIData(nil, {}, function(enemy, weaponName)
                lu.assertEquals(enemy.WeaponName, "InfestedCerberusHowlSummonSelector")
                lu.assertNil(weaponName)
                return nativeData
            end, { Name = "InfestedCerberus", WeaponName = "InfestedCerberusHowlSummonSelector" })
            restore()

            lu.assertNotEquals(result, nativeData)
            lu.assertEquals(result.ChainedWeaponOptions, { nativeId })
            lu.assertTrue(result.SkipFireWeapon)
            lu.assertEquals(nativeData.ChainedWeaponOptions, { "native-first", "native-second" })
        end
    end
end

function TestCerberus.testHowlAndBurrowRemainIndependentAndOptional()
    local encounter = {}
    local phase = { encounterKey = "BossInfestedCerberus01", customization = { decision("burrow", "CerberusSpawns03") } }
    local callbacks = attach(phase, encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    local nativeHowl = { ChainedWeaponOptions = { "native" } }
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeHowl end,
        { Name = "InfestedCerberus", WeaponName = "InfestedCerberusHowlSummonSelector" }), nativeHowl)
    local sourceStages = stages()
    callbacks.StagedAI(nil, {}, function(enemy)
        lu.assertEquals(enemy.AIStages[2].RandomSpawnEncounter, { "CerberusSpawns03" })
    end, { Name = "InfestedCerberus", AIStages = sourceStages })
    restore()

    phase = { encounterKey = "BossInfestedCerberus01", customization = {
        decision("howl", "InfestedCerberusHowlSummonShadeLarge"),
    } }
    callbacks = attach(phase, encounter, { state = "synchronized" })
    restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    callbacks.StagedAI(nil, {}, function(enemy)
        lu.assertEquals(enemy.AIStages[2].RandomSpawnEncounter[1], "CerberusSpawns01")
    end, { Name = "InfestedCerberus", AIStages = stages() })
    restore()
end

function TestCerberus.testMinionWrongSelectorAndPassiveStatesPassThrough()
    local cases = {
        { state = nil, phase = { encounterKey = "BossInfestedCerberus01", customization = { decision("burrow", "CerberusSpawns02") } } },
        { state = { state = "desynchronized" }, phase = { encounterKey = "BossInfestedCerberus01",
            customization = { decision("burrow", "CerberusSpawns02") } } },
        { state = { state = "synchronized" }, phase = nil },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossInfestedCerberus01" } },
        { state = { state = "synchronized" }, phase = { encounterKey = "Other",
            customization = { decision("burrow", "CerberusSpawns02") } } },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossInfestedCerberus01",
            customization = { decision("burrow", "CerberusSpawns02") } }, unbound = true },
    }
    for _, case in ipairs(cases) do
        local encounter, sourceStages = {}, stages()
        local callbacks = attach(case.phase, encounter, case.state)
        local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = case.unbound and {} or encounter } } })
        callbacks.StagedAI(nil, {}, function(enemy) lu.assertEquals(enemy.AIStages, sourceStages) end,
            { Name = "InfestedCerberus", AIStages = sourceStages })
        restore()
    end

    local encounter, nativeData = {}, { ChainedWeaponOptions = { "native" } }
    local callbacks = attach({ encounterKey = "BossInfestedCerberus01",
        customization = { decision("howl", "InfestedCerberusHowlSummonShadeSmall") } }, encounter,
        { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Minion", WeaponName = "InfestedCerberusHowlSummonSelector" }), nativeData)
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "InfestedCerberus", WeaponName = "OtherWeapon" }), nativeData)
    restore()
end

function TestCerberus.testNativeErrorsPropagateAndCompositionRegistersExactContacts()
    local encounter = {}
    local callbacks = attach({ encounterKey = "BossInfestedCerberus01",
        customization = { decision("burrow", "CerberusSpawns01") } }, encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    local ok, message = pcall(callbacks.StagedAI, nil, {}, function() error("native stage failure") end,
        { Name = "InfestedCerberus", AIStages = stages() })
    restore()
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native stage failure")

    callbacks = attach({ encounterKey = "BossInfestedCerberus01",
        customization = { decision("howl", "InfestedCerberusHowlSummonShadeSmall") } }, encounter,
        { state = "synchronized" })
    restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    ok, message = pcall(callbacks.GetWeaponAIData, nil, {}, function() error("native weapon failure") end,
        { Name = "InfestedCerberus", WeaponName = "InfestedCerberusHowlSummonSelector" })
    restore()
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native weapon failure")

    local module, registered = capture()
    encounterHooks.attach(module, {}, function() return { state = "desynchronized" } end, function() end, {
        encounterPhase = function() return nil end,
    })
    lu.assertNotNil(registered.StagedAI)
    lu.assertNotNil(registered.GetWeaponAIData)
end
