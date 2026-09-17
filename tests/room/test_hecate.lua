-- luacheck: globals TestHecate
local lu = require("luaunit")
local hecate = require("mods.room.timeline.encounters.hecate")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestHecate = {}

local function capture()
    local callbacks = {}
    return { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }, callbacks
end

local function attach(phase, encounter, state)
    local module, callbacks = capture()
    hecate.attach(module, {}, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks
end

local function decision(nativeId)
    return { decisionKey = "interlude", kind = "single", choiceKey = "chosen", nativeId = nativeId }
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

local function nativeHecateStageTransition2(enemy)
    table.insert(enemy.WeaponOptions, enemy.MidPhaseWeapon)
    return "native-reuse"
end

function TestHecate.testPublishedNormalAndRivalInterludeReplaceOnlyTheNativeInsertedWeapon()
    local choices = {
        { encounterKey = "BossHecate01", nativeId = "HecateMeteorShower" },
        { encounterKey = "BossHecate02", nativeId = "HecateLaser_EM" },
    }
    for _, case in ipairs(choices) do
        local encounter = {}
        local callbacks = attach({ encounterKey = case.encounterKey, customization = { decision(case.nativeId) } },
            encounter, { state = "synchronized" })
        local enemy = { WeaponOptions = { "preexisting" } }
        local result = callbacks.HecateStageTransition1(nil, {}, function(nativeEnemy)
            nativeEnemy.MidPhaseWeapon = "native-random"
            table.insert(nativeEnemy.WeaponOptions, nativeEnemy.MidPhaseWeapon)
            return "native-transition"
        end, enemy, { CurrentRoom = { Encounter = encounter } }, {})
        lu.assertEquals(result, "native-transition")
        lu.assertEquals(enemy.MidPhaseWeapon, case.nativeId)
        lu.assertEquals(enemy.WeaponOptions, { "preexisting", case.nativeId })

        -- Transition2 stays native and reuses the value remembered above.
        lu.assertEquals(nativeHecateStageTransition2(enemy), "native-reuse")
        lu.assertEquals(enemy.WeaponOptions, { "preexisting", case.nativeId, case.nativeId })
    end
end

function TestHecate.testExactPublishedWeaponDropsOnlyItsProgressionGateAndRetainsNativeFalse()
    local encounter = {}
    local selectedWeapon = { GameStateRequirements = { RequiredClears = 1 }, Requirements = { Range = 10 } }
    local callbacks = attach({ encounterKey = "BossHecate01", customization = { decision("HecateLaser") } },
        encounter, { state = "synchronized" })
    local restore = restoreGlobals({
        CurrentRun = { CurrentRoom = { Encounter = encounter } }, WeaponData = { HecateLaser = selectedWeapon },
    })
    local observed
    local result = callbacks.IsEnemyWeaponEligible(nil, {}, function(_, weaponData, requirements)
        observed = { weaponData = weaponData, requirements = requirements }
        return false
    end, { MidPhaseWeapon = "HecateLaser" }, selectedWeapon)
    restore()

    lu.assertFalse(result)
    lu.assertNotEquals(observed.weaponData, selectedWeapon)
    lu.assertNil(observed.weaponData.GameStateRequirements)
    lu.assertEquals(observed.weaponData.Requirements, selectedWeapon.Requirements)
    lu.assertEquals(selectedWeapon.GameStateRequirements, { RequiredClears = 1 })
end

function TestHecate.testEligibilityLeavesUnrelatedWeaponDataNative()
    local encounter, selectedWeapon, otherWeapon = {}, { GameStateRequirements = { RequiredClears = 1 } }, {}
    local callbacks = attach({ encounterKey = "BossHecate01", customization = { decision("HecateLaser") } },
        encounter, { state = "synchronized" })
    local restore = restoreGlobals({
        CurrentRun = { CurrentRoom = { Encounter = encounter } }, WeaponData = { HecateLaser = selectedWeapon },
    })
    local observed = callbacks.IsEnemyWeaponEligible(nil, {}, function(_, weaponData) return weaponData end,
        { MidPhaseWeapon = "HecateLaser" }, otherWeapon)
    restore()
    lu.assertEquals(observed, otherWeapon)
end

function TestHecate.testDefaultNoPlanDesyncUnboundAndWrongEncounterPassThrough()
    local cases = {
        { state = nil, phase = { encounterKey = "BossHecate01", customization = { decision("HecateLaser") } } },
        { state = { state = "desynchronized" }, phase = { encounterKey = "BossHecate01",
            customization = { decision("HecateLaser") } } },
        { state = { state = "synchronized" }, phase = nil },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossHecate01",
            customization = { decision("HecateLaser") } }, unbound = true },
        { state = { state = "synchronized" }, phase = { encounterKey = "Other",
            customization = { decision("HecateLaser") } } },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossHecate01" } },
    }
    for _, case in ipairs(cases) do
        local encounter, enemy = {}, { WeaponOptions = {} }
        local callbacks = attach(case.phase, encounter, case.state)
        callbacks.HecateStageTransition1(nil, {}, function(nativeEnemy)
            nativeEnemy.MidPhaseWeapon = "native-random"
            table.insert(nativeEnemy.WeaponOptions, "native-random")
        end, enemy, { CurrentRoom = { Encounter = case.unbound and {} or encounter } }, {})
        lu.assertEquals(enemy.WeaponOptions, { "native-random" })
    end
end

function TestHecate.testNativeErrorPropagatesAndEncounterHooksRegisterHecateContacts()
    local encounter = {}
    local callbacks = attach({ encounterKey = "BossHecate01", customization = { decision("HecateLaser") } },
        encounter, { state = "synchronized" })
    local ok, message = pcall(callbacks.HecateStageTransition1, nil, {}, function() error("native failure") end,
        { WeaponOptions = {} }, { CurrentRoom = { Encounter = encounter } }, {})
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native failure")

    local module, registered = capture()
    encounterHooks.attach(module, {}, function() return { state = "desynchronized" } end, function() end, {
        encounterPhase = function() return nil end,
    })
    lu.assertNotNil(registered.HecateStageTransition1)
    lu.assertNotNil(registered.IsEnemyWeaponEligible)
end
