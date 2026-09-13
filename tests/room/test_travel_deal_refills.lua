-- luacheck: globals TestTravelDealRefills
local lu = require("luaunit")
local support = require("tests.harness.hook_composition")

local capture, stub, opaque = support.capture, support.stub, support.opaque
local attachFeatureHooks = support.attachFeatureHooks

TestTravelDealRefills = {}

local function transaction(carrier)
    local refill
    if carrier == "worldShop" then
        refill = {
            carrier = carrier,
            source = { owner = "shop-source", offerKey = "Boon" },
            replacement = {
                slotIndex = 0, groupIndex = 0, optionKey = "ArmorBoost",
                reward = { rewardType = "Armor", producerLifecycleKey = "purchase" },
            },
        }
    elseif carrier == "stygianWell" then
        refill = {
            carrier = carrier,
            source = { owner = "well-source", generationKey = "initial:secondLeft" },
            replacement = {
                generationKey = "travelDealRefill", offerKey = "RandomStoreItem",
                effect = "neutral",
            },
        }
    else
        refill = {
            carrier = carrier,
            source = { generationKey = "initial:secondLeft", slotIndex = 2 },
            replacement = {
                generationKey = "travelDealRefill", slotIndex = 2,
                optionKey = "TalentDrop", rewardType = "TalentDrop",
                deliverySourceKey = "shrine-refill-delivery",
                purchase = { roomDelay = 4, rushed = false },
            },
        }
    end
    return { kind = "travelDealRefill", owner = carrier .. "-refill", refill = refill }
end

local function harness(carrier, published, options)
    local module, _, callbacks = capture()
    local node = transaction(carrier)
    local overview = options and options.overview or {}
    local active = opaque({ occurrence = { id = "room", overview = overview } }, function(contact)
        if published ~= false and contact.kind == "travelDealRefill"
            and contact.carrier == carrier then return { transaction = node } end
    end)
    local diagnostics, begins, completions = {}, 0, 0
    local session = stub()
    session.current = function() return active end
    session.begin = function(_, handle)
        begins = begins + 1
        if options and options.denyBegin then return nil end
        return support.fakePayload(handle)
    end
    session.complete = function() completions = completions + 1 end
    session.diagnostic = function(_, checkpoint, observed)
        diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed }
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)
    return callbacks, node.refill, diagnostics,
        function() return begins end, function() return completions end
end

local function fill(callbacks, storeData, observeArgs)
    return callbacks.FillInShopOptions(nil, {}, function(args)
        if observeArgs then observeArgs(args) end
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf or {}) do
            for _, option in ipairs(group.OptionsData or {}) do options[#options + 1] = option end
            for _, option in ipairs(group.Options or {}) do options[#options + 1] = option end
        end
        for _, option in ipairs(args.StoreData.HealingOffers
            and args.StoreData.HealingOffers.WeightedList or {}) do options[#options + 1] = option end
        for _, option in ipairs(args.StoreData.Traits or {}) do options[#options + 1] = option end
        for _, option in ipairs(args.StoreData.Consumables or {}) do options[#options + 1] = option end
        return { StoreOptions = options }
    end, { StoreData = storeData })
end

function TestTravelDealRefills.testWorldShopUsesPublishedSlotAndCompletesAfterNativeRestock()
    local callbacks, refill, diagnostics, begins, completions = harness("worldShop")
    local generated, retried
    local restock = coroutine.create(function()
        return callbacks.RestockWorldItem(nil, {}, function()
            coroutine.yield("waiting-for-restock-screen")
            generated = fill(callbacks, { GroupsOf = { {
                OptionsData = { { Name = "Other" }, { Name = refill.replacement.optionKey } },
            } } })
            retried = fill(callbacks, { GroupsOf = { {
                OptionsData = { { Name = "Other" }, { Name = refill.replacement.optionKey } },
            } } })
            lu.assertEquals(completions(), 0)
            return true
        end, 1, 91, {})
    end)
    local resumed, reason = coroutine.resume(restock)
    lu.assertTrue(resumed)
    lu.assertEquals(reason, "waiting-for-restock-screen")
    local foreign = fill(callbacks, { GroupsOf = { {
        OptionsData = { { Name = "Foreign" } },
    } } })
    lu.assertEquals(foreign.StoreOptions[1].Name, "Foreign")
    resumed = coroutine.resume(restock)
    lu.assertTrue(resumed)
    lu.assertEquals(coroutine.status(restock), "dead")
    lu.assertEquals(generated.StoreOptions[1].Name, "ArmorBoost")
    lu.assertEquals(retried.StoreOptions[1].Name, "ArmorBoost")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(diagnostics, {})
end

function TestTravelDealRefills.testWorldShopRefillConstructionMissDiagnosesAndCompletesAtNativeTerminal()
    local callbacks, _, diagnostics, begins, completions = harness("worldShop")
    local nativeCalls = 0
    callbacks.RestockWorldItem(nil, {}, function()
        nativeCalls = nativeCalls + 1
        fill(callbacks, { GroupsOf = {} })
        return true
    end, 1, 91, {})
    lu.assertEquals(diagnostics[1].checkpoint, "shop-refill-group")
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
end

function TestTravelDealRefills.testWorldShopWrongRefillDiagnosesAndPassesNativeThroughUnclaimed()
    local initialOverview = { shop = { offers = { { offerKey = "InitialOffer" } } } }
    local callbacks, _, diagnostics, begins, completions = harness("worldShop", true,
        { overview = initialOverview })
    local nativeCalls = 0
    local nativeStore = { GroupsOf = { { OptionsData = {
        { Name = "InitialOffer" }, { Name = "NativeRefill" },
    } } } }
    local received
    callbacks.RestockWorldItem(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, 2, 91, {})
    lu.assertEquals(diagnostics[1].checkpoint, "shop-refill-slot")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(nativeCalls, 1)
    lu.assertIs(received, nativeStore)

    callbacks, _, diagnostics, begins, completions = harness("worldShop", false,
        { overview = initialOverview })
    received = nil
    callbacks.RestockWorldItem(nil, {}, function()
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, 1, 91, {})
    lu.assertEquals(diagnostics, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertIs(received, nativeStore)
end

function TestTravelDealRefills.testDeniedWorldRefillPassesNativeArgumentsWithoutInitialInventoryFallback()
    local overview = { shop = { offers = { { offerKey = "InitialOffer" } } } }
    local callbacks, _, diagnostics, begins, completions = harness("worldShop", true,
        { overview = overview, denyBegin = true })
    local nativeStore = { GroupsOf = { { OptionsData = {
        { Name = "InitialOffer" }, { Name = "NativeRefill" },
    } } } }
    local received
    local generated = callbacks.RestockWorldItem(nil, {}, function()
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, 1, 91, {})
    lu.assertIs(received, nativeStore)
    lu.assertEquals(#generated.StoreOptions, 2)
    lu.assertEquals(generated.StoreOptions[2].Name, "NativeRefill")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(diagnostics, {})
end

function TestTravelDealRefills.testWellRefillUsesPublishedSourceAndCompletesAfterInventoryGeneration()
    local callbacks, refill, diagnostics, begins, completions = harness("stygianWell")
    local source = {
        Name = "TemporaryDiscountTrait", Index = 2,
        __runPlannerGenerationKey = refill.source.generationKey,
    }
    local generated
    callbacks.HandleStorePurchase(nil, {}, function()
        generated = fill(callbacks, {
            HealingOffers = { WeightedList = { { Name = "HealDropRange" } } },
            Traits = {},
            Consumables = { { Name = "Other" }, { Name = refill.replacement.offerKey } },
        })
        return true
    end, {}, { Index = 2, Data = source }, {})
    lu.assertEquals(generated.StoreOptions[2].Name, "RandomStoreItem")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(diagnostics, {})
end

function TestTravelDealRefills.testWellWrongAndMissingRefillsStayDetectable()
    local overview = { stygianWell = { interacted = true, offers = {
        { generationKey = "initial:healing", offerKey = "HealDropRange" },
        { generationKey = "initial:secondLeft", offerKey = "Source" },
        { generationKey = "initial:secondRight", offerKey = "Other" },
    } } }
    local callbacks, _, diagnostics, begins, completions = harness("stygianWell", true,
        { overview = overview })
    local nativeStore = { HealingOffers = { WeightedList = { { Name = "HealDropRange" } } },
        Traits = {}, Consumables = { { Name = "Source" }, { Name = "NativeRefill" } } }
    local received
    callbacks.HandleStorePurchase(nil, {}, function()
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, {}, {
        Index = 2, Data = { Name = "Other", __runPlannerGenerationKey = "initial:secondRight" },
    }, {})
    lu.assertEquals(diagnostics[1].checkpoint, "well-refill-source")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertIs(received, nativeStore)

    callbacks, _, diagnostics, begins, completions = harness("stygianWell")
    callbacks.HandleStorePurchase(nil, {}, function() return true end, {}, {
        Index = 2, Data = { Name = "Source", __runPlannerGenerationKey = "initial:secondLeft" },
    }, {})
    lu.assertEquals(diagnostics, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

end

function TestTravelDealRefills.testWellPurchaseRejectedBeforeFillDoesNotBeginRefill()
    local callbacks, _, diagnostics, begins, completions = harness("stygianWell")
    local result = callbacks.HandleStorePurchase(nil, {}, function() return "native-rejected" end, {}, {
        Index = 2, Data = { Name = "Source", __runPlannerGenerationKey = "initial:secondLeft" },
    }, {})
    lu.assertEquals(result, "native-rejected")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(diagnostics, {})
end

function TestTravelDealRefills.testWellRefillWithoutCandidatePassesNativeArgumentsWithoutInitialFallback()
    local overview = { stygianWell = { interacted = true, offers = {
        { generationKey = "initial:healing", offerKey = "HealDropRange" },
        { generationKey = "initial:secondLeft", offerKey = "Source" },
        { generationKey = "initial:secondRight", offerKey = "Other" },
    } } }
    local callbacks, _, diagnostics, begins, completions = harness("stygianWell", false,
        { overview = overview })
    local nativeStore = { HealingOffers = { WeightedList = { { Name = "HealDropRange" } } },
        Traits = {}, Consumables = { { Name = "Source" }, { Name = "NativeRefill" } } }
    local received
    callbacks.HandleStorePurchase(nil, {}, function()
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, {}, { Index = 2, Data = { Name = "Source" } }, {})
    lu.assertIs(received, nativeStore)
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(diagnostics, {})
end

function TestTravelDealRefills.testShrineRefillUsesPublishedSourceDelayAndEventualAcquisitionOwnership()
    local callbacks, refill, diagnostics, begins, completions = harness("hermesShrine")
    local source = {
        Name = "Source", Purchased = true,
        __runPlannerGenerationKey = refill.source.generationKey,
    }
    local generated, screen
    local priorSurfaceShopData = _G.SurfaceShopData
    _G.SurfaceShopData = { DelayMin = 2, DelayMax = 8 }
    callbacks.HandleSurfaceShopAction(nil, {}, function()
        generated = fill(callbacks, { GroupsOf = { {
            OptionsData = { { Name = "Other" }, { Name = refill.replacement.optionKey } },
        } } })
        _G.CurrentRun = { CurrentRoom = { Store = { StoreOptions = generated.StoreOptions } } }
        screen = { Components = {} }
        callbacks.CreateSurfaceShopButtons(nil, {}, function(value)
            local option = generated.StoreOptions[2]
            option.RoomDelay = callbacks.RandomInt(nil, {}, function() return 8 end, 2, 8)
            value.Components.PurchaseButton2 = { Data = option }
        end, screen)
        return true
    end, {}, { Data = source }, {})
    _G.CurrentRun = nil
    _G.SurfaceShopData = priorSurfaceShopData
    lu.assertEquals(generated.StoreOptions[2].Name, "TalentDrop")
    lu.assertEquals(generated.StoreOptions[2].RoomDelay, 4)
    lu.assertEquals(screen.Components.PurchaseButton2.Data.RoomDelay, 4)
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(diagnostics, {})
end

function TestTravelDealRefills.testShrineWrongAndMissingRefillsStayDetectable()
    local overview = { hermesShrine = { offers = {
        { offerKey = "InitialOffer" }, { offerKey = "Other" }, { offerKey = "Third" },
    } } }
    local callbacks, _, diagnostics, begins, completions = harness("hermesShrine", true,
        { overview = overview })
    local nativeStore = { GroupsOf = { { OptionsData = {
        { Name = "InitialOffer" }, { Name = "NativeRefill" },
    } } } }
    local received
    callbacks.HandleSurfaceShopAction(nil, {}, function()
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, {}, { Data = {
        Purchased = true, __runPlannerGenerationKey = "initial:secondRight",
    } }, {})
    lu.assertEquals(diagnostics[1].checkpoint, "shrine-refill-source")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertIs(received, nativeStore)

    callbacks, _, diagnostics, begins, completions = harness("hermesShrine")
    callbacks.HandleSurfaceShopAction(nil, {}, function() return true end, {}, { Data = {
        Purchased = true, __runPlannerGenerationKey = "initial:secondLeft",
    } }, {})
    lu.assertEquals(diagnostics, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

end

function TestTravelDealRefills.testShrineRefillWithoutCandidatePassesNativeArgumentsWithoutInitialFallback()
    local overview = { hermesShrine = { offers = {
        { offerKey = "InitialOffer" }, { offerKey = "Other" }, { offerKey = "Third" },
    } } }
    local callbacks, _, diagnostics, begins, completions = harness("hermesShrine", false,
        { overview = overview })
    local nativeStore = { GroupsOf = { { OptionsData = {
        { Name = "InitialOffer" }, { Name = "NativeRefill" },
    } } } }
    local received
    callbacks.HandleSurfaceShopAction(nil, {}, function()
        return fill(callbacks, nativeStore, function(args) received = args.StoreData end)
    end, {}, { Data = { Purchased = true, Name = "Source" } }, {})
    lu.assertIs(received, nativeStore)
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(diagnostics, {})
end

return TestTravelDealRefills
