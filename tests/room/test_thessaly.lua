-- ShipCombat adapter witnesses: exact phase count, full wheel cohort, and a
-- non-blocking divergent player choice.
-- luacheck: globals TestThessaly
local lu = require("luaunit")
local thessaly = require("mods.room.timeline.encounters.thessaly")
local navigation = require("mods.navigation.hooks")
local acquisitionBinding = require("mods.room.timeline.acquisitions.binding")
local directPickups = require("mods.room.timeline.acquisitions.pickups.hooks")
local timelineBindings = require("mods.room.timeline.bindings")
local timeline = require("mods.room.timeline.session")

TestThessaly = {}

function TestThessaly.testIndexesSelectedWheelAcquisitionByItsExactWheel()
    local transaction = {
        kind = "acquisition", owner = "picked",
        sourceOwner = '["rewardWheelOffer","Surface","O","room","wheel2","offer1"]',
        reward = { rewardType = "MaxHealthDrop", producerLifecycleKey = "RoomReward" },
        producerLifecycleKey = "RoomReward", roles = {},
        window = { kind = "shipPostCombat", wheelKey = "wheel2" },
    }
    local index = assert(timelineBindings.index({ transactionsByOwner = { picked = transaction } }))
    local row = assert(timelineBindings.resolve(index, {
        kind = "rewardWheelAcquisition", wheelKey = "wheel2",
    }))
    lu.assertEquals(row.transaction, transaction)
    lu.assertNil(timelineBindings.resolve(index, {
        kind = "rewardWheelAcquisition", wheelKey = "wheel1",
    }))
end

local function capture()
    local callbacks = {}
    return {
        hooks = { wrap = function(name, _, callback) callbacks[name] = callback end },
    }, callbacks
end

local function fixture(offerCount, pickedOfferKey)
    local phase = { slotKey = "Combat1", encounterKey = "ShipEncounter" }
    local offers = {
        {
            offerKey = "offer1",
            reward = { rewardType = "ZeusUpgrade", source = "Zeus", producerLifecycleKey = "wheel1" },
        },
        {
            offerKey = "offer2",
            reward = { rewardType = "MaxHealthDrop", producerLifecycleKey = "wheel1" },
        },
    }
    while #offers > offerCount do table.remove(offers) end
    local wheel = {
        wheelKey = "wheel1", phaseKey = "Combat1", phaseOwner = "phase-owner",
        offerCount = offerCount, storeKey = "RunProgress", offers = offers,
        pickedOfferKey = pickedOfferKey,
    }
    local active = { occurrence = { overview = {
        encounterPhases = { { slotKey = "Intro" }, phase }, rewardWheels = { wheel },
    } } }
    return active, phase, wheel
end

local function successiveWheelChoices(firstCount, secondCount)
    local active = fixture(firstCount, "offer" .. firstCount)
    local occurrence = active.occurrence
    occurrence.overview.rewardWheels[2] = {
        wheelKey = "wheel2", pickedOfferKey = "offer" .. secondCount,
    }
    occurrence.timeline = {
        transactions = {}, dependencies = { { owner = "choice2", afterOwner = "choice1" } },
        obligations = {
            { owner = "choice1", checkpoint = "roomExit" },
            { owner = "choice2", checkpoint = "roomExit" },
        },
    }
    occurrence.transactionsByOwner = {}
    for i = 1, 2 do
        local transaction = {
            kind = "chooseRewardWheel", owner = "choice" .. i,
            wheelKey = "wheel" .. i,
            pickedOfferKey = occurrence.overview.rewardWheels[i].pickedOfferKey,
            window = { kind = "shipPreCombat", wheelKey = "wheel" .. i },
        }
        occurrence.timeline.transactions[i] = transaction
        occurrence.transactionsByOwner[transaction.owner] = transaction
    end
    local dag = timeline.new(occurrence)
    local state = { state = "synchronized" }
    local room = {
        current = function() return active end,
        resolve = function(_, _, contact) return timeline.resolve(dag, timelineBindings.resolve, contact) end,
        bind = function(_, _, handle, native) return timeline.bind(dag, handle, native) end,
        begin = function(_, handle) return timeline.begin(dag, handle) end,
        window = function(_, window) return timeline.open(dag, window) end,
        releaseCompletedBinding = function(_, _, handle, native)
            return timeline.releaseCompletedBinding(dag, handle, native)
        end,
    }
    local module, callbacks = capture()
    local shipCombat = thessaly.create()
    shipCombat.attach(module, {
        complete = function(_, handle) return timeline.complete(dag, handle) end,
        diagnostic = function() error("unexpected diagnostic") end,
    }, function() return state end, function() end, room)
    local centralWheel = { Name = "ShipsSteeringWheel", ObjectId = 1 }
    for i, offerCount in ipairs({ firstCount, secondCount }) do
        local wheelKey = "wheel" .. i
        -- Native single-offer phases reuse the central wheel; two-offer
        -- phases create temporary left/right carriers pointing to that wheel.
        local carriers = offerCount == 1 and { centralWheel } or {
            { Name = "ShipsSteeringWheelLeft", WheelObstacleId = centralWheel.ObjectId },
            { Name = "ShipsSteeringWheelRight", WheelObstacleId = centralWheel.ObjectId },
        }
        local nativeWheel = carriers[offerCount]
        nativeWheel.__runPlannerWheelKey = wheelKey
        nativeWheel.__runPlannerOfferKey = "offer" .. offerCount
        lu.assertTrue(timeline.open(dag, "shipPreCombat:" .. wheelKey))
        callbacks.UseShipWheel(nil, {}, function(wheel)
            lu.assertIs(wheel, nativeWheel)
            lu.assertTrue(dag.completedOwners["choice" .. i])
            lu.assertNil(timeline.bound(dag, nativeWheel))
            lu.assertEquals(shipCombat.takeRewardProducer(state, active).wheelKey, wheelKey)
        end, nativeWheel)
    end
    lu.assertNil(dag.firstFault)
    lu.assertNil(dag.firstMismatch)
    lu.assertTrue(timeline.checkpoint(dag, "roomExit"))
end

function TestThessaly.testSuccessiveCombatChoicesSupportBothNativeWheelLayouts()
    for firstCount = 1, 2 do
        for secondCount = 1, 2 do
            successiveWheelChoices(firstCount, secondCount)
        end
    end
end

function TestThessaly.testExactPublishedPhaseCountBypassesNativeThirdPhaseRoll()
    for _, expectedCount in ipairs({ 2, 3 }) do
        local active = fixture(1, "offer1")
        active.occurrence.overview.encounterPhases = {
            { slotKey = "Intro" }, { slotKey = "Combat1" },
        }
        if expectedCount == 3 then
            active.occurrence.overview.encounterPhases[3] = { slotKey = "Combat2" }
        end
        local state = { state = "synchronized" }
        local nativeRoom = { MultipleEncountersData = { {}, {}, {
            GameStateRequirements = { ChanceToPlay = 0.6 },
        } } }
        local room = {
            encounterAt = function(_, index, destination)
                lu.assertEquals(destination, nativeRoom)
                return active.occurrence.overview.encounterPhases[index]
            end,
        }
        local shipCombat = thessaly.create()
        local third = nativeRoom.MultipleEncountersData[3]
        local restore = shipCombat.preparePhases(state, room, nativeRoom)
        local observed = #nativeRoom.MultipleEncountersData
        if expectedCount == 3 then
            lu.assertNil(nativeRoom.MultipleEncountersData[3].GameStateRequirements)
        end
        restore()
        lu.assertEquals(observed, expectedCount)
        lu.assertEquals(nativeRoom.MultipleEncountersData[3], third)
        lu.assertEquals(third.GameStateRequirements, { ChanceToPlay = 0.6 })
    end
end

local function runWheel(offerCount, pickedOfferKey, selectedIndex)
    local module, callbacks = capture()
    local active, phase, wheel = fixture(offerCount, pickedOfferKey)
    local state = { state = "synchronized" }
    local nativeEncounter = {}
    local windows, completed, diagnostics = {}, {}, {}
    local handle = {}
    local room = {
        current = function() return active end,
        encounterPhase = function(_, value) return value == nativeEncounter and phase or nil end,
        window = function(_, value) windows[#windows + 1] = value; return true end,
        resolve = function(_, context, contact)
            lu.assertEquals(context, active)
            lu.assertEquals(contact, { kind = "rewardWheel", wheelKey = "wheel1" })
            return handle
        end,
        bind = function(_, context, value, native)
            lu.assertEquals(context, active)
            lu.assertEquals(value, handle)
            lu.assertNotNil(native)
            return handle
        end,
        begin = function(_, value)
            lu.assertEquals(value, handle)
            return { transaction = { pickedOfferKey = wheel.pickedOfferKey } }
        end,
        releaseCompletedBinding = function(_, _, value)
            lu.assertEquals(completed[#completed], value)
            return true
        end,
    }
    local session = {
        complete = function(_, value) completed[#completed + 1] = value end,
        diagnostic = function(_, checkpoint, observed)
            diagnostics[#diagnostics + 1] = { checkpoint, observed }
        end,
    }
    local shipCombat = thessaly.create()
    navigation.attach(module, session, function() return state end, function() end, {}, room, nil,
        shipCombat.rewardContext)
    shipCombat.attach(module, session, function() return state end, function() end, room)

    local nativeRoom = { Encounter = nativeEncounter }
    local obstacles = {}
    local chosenRewards = {}
    local selected
    local result = callbacks.ShipsEncounterSetup(nil, {}, function()
        lu.assertEquals(callbacks.RandomChance(nil, {}, function() return false end, 0.25), offerCount == 2)
        lu.assertEquals(callbacks.ChooseNextRewardStore(nil, {}, function() return "MetaProgress" end, {}),
            "RunProgress")
        for index = 1, offerCount do
            local rewardType = callbacks.ChooseRoomReward(nil, {}, function() return "wrong" end,
                {}, nativeRoom, "MetaProgress", chosenRewards, { IgnoreForcedReward = true })
            chosenRewards[index] = rewardType
            callbacks.SetupRoomReward(nil, {}, function()
                nativeRoom.ForceLootName = "wrong-source"
                return true
            end, {}, nativeRoom, {}, { AlwaysSetupForceLootName = true })
            local obstacle = {}
            obstacles[index] = obstacle
            callbacks.CreateDoorRewardPreview(nil, {}, function() return true end, obstacle, rewardType)
        end
        selected = obstacles[selectedIndex]
        callbacks.UseShipWheel(nil, {}, function(value) return value end, selected)
        return "native-result"
    end, nativeEncounter, {})
    return {
        result = result, chosenRewards = chosenRewards, obstacles = obstacles,
        selected = selected, windows = windows, completed = completed, diagnostics = diagnostics,
    }
end

function TestThessaly.testForcesOneAndTwoOfferWheelCohortsAndCompletesExactChoice()
    local one = runWheel(1, "offer1", 1)
    lu.assertEquals(one.result, "native-result")
    lu.assertEquals(one.chosenRewards, { "ZeusUpgrade" })
    lu.assertEquals(one.obstacles[1].__runPlannerOfferKey, "offer1")
    lu.assertEquals(one.windows, { "shipPreCombat:wheel1", "shipPostCombat:wheel1" })
    lu.assertEquals(#one.completed, 1)
    lu.assertEquals(one.diagnostics, {})

    local two = runWheel(2, "offer2", 2)
    lu.assertEquals(two.chosenRewards, { "ZeusUpgrade", "MaxHealthDrop" })
    lu.assertEquals(two.obstacles[2].__runPlannerOfferKey, "offer2")
    lu.assertEquals(#two.completed, 1)
    lu.assertEquals(two.diagnostics, {})
end

function TestThessaly.testDivergentWheelChoiceDoesNotBlockNativeUse()
    local result = runWheel(2, "offer2", 1)
    lu.assertEquals(result.selected, result.obstacles[1])
    lu.assertEquals(#result.completed, 1)
    lu.assertEquals(result.diagnostics, { { "ship-wheel-selection", "offer1" } })
end

function TestThessaly.testWheelSelectionPublishesBeforeNativeNotificationResumesSetup()
    local module, callbacks = capture()
    local active, phase = fixture(1, "offer1")
    local state, encounter, handle = { state = "synchronized" }, {}, {}
    local windows, completed = {}, {}
    local room = {
        current = function() return active end,
        encounterPhase = function(_, value) return value == encounter and phase or nil end,
        window = function(_, value) windows[#windows + 1] = value; return true end,
        resolve = function(_, context, contact)
            lu.assertEquals(context, active)
            lu.assertEquals(contact, { kind = "rewardWheel", wheelKey = "wheel1" })
            return handle
        end,
        bind = function(_, context, value, native)
            lu.assertEquals(context, active)
            lu.assertEquals(value, handle)
            lu.assertNotNil(native)
            return handle
        end,
        begin = function(_, value)
            lu.assertEquals(value, handle)
            return { transaction = { pickedOfferKey = "offer1" } }
        end,
        releaseCompletedBinding = function(_, _, value)
            lu.assertEquals(completed[#completed], value)
            return true
        end,
    }
    local session = {
        complete = function(_, value) completed[#completed + 1] = value end,
        diagnostic = function() error("unexpected diagnostic") end,
    }
    local shipCombat = thessaly.create()
    navigation.attach(module, session, function() return state end, function() end, {}, room, nil,
        shipCombat.rewardContext)
    shipCombat.attach(module, session, function() return state end, function() end, room)

    local nativeRoom = { Encounter = encounter }
    local selected, resumed = {}, false
    local setup = coroutine.create(function()
        return callbacks.ShipsEncounterSetup(nil, {}, function()
            callbacks.RandomChance(nil, {}, function() return false end, 1)
            callbacks.ChooseNextRewardStore(nil, {}, function() return "NativeStore" end, {})
            local rewardType = callbacks.ChooseRoomReward(nil, {}, function() return "NativeReward" end,
                {}, nativeRoom, "NativeStore", {}, { IgnoreForcedReward = true })
            callbacks.SetupRoomReward(nil, {}, function()
                nativeRoom.ForceLootName = "native-source"
            end, {}, nativeRoom, {}, { AlwaysSetupForceLootName = true })
            callbacks.CreateDoorRewardPreview(nil, {}, function() return true end, selected, rewardType)
            coroutine.yield("wait-for-wheel")
            resumed = true
            return "setup-resumed"
        end, encounter, {})
    end)
    local ok, yielded = coroutine.resume(setup)
    lu.assertTrue(ok)
    lu.assertEquals(yielded, "wait-for-wheel")
    lu.assertEquals(selected.__runPlannerWheelKey, "wheel1")
    lu.assertEquals(selected.__runPlannerOfferKey, "offer1")

    local unrelated = {}
    lu.assertEquals(callbacks.ChooseNextRewardStore(nil, {}, function() return "NativeStore" end, {}), "NativeStore")
    callbacks.CreateDoorRewardPreview(nil, {}, function(obstacle)
        lu.assertNil(obstacle.__runPlannerWheelKey)
        return true
    end, unrelated, "NativeReward")

    local result = callbacks.UseShipWheel(nil, {}, function()
        lu.assertEquals(completed, { handle })
        lu.assertEquals(windows, { "shipPreCombat:wheel1", "shipPostCombat:wheel1" })
        local producer = shipCombat.takeRewardProducer(state, active)
        lu.assertEquals(producer.active, active)
        lu.assertEquals(producer.wheelKey, "wheel1")
        lu.assertNil(shipCombat.takeRewardProducer(state, active))
        local resumedOk = coroutine.resume(setup)
        lu.assertTrue(resumedOk)
        lu.assertEquals(coroutine.status(setup), "dead")
        return "native-use"
    end, selected)
    lu.assertEquals(result, "native-use")
    lu.assertTrue(resumed)
end

function TestThessaly.testDeniedStampedWheelBeginLeavesNativeUseUnsteered()
    local module, callbacks = capture()
    local active = fixture(1, "offer1")
    local state, handle = { state = "synchronized" }, {}
    local bound, nativeUsed, reports = false, false, 0
    local room = {
        current = function() return active end,
        resolve = function(_, context, contact)
            lu.assertEquals(context, active)
            lu.assertEquals(contact, { kind = "rewardWheel", wheelKey = "wheel1" })
            return handle
        end,
        bind = function(_, context, value)
            lu.assertEquals(context, active)
            lu.assertEquals(value, handle)
            bound = true
            return handle
        end,
        begin = function() return nil end,
        window = function() error("denied wheel must not open a window") end,
    }
    local session = {
        complete = function() error("denied wheel must not complete") end,
        diagnostic = function() error("denied wheel must not diagnose selection") end,
    }
    local shipCombat = thessaly.create()
    shipCombat.attach(module, session, function() return state end, function() reports = reports + 1 end, room)
    local wheel = { __runPlannerWheelKey = "wheel1", __runPlannerOfferKey = "offer1" }
    local result = callbacks.UseShipWheel(nil, {}, function(value)
        nativeUsed = value == wheel
        return "native-use"
    end, wheel)
    lu.assertEquals(result, "native-use")
    lu.assertTrue(nativeUsed)
    lu.assertTrue(bound)
    lu.assertEquals(reports, 1)
    lu.assertNil(shipCombat.takeRewardProducer(state, active))
end

function TestThessaly.testSelectedWheelRewardBindsAndCompletesThroughStandardPickupLifecycle()
    local module, callbacks = capture()
    local active, phase, wheel = fixture(1, "offer1")
    wheel.offers[1].reward = { rewardType = "MaxHealthDrop", producerLifecycleKey = "RoomReward" }
    local state = { state = "synchronized" }
    local encounter, choiceHandle, pickupHandle = {}, {}, {}
    local nativeBindings, completed = {}, {}
    local choicePayload = { transaction = {
        kind = "chooseRewardWheel", pickedOfferKey = "offer1",
    } }
    local pickupRole = {
        role = "self", disposition = "normal", lifecyclePoint = "roomRewardPickup",
        kind = "consumable", gameName = "MaxHealthDrop",
    }
    local pickupPayload = { transaction = {
        kind = "acquisition", roles = { pickupRole },
    }, detail = pickupRole }
    local room = {
        current = function() return active end,
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
        window = function() return true end,
        resolve = function(_, context, contact)
            lu.assertEquals(context, active)
            if contact.kind == "rewardWheel" then return choiceHandle end
            if contact.kind == "rewardWheelAcquisition" then
                lu.assertEquals(contact.wheelKey, "wheel1")
                return pickupHandle
            end
            if contact.kind == "materialized" then
                lu.assertEquals(contact.source, pickupHandle)
                lu.assertEquals(contact.gameName, "MaxHealthDrop")
                return pickupHandle
            end
        end,
        bind = function(_, context, handle, native)
            lu.assertEquals(context, active)
            nativeBindings[native] = handle
            return handle
        end,
        bound = function(_, context, native)
            lu.assertEquals(context, active)
            return nativeBindings[native]
        end,
        begin = function(_, handle)
            return handle == choiceHandle and choicePayload or pickupPayload
        end,
        peek = function(_, handle)
            return handle == pickupHandle and pickupPayload or choicePayload
        end,
        releaseCompletedBinding = function() return true end,
    }
    local session = {
        complete = function(_, handle) completed[#completed + 1] = handle; return true end,
        diagnostic = function() error("unexpected diagnostic") end,
    }
    local shipCombat = thessaly.create()
    navigation.attach(module, session, function() return state end, function() end, {}, room, nil,
        shipCombat.rewardContext)
    shipCombat.attach(module, session, function() return state end, function() end, room)
    acquisitionBinding.attach(module, session, function() return state end, function() end, room,
        shipCombat.takeRewardProducer)
    directPickups.attach(module, session, function() return state end, function() end, room, {
        scope = function() return {} end,
        call = function(_, callback) return callback() end,
        activate = function() end,
        requireConsumed = function() return true end,
    })

    local wheelObstacle = {}
    callbacks.ShipsEncounterSetup(nil, {}, function()
        callbacks.RandomChance(nil, {}, function() return false end, 1)
        callbacks.ChooseNextRewardStore(nil, {}, function() return "wrong" end, {})
        local rewardType = callbacks.ChooseRoomReward(nil, {}, function() return "wrong" end,
            {}, { Encounter = encounter }, "RunProgress", {}, { IgnoreForcedReward = true })
        callbacks.CreateDoorRewardPreview(nil, {}, function() end, wheelObstacle, rewardType)
        callbacks.UseShipWheel(nil, {}, function() return true end, wheelObstacle)
    end, encounter, {})
    local pickup = callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateConsumableItem(nil, {}, function()
            return { Name = "MaxHealthDrop" }
        end, {})
    end, {}, {})
    callbacks.UseConsumableItem(nil, {}, function(item)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, item, {})
        return true
    end, pickup, {}, {})

    lu.assertEquals(completed, { choiceHandle, pickupHandle })
    lu.assertNil(shipCombat.takeRewardProducer(state, active))
end
