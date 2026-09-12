-- luacheck: globals TestTransformations
local lu = require("luaunit")
local transformations = require("mods.room.timeline.transformations.hooks")
local binding = require("mods.room.timeline.acquisitions.binding")
local navigation = require("mods.navigation.hooks")

TestTransformations = {}

local function capture()
    local callbacks, registered = {}, {}
    local module = { hooks = { wrap = function(name, id, callback)
        callbacks[name] = callback
        registered[name] = registered[name] or {}
        registered[name][id] = callback
    end } }
    module.registered = registered
    return module, callbacks
end

local function sourceRow(disposition, replacement)
    local role = {
        role = "self", disposition = disposition, lifecyclePoint = "roomRewardPickup",
        kind = "loot", gameName = "MetaCurrencyDrop",
    }
    if replacement ~= nil then role.replacement = replacement end
    local transaction = { kind = "acquisition", owner = "source", roles = { role } }
    return { transaction = transaction, detail = role }
end

local function childRow()
    local role = {
        role = "replacement", disposition = "normal", lifecyclePoint = "roomRewardPickup",
        kind = "loot", gameName = "RoomRewardConsolationPrize",
        producer = { kind = "artificerReplacement", sourceOwner = "source", sourceRole = "self" },
    }
    local transaction = {
        kind = "acquisition", owner = "replacement",
        reward = { rewardType = "Boon", source = "ApolloUpgrade" }, roles = { role },
    }
    return { transaction = transaction, detail = role }
end

local function roomHarness(source, child, boundSource, authoredSource)
    local active = { occurrence = {} }
    local nativeBindings = boundSource and { [boundSource] = source } or {}
    local completed, readyClaims, boundChildren = {}, 0, {}
    local sourcePayload = authoredSource or sourceRow("artificer")
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return nativeBindings[native] end,
        peek = function(_, handle)
            if handle == source then return sourcePayload end
            if handle == child then return child end
        end,
        begin = function(_, handle)
            if handle == source then return sourcePayload end
            if handle == child then return child end
        end,
        claimReady = function(_, _, contact, native, compatible)
            readyClaims = readyClaims + 1
            if contact.kind == "artificer" and compatible(source.transaction, contact) ~= nil then
                nativeBindings[native] = source
                return source, sourceRow("artificer")
            end
        end,
        sourceRole = function(_, _, handle, gameName)
            if handle == source and gameName == "MetaCurrencyDrop" then return "self" end
        end,
        resolve = function(_, _, contact)
            if contact.kind == "produced" and contact.source == source and contact.role == "self" then
                return child
            end
        end,
        bind = function(_, _, handle, native)
            boundChildren[#boundChildren + 1] = { handle = handle, native = native }
            nativeBindings[native] = handle
            return handle
        end,
        complete = function(_, handle)
            completed[#completed + 1] = { handle = handle }
        end,
    }
    return room, active, completed, function() return readyClaims end, boundChildren
end

function TestTransformations.testArtificerNeverClaimsAnAlreadyBoundNormalCarrier()
    local module, callbacks = capture()
    local source, wrong = { ObjectId = 13, Name = "MetaCurrencyDrop" }, sourceRow("normal")
    local claims, completions = 0, 0
    local room = {
        current = function() return {} end,
        bound = function() return source end,
        peek = function() return wrong end,
        claimReady = function() claims = claims + 1 end,
        complete = function() completions = completions + 1 end,
    }
    transformations.attach(module, {}, function() return {} end, function() end, room)
    callbacks.ConvertMetaRewardPresentation(nil, {}, function(target) return target end, source)
    lu.assertEquals(claims, 0)
    lu.assertEquals(completions, 0)
end

function TestTransformations.testArtificerUsesTheBoundRoleDispositionInsteadOfAnotherTransactionRole()
    local module, callbacks = capture()
    local source = { ObjectId = 14, Name = "MetaCurrencyDrop" }
    local normal = sourceRow("normal")
    normal.transaction.roles[#normal.transaction.roles + 1] = {
        role = "alternate", disposition = "artificer", lifecyclePoint = "roomRewardPickup",
        kind = "loot", gameName = "MetaCurrencyDrop",
    }
    local claims, begins = 0, 0
    local room = {
        current = function() return {} end,
        bound = function() return {} end,
        peek = function() return normal end,
        begin = function() begins = begins + 1; return normal end,
        claimReady = function() claims = claims + 1 end,
        complete = function() end,
    }
    transformations.attach(module, {}, function() return {} end, function() end, room)
    callbacks.ConvertMetaRewardPresentation(nil, {}, function(target) return target end, source)
    lu.assertEquals(claims, 0)
    lu.assertEquals(begins, 0)
end

function TestTransformations.testArtificerSpawnDoesNotBindAsTheIncomingRoomReward()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local current = {
        occurrence = {
            overview = { incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "Boon" } },
        },
    }
    local producerResolves, bound = 0, 0
    local room = {
        current = function() return current end,
        resolve = function(_, _, contact)
            if contact.kind == "producer" then producerResolves = producerResolves + 1 end
        end,
        bind = function() bound = bound + 1 end,
    }
    binding.attach(module, {}, function() return state end, function() end, room)
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return { Name = "ZeusUpgrade" } end, {})
    end, {}, { IgnoreRoomSpawnOnLootPoint = true, SpawnRewardOnId = 44 })
    lu.assertEquals(producerResolves, 0)
    lu.assertEquals(bound, 0)
end

function TestTransformations.testArtificerPublishesChildButCompletesOnlyAfterVerifiedSpawnAndDestroy()
    local module, callbacks = capture()
    local source, child = {}, childRow()
    local target = { ObjectId = 17, Name = "MetaCurrencyDrop" }
    local room, _, completed, readyClaims, boundChildren = roomHarness(source, child, target)
    local scope = transformations.attach(module, {}, function() return {} end, function() end, room)

    -- The authored child names the native Forfeit result while its reward
    -- records the underlying Boon selected from RunProgress.
    lu.assertEquals(child.transaction.reward.rewardType, "Boon")
    lu.assertEquals(child.detail.gameName, "RoomRewardConsolationPrize")

    local selection
    callbacks.ConvertMetaRewardPresentation(nil, {}, function(value)
        return value
    end, target)
    lu.assertEquals(readyClaims(), 0)
    selection = scope.consumeRewardSelection({}, {}, "RunProgress",
        { { RewardType = "Devotion" }, { RewardType = "SpellDrop" } },
        { IgnoreForcedReward = true })
    lu.assertEquals(selection, child)
    lu.assertNil(scope.consumeRewardSelection({}, {}, "MetaProgress", {}, {}))
    lu.assertEquals(boundChildren, {})
    local created = callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return {
            Name = "RoomRewardConsolationPrize",
        } end, {})
    end, {}, { IgnoreRoomSpawnOnLootPoint = true, SpawnRewardOnId = 17 })
    lu.assertEquals(created.Name, "RoomRewardConsolationPrize")
    lu.assertEquals(completed, {})
    module.registered.Destroy["run-planner-artificer-source-destroyed"](
        nil, {}, function() return true end, { Id = 17 })
    lu.assertEquals(#completed, 1)
end

function TestTransformations.testArtificerRetainsSourceSteeringWhenTimePieceConsumesChild()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local source = {}
    local target = { ObjectId = 22, Name = "MetaCurrencyDrop" }
    local replacement = {
        reward = { rewardType = "Boon", producerLifecycleKey = "RoomReward", source = "ApolloUpgrade" },
        gameName = "RoomRewardConsolationPrize",
    }
    local authoredSource = sourceRow("artificer", replacement)
    local room, _, completed = roomHarness(source, nil, target, authoredSource)
    local scope = transformations.attach(module, {}, function() return state end, function() end, room)
    navigation.attach(module, {}, function() return state end, function() end, {}, room, scope)

    callbacks.ConvertMetaRewardPresentation(nil, {}, function(value) return value end, target)
    local selectedRoom
    callbacks.ChooseRoomReward(nil, {}, function(_, nativeRoom)
        selectedRoom = nativeRoom
        lu.assertTrue(callbacks.IsRoomRewardEligible(nil, {}, function() return false end,
            {}, nativeRoom, { Name = "Boon" }, {}, {}))
        lu.assertFalse(callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
            {}, nativeRoom, { Name = "WeaponUpgrade" }, {}, {}))
        return "Boon"
    end, {}, {}, "RunProgress",
        { { RewardType = "Devotion" }, { RewardType = "SpellDrop" } },
        { IgnoreForcedReward = true })
    lu.assertEquals(selectedRoom.ForceLootName, "ApolloUpgrade")
    lu.assertNil(scope.consumeRewardSelection({}, {}, "RunProgress",
        { { RewardType = "Devotion" }, { RewardType = "SpellDrop" } },
        { IgnoreForcedReward = true }))

    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function()
            return { Name = "RoomRewardConsolationPrize" }
        end, {})
    end, {}, { IgnoreRoomSpawnOnLootPoint = true, SpawnRewardOnId = target.ObjectId })
    module.registered.Destroy["run-planner-artificer-source-destroyed"](
        nil, {}, function() return true end, { Id = target.ObjectId })
    lu.assertEquals(#completed, 1)
end

function TestTransformations.testArtificerWrongSpawnStaysIncompleteAtSourceDestruction()
    local module, callbacks = capture()
    local source, child = {}, childRow()
    local target = { ObjectId = 19, Name = "MetaCurrencyDrop" }
    local room, _, completed = roomHarness(source, child, target)
    transformations.attach(module, { diagnostic = function() end }, function() return {} end, function() end, room)

    lu.assertEquals(callbacks.ConvertMetaRewardPresentation(nil, {}, function(value) return value end, target), target)
    local result = callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return { Name = "WeaponUpgrade" } end, {})
    end, {}, { IgnoreRoomSpawnOnLootPoint = true, SpawnRewardOnId = target.ObjectId })
    lu.assertEquals(result.Name, "WeaponUpgrade")
    lu.assertEquals(completed, {})
    module.registered.Destroy["run-planner-artificer-source-destroyed"](
        nil, {}, function() return true end, { Id = target.ObjectId })
    lu.assertEquals(#completed, 0)
end

function TestTransformations.testArtificerRejectedPresentationLeavesNativeResultAndNoPendingSelection()
    local module, callbacks = capture()
    local source, child = {}, childRow()
    local target = { ObjectId = 20, Name = "MetaCurrencyDrop" }
    local room, _, completed = roomHarness(source, child, target)
    local scope = transformations.attach(module, {}, function() return {} end, function() end, room)

    lu.assertFalse(callbacks.ConvertMetaRewardPresentation(nil, {}, function() return false end, target))
    lu.assertNil(scope.consumeRewardSelection({}, {}, "RunProgress",
        { { RewardType = "Devotion" }, { RewardType = "SpellDrop" } }, true))
    lu.assertEquals(completed, {})
end

function TestTransformations.testArtificerScopesItsPublishedRewardThroughNavigationOnly()
    local module, callbacks = capture()
    local source, child = {}, childRow()
    local target = { ObjectId = 18, Name = "MetaCurrencyDrop" }
    local room = roomHarness(source, child, target)
    local state = { state = "synchronized" }
    local scope = transformations.attach(module, {}, function() return state end, function() end, room)
    navigation.attach(module, {}, function() return state end, function() end, {}, room, scope)

    local selectedStore, selectedRoom
    callbacks.ConvertMetaRewardPresentation(nil, {}, function(value) return value end, target)
    local unrelated = callbacks.ChooseRoomReward(nil, {}, function()
        return "unrelated"
        end, {}, {}, "RunProgress", {
            { RewardType = "Devotion" }, { RewardType = "SpellDrop" },
        }, {})
    lu.assertEquals(unrelated, "unrelated")
    callbacks.ChooseRoomReward(nil, {}, function(_, nativeRoom, rewardStore)
            selectedRoom = nativeRoom
            selectedStore = rewardStore
            lu.assertTrue(callbacks.IsRoomRewardEligible(nil, {}, function() return false end,
                {}, nativeRoom, { Name = "Boon" }, {}, {}))
            lu.assertFalse(callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                {}, nativeRoom, { Name = "WeaponUpgrade" }, {}, {}))
            return "Boon"
        end, {}, {}, "RunProgress",
            { { RewardType = "Devotion" }, { RewardType = "SpellDrop" } },
            { IgnoreForcedReward = true })
    lu.assertEquals(selectedStore, "RunProgress")
    lu.assertEquals(selectedRoom.RewardStoreName, "RunProgress")
    lu.assertEquals(selectedRoom.ForceLootName, "ApolloUpgrade")
    lu.assertNil(scope.consumeRewardSelection({}, {}, "RunProgress",
        { { RewardType = "Devotion" }, { RewardType = "SpellDrop" } },
        { IgnoreForcedReward = true }))
end

function TestTransformations.testArtificerClaimsAnUnboundSourceAtAcceptedContact()
    local module, callbacks = capture()
    local source, child = {}, childRow()
    local room, _, _, readyClaims = roomHarness(source, child)
    transformations.attach(module, {}, function() return {} end, function() end, room)
    callbacks.ConvertMetaRewardPresentation(nil, {}, function(target) return target end, {
        ObjectId = 21, Name = "MetaCurrencyDrop",
    })
    lu.assertEquals(readyClaims(), 1)
end

function TestTransformations.testItemEffectCompletesOnlyAfterAcceptedNativeUseReturns()
    local module, callbacks = capture()
    local item, handle = { Name = "TemporaryForcedSecretDoorTrait" }, {}
    local payload = { transaction = {
        kind = "itemEffect", owner = "spark", itemKey = item.Name, effect = "spark", extended = false,
    } }
    local begins, completions = 0, 0
    local room = {
        current = function() return {} end,
        bound = function() return nil end,
        claimReady = function(_, _, _, native, compatible)
            if compatible(payload.transaction, { gameName = native.Name }) then return handle, payload end
        end,
        begin = function(_, value) if value == handle then begins = begins + 1; return payload end end,
        peek = function() return nil end,
    }
    local session = { complete = function(_, value) if value == handle then completions = completions + 1 end end }
    transformations.attach(module, session, function() return {} end, function() end, room)
    callbacks.UseConsumableItem(nil, {}, function(native)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, native, {})
        lu.assertEquals(completions, 0)
        return true
    end, item, {}, {})
    lu.assertEquals(begins, 1)
    lu.assertEquals(completions, 1)
end

local function outcomeHarness(transaction, beginPayload)
    local module, callbacks = capture()
    local state, current, handle = {}, {}, {}
    local payload = { transaction = transaction }
    local begins, completions, mismatches = 0, 0, {}
    local room = {
        current = function() return current end,
        bound = function() return nil end,
        peek = function(_, value) return value == handle and payload or nil end,
        claimReady = function(_, _, contact, _, compatible)
            if compatible(transaction, contact) then return handle, payload end
        end,
        begin = function(_, value)
            if value == handle then
                begins = begins + 1
                if beginPayload == false then return nil end
                return payload
            end
        end,
    }
    local session = {
        complete = function(_, value) if value == handle then completions = completions + 1 end end,
        diagnostic = function(_, checkpoint, observed)
            mismatches[#mismatches + 1] = {
                checkpoint = checkpoint, observed = observed,
            }
        end,
    }
    transformations.attach(module, session, function() return state end, function() end, room)
    return callbacks, function() return completions end, mismatches,
        function() return begins end
end

function TestTransformations.testRejectedAnvilBeginLeavesNativeSelectionsUntouched()
    local callbacks, completions, mismatches, begins = outcomeHarness({
        kind = "transformation",
        transformation = {
            kind = "anvilOfFates", removedTraitKey = "OldHammer",
            addedTraitKeys = { "NewHammerOne", "NewHammerTwo" },
        },
    }, false)
    local item = { Name = "ChaosWeaponUpgrade" }
    local selected, called
    callbacks.UseConsumableItem(nil, {}, function(native)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, native, {})
        callbacks.ChaosHammerUpgrade(nil, {}, function()
            called = true
            selected = callbacks.RemoveRandomValue(nil, {}, function(pool) return pool[1] end,
                { "Other", "OldHammer" }, {})
            return true
        end, {})
        return true
    end, item, {}, {})
    lu.assertTrue(called)
    lu.assertEquals(selected, "Other")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(mismatches, {})
end

function TestTransformations.testAnvilOutcomeSteersAllThreeSelectionsAndCompletesAfterUse()
    local callbacks, completions, mismatches, begins = outcomeHarness({
        kind = "transformation",
        transformation = {
            kind = "anvilOfFates", removedTraitKey = "OldHammer",
            addedTraitKeys = { "NewHammerOne", "NewHammerTwo" },
        },
    })
    local item = { Name = "ChaosWeaponUpgrade" }
    local selected = {}
    callbacks.UseConsumableItem(nil, {}, function(native)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, native, {})
        callbacks.ChaosHammerUpgrade(nil, {}, function()
            local values = { "Other", "OldHammer", "NewHammerOne", "NewHammerTwo" }
            for index = 1, 3 do
                selected[index] = callbacks.RemoveRandomValue(nil, {}, function(pool) return pool[1] end,
                    values, {})
            end
            return true
        end, {})
        lu.assertEquals(completions(), 0)
        return true
    end, item, {}, {})
    lu.assertEquals(selected, { "OldHammer", "NewHammerOne", "NewHammerTwo" })
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(mismatches, {})
end

function TestTransformations.testWellTwistOutcomeSteersNativeAwardAndCompletesAfterUse()
    local callbacks, completions, mismatches, begins = outcomeHarness({
        kind = "transformation",
        transformation = {
            kind = "stygianWellTwist", sourceItemKey = "RandomStoreItem",
            resultItemKey = "HealDropRange",
        },
    })
    local item = { Name = "RandomStoreItem" }
    local selected
    callbacks.UseConsumableItem(nil, {}, function(native)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, native, {})
        callbacks.AwardRandomStoreItem(nil, {}, function(values)
            selected = callbacks.GetRandomValue(nil, {}, function(pool) return pool[1] end, values, {})
            return selected
        end, { { Name = "Other" }, { Name = "HealDropRange" } }, {})
        lu.assertEquals(completions(), 0)
        return true
    end, item, {}, {})
    lu.assertEquals(selected.Name, "HealDropRange")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 1)
    lu.assertEquals(mismatches, {})
end

function TestTransformations.testRejectedTwistBeginLeavesNativeSelectionUntouched()
    local callbacks, completions, mismatches, begins = outcomeHarness({
        kind = "transformation",
        transformation = {
            kind = "stygianWellTwist", sourceItemKey = "RandomStoreItem",
            resultItemKey = "HealDropRange",
        },
    }, false)
    local item = { Name = "RandomStoreItem" }
    local selected, called
    callbacks.UseConsumableItem(nil, {}, function(native)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, native, {})
        callbacks.AwardRandomStoreItem(nil, {}, function(values)
            called = true
            selected = callbacks.GetRandomValue(nil, {}, function(pool) return pool[1] end, values, {})
            return selected
        end, { { Name = "Other" }, { Name = "HealDropRange" } }, {})
        return true
    end, item, {}, {})
    lu.assertTrue(called)
    lu.assertEquals(selected.Name, "Other")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(completions(), 0)
    lu.assertEquals(mismatches, {})
end

function TestTransformations.testTwistUseFaultRestoresTheNativeSelector()
    local callbacks = outcomeHarness({
        kind = "transformation",
        transformation = {
            kind = "stygianWellTwist", sourceItemKey = "RandomStoreItem",
            resultItemKey = "HealDropRange",
        },
    })
    local item = { Name = "RandomStoreItem" }
    local ok, failure = pcall(callbacks.UseConsumableItem, nil, {}, function(native)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, native, {})
        error("native twist failure")
    end, item, {}, {})
    local native = callbacks.GetRandomValue(nil, {}, function(values) return values[1] end,
        { { Name = "Other" }, { Name = "HealDropRange" } }, {})
    lu.assertFalse(ok)
    lu.assertStrContains(failure, "native twist failure")
    lu.assertEquals(native.Name, "Other")
end

return TestTransformations
