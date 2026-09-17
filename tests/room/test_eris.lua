-- luacheck: globals TestEris
local lu = require("luaunit")
local eris = require("mods.room.timeline.encounters.eris")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestEris = {}

local function capture()
    local callbacks = {}
    return { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }, callbacks
end

local function attach(phase, encounter, state)
    local module, callbacks = capture()
    eris.attach(module, {}, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks
end

local function prefix(key, choices)
    local rows = {}
    for _, nativeId in ipairs(choices) do rows[#rows + 1] = { choiceKey = nativeId, nativeId = nativeId } end
    return { decisionKey = key, kind = "orderedPrefix", choices = rows }
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

local function resolved(options)
    return { SkipFireWeapon = true, ChainedWeaponOptions = options, OtherNativeField = "retained" }
end

local families = {
    {
        encounterKey = "BossEris01", selector = "ErisSummonSelector", decisionKey = "earlySummons",
        options = { "ErisSummon01", "ErisSummon02" },
    },
    {
        encounterKey = "BossEris01", selector = "ErisSummonSelector2", decisionKey = "lateSummons",
        options = { "ErisSummon03", "ErisSummon04" },
    },
    {
        encounterKey = "BossEris02", selector = "ErisEMSummonSelector", decisionKey = "earlySummons",
        options = { "ErisEMSummonHarpy", "ErisEMSummonSwab", "ErisEMSummonJellyfish", "ErisEMSummonTurtle" },
    },
    {
        encounterKey = "BossEris02", selector = "ErisEMSummonSelector2", decisionKey = "lateSummons",
        options = {
            "ErisEMSummonFishmanRanged", "ErisEMSummonFishmanMelee", "ErisEMSummonFishSwarmer", "ErisEMSummonAutomaton",
        },
    },
}

function TestEris.testFourSelectorDomainsUseConcreteVariantHistoryForZeroOneAndTwoPrefixes()
    for _, family in ipairs(families) do
        local encounter = {}
        local phase = { encounterKey = family.encounterKey, customization = {} }
        local callbacks = attach(phase, encounter, { state = "synchronized" })
        local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
        local enemy = { Name = "Eris", WeaponName = family.selector, WeaponHistory = {} }

        local defaultData = resolved(family.options)
        lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return defaultData end, enemy), defaultData)

        phase.customization = { prefix(family.decisionKey, { family.options[1] }) }
        local nativeFirst = resolved(family.options)
        local first = callbacks.GetWeaponAIData(nil, {}, function() return nativeFirst end, enemy)
        local repeated = callbacks.GetWeaponAIData(nil, {}, function() return resolved(family.options) end, enemy)
        lu.assertEquals(first.ChainedWeaponOptions, { family.options[1] })
        lu.assertEquals(repeated.ChainedWeaponOptions, { family.options[1] })
        lu.assertEquals(nativeFirst.ChainedWeaponOptions, family.options)
        lu.assertEquals(enemy.WeaponHistory, {})

        -- DoAttackerAILoop appends the selector after the getter but before its
        -- concrete chained summon executes; that append must not advance us.
        enemy.WeaponHistory[#enemy.WeaponHistory + 1] = family.selector
        local afterSelector = callbacks.GetWeaponAIData(nil, {}, function() return resolved(family.options) end, enemy)
        lu.assertEquals(afterSelector.ChainedWeaponOptions, { family.options[1] })

        enemy.WeaponHistory[#enemy.WeaponHistory + 1] = family.options[1]
        local nativeTail = resolved(family.options)
        lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeTail end, enemy), nativeTail)

        phase.customization = { prefix(family.decisionKey, { family.options[1], family.options[2] }) }
        local second = callbacks.GetWeaponAIData(nil, {}, function() return resolved(family.options) end, enemy)
        lu.assertEquals(second.ChainedWeaponOptions, { family.options[2] })
        lu.assertEquals(second.OtherNativeField, "retained")

        enemy.WeaponHistory[#enemy.WeaponHistory + 1] = family.options[2]
        local exhausted = resolved(family.options)
        lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return exhausted end, enemy), exhausted)
        restore()
    end
end

function TestEris.testEarlyAndLateHistoriesAreIndependent()
    local encounter = {}
    local phase = { encounterKey = "BossEris01", customization = {
        prefix("earlySummons", { "ErisSummon01", "ErisSummon02" }),
        prefix("lateSummons", { "ErisSummon03", "ErisSummon04" }),
    } }
    local callbacks = attach(phase, encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    local enemy = { Name = "Eris", WeaponName = "ErisSummonSelector2", WeaponHistory = { "ErisSummon01" } }
    local result = callbacks.GetWeaponAIData(nil, {}, function() return resolved({ "ErisSummon03", "ErisSummon04" }) end,
        enemy)
    restore()
    lu.assertEquals(result.ChainedWeaponOptions, { "ErisSummon03" })
end

function TestEris.testGrenadeRouteAndAutomatonInnerSelectionStayNative()
    local encounter = {}
    local phase = { encounterKey = "BossEris02", customization = {
        prefix("earlySummons", { "ErisEMSummonHarpy" }),
        prefix("lateSummons", { "ErisEMSummonAutomaton" }),
    } }
    local callbacks = attach(phase, encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    local enemy = { Name = "Eris", WeaponName = "ErisGrenadeLuciferCluster01", WeaponHistory = {} }
    local grenadeData = resolved({ "ErisEMSummonSelector" })
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return grenadeData end, enemy), grenadeData)
    lu.assertEquals(enemy.WeaponHistory, {})

    enemy.WeaponName = "ErisEMSummonSelector"
    local summon = callbacks.GetWeaponAIData(nil, {}, function()
        return resolved({ "ErisEMSummonHarpy", "ErisEMSummonSwab", "ErisEMSummonJellyfish", "ErisEMSummonTurtle" })
    end, enemy)
    lu.assertEquals(summon.ChainedWeaponOptions, { "ErisEMSummonHarpy" })

    enemy.WeaponName = "ErisEMSummonAutomaton"
    local automatonData = { SpawnerOptions = { "AutomatonBeamer_Elite", "AutomatonEnforcer_Elite" } }
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return automatonData end, enemy), automatonData)
    restore()
end

function TestEris.testMinionAndPassiveBindingsPassThrough()
    local cases = {
        { state = nil, phase = { encounterKey = "BossEris01", customization = { prefix("earlySummons", { "ErisSummon01" }) } } },
        { state = { state = "desynchronized" }, phase = { encounterKey = "BossEris01",
            customization = { prefix("earlySummons", { "ErisSummon01" }) } } },
        { state = { state = "synchronized" }, phase = nil },
        { state = { state = "synchronized" }, phase = { encounterKey = "Other",
            customization = { prefix("earlySummons", { "ErisSummon01" }) } } },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossEris01",
            customization = { prefix("earlySummons", { "ErisSummon01" }) } }, unbound = true },
    }
    for _, case in ipairs(cases) do
        local encounter, nativeData = {}, resolved({ "ErisSummon01", "ErisSummon02" })
        local callbacks = attach(case.phase, encounter, case.state)
        local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = case.unbound and {} or encounter } } })
        lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
            { Name = "Eris", WeaponName = "ErisSummonSelector", WeaponHistory = {} }), nativeData)
        restore()
    end

    local encounter, nativeData = {}, resolved({ "ErisSummon01", "ErisSummon02" })
    local callbacks = attach({ encounterKey = "BossEris01",
        customization = { prefix("earlySummons", { "ErisSummon01" }) } }, encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Minion", WeaponName = "ErisSummonSelector", WeaponHistory = {} }), nativeData)
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Eris", WeaponName = "OtherWeapon", WeaponHistory = {} }), nativeData)
    restore()
end

function TestEris.testNativeErrorsPropagateAndCompositionRegistersGetter()
    local encounter = {}
    local callbacks = attach({ encounterKey = "BossEris01",
        customization = { prefix("earlySummons", { "ErisSummon01" }) } }, encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Encounter = encounter } } })
    local ok, message = pcall(callbacks.GetWeaponAIData, nil, {}, function() error("native getter failure") end,
        { Name = "Eris", WeaponName = "ErisSummonSelector", WeaponHistory = {} })
    restore()
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native getter failure")

    local module, registered = capture()
    encounterHooks.attach(module, {}, function() return { state = "desynchronized" } end, function() end, {
        encounterPhase = function() return nil end,
    })
    lu.assertNotNil(registered.GetWeaponAIData)
end
