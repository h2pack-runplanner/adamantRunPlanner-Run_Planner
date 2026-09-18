-- luacheck: globals TestChronos
local lu = require("luaunit")
local chronos = require("mods.room.timeline.encounters.chronos")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestChronos = {}

local function capture()
    local callbacks = {}
    return { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }, callbacks
end

local function decision(nativeId)
    return { decisionKey = "lateSummon", kind = "single", choiceKey = "chosen", nativeId = nativeId }
end

local function attach(phase, encounter, diagnostics, state)
    local module, callbacks = capture()
    chronos.attach(module, { diagnostic = function(_, checkpoint, observed)
        diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed }
    end }, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks
end

local function installCurrent(encounter)
    local prior = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = encounter } }
    return function() _G.CurrentRun = prior end
end

function TestChronos.testNormalLateSummonNarrowsEveryNativePairSelectorWithoutMutatingNativeData()
    local choices = { "ChronosEliteSpawn1", "ChronosEliteSpawn2", "ChronosEliteSpawn3" }
    for _, nativeId in ipairs(choices) do
        local encounter, diagnostics = {}, {}
        local callbacks = attach({ encounterKey = "BossChronos01", customization = { decision(nativeId) } }, encounter,
            diagnostics, { state = "synchronized" })
        local restore = installCurrent(encounter)
        local nativeData = { PreAttackRandomDumbFireWeapon = choices, NativeField = "retained" }
        local result = callbacks.GetWeaponAIData(nil, {}, function(enemy, weaponName)
            lu.assertEquals(enemy.Name, "Chronos")
            lu.assertEquals(weaponName, "ChronosDefense3")
            return nativeData
        end, { Name = "Chronos" }, "ChronosDefense3")
        restore()
        lu.assertEquals(result.PreAttackRandomDumbFireWeapon, { nativeId })
        lu.assertEquals(result.NativeField, "retained")
        lu.assertEquals(nativeData.PreAttackRandomDumbFireWeapon, choices)
        lu.assertEquals(diagnostics, {})
    end
end

function TestChronos.testRivalLateSummonNarrowsEveryNativeSpawnerOptionWithoutMutatingNativeData()
    local choices = {
        "Screamer2_SuperElite", "Treant2_SuperElite", "Octofish_SuperElite", "Vampire_SuperElite",
        "Lamia_SuperElite", "ClockworkHeavyMelee_SuperElite", "SatyrRatCatcher_SuperElite",
    }
    for _, nativeId in ipairs(choices) do
        local encounter, diagnostics = {}, {}
        local callbacks = attach({ encounterKey = "BossChronos02", customization = { decision(nativeId) } }, encounter,
            diagnostics, { state = "synchronized" })
        local restore = installCurrent(encounter)
        local nativeData = { SpawnerOptions = choices, SpawnRate = 0.02 }
        local result = callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
            { Name = "Chronos", WeaponName = "ChronosSuperEliteSpawn1" })
        restore()
        lu.assertEquals(result.SpawnerOptions, { nativeId })
        lu.assertEquals(result.SpawnRate, 0.02)
        lu.assertEquals(nativeData.SpawnerOptions, choices)
        lu.assertEquals(diagnostics, {})
    end
end

function TestChronos.testDefaultAndVariantMismatchesPassThrough()
    local encounter, diagnostics = {}, {}
    local nativeData = { PreAttackRandomDumbFireWeapon = { "ChronosEliteSpawn1", "ChronosEliteSpawn2" } }
    local callbacks = attach({ encounterKey = "BossChronos01", customization = {} }, encounter, diagnostics,
        { state = "synchronized" })
    local restore = installCurrent(encounter)
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Chronos", WeaponName = "ChronosDefense3" }), nativeData)
    restore()

    callbacks = attach({ encounterKey = "BossChronos02", customization = { decision("Screamer2_SuperElite") } },
        encounter, diagnostics, { state = "synchronized" })
    restore = installCurrent(encounter)
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Chronos", WeaponName = "ChronosDefense3" }), nativeData)
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Minion", WeaponName = "ChronosSuperEliteSpawn1" }), nativeData)
    restore()
    lu.assertEquals(diagnostics, {})
end

function TestChronos.testUnavailableAuthoredOperandIsDiagnosticOnlyAndNativeErrorsPropagate()
    local encounter, diagnostics = {}, {}
    local callbacks = attach({ encounterKey = "BossChronos01", customization = { decision("Missing") } }, encounter,
        diagnostics, { state = "synchronized" })
    local restore = installCurrent(encounter)
    local nativeData = { PreAttackRandomDumbFireWeapon = { "ChronosEliteSpawn1" } }
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Chronos", WeaponName = "ChronosDefense3" }), nativeData)
    local ok, message = pcall(callbacks.GetWeaponAIData, nil, {}, function() error("native getter failure") end,
        { Name = "Chronos", WeaponName = "ChronosDefense3" })
    restore()
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native getter failure")
    lu.assertEquals(diagnostics, { { checkpoint = "chronos-late-summon", observed = {
        reason = "unavailable", encounterKey = "BossChronos01", decisionKey = "lateSummon",
        requested = "Missing", available = { "ChronosEliteSpawn1" },
    } } })
end

function TestChronos.testMissingNativePoolIsDiagnosticOnly()
    local encounter, diagnostics = {}, {}
    local callbacks = attach({ encounterKey = "BossChronos01", customization = { decision("Missing") } }, encounter,
        diagnostics, { state = "synchronized" })
    local restore = installCurrent(encounter)
    local nativeData = { NativeField = "retained" }
    lu.assertEquals(callbacks.GetWeaponAIData(nil, {}, function() return nativeData end,
        { Name = "Chronos", WeaponName = "ChronosDefense3" }), nativeData)
    restore()
    lu.assertEquals(diagnostics, { { checkpoint = "chronos-late-summon", observed = {
        reason = "unavailable", encounterKey = "BossChronos01", decisionKey = "lateSummon",
        requested = "Missing", available = nil,
    } } })
end

function TestChronos.testCompositionRegistersChronosContact()
    local module, callbacks = capture()
    encounterHooks.attach(module, {}, function() return { state = "desynchronized" } end, function() end, {
        encounterPhase = function() return nil end,
    })
    lu.assertNotNil(callbacks.GetWeaponAIData)
end
