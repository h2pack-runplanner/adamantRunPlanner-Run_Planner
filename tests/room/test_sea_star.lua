-- luacheck: globals TestSeaStar
local lu = require("luaunit")
local seaStar = require("mods.room.timeline.acquisitions.sea_star").create()
local nativeGame = require("tests.harness.native_game")

TestSeaStar = {}

local function installed(instance)
    local callbacks, mismatches = {}, {}
    (instance or seaStar).attach({
        hooks = { wrap = function(name, _, callback) callbacks[name] = callback end },
    })
    return callbacks, mismatches
end

function TestSeaStar.testCreatedInstancesDoNotShareAnActiveChanceScope()
    local definition = require("mods.room.timeline.acquisitions.sea_star")
    local first, second = definition.create(), definition.create()
    local firstCallbacks = installed(first)
    local secondCallbacks = installed(second)
    local scope = first.scope({}, { detail = { seaStarResult = { kind = "proc" } } })
    local result = first.call(scope, function()
        return secondCallbacks.GetTotalHeroTraitValue(nil, {}, function() return "native" end,
            "DoubleRewardChance", {})
    end, function() end)
    lu.assertEquals(result, "native")
    lu.assertFalse(scope.chanceRead)
    lu.assertEquals(firstCallbacks.GetTotalHeroTraitValue(nil, {}, function() return "native" end,
        "DoubleRewardChance", {}), "native")
end

local function payload(kind)
    return { detail = { seaStarResult = { kind = kind } } }
end

function TestSeaStar.testInsertsBothPublishedOperandsAndLeavesNativeRngToResolveThem()
    local callbacks = installed()
    for _, expected in ipairs({ "proc", "noProc" }) do
        for _, luck in ipairs({ 1, 2 }) do
            local scope = seaStar.scope({}, payload(expected))
            local mismatches = {}
            local observed = {}
            local result = seaStar.call(scope, function()
                lu.assertTrue(nativeGame.randomChance(0, observed)(0.5))
                local operand = callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
                    "DoubleRewardChance", {})
                return nativeGame.randomChance(expected == "proc" and 1 or 0, observed)(operand * luck)
            end, function(_, checkpoint, wanted, observed)
                mismatches[#mismatches + 1] = { checkpoint, wanted, observed }
            end)
            lu.assertEquals(result, expected == "proc")
            lu.assertEquals(scope.chanceRead, true)
            lu.assertEquals(observed, { 0.5, (expected == "proc" and 1 or -1) * luck })
            lu.assertEquals(mismatches, {})
        end
    end
end

function TestSeaStar.testMissingChanceReadDiagnoses()
    local callbacks = installed()
    local mismatches = {}
    seaStar.call(seaStar.scope({}, payload("proc")), function()
        return nativeGame.randomChance(0, {})(0.25)
    end, function(_, checkpoint, wanted, observed)
        mismatches[#mismatches + 1] = { checkpoint, wanted, observed }
    end)
    lu.assertEquals(mismatches, { { "sea-star-chance", "proc", "missing" } })
end

function TestSeaStar.testScopeWithoutAResultLeavesItsNativeChanceOperandUntouched()
    local callbacks = installed()
    local scope = seaStar.scope({}, { detail = {} })
    lu.assertEquals(seaStar.call(scope, function()
        return callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0.25 end,
            "DoubleRewardChance", {})
    end, function() error("must not mismatch") end), 0.25)
end

function TestSeaStar.testNestedAndFaultedCallsRestoreTheActiveChanceOperand()
    local callbacks = installed()
    local outer = seaStar.scope({}, payload("proc"))
    local inner = seaStar.scope({}, payload("noProc"))
    local result = seaStar.call(outer, function()
        local ok, message = pcall(seaStar.call, inner, function()
            lu.assertEquals(callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
                "DoubleRewardChance", {}), -1)
            error("native inner failure")
        end, function() end)
        lu.assertFalse(ok)
        lu.assertStrContains(message, "native inner failure")
        lu.assertEquals(callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
            "DoubleRewardChance", {}), 1)
        return "outer-result"
    end, function() end)
    lu.assertEquals(result, "outer-result")
    lu.assertEquals(callbacks.GetTotalHeroTraitValue(nil, {}, function() return "native-after" end,
        "DoubleRewardChance", {}), "native-after")

    local failed = seaStar.scope({}, payload("proc"))
    local ok, message = pcall(seaStar.call, failed, function()
        lu.assertEquals(callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
            "DoubleRewardChance", {}), 1)
        error("native outer failure")
    end, function() end)
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native outer failure")
    lu.assertEquals(callbacks.GetTotalHeroTraitValue(nil, {}, function() return "native-after-fault" end,
        "DoubleRewardChance", {}), "native-after-fault")
end
