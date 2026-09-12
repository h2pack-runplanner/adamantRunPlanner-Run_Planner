-- luacheck: globals TestNemesisEncounters
local lu = require("luaunit")
local nemesis = require("mods.room.timeline.encounters.nemesis")
local poolHooks = require("mods.room.features.inventory.purging_pool_hooks")

TestNemesisEncounters = {}

local function harness(itemGameName)
    local callbacks = {}
    local module = {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }
    local state = {}
    local handle = {}
    local payload = {
        transaction = {
            kind = "encounterInteraction",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "freeItem", itemGameName = itemGameName },
            },
        },
    }
    local diagnostics, completions = {}, {}
    local session = {
        diagnostic = function(_, checkpoint, observed)
            diagnostics[#diagnostics + 1] = {
                checkpoint = checkpoint,
                observed = observed,
            }
        end,
        complete = function(_, currentHandle)
            completions[#completions + 1] = currentHandle
        end,
    }
    local room = {
        encounterHandle = function() return handle end,
        begin = function(_, currentHandle)
            if currentHandle == handle then return payload end
        end,
    }
    nemesis.attach(module, session, function() return state end, function() end, room)
    return callbacks, state, handle, diagnostics, completions
end

function TestNemesisEncounters.testFreeItemConstrainsNativePoolAndCompletesAfterDrop()
    local callbacks, _, handle, mismatches, completions = harness("ArmorBoost")
    local wanted = { Name = "ArmorBoost", marker = "wanted" }
    local args = {
        Consumables = {
            { Name = "HealDrop", marker = "other" },
            wanted,
            RandomSelection = true,
        },
    }
    local observed
    local result = callbacks.NPCRewardDropPreProcessArgs(nil, {}, function(nativeArgs)
        observed = nativeArgs.Consumables
        return "preprocessed"
    end, args, {}, {})

    lu.assertEquals(result, "preprocessed")
    lu.assertEquals(#observed, 1)
    lu.assertEquals(observed[1], wanted)
    lu.assertTrue(observed.RandomSelection)
    lu.assertEquals(mismatches, {})
    lu.assertEquals(completions, {})

    local dropped = callbacks.NPCRewardDrop(nil, {}, function() return "dropped" end, {}, {})
    lu.assertEquals(dropped, "dropped")
    lu.assertEquals(completions, { handle })
end

function TestNemesisEncounters.testUnavailableFreeItemPreservesTheNativePoolAndCompletesAtDrop()
    local callbacks, _, handle, diagnostics, completions = harness("LastStandDrop")
    local available = { Name = "HealDrop" }
    local blocked = { Name = "LastStandDrop", GameStateRequirements = { "MissingLastStand" } }
    local consumables = { available, blocked, RandomSelection = true }
    local args = { Consumables = consumables }
    local called, observed = 0
    local priorEligibility = _G.IsGameStateEligible
    _G.IsGameStateEligible = function(row, requirements)
        lu.assertEquals(row, blocked)
        lu.assertEquals(requirements, blocked.GameStateRequirements)
        return false
    end
    local ok, result = pcall(callbacks.NPCRewardDropPreProcessArgs, nil, {}, function(nativeArgs)
            called = called + 1
            observed = nativeArgs.Consumables
            return "native-result"
        end, args, {}, {})
    _G.IsGameStateEligible = priorEligibility
    if not ok then error(result, 0) end

    lu.assertEquals(result, "native-result")
    lu.assertEquals(called, 1)
    lu.assertEquals(observed, consumables)
    lu.assertTrue(observed.RandomSelection)
    lu.assertEquals(diagnostics, {
        { checkpoint = "nemesis-free-item", observed = "unavailable" },
    })
    lu.assertEquals(completions, {})
    callbacks.NPCRewardDrop(nil, {}, function() return "dropped" end, {}, {})
    lu.assertEquals(completions, { handle })

    callbacks.NPCRewardDrop(nil, {}, function() return true end, {}, {})
    lu.assertEquals(completions, { handle })
end

local function traitTradeHarness(traitKey, response)
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local state, handle = {}, {}
    local payload = {
        transaction = {
            kind = "encounterInteraction",
            resolution = { kind = "nemesisRandomEvent", outcome = {
                kind = "traitTrade", traitKey = traitKey, response = response,
            } },
        },
    }
    local diagnostics, completions = {}, {}
    local session = {
        diagnostic = function(_, checkpoint, observed)
            diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed }
        end,
        complete = function(_, currentHandle) completions[#completions + 1] = currentHandle end,
    }
    local room = {
        encounterHandle = function() return handle end,
        begin = function(_, currentHandle) return currentHandle == handle and payload or nil end,
    }
    nemesis.attach(module, session, function() return state end, function() end, room)
    return callbacks, handle, diagnostics, completions
end

local function nativeTradeArgs()
    return { GiveOptions = { { SellTrait = true } }, GetOptions = {} }
end

function TestNemesisEncounters.testTraitTradeUsesPublishedNativeCandidateAndDefersAcceptedRemoval()
    local callbacks, handle, diagnostics, completions = traitTradeHarness("Target", "accept")
    local target = { Name = "Target", Value = 20, Rarity = "Common" }
    local other = { Name = "Other", Value = 10, Rarity = "Common" }
    local nativeRoom = {}
    local source, args = {}, nativeTradeArgs()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = nativeRoom }
    local result = callbacks.NemesisTradeChoice(nil, {}, function(nativeSource, nativeArgs)
        lu.assertEquals(nativeArgs.GiveOptions, { { SellTrait = true } })
        callbacks.GenerateSellTraitShop(nil, {}, function(room)
            room.SellOptions = { other }
            room.SellValues = { Target = target }
            return "native-generated"
        end, nativeRoom, { SellOptionCount = 1, PrioritizeCommonTraits = true })
        nativeSource.Accepted = true
        return "native-trade"
    end, source, args, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-trade")
    lu.assertEquals(nativeRoom.SellOptions, { target })
    lu.assertNil(nativeRoom.SellValues.Target)
    lu.assertEquals(diagnostics, {})
    lu.assertEquals(completions, {})
    callbacks.RemoveTrait(nil, {}, function() return "native-removal" end, {}, "Target", {})
    lu.assertEquals(completions, { handle })
end

function TestNemesisEncounters.testRejectedTraitTradeUsesPublishedNativeCandidateWithoutRemoval()
    local callbacks, handle, diagnostics, completions = traitTradeHarness("Target", "reject")
    local target = { Name = "Target", Value = 20, Rarity = "Rare" }
    local nativeRoom = {}
    local source, args = {}, nativeTradeArgs()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = nativeRoom }
    callbacks.NemesisTradeChoice(nil, {}, function(_, nativeArgs)
        lu.assertEquals(nativeArgs.GiveOptions, { { SellTrait = true } })
        callbacks.GenerateSellTraitShop(nil, {}, function(room)
            room.SellOptions = {}
            room.SellValues = { Target = target }
        end, nativeRoom, { SellOptionCount = 1, PrioritizeCommonTraits = true })
    end, source, args, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(nativeRoom.SellOptions, { target })
    lu.assertNil(nativeRoom.SellValues.Target)
    lu.assertEquals(diagnostics, {})
    lu.assertEquals(completions, { handle })
end

function TestNemesisEncounters.testUnavailableTraitTradeLeavesNativeSelectionUntouched()
    local callbacks, handle, diagnostics, completions = traitTradeHarness("Target", "reject")
    local other = { Name = "Other", Value = 10, Rarity = "Common" }
    local nativeRoom = {}
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = nativeRoom }
    callbacks.NemesisTradeChoice(nil, {}, function()
        callbacks.GenerateSellTraitShop(nil, {}, function(room)
            room.SellOptions = { other }
            room.SellValues = {}
        end, nativeRoom, { SellOptionCount = 1, PrioritizeCommonTraits = true })
    end, {}, nativeTradeArgs(), {})
    _G.CurrentRun = priorRun

    lu.assertEquals(nativeRoom.SellOptions, { other })
    lu.assertEquals(diagnostics, { { checkpoint = "nemesis-trait-trade", observed = "unavailable" } })
    lu.assertEquals(completions, { handle })
end

function TestNemesisEncounters.testTraitTradeRestoresItsOneShotTargetAfterNativeFailure()
    local callbacks = traitTradeHarness("Target", "reject")
    local nativeRoom = {}
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = nativeRoom }
    local ok, message = pcall(callbacks.NemesisTradeChoice, nil, {}, function()
        callbacks.GenerateSellTraitShop(nil, {}, function()
            error("native trade generation failure")
        end, nativeRoom, { SellOptionCount = 1, PrioritizeCommonTraits = true })
    end, {}, nativeTradeArgs(), {})
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native trade generation failure")

    local native = { Name = "Native", Value = 10, Rarity = "Common" }
    callbacks.GenerateSellTraitShop(nil, {}, function(room)
        room.SellOptions = { native }
        room.SellValues = {}
    end, nativeRoom, { SellOptionCount = 1, PrioritizeCommonTraits = true })
    _G.CurrentRun = priorRun
    lu.assertEquals(nativeRoom.SellOptions, { native })
end

local function layeredCapture()
    local layers = {}
    local module = { hooks = { wrap = function(name, _, callback)
        layers[name] = layers[name] or {}
        layers[name][#layers[name] + 1] = callback
    end } }
    local function call(name, base, ...)
        local callbacks = layers[name] or {}
        local function nextLayer(index, ...)
            if index > #callbacks then return base(...) end
            return callbacks[index](nil, {}, function(...) return nextLayer(index + 1, ...) end, ...)
        end
        return nextLayer(1, ...)
    end
    return module, call
end

function TestNemesisEncounters.testTraitTradeSurvivesPoolHooksInEitherRegistrationOrder()
    for _, attachPoolFirst in ipairs({ false, true }) do
        local module, call = layeredCapture()
        local state, handle = {}, {}
        local target = { Name = "Target", Value = 20, Rarity = "Common" }
        local poolTarget = { Name = "PoolTarget", Value = 10, Rarity = "Common" }
        local nativeRoom = {}
        local active = { occurrence = { overview = {
            purgingPool = { interacted = true, traits = { { traitKey = "PoolTarget" } } },
        } } }
        local payload = { transaction = { kind = "encounterInteraction", resolution = {
            kind = "nemesisRandomEvent", outcome = { kind = "traitTrade", traitKey = "Target", response = "reject" },
        } } }
        local session = { diagnostic = function() end, complete = function() end }
        local room = {
            current = function() return active end,
            encounterHandle = function() return handle end,
            begin = function(_, currentHandle) return currentHandle == handle and payload or nil end,
        }
        local attachPool = function()
            poolHooks.attach(module, session, function() return state end, function() end, room)
        end
        local attachNemesis = function()
            nemesis.attach(module, session, function() return state end, function() end, room)
        end
        if attachPoolFirst then attachPool(); attachNemesis() else attachNemesis(); attachPool() end

        local priorRun = _G.CurrentRun
        _G.CurrentRun = { CurrentRoom = nativeRoom }
        call("NemesisTradeChoice", function()
            call("GenerateSellTraitShop", function(nativeRoomArg)
                nativeRoomArg.SellOptions = {}
                nativeRoomArg.SellValues = { Target = target, PoolTarget = poolTarget }
            end, nativeRoom, { SellOptionCount = 1, PrioritizeCommonTraits = true })
        end, {}, nativeTradeArgs(), {})
        _G.CurrentRun = priorRun

        lu.assertEquals(nativeRoom.SellOptions, { target })
        lu.assertNil(nativeRoom.SellValues.Target)
        lu.assertNotEquals(nativeRoom.SellOptions[1], poolTarget)
    end
end
