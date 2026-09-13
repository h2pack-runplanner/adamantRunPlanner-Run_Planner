-- luacheck: globals TestTimelineBindings
local lu = require("luaunit")
local bindings = require("mods.room.timeline.bindings")
local timelineSession = require("mods.room.timeline.session")

TestTimelineBindings = {}

local function resolved(index, contact)
    return assert(bindings.resolve(index, contact))
end

local function occurrence()
    return {
        overview = { shop = { offers = {} }, stygianWell = { offers = {} } },
        transactionsByOwner = {
            owner = {
                owner = "owner", kind = "acquisition", offerKey = "offer",
                window = { kind = "standard", phase = "beforeCombat" },
            },
        },
    }
end

function TestTimelineBindings.testIndexesRejectAmbiguousPublishedKeys()
    local item = occurrence()
    item.transactionsByOwner.other = {
        owner = "other", kind = "acquisition", offerKey = "offer",
        window = { kind = "standard", phase = "beforeCombat" },
    }
    local index, errorValue = bindings.index(item)
    lu.assertNil(index)
    lu.assertEquals(errorValue.checkpoint, "timeline-binding")
end

function TestTimelineBindings.testTrialAcquisitionsShareSourceButBindDistinctNativeGods()
    local chosen = {
        owner = "chosen", sourceOwner = "incoming", kind = "acquisition",
        producerLifecycleKey = "RoomReward", reward = { rewardType = "Devotion" },
        window = { kind = "standard", phase = "beforeCombat" },
        roles = { { role = "chosenSource", gameName = "ZeusUpgrade" } },
    }
    local spurned = {
        owner = "spurned", sourceOwner = "incoming", kind = "acquisition",
        producerLifecycleKey = "RoomReward", reward = { rewardType = "Devotion" },
        window = { kind = "standard", phase = "afterCombat" },
        roles = { { role = "spurnedSource", gameName = "HeraUpgrade" } },
    }
    local item = {
        overview = { incomingReward = chosen.reward },
        transactionsByOwner = { chosen = chosen, spurned = spurned },
    }
    item.overview.incomingReward.producerLifecycleKey = "RoomReward"
    local index = assert(bindings.index(item))
    for _, transaction in ipairs({ chosen, spurned }) do
        lu.assertEquals(resolved(index, { kind = "source", sourceOwner = "incoming",
            gameName = transaction.roles[1].gameName }).transaction, transaction)
    end
    -- Native SpawnRoomReward creates the spurned reward after the trial;
    -- resolve against actual material identity, not the shared source alone.
    local callbacks, bound = {}, nil
    local current = { occurrence = item }
    require("mods.room.timeline.acquisitions.binding").attach({
        hooks = { wrap = function(name, _, callback) callbacks[name] = callback end },
    }, {}, function() return {} end, function() end, {
        current = function() return current end,
        resolve = function(_, _, contact)
            return assert(bindings.resolve(index, contact, contact.source))
        end,
        bind = function(_, _, row, native) bound = { row = row, native = native } end,
    })
    local native = { Name = "HeraUpgrade", GodLoot = true }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return native end, {})
    end, {}, {})
    lu.assertEquals(bound.row.transaction, spurned)
    lu.assertEquals(bound.row.detail.role, "spurnedSource")
    lu.assertIs(bound.native, native)
    lu.assertEquals(resolved(index, { kind = "producer", producerLifecycleKey = "RoomReward",
        rewardType = "Devotion", gameName = "ZeusUpgrade" }).transaction, chosen)
end

function TestTimelineBindings.testExactShopOwnerKeepsItsBlockedOwnerInsteadOfClaimingAReadyPeer()
    local normal = {
        owner = "normal", sourceOwner = "shop:normal", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = { { role = "self", gameName = "RandomLoot" } },
    }
    local boosted = {
        owner = "boosted", sourceOwner = "shop:boosted", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = { { role = "self", gameName = "RandomLoot" } },
    }
    local item = {
        transactionsByOwner = { normal = normal, boosted = boosted },
        timeline = {
            transactions = { normal, boosted },
            dependencies = { { owner = "boosted", afterOwner = "normal" } }, obligations = {},
        },
    }
    local session = timelineSession.new(item, assert(bindings.index(item)))
    lu.assertTrue(timelineSession.open(session, "roomEntered"))
    local handle = assert(timelineSession.resolve(session, bindings.resolve,
        { kind = "owner", owner = "boosted" }))
    lu.assertNil(timelineSession.begin(session, handle))
    lu.assertEquals(session.firstMismatch.checkpoint, "transaction-prerequisite")
    lu.assertEquals(session.firstMismatch.observed, "boosted")
    lu.assertNil(timelineSession.resolve(session, bindings.resolve,
        { kind = "owner", owner = "unplanned" }))

    local unownedSession = timelineSession.new(item, assert(bindings.index(item)))
    lu.assertTrue(timelineSession.open(unownedSession, "roomEntered"))
    local unownedNative = { Name = "RandomLoot", __runPlannerWorldShop = true }
    local claimed = timelineSession.claimReady(unownedSession,
        { kind = "directPickup", gameName = "RandomLoot" },
        unownedNative, function(transaction)
            return transaction.roles[1]
        end)
    lu.assertNil(claimed)
    lu.assertNil(unownedSession.firstMismatch)
    lu.assertNil(timelineSession.bound(unownedSession, unownedNative))
    local peerHandle, peerPayload = timelineSession.claimReady(unownedSession,
        { kind = "directPickup", gameName = "RandomLoot" }, { Name = "RandomLoot" }, function(transaction)
            return transaction.roles[1]
        end)
    lu.assertNotNil(peerHandle)
    lu.assertEquals(peerPayload.transaction.owner, "normal")
end


function TestTimelineBindings.testShrineDeliveriesUseExactSourceKeysWhenGenerationsRepeat()
    local item = occurrence()
    item.transactionsByOwner = {
        first = {
            owner = "first", kind = "acquisition", hermesShrineSourceKey = "source-one:initial:first",
            sourceOwner = "host-one", window = { kind = "standard", phase = "afterCombat" },
        },
        second = {
            owner = "second", kind = "acquisition", hermesShrineSourceKey = "source-two:initial:first",
            sourceOwner = "host-two", window = { kind = "standard", phase = "afterCombat" },
        },
    }
    local index = assert(bindings.index(item))
    lu.assertEquals(
        bindings.resolve(index, {
            kind = "hermesShrineDelivery", sourceKey = "source-one:initial:first",
        }).transaction.owner,
        "first"
    )
    lu.assertEquals(
        bindings.resolve(index, {
            kind = "hermesShrineDelivery", sourceKey = "source-two:initial:first",
        }).transaction.owner,
        "second"
    )
end

function TestTimelineBindings.testKeepsakeReplayUsesItsOwnCarrierNamespace()
    local item = occurrence()
    item.transactionsByOwner = {
        rack = {
            owner = "rack", kind = "keepsakeChange", keepsakeKey = "hammer",
            window = { kind = "standard", phase = "afterCombat" },
        },
        replay = {
            owner = "replay", kind = "keepsakeReplay", keepsakeKey = "hammer",
            window = { kind = "standard", phase = "beforeCombat" },
            equipResults = { experimentalHammer = { kind = "exhausted" } },
        },
    }
    local index = assert(bindings.index(item))
    lu.assertEquals(bindings.resolve(index, { kind = "keepsake", keepsakeKey = "hammer" }).transaction.owner,
        "rack")
    lu.assertEquals(bindings.resolve(index, { kind = "keepsakeReplay", keepsakeKey = "hammer" }).transaction.owner,
        "replay")
end

function TestTimelineBindings.testMaterializationBindsTheExactPublishedRole()
    local item = occurrence()
    item.transactionsByOwner.owner.roles = {
        { role = "loot", lifecyclePoint = "pickup", kind = "loot", gameName = "ApolloUpgrade" },
        { role = "resource", lifecyclePoint = "pickup", kind = "resource", gameName = "MetaCurrencyDrop" },
    }
    local index = assert(bindings.index(item))
    local producer = resolved(index, { kind = "offer", offerKey = "offer" })
    local loot = assert(bindings.resolve(index,
        { kind = "materialized", gameName = "ApolloUpgrade" }, producer))
    local consumable = assert(bindings.resolve(index,
        { kind = "materialized", gameName = "MetaCurrencyDrop" }, producer))
    lu.assertEquals(loot.detail.role, "loot")
    lu.assertEquals(consumable.detail.role, "resource")
    lu.assertNil(bindings.resolve(index, { kind = "materialized", gameName = "UnknownDrop" }, producer))
end

function TestTimelineBindings.testProducedAcquisitionUsesItsPublishedSourceOwnerNotTimelineOwner()
    local item = occurrence()
    item.transactionsByOwner.owner.sourceOwner = "incoming-reward"
    item.transactionsByOwner.owner.roles = {
        { role = "self", lifecyclePoint = "pickup", kind = "resource", gameName = "MetaCurrencyDrop" },
    }
    item.transactionsByOwner.child = {
        owner = "child-action",
        sourceOwner = "child-source",
        kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            {
                role = "source", lifecyclePoint = "pickup", kind = "consumable",
                gameName = "RoomRewardConsolationPrize",
                producer = {
                    kind = "artificerReplacement",
                    sourceOwner = "incoming-reward",
                    sourceRole = "self",
                },
            },
        },
    }
    local index = assert(bindings.index(item))
    local source = resolved(index, { kind = "offer", offerKey = "offer" })
    local child = bindings.resolve(index, { kind = "produced", role = "self" }, source)
    lu.assertEquals(child.transaction.owner, "child-action")
    lu.assertEquals(child.detail.gameName, "RoomRewardConsolationPrize")
end

function TestTimelineBindings.testTimelineClaimUsesPublishedOrderForIndependentCompatibleActions()
    local first = {
        owner = "first", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "first", lifecyclePoint = "roomExit", kind = "resource",
                gameName = "ElementalBoost", disposition = "normal" },
        },
    }
    local second = {
        owner = "second", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "second", lifecyclePoint = "roomRewardPickup", kind = "resource",
                gameName = "ElementalBoost", disposition = "normal" },
        },
    }
    local claimOccurrence = {
        transactionsByOwner = { second = second, first = first },
        timeline = { transactions = { first, second }, dependencies = {}, obligations = {} },
    }
    local index = assert(bindings.index(claimOccurrence))
    local session = timelineSession.new(claimOccurrence, index)
    local function compatible(transaction, contact)
        for _, role in ipairs(transaction.roles or {}) do
            if role.gameName == contact.gameName then return role end
        end
    end
    local firstNative, secondNative = { Name = "ElementalBoost" }, { Name = "ElementalBoost" }
    local firstHandle, firstPayload = timelineSession.claimReady(session,
        { kind = "directPickup", gameName = "ElementalBoost" }, firstNative, compatible)
    lu.assertNotNil(firstHandle)
    lu.assertEquals(firstPayload.transaction.owner, "first")
    local secondHandle, secondPayload = timelineSession.claimReady(session,
        { kind = "directPickup", gameName = "ElementalBoost" }, secondNative, compatible)
    lu.assertNotNil(secondHandle)
    lu.assertEquals(secondPayload.transaction.owner, "second")
    lu.assertEquals(timelineSession.bound(session, firstNative), firstHandle)
    lu.assertEquals(timelineSession.bound(session, secondNative), secondHandle)
    lu.assertNil(timelineSession.claimReady(session,
        { kind = "directPickup", gameName = "UnknownDrop" }, { Name = "UnknownDrop" }, compatible))
end
