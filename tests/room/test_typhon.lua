-- luacheck: globals TestTyphon
local lu = require("luaunit")
local typhon = require("mods.room.timeline.encounters.typhon")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestTyphon = {}

local function capture()
    local callbacks = {}
    return { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }, callbacks
end

local function decision(key, nativeId)
    return { decisionKey = key, kind = "single", choiceKey = "chosen", nativeId = nativeId }
end

local function attach(phase, encounter, diagnostics, state)
    local module, callbacks = capture()
    typhon.attach(module, { diagnostic = function(_, checkpoint, observed)
        diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed }
    end }, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks
end

function TestTyphon.testNormalEggWavesNarrowAllNativeChoicesBeforeTheTransitionDraw()
    local families = {
        { key = "firstEggWave", options = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03" } },
        { key = "secondEggWave", options = { "TyphonHeadCastSummon02", "TyphonHeadCastSummon05" } },
    }
    for _, family in ipairs(families) do
        for _, nativeId in ipairs(family.options) do
            local encounter, diagnostics = {}, {}
            local callbacks = attach({ encounterKey = "BossTyphonHead01", customization = { decision(family.key, nativeId) } },
                encounter, diagnostics, { state = "synchronized" })
            local source = { FireRandomWeapon = family.options, FireWeapon = "previous-native-draw", NativeField = true }
            local result = callbacks.BossStageTransition(nil, {}, function(enemy, _currentRun, aiStage)
                lu.assertEquals(enemy.Name, "TyphonHead")
                lu.assertEquals(aiStage.FireRandomWeapon, { nativeId })
                lu.assertNil(aiStage.FireWeapon)
                aiStage.FireWeapon = aiStage.FireWeapon or aiStage.FireRandomWeapon[1]
                return aiStage
            end, { Name = "TyphonHead" }, { CurrentRoom = { Encounter = encounter } }, source)
            lu.assertEquals(result.FireWeapon, nativeId)
            lu.assertEquals(source.FireRandomWeapon, family.options)
            lu.assertEquals(source.FireWeapon, "previous-native-draw")
            lu.assertEquals(diagnostics, {})
        end
    end
end

function TestTyphon.testRivalSecondEggWaveUsesAlreadyOverriddenNativePool()
    local options = { "TyphonHeadCastSummonBoar", "TyphonHeadCastSummonDragon" }
    for _, nativeId in ipairs(options) do
        local encounter, diagnostics = {}, {}
        local callbacks = attach({ encounterKey = "BossTyphonHead02", customization = {
            decision("secondEggWave", nativeId),
        } }, encounter, diagnostics, { state = "synchronized" })
        local source = { FireRandomWeapon = options, NativeField = "Rival" }
        local result = callbacks.BossStageTransition(nil, {}, function(_, _, aiStage)
            lu.assertEquals(aiStage.FireRandomWeapon, { nativeId })
            return aiStage.FireRandomWeapon[1]
        end, { Name = "TyphonHead" }, { CurrentRoom = { Encounter = encounter } }, source)
        lu.assertEquals(result, nativeId)
        lu.assertEquals(source.FireRandomWeapon, options)
        lu.assertEquals(diagnostics, {})
    end
end

function TestTyphon.testDefaultFixedRivalFirstWaveAndVariantMismatchesPassThrough()
    local encounter, diagnostics = {}, {}
    local callbacks = attach({ encounterKey = "BossTyphonHead02", customization = {
        decision("secondEggWave", "TyphonHeadCastSummonBoar"),
    } }, encounter, diagnostics, { state = "synchronized" })
    local captain = { FireRandomWeapon = { "TyphonHeadCastSummonCaptain" }, FireWeapon = "captain" }
    lu.assertEquals(callbacks.BossStageTransition(nil, {}, function(_, _, aiStage) return aiStage end,
        { Name = "TyphonHead" }, { CurrentRoom = { Encounter = encounter } }, captain), captain)

    callbacks = attach({ encounterKey = "BossTyphonHead01", customization = {} }, encounter, diagnostics,
        { state = "synchronized" })
    local nativeStage = { FireRandomWeapon = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03" }, FireWeapon = "kept" }
    lu.assertEquals(callbacks.BossStageTransition(nil, {}, function(_, _, aiStage) return aiStage end,
        { Name = "TyphonHead" }, { CurrentRoom = { Encounter = encounter } }, nativeStage), nativeStage)
    lu.assertEquals(diagnostics, {})
end

function TestTyphon.testUnavailableOperandIsDiagnosticOnlyAndNativeErrorsPropagate()
    local encounter, diagnostics = {}, {}
    local callbacks = attach({ encounterKey = "BossTyphonHead01", customization = {
        decision("firstEggWave", "Missing"),
    } }, encounter, diagnostics, { state = "synchronized" })
    local nativeStage = { FireRandomWeapon = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03" } }
    lu.assertEquals(callbacks.BossStageTransition(nil, {}, function(_, _, aiStage) return aiStage end,
        { Name = "TyphonHead" }, { CurrentRoom = { Encounter = encounter } }, nativeStage), nativeStage)
    local ok, message = pcall(callbacks.BossStageTransition, nil, {}, function() error("native transition failure") end,
        { Name = "TyphonHead" }, { CurrentRoom = { Encounter = encounter } }, nativeStage)
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native transition failure")
    lu.assertEquals(diagnostics, {
        { checkpoint = "typhon-egg-wave", observed = {
            reason = "unavailable", encounterKey = "BossTyphonHead01", decisionKey = "firstEggWave",
            requested = "Missing", available = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03" },
        } },
        { checkpoint = "typhon-egg-wave", observed = {
            reason = "unavailable", encounterKey = "BossTyphonHead01", decisionKey = "firstEggWave",
            requested = "Missing", available = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03" },
        } },
    })
end

function TestTyphon.testCompositionRegistersTyphonTransitionContact()
    local module, callbacks = capture()
    encounterHooks.attach(module, {}, function() return { state = "desynchronized" } end, function() end, {
        encounterPhase = function() return nil end,
    })
    lu.assertNotNil(callbacks.BossStageTransition)
end
