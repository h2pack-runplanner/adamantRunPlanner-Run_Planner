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

local function harness(carrier, published)
    local module, _, callbacks = capture()
    local node = transaction(carrier)
    local active = opaque({ occurrence = { id = "room", overview = {} } }, function(contact)
        if published ~= false and contact.kind == "travelDealRefill"
            and contact.carrier == carrier then return { transaction = node } end
    end)
    local mismatches, begins, completions = {}, 0, 0
    local session = stub()
    session.current = function() return active end
    session.begin = function(_, handle)
        begins = begins + 1
        return support.fakePayload(handle)
    end
    session.complete = function() completions = completions + 1 end
    session.mismatch = function(_, checkpoint, expected, observed)
        mismatches[#mismatches + 1] = {
            checkpoint = checkpoint, expected = expected, observed = observed,
        }
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)
    return callbacks, node.refill, mismatches,
        function() return begins end, function() return completions end
end

local function fill(callbacks, storeData)
    return callbacks.FillInShopOptions(nil, {}, function(args)
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
    local callbacks, refill, mismatches, begins, completions = harness("worldShop")
    local generated
    callbacks.RestockWorldItem(nil, {}, function()
        generated = fill(callbacks, { GroupsOf = { {
            OptionsData = { { Name = "Other" }, { Name = refill.replacement.optionKey } },
        } } })
        lu.assertEquals(completions(), 0)
        return true
    end, 1, 91, {})
    lu.assertEquals(generated.StoreOptions[1].Name, "ArmorBoost")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(mismatches, {})
end

function TestTravelDealRefills.testWorldShopWrongAndUnexpectedRestocksReportWithoutCompleting()
    local callbacks, _, mismatches, begins, completions = harness("worldShop")
    callbacks.RestockWorldItem(nil, {}, function() return true end, 2, 91, {})
    lu.assertEquals(mismatches[1].checkpoint, "shop-refill-slot")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

    callbacks, _, mismatches, begins, completions = harness("worldShop", false)
    callbacks.RestockWorldItem(nil, {}, function() return true end, 1, 91, {})
    lu.assertEquals(mismatches[1].checkpoint, "shop-refill-unexpected")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)
end

function TestTravelDealRefills.testWellRefillUsesPublishedSourceAndCompletesAfterInventoryGeneration()
    local callbacks, refill, mismatches, begins, completions = harness("stygianWell")
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
    lu.assertEquals(mismatches, {})
end

function TestTravelDealRefills.testWellWrongAndMissingRefillsStayDetectable()
    local callbacks, _, mismatches, begins, completions = harness("stygianWell")
    callbacks.HandleStorePurchase(nil, {}, function() return true end, {}, {
        Index = 2, Data = { Name = "Other", __runPlannerGenerationKey = "initial:secondRight" },
    }, {})
    lu.assertEquals(mismatches[1].checkpoint, "well-refill-source")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

    callbacks, _, mismatches, begins, completions = harness("stygianWell")
    callbacks.HandleStorePurchase(nil, {}, function() return true end, {}, {
        Index = 2, Data = { Name = "Source", __runPlannerGenerationKey = "initial:secondLeft" },
    }, {})
    lu.assertEquals(mismatches, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

end

function TestTravelDealRefills.testShrineRefillUsesPublishedSourceDelayAndEventualAcquisitionOwnership()
    local callbacks, refill, mismatches, begins, completions = harness("hermesShrine")
    local source = {
        Name = "Source", Purchased = true,
        __runPlannerGenerationKey = refill.source.generationKey,
    }
    local generated, screen
    callbacks.HandleSurfaceShopAction(nil, {}, function()
        generated = fill(callbacks, { GroupsOf = { {
            OptionsData = { { Name = "Other" }, { Name = refill.replacement.optionKey } },
        } } })
        _G.CurrentRun = { CurrentRoom = { Store = { StoreOptions = generated.StoreOptions } } }
        screen = { Components = {} }
        callbacks.CreateSurfaceShopButtons(nil, {}, function(value)
            value.Components.PurchaseButton2 = { Data = {} }
        end, screen)
        return true
    end, {}, { Data = source }, {})
    _G.CurrentRun = nil
    lu.assertEquals(generated.StoreOptions[2].Name, "TalentDrop")
    lu.assertEquals(generated.StoreOptions[2].RoomDelay, 4)
    lu.assertEquals(screen.Components.PurchaseButton2.Data.RoomDelay, 4)
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(mismatches, {})
end

function TestTravelDealRefills.testShrineWrongAndMissingRefillsStayDetectable()
    local callbacks, _, mismatches, begins, completions = harness("hermesShrine")
    callbacks.HandleSurfaceShopAction(nil, {}, function() return true end, {}, { Data = {
        Purchased = true, __runPlannerGenerationKey = "initial:secondRight",
    } }, {})
    lu.assertEquals(mismatches[1].checkpoint, "shrine-refill-source")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

    callbacks, _, mismatches, begins, completions = harness("hermesShrine")
    callbacks.HandleSurfaceShopAction(nil, {}, function() return true end, {}, { Data = {
        Purchased = true, __runPlannerGenerationKey = "initial:secondLeft",
    } }, {})
    lu.assertEquals(mismatches, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(completions(), 0)

end

return TestTravelDealRefills
