-- luacheck: globals TestFeatureInteractionHooks
local lu = require("luaunit")
local roomCoordinatorModule = require("mods.room.coordinator")
local json = require("mods.protocol.json")
local mysteryAcquisitions = require("mods.room.timeline.acquisitions.mystery.hooks")
local traitSeaStar = require("mods.room.timeline.acquisitions.sea_star").create()
local traitAcquisitions = require("mods.room.timeline.acquisitions.traits.hooks")
local loadoutHexTree = require("mods.spells.hex_tree").create()
local loadoutHooks = require("mods.loadout.hooks")
local runtimeSession = require("mods.runtime.session")
local support = require("tests.harness.hook_composition")
local capture, stub, opaque = support.capture, support.stub, support.opaque
local fakePayload, attachFeatureHooks = support.fakePayload, support.attachFeatureHooks

TestFeatureInteractionHooks = {}

function TestFeatureInteractionHooks.testShrinePublishesAllThreeOffersAndKeepsUnpurchasedRowsVisible()
    local module, _, callbacks = capture()
    local mismatches = {}
    local active = opaque({
        occurrence = { overview = { hermesShrine = {
            offers = {
                {
                    generationKey = "initial:first", optionKey = "BoonA",
                    rewardType = "BoonA", slotIndex = 1,
                    purchase = { roomDelay = 2, rushed = true },
                },
                {
                    generationKey = "initial:secondLeft", optionKey = "BoonB",
                    rewardType = "BoonB", slotIndex = 2,
                    purchase = { roomDelay = 8, rushed = false },
                },
                {
                    generationKey = "initial:secondRight", optionKey = "BoonC",
                    rewardType = "BoonC", slotIndex = 3,
                },
            },
        } } },
    }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    session.mismatch = function(_, checkpoint, expected, observed)
        mismatches[#mismatches + 1] = { checkpoint = checkpoint, expected = expected, observed = observed }
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf) do
            for _, option in ipairs(group.OptionsData or {}) do options[#options + 1] = option end
        end
        return { StoreOptions = options }
    end, { StoreData = { GroupsOf = {
        { Offers = 3, OptionsData = {
            { Name = "BoonA" }, { Name = "BoonB" }, { Name = "BoonC" }, { Name = "OffPlan" },
        } },
    } } })

    lu.assertEquals(#generated.StoreOptions, 3)
    lu.assertEquals(generated.StoreOptions[1].__runPlannerGenerationKey, "initial:first")
    lu.assertEquals(generated.StoreOptions[2].__runPlannerGenerationKey, "initial:secondLeft")
    lu.assertEquals(generated.StoreOptions[3].__runPlannerGenerationKey, "initial:secondRight")
    local priorRun = _G.CurrentRun
    local priorSurfaceShopData = _G.SurfaceShopData
    _G.SurfaceShopData = { DelayMin = 2, DelayMax = 8 }
    _G.CurrentRun = { CurrentRoom = { Store = { StoreOptions = generated.StoreOptions } } }
    local screen = { Components = {} }
    local observedDuringBase
    local first, second = callbacks.CreateSurfaceShopButtons(nil, {}, function(value)
        for index = 1, 3 do
            local option = generated.StoreOptions[index]
            option.RoomDelay = callbacks.RandomInt(nil, {}, function()
                return index == 1 and 8 or 2
            end, 2, 8)
            value.Components["PurchaseButton" .. index] = { Data = option }
        end
        observedDuringBase = generated.StoreOptions[1].RoomDelay
        return "native-first", "native-second"
    end, screen)
    _G.CurrentRun = priorRun
    _G.SurfaceShopData = priorSurfaceShopData
    lu.assertEquals(observedDuringBase, 2)
    lu.assertEquals(generated.StoreOptions[1].RoomDelay, 2)
    lu.assertEquals(screen.Components.PurchaseButton1.Data.RoomDelay, 2)
    lu.assertEquals(generated.StoreOptions[2].RoomDelay, 8)
    lu.assertEquals(screen.Components.PurchaseButton2.Data.RoomDelay, 8)
    lu.assertEquals(generated.StoreOptions[3].RoomDelay, 2)
    lu.assertEquals(first, "native-first")
    lu.assertEquals(second, "native-second")
    lu.assertEquals(mismatches, {})
end

function TestFeatureInteractionHooks.testShrineBuilderFaultRestoresDelayScope()
    local module, _, callbacks = capture()
    local active = opaque({ occurrence = { overview = { hermesShrine = {
        offers = {
            { slotIndex = 1, purchase = { roomDelay = 2 } },
        },
    } } } }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    local priorSurfaceShopData = _G.SurfaceShopData
    _G.SurfaceShopData = { DelayMin = 2, DelayMax = 8 }
    local option = { Name = "BoonA" }
    _G.CurrentRun = { CurrentRoom = { Store = { StoreOptions = { option } } } }
    local screen = { Components = {} }
    local ok, failure = pcall(callbacks.CreateSurfaceShopButtons, nil, {}, function(value)
        value.Components.PurchaseButton1 = { Data = option }
        error("native shrine failure")
    end, screen)
    local nativeCalls = 0
    local nativeDelay = callbacks.RandomInt(nil, {}, function(_, maximum)
        nativeCalls = nativeCalls + 1
        return maximum
    end, 2, 8)
    _G.CurrentRun = priorRun
    _G.SurfaceShopData = priorSurfaceShopData

    lu.assertFalse(ok)
    lu.assertStrContains(failure, "native shrine failure")
    lu.assertEquals(nativeDelay, 8)
    lu.assertEquals(nativeCalls, 1)
end


function TestFeatureInteractionHooks.testShrineDeliveryBindsExactSourceWithoutBeginningAcquisition()
    local module, _, callbacks = capture()
    local begun = 0
    local delivery = {
        owner = "shrine-delivery", kind = "acquisition",
        hermesShrineSourceKey = "source-one:initial:first",
    }
    local active = opaque({
        occurrence = { overview = { hermesShrine = {
            offers = {
                { generationKey = "initial:first", optionKey = "BoonA", rewardType = "BoonA", slotIndex = 1 },
                { generationKey = "initial:secondLeft", optionKey = "BoonB", rewardType = "BoonB", slotIndex = 2 },
                { generationKey = "initial:secondRight", optionKey = "BoonC", rewardType = "BoonC", slotIndex = 3 },
            },
        } } },
    }, function(contact)
        if contact.kind == "hermesShrineDelivery"
            and contact.sourceKey == "source-one:initial:first" then
            return { transaction = delivery }
        end
    end)
    local session = stub()
    session.current = function() return active end
    session.begin = function() begun = begun + 1 end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = {} }
    local item = {
        Name = "MysteryBoon", __runPlannerShrine = true,
        __runPlannerShrineSourceKey = "source-one:initial:first",
    }
    callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 91 } end, item, 10)
    lu.assertEquals(begun, 0)
    _G.CurrentRun = priorRun
end


function TestFeatureInteractionHooks.testUninteractedPoolLeavesNativeSaleMenuUntouched()
    local module, _, callbacks = capture()
    local nativeOptions = { { Name = "TraitA" }, { Name = "TraitB" } }
    local active = opaque({ occurrence = { overview = {
        purgingPool = { interacted = false },
    } } }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { SellOptions = nativeOptions } }
    callbacks.CreateSellButtons(nil, {}, function() return true end, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(_G.CurrentRun, priorRun)
    lu.assertEquals(nativeOptions, { { Name = "TraitA" }, { Name = "TraitB" } })
end

function TestFeatureInteractionHooks.testInteractedPoolSteersOnlyTheNativeSaleMenu()
    local module, _, callbacks = capture()
    local active = opaque({ occurrence = { overview = {
        purgingPool = { interacted = true, traits = {
            { slotKey = "left", traitKey = "TraitB" },
            { slotKey = "middle", traitKey = "TraitA" },
        } },
    } } }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    local nativeOptions = { { Name = "TraitA" }, { Name = "TraitC" } }
    local nativeRoom = {
        SellOptions = nativeOptions,
        SellValues = {
            TraitA = { Name = "TraitA", Value = 10 },
            TraitB = { Name = "TraitB", Value = 20 },
            TraitC = { Name = "TraitC", Value = 30 },
        },
    }
    _G.CurrentRun = { CurrentRoom = nativeRoom }
    -- Native generation already selected TraitA and removed it from
    -- SellValues; TraitB remains in the legal candidate map but was omitted
    -- from the random rows.  The authored menu must recover both.
    nativeRoom.SellValues.TraitA = nil
    nativeRoom.SellOptions = { { Name = "TraitA", Value = 10 } }
    callbacks.CreateSellButtons(nil, {}, function() return true end, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(nativeRoom.SellOptions[1].Name, "TraitB")
    lu.assertEquals(nativeRoom.SellOptions[2].Name, "TraitA")
    lu.assertNil(callbacks.HandleSellChoiceSelection)
end


function TestFeatureInteractionHooks.testSuccessfulNativeKeepsakeEquipCompletesTheRackTransaction()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "rack", kind = "keepsakeChange", keepsakeKey = "GoldifyKeepsake",
        window = { kind = "standard", phase = "beforeCombat" }, equipResults = {},
    }
    local occurrence = { transactionsByOwner = { rack = node }, timeline = { dependencies = {}, obligations = {} } }
    local plan = { occurrencesById = { one = occurrence } }
    local state = { initialized = true, state = "synchronized", plan = plan, route = {} }
    state.room = roomCoordinatorModule.new(plan, function() end, {})
    assert(roomCoordinatorModule.enter(state, occurrence))
    local session = stub()
    session.complete = function(_, handle)
        completed = { handle = handle }
        return true
    end
    local priorImport = _G.import
    _G.import = function(path)
        return assert(loadfile("src/" .. path))()
    end
    loadoutHooks.attach(module, { inbox = {}, session = session, loadout = {}, activePlanSlot = function() return 1 end },
        function() return state end, function() end, roomCoordinatorModule, loadoutHexTree)
    callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "GoldifyKeepsake", {})
    _G.import = priorImport

    lu.assertNotNil(completed.handle)
end

function TestFeatureInteractionHooks.testPurchasedMysteryBoonCompletesAfterItsTraitRowsAreInstalled()
    local module, _, callbacks = capture()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local completions = {}
    local node = {
        owner = "mystery", kind = "acquisition", sourceOwner = "mystery",
        producerLifecycleKey = "WorldShop", reward = { rewardType = "BlindBoxLoot" },
        window = { kind = "postOutgoing" },
        roles = {
            { role = "box", lifecyclePoint = "purchase", gameName = "BlindBoxLoot" },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                disposition = "normal", gameName = "HeraUpgrade",
                traitOffer = {
                    kind = "traits", giver = "Hera", selected = "option1",
                    options = {
                        { key = "HeraCastBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraSprintBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraManaBoon", rarity = "Common", effectiveLevel = 4 },
                    },
                },
            },
        },
    }
    local occurrence = {
        id = "shop",
        overview = { shop = { offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } } } },
        transactionsByOwner = { mystery = node },
        timeline = { transactions = { node }, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { shop = occurrence } }
    local mismatches = {}
    local room = roomCoordinatorModule.new(plan, function(errorValue, expected, observed)
        mismatches[#mismatches + 1] = { error = errorValue, expected = expected, observed = observed }
    end)
    local state = { state = "synchronized", plan = plan, room = room }
    local active = assert(roomCoordinatorModule.enter(state, occurrence))
    assert(roomCoordinatorModule.window(state, "postOutgoing"))
    local box = { Name = "BlindBoxLoot" }
    local loot = { Name = "HeraUpgrade", GodLoot = true }
    lu.assertNil(roomCoordinatorModule.bound(state, active, box))
    local session = {
        current = roomCoordinatorModule.current,
        peek = roomCoordinatorModule.peek,
        bind = roomCoordinatorModule.bind,
        bound = roomCoordinatorModule.bound,
        begin = roomCoordinatorModule.begin,
        resolve = roomCoordinatorModule.resolve,
        claimReady = roomCoordinatorModule.claimReady,
        mismatch = function() end,
    }
    session.complete = function(runtimeState, handle)
        completions[#completions + 1] = { handle = handle }
        return roomCoordinatorModule.complete(runtimeState, handle)
    end
    mysteryAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    traitAcquisitions.attach(module, session, function() return state end,
        function() end, roomCoordinatorModule, traitSeaStar)

    callbacks.UnwrapRandomLoot(nil, {}, function()
        callbacks.GiveLoot(nil, {}, function(args)
            lu.assertEquals(args.ForceLootName, "HeraUpgrade")
            return loot
        end, {})
    end, box)
    lu.assertNotNil(roomCoordinatorModule.bound(state, active, box))
    lu.assertEquals(#completions, 0)
    local boxHandle = roomCoordinatorModule.bound(state, active, box)
    lu.assertNotNil(boxHandle)
    lu.assertTrue(rawequal(roomCoordinatorModule.bound(state, active, loot), boxHandle))
    lu.assertEquals(roomCoordinatorModule.peek(state, boxHandle).detail, node.roles[2])
    callbacks.HandleLootPickup(nil, {}, function(_, nativeLoot)
        callbacks.CreateBoonLootButtons(nil, {}, function() return true end, {}, nativeLoot, false, {})
    end, _G.CurrentRun, loot, {})
    lu.assertEquals(#completions, 1)
    _G.CurrentRun.Hero.Traits = { { Name = "HeraCastBoon", Rarity = "Common", StackNum = 4 } }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "HeraCastBoon" } }, {})
    lu.assertEquals(#completions, 1)
    lu.assertEquals(mismatches, {})
    _G.CurrentRun = priorRun
end

function TestFeatureInteractionHooks.testDestinationShopInventoryUsesTheNextOccurrenceBeforeRoomEntry()
    local module, _, callbacks = capture()
    local shop = opaque({
        occurrence = { id = "shop", overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
            { offerKey = "MajorNonBoon", optionKey = "ArmorBoost" },
            { offerKey = "Minor", optionKey = "MaxManaDrop" },
        } } } },
    }, function() return nil end)
    local session = stub()
    session.current = function() return nil end
    session.prepare = function(_, value)
        lu.assertEquals(value, shop.occurrence)
        return shop
    end
    local state = { route = {} }
    local route = { expected = function() return shop.occurrence end }
    attachFeatureHooks(module, session, function() return state end, function() end, session, route)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { __runPlannerExecutionRoomId = "shop" } }
    local result = callbacks.FillInShopOptions(nil, {}, function(args)
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf) do options[#options + 1] = group.OptionsData[1] end
        return { StoreOptions = options }
    end, { StoreData = { GroupsOf = {
        { OptionsData = { { Name = "RandomLoot" }, { Name = "BlindBoxLoot" } } },
        { OptionsData = { { Name = "ArmorBoost" }, { Name = "MetaCurrencyDrop" } } },
        { OptionsData = { { Name = "StackUpgrade" }, { Name = "MaxManaDrop" } } },
    } } })
    _G.CurrentRun = priorRun

    lu.assertEquals(result.StoreOptions[1].Name, "BlindBoxLoot")
    lu.assertEquals(result.StoreOptions[2].Name, "ArmorBoost")
    lu.assertEquals(result.StoreOptions[3].Name, "MaxManaDrop")
end



function TestFeatureInteractionHooks.testUninteractedWellLeavesNativeInventoryUntouched()
    local module, _, callbacks = capture()
    local active = opaque({ occurrence = { overview = {
        stygianWell = { interacted = false },
    } } }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local source = {
        StoreData = {
            HealingOffers = { WeightedList = { { Name = "ArmorBoostStore" } } },
            Traits = { { Name = "TemporaryDiscountTrait" } },
            Consumables = { { Name = "RandomStoreItem" } },
        },
    }
    local received
    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        received = args
        return { StoreOptions = { { Name = "ArmorBoostStore" } } }
    end, source)
    lu.assertTrue(received == source)
    lu.assertEquals(generated.StoreOptions[1].Name, "ArmorBoostStore")
end

function TestFeatureInteractionHooks.testInteractedWellSteersItsThreeInitialOfferSlots()
    local module, _, callbacks = capture()
    local expected = {
        { generationKey = "initial:healing", offerKey = "ArmorBoostStore" },
        { generationKey = "initial:secondLeft", offerKey = "TemporaryDiscountTrait" },
        { generationKey = "initial:secondRight", offerKey = "RandomStoreItem" },
    }
    local active = opaque({ occurrence = { overview = {
        stygianWell = { interacted = true, offers = expected },
    } } }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        return { StoreOptions = {
            args.StoreData.HealingOffers.WeightedList[1],
            args.StoreData.Traits[1],
            args.StoreData.Consumables[1],
        } }
    end, { StoreData = {
        HealingOffers = { WeightedList = {
            { Name = "HealDropRange" }, { Name = "ArmorBoostStore" },
        } },
        Traits = { { Name = "TemporaryDiscountTrait" }, { Name = "TemporaryMoveSpeedTrait" } },
        Consumables = { { Name = "RandomStoreItem" }, { Name = "LastStandShopItem" } },
    } })

    lu.assertEquals(generated.StoreOptions[1].Name, "ArmorBoostStore")
    lu.assertEquals(generated.StoreOptions[2].Name, "TemporaryDiscountTrait")
    lu.assertEquals(generated.StoreOptions[3].Name, "RandomStoreItem")
    for index, offer in ipairs(expected) do
        lu.assertEquals(generated.StoreOptions[index].__runPlannerGenerationKey, offer.generationKey)
        lu.assertEquals(generated.StoreOptions[index].__runPlannerOfferKey, offer.offerKey)
    end
end





function TestFeatureInteractionHooks.testWorldShopInventoryUsesThePublishedOfferSetAcrossQGroups()
    local module, _, callbacks = capture()
    local expected = {
        { offerKey = "Boon", transactionOwner = "shop:boosted", optionKey = "BoostedRandomLoot" },
        { offerKey = "Minor", transactionOwner = "shop:minor", optionKey = "MaxManaDrop" },
        { offerKey = "Major", transactionOwner = "shop:major", optionKey = "ArmorBoost" },
        { offerKey = "Hammer", transactionOwner = "shop:hammer", optionKey = "WeaponUpgradeDrop" },
        { offerKey = "Talent", transactionOwner = "shop:talent", optionKey = "TalentDrop" },
        { offerKey = "Spell", transactionOwner = "shop:spell", optionKey = "SpellDrop" },
    }
    local active = opaque({ occurrence = { overview = { shop = { offers = expected } } } }, function()
        return nil
    end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf) do
            for _, option in ipairs(group.OptionsData or {}) do
                if option.Name == "BoostedRandomLoot" then
                    options[#options + 1] = {
                        Name = "RandomLoot",
                        Args = {
                            AddBoostedAnimation = true,
                            BoonRaritiesOverride = { Rare = 0.9 },
                        },
                    }
                else
                    options[#options + 1] = option
                end
            end
        end
        return { StoreOptions = options }
    end, { StoreData = { GroupsOf = {
        { OptionsData = {
            { Name = "BlindBoxLoot" }, { Name = "BoostedRandomLoot" },
            { Name = "MaxHealthDrop" },
        } },
        { OptionsData = { { Name = "MaxManaDrop" }, { Name = "StackUpgrade" } } },
        { OptionsData = { { Name = "ArmorBoost" }, { Name = "LastStandDrop" } } },
        { OptionsData = { { Name = "WeaponUpgradeDrop" }, { Name = "ChaosWeaponUpgrade" } } },
        { OptionsData = { { Name = "TalentDrop" }, { Name = "SpellDrop" } } },
    } } })

    lu.assertEquals(#generated.StoreOptions, #expected)
    for index, offer in ipairs(expected) do
        lu.assertEquals(generated.StoreOptions[index].Name,
            offer.optionKey == "BoostedRandomLoot" and "RandomLoot" or offer.optionKey)
        if offer.optionKey == "BoostedRandomLoot" then
            lu.assertTrue(generated.StoreOptions[index].Args.AddBoostedAnimation)
        end
        lu.assertEquals(generated.StoreOptions[index].__runPlannerOfferKey, offer.offerKey)
        lu.assertTrue(generated.StoreOptions[index].__runPlannerWorldShop)
        lu.assertEquals(generated.StoreOptions[index].__runPlannerTransactionOwner, offer.transactionOwner)
    end
end

function TestFeatureInteractionHooks.testWorldShopWorldItemsBindOnlyTheirStampedTransactionOwners()
    local module, _, callbacks = capture()
    local normal = {
        owner = "normal", sourceOwner = "shop:normal", kind = "acquisition",
        roles = { {
            role = "self", gameName = "RandomLoot",
            traitOffer = { options = { { key = "ApolloWeaponBoon", rarity = "Common" } } },
        } },
    }
    local boosted = {
        owner = "boosted", sourceOwner = "shop:boosted", kind = "acquisition",
        roles = { {
            role = "self", gameName = "RandomLoot",
            traitOffer = { options = { { key = "ApolloWeaponBoon", rarity = "Heroic" } } },
        } },
    }
    local genericLookups, nativeCalls = 0, 0
    local active = opaque({ occurrence = { overview = { shop = { offers = {
        { offerKey = "normal", transactionOwner = normal.owner, optionKey = "RandomLoot" },
        { offerKey = "boosted", transactionOwner = boosted.owner, optionKey = "BoostedRandomLoot" },
    } } } } }, function(contact)
        if contact.kind == "owner" and contact.owner == normal.owner then
            return { transaction = normal }
        end
        if contact.kind == "owner" and contact.owner == boosted.owner then
            return { transaction = boosted }
        end
        if contact.kind == "materialized" and contact.source and contact.source.transaction == normal then
            return { transaction = normal, detail = normal.roles[1] }
        end
        if contact.kind == "materialized" and contact.source and contact.source.transaction == boosted then
            return { transaction = boosted, detail = boosted.roles[1] }
        end
        if contact.kind == "offer" then genericLookups = genericLookups + 1 end
    end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        return { StoreOptions = {
            args.StoreData.GroupsOf[1].OptionsData[1],
            {
                Name = "RandomLoot",
                Args = args.StoreData.GroupsOf[1].OptionsData[2].Args,
            },
        } }
    end, { StoreData = { GroupsOf = { { OptionsData = {
        { Name = "RandomLoot" },
        { Name = "BoostedRandomLoot", Args = { AddBoostedAnimation = true, BoonRaritiesOverride = { Rare = 1 } } },
    } } } } })
    lu.assertTrue(generated.StoreOptions[1].__runPlannerWorldShop)
    lu.assertEquals(generated.StoreOptions[1].__runPlannerTransactionOwner, normal.owner)
    lu.assertTrue(generated.StoreOptions[2].__runPlannerWorldShop)
    lu.assertEquals(generated.StoreOptions[2].__runPlannerTransactionOwner, boosted.owner)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Store = { StoreOptions = generated.StoreOptions } } }
    local screen = { Components = {} }
    callbacks.CreateStoreButtons(nil, {}, function(value)
        for index, option in ipairs(generated.StoreOptions) do
            value.Components["PurchaseButton" .. index] = { Data = { Name = option.Name } }
        end
    end, screen)
    _G.CurrentRun = priorRun
    lu.assertTrue(screen.Components.PurchaseButton1.Data.__runPlannerWorldShop)
    lu.assertEquals(screen.Components.PurchaseButton1.Data.__runPlannerTransactionOwner, normal.owner)
    lu.assertTrue(screen.Components.PurchaseButton2.Data.__runPlannerWorldShop)
    lu.assertEquals(screen.Components.PurchaseButton2.Data.__runPlannerTransactionOwner, boosted.owner)

    local boostedNative = callbacks.SpawnStoreItemInWorld(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return { Name = "RandomLoot" }
    end, screen.Components.PurchaseButton2.Data, nil)
    local normalNative = callbacks.SpawnStoreItemInWorld(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return { Name = "RandomLoot" }
    end, screen.Components.PurchaseButton1.Data, nil)
    lu.assertNotNil(active.bindingFor(boostedNative))
    lu.assertEquals(fakePayload(active.bindingFor(boostedNative)).transaction, boosted)
    lu.assertEquals(fakePayload(active.bindingFor(normalNative)).transaction, normal)
    lu.assertEquals(fakePayload(active.bindingFor(boostedNative)).detail.traitOffer.options[1].rarity, "Heroic")
    lu.assertEquals(fakePayload(active.bindingFor(normalNative)).detail.traitOffer.options[1].rarity, "Common")

    local unplannedNative = callbacks.SpawnStoreItemInWorld(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return { Name = "RandomLoot" }
    end, {
        Name = "RandomLoot", __runPlannerOfferKey = "normal", __runPlannerWorldShop = true,
    }, nil)
    lu.assertNil(active.bindingFor(unplannedNative))
    lu.assertEquals(genericLookups, 0)
    lu.assertEquals(nativeCalls, 3)
end

function TestFeatureInteractionHooks.testBlockedStampedWorldShopOwnerReachesNativeTraitHookWithoutPeerRebinding()
    local module, _, callbacks = capture()
    local normal = {
        owner = "normal", sourceOwner = "shop:normal", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup", gameName = "RandomLoot",
            traitOffer = { kind = "traits", giver = "Apollo", selected = "option1", options = {
                { key = "ApolloAttack" }, { key = "ApolloSpecial" }, { key = "ApolloCast" },
            } },
        } },
    }
    local boosted = {
        owner = "boosted", sourceOwner = "shop:boosted", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" }, roles = normal.roles,
    }
    local occurrence = {
        id = "shop", overview = { shop = { offers = {
            { offerKey = "normal", optionKey = "RandomLoot" },
            { offerKey = "boosted", optionKey = "BoostedRandomLoot", transactionOwner = boosted.owner },
        } } },
        transactionsByOwner = { normal = normal, boosted = boosted },
        timeline = {
            transactions = { normal, boosted },
            dependencies = { { owner = "boosted", afterOwner = "normal" } }, obligations = {},
        },
    }
    local plan = { occurrencesById = { shop = occurrence } }
    local mismatches = {}
    local room = roomCoordinatorModule.new(plan, function(errorValue)
        mismatches[#mismatches + 1] = errorValue
    end)
    local state = { state = "synchronized", plan = plan, room = room }
    local active = assert(roomCoordinatorModule.enter(state, occurrence))
    local session = {
        current = roomCoordinatorModule.current, peek = roomCoordinatorModule.peek,
        bind = roomCoordinatorModule.bind, bound = roomCoordinatorModule.bound,
        begin = roomCoordinatorModule.begin, resolve = roomCoordinatorModule.resolve,
        claimReady = roomCoordinatorModule.claimReady, mismatch = function() end,
    }
    attachFeatureHooks(module, session, function() return state end, function() end, roomCoordinatorModule)
    traitAcquisitions.attach(module, session, function() return state end,
        function() end, roomCoordinatorModule, traitSeaStar)

    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        return { StoreOptions = {
            args.StoreData.GroupsOf[1].OptionsData[1],
            { Name = "RandomLoot", Args = args.StoreData.GroupsOf[1].OptionsData[2].Args },
        } }
    end, { StoreData = { GroupsOf = { { OptionsData = {
        { Name = "RandomLoot" },
        { Name = "BoostedRandomLoot", Args = { AddBoostedAnimation = true, BoonRaritiesOverride = { Rare = 1 } } },
    } } } } })
    lu.assertTrue(generated.StoreOptions[2].__runPlannerWorldShop)
    lu.assertEquals(generated.StoreOptions[2].__runPlannerTransactionOwner, "boosted")

    local nativeCalls = 0
    local native = callbacks.SpawnStoreItemInWorld(nil, {}, function()
        return { Name = "RandomLoot", GodLoot = true }
    end, generated.StoreOptions[2], nil)
    local handle = active._timeline.nativeHandles[native]
    lu.assertNotNil(handle)
    lu.assertEquals(active._timeline.handles[handle].transaction.owner, "boosted")

    callbacks.HandleLootPickup(nil, {}, function()
        nativeCalls = nativeCalls + 1
    end, {}, native, {})
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(#mismatches, 1)
    lu.assertEquals(mismatches[1].checkpoint, "transaction-prerequisite")
    lu.assertEquals(mismatches[1].observed, "boosted")
    lu.assertNil(active._timeline.completedOwners.normal)
    lu.assertNil(active._timeline.completedOwners.boosted)
end



function TestFeatureInteractionHooks.testInfernalContractUsesThePublishedFreePedestalInventory()
    local module, _, callbacks = capture()
    local sourceOwner = "acquisition-owner"
    local active = opaque({ occurrence = { overview = { shop = {
        offers = {}, infernalContract = { sourceOwner = sourceOwner, rewardType = "BlindBoxLoot" },
    } } } }, function(_contact)
        return nil
    end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = {} }
    callbacks.SpawnZagContractRewards(nil, {}, function()
        local generated = callbacks.FillInShopOptions(nil, {}, function(args)
            return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
        end, { StoreData = { GroupsOf = { { OptionsData = {
            { Name = "MetaCurrencyDrop" }, { Name = "BlindBoxLoot" },
        } } } } })
        lu.assertEquals(generated.StoreOptions[1].Name, "BlindBoxLoot")
        lu.assertEquals(generated.StoreOptions[1].__runPlannerContractSourceOwner, sourceOwner)
        callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 15 } end,
            generated.StoreOptions[1], nil)
    end, {}, {})
    _G.CurrentRun = priorRun
end
