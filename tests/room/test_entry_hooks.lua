-- luacheck: globals TestRoomEntryHooks
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local doors = require("mods.navigation.doors")
local roomHooks = require("mods.room.hooks")
local roomCoordinatorModule = require("mods.room.coordinator")
local routeSessionModule = require("mods.route.session")
local runtimeSessionModule = require("mods.runtime.session")
local admissionProjection = require("mods.room.conformance.admission")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local roomFeatureHooks = require("mods.room.features.hooks")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub
local attachRewardHooks = support.attachRewardHooks
local navigationEntryStub = support.navigationEntryStub
local unusedLoadoutScope = {
    synchronizeStartingRoom = function()
        error("starting-room loadout synchronization is outside this test")
    end,
}

TestRoomEntryHooks = {}

local function hookedRuntimeState()
    local occurrence = {
        id = "opening", gameName = "F_Opening01",
        overview = { encounterPhases = {}, requiredObjects = {}, additional = {} },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
        doors = { kind = "terminal" }, roomExitConformance = { facts = {} }, conformanceExpected = {},
    }
    local plan = {
        occurrences = { occurrence }, occurrencesById = { opening = occurrence },
        selectedOccurrenceIds = { "opening" },
    }
    local state = runtimeSessionModule.create()
    state.initialized, state.state, state.reason = true, "synchronized", "ready"
    state.plan, state.route = plan, routeSessionModule.new(plan)
    state.room = roomCoordinatorModule.new(plan, function(errorValue, expected, observed)
        return runtimeSessionModule.mismatch(state, errorValue, expected, observed)
    end, {
        onFault = function(errorValue, expected, observed)
            return runtimeSessionModule.fault(state, errorValue, expected, observed)
        end,
    })
    return state
end

local function attachRuntimeEntryHook(state)
    local module, _, callbacks = capture()
    roomHooks.attach(module, runtimeSessionModule, function() return state end, function() end,
        routeSessionModule, roomCoordinatorModule, nil, {
            proveIncomingReward = function() return true end,
            proveOutgoingDoors = function() return true end,
        }, unusedLoadoutScope)
    return callbacks
end

function TestRoomEntryHooks.testStartRoomGameplayMismatchStillCallsNativeExactlyOnce()
    local state = hookedRuntimeState()
    local callbacks = attachRuntimeEntryHook(state)
    local nativeCalls = 0
    local result = callbacks.StartRoom(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return "native-entry"
    end, {}, { Name = "F_Wrong" })

    lu.assertEquals(result, "native-entry")
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(state.firstMismatch.checkpoint, "room-entry")
    lu.assertNil(state.firstFault)
    lu.assertEquals(state.state, "desynchronized")
end

function TestRoomEntryHooks.testStartRoomExecutorFaultStillCallsNativeExactlyOnce()
    local state = hookedRuntimeState()
    local callbacks = attachRuntimeEntryHook(state)
    local nativeCalls = 0
    local result = callbacks.StartRoom(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return "native-entry"
    end, {}, { Name = "F_Opening01", __runPlannerExecutionRoomId = "wrong-stamp" })

    lu.assertEquals(result, "native-entry")
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(state.firstFault.checkpoint, "route-occurrence-stamp")
    lu.assertNil(state.firstMismatch)
    lu.assertEquals(state.state, "faulted")
end

function TestRoomEntryHooks.testFreshPostbossStartRoomAdmissionAdoptsTheRestoredNativeRoom()
    local priorVerify, priorGame, priorCurrentRun = admissionProjection.verify, _G.game, _G.CurrentRun
    admissionProjection.verify = function() return true end

    local opening = {
        id = "opening", gameName = "F_Opening01",
        overview = { encounterPhases = {}, requiredObjects = {}, additional = {} },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
        doors = { kind = "terminal" }, roomExitConformance = { facts = {} },
    }
    local postboss = {
        id = "postboss", gameName = "F_PostBoss01", resumeBoundary = "postbossEntry",
        overview = { encounterPhases = {}, requiredObjects = {}, additional = {} },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
        doors = { kind = "terminal" }, roomExitConformance = { facts = {} },
    }
    local plan = {
        kind = "ready",
        startingLoadout = { weaponKey = "WeaponStaffSwing", aspectKey = "BaseStaffAspect" },
        occurrences = { opening, postboss }, occurrencesById = { opening = opening, postboss = postboss },
        selectedOccurrenceIds = { "opening", "postboss" },
    }
    local state = runtimeSessionModule.create()
    local currentRun = { CurrentRoom = { Name = "F_PostBoss01" } }
    _G.CurrentRun = currentRun
    _G.game = { RoomData = { F_PostBoss01 = { Name = "F_PostBoss01" } } }
    local module, _, callbacks = capture()
    local session = runtimeSessionModule
    local navigationEntry = {
        realizeIncomingReward = function() error("restored room must not be realized again") end,
        proveIncomingReward = function() return true end,
        proveOutgoingDoors = function() return true end,
    }
    local synchronizedRoom, startingSyncCalled = false, false
    roomHooks.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomCoordinatorModule, nil, navigationEntry,
        { synchronizeStartingRoom = function()
            startingSyncCalled = true
            return false
        end }, {
            inbox = { load = function(slot)
                lu.assertEquals(slot, 5)
                return true, plan
            end },
            activePlanSlot = function() return 5 end,
        })

    local result = callbacks.StartRoom(nil, {}, function(run, nativeRoom)
        synchronizedRoom = nativeRoom
        lu.assertEquals(run.CurrentRoom, nativeRoom)
        return "native-started"
    end, currentRun, nil)

    admissionProjection.verify, _G.game, _G.CurrentRun = priorVerify, priorGame, priorCurrentRun
    lu.assertEquals(result, "native-started")
    lu.assertFalse(startingSyncCalled)
    lu.assertTrue(rawequal(synchronizedRoom, currentRun.CurrentRoom))
    lu.assertEquals(synchronizedRoom.Name, "F_PostBoss01")
    lu.assertNil(synchronizedRoom.RewardType)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(routeSessionModule.current(state.route).id, "postboss")
    lu.assertEquals(state.route.index, 2)
    lu.assertNotNil(roomCoordinatorModule.current(state))
end

function TestRoomEntryHooks.testOpeningFinalizesLoadoutBeforeForcingNativeCreationFacts()
    local module, _, callbacks = capture()
    local transaction = {
        owner = "opening-reward", kind = "acquisition", offerKey = "opening-reward",
        window = { kind = "standard", phase = "beforeCombat" },
    }
    local occurrence = {
        id = "opening", gameName = "F_Opening01", biomeKey = "F",
        overview = {
            encounterPhases = { { slotKey = "Encounter", encounterKey = "OpeningGeneratedF" } },
            incomingReward = { rewardType = "WeaponUpgrade", source = "WeaponUpgrade" },
            requiredObjects = {}, additional = {},
        },
        transactionsByOwner = { [transaction.owner] = transaction },
        timeline = { transactions = { transaction }, dependencies = {}, obligations = {} },
        doors = { kind = "terminal" }, roomExitConformance = { facts = {} },
        conformanceExpected = {},
    }
    local plan = {
        occurrences = { occurrence }, occurrencesById = { opening = occurrence },
        selectedOccurrenceIds = { "opening" },
    }
    local state = {
        state = "starting", plan = plan, route = routeSessionModule.new(plan), diagnostics = {},
    }
    state.room = roomCoordinatorModule.new(plan, function(errorValue)
        state.firstMismatch = errorValue
        state.state = "desynchronized"
    end)
    local session = stub()
    session.mismatch = function(_, errorValue)
        state.firstMismatch = errorValue
        state.state = "desynchronized"
    end
    local loadoutScope = {
        synchronizeStartingRoom = function()
            state.state = "synchronized"
            return true
        end,
    }
    local navigationEntry = navigation.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomCoordinatorModule)
    roomHooks.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomCoordinatorModule, nil, navigationEntry, loadoutScope)
    encounterHooks.attach(module, session, function() return state end, function() end,
        roomCoordinatorModule)

    local priorGame, priorForce = _G.game, _G.ForceNextEncounter
    local rewardBag = { { Name = "Boon" }, { Name = "WeaponUpgrade" } }
    local currentRun = { RewardPriorities = {}, RewardStores = { RunProgress = rewardBag } }
    _G.game = {
        RoomData = { F_Opening01 = { Name = "F_Opening01" } },
        EncounterData = { OpeningGeneratedF = { Name = "OpeningGeneratedF" } },
    }
    _G.game.CreateRoom = function(roomData, args)
        return callbacks.CreateRoom(nil, {}, function(created)
            callbacks.SetupRoomReward(nil, {}, function(_, nativeRoom)
                nativeRoom.ForceLootName = "RandomUpgrade"
            end, currentRun, created, nil, {})
            created.ChosenRewardType = callbacks.ChooseRoomReward(nil, {},
                function(run, nativeRoom, store)
                    for index, reward in ipairs(run.RewardStores[store]) do
                        if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                            run, nativeRoom, reward, {}, {}) then
                            table.remove(run.RewardStores[store], index)
                            return reward.Name
                        end
                    end
                end, currentRun, created, "RunProgress", {}, {})
            created.Encounter = callbacks.ChooseEncounter(nil, {}, function(run)
                return { Name = run.ForceNextEncounterData and run.ForceNextEncounterData.Name or "Wrong" }
            end, currentRun, created, args)
            return created
        end, roomData, args)
    end

    local nativeFallbackCalled = false
    local result = callbacks.ChooseStartingRoom(nil, {}, function()
        nativeFallbackCalled = true
        return { Name = "NativeOpening" }
    end, currentRun, {})
    lu.assertEquals(state.state, "synchronized")
    lu.assertFalse(nativeFallbackCalled)
    lu.assertEquals(result.Name, "F_Opening01")
    lu.assertEquals(result.ChosenRewardType, "WeaponUpgrade")
    lu.assertEquals(result.ForceLootName, "WeaponUpgrade")
    lu.assertEquals(rewardBag, { { Name = "Boon" } })
    lu.assertEquals(result.Encounter.Name, "OpeningGeneratedF")
    callbacks.StartRoom(nil, {}, function() return true end, currentRun, result)
    local active = roomCoordinatorModule.current(state)
    lu.assertNotNil(active)
    local handle = assert(roomCoordinatorModule.resolve(state, active,
        { kind = "offer", offerKey = "opening-reward" }))
    lu.assertTrue(roomCoordinatorModule.complete(state, handle))
    lu.assertNil(state.firstMismatch)
    _G.game, _G.ForceNextEncounter = priorGame, priorForce
end

function TestRoomEntryHooks.testOpeningLoadoutMismatchReturnsToUnblockedNativeSelection()
    local module, _, callbacks = capture()
    local state = { state = "starting" }
    local nativeRoom = { Name = "NativeOpening" }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        { expected = function() error("route must remain untouched") end }, {}, nil,
        navigationEntryStub, {
            synchronizeStartingRoom = function()
                state.state = "desynchronized"
                return false
            end,
        })

    local result = callbacks.ChooseStartingRoom(nil, {}, function() return nativeRoom end, {}, {})
    lu.assertEquals(result, nativeRoom)
    lu.assertEquals(state.state, "desynchronized")
end

function TestRoomEntryHooks.testLaterDreamStartingRoomForcesTheCursorSuccessorBeforePostbossExit()
    local module, _, callbacks = capture()
    local occurrence = { id = "dream-next", gameName = "F_Opening01", overview = {} }
    local state = {
        state = "synchronized", plan = { routeKey = "Dream" }, route = { currentOccurrence = { id = "postboss" } },
    }
    local prepared = false
    local room = {
        prepare = function(_, selected)
            lu.assertEquals(selected, occurrence)
            prepared = true
            return {}
        end,
        realize = function(_, selected)
            lu.assertTrue(prepared)
            lu.assertEquals(selected, occurrence)
            return { Name = selected.gameName }
        end,
    }
    local priorGame = _G.game
    _G.game = {
        CreateRoom = function(data)
            data.created = true
            return data
        end,
    }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        {
            expected = function() error("later Dream entry must not use the current Postboss") end,
            next = function(route)
                lu.assertEquals(route, state.route)
                return occurrence
            end,
        }, room, nil, {
            realizeIncomingReward = function(_, data) return data end,
        }, {
            synchronizeStartingRoom = function()
                error("later Dream entry must not re-run startup synchronization")
            end,
        })
    local fallback = false
    local result = callbacks.ChooseStartingRoom(nil, {}, function()
        fallback = true
    end, { IsDreamRun = true }, { StartingBiome = "F" })
    _G.game = priorGame
    lu.assertFalse(fallback)
    lu.assertTrue(result.created)
    lu.assertEquals(result.Name, "F_Opening01")
end

function TestRoomEntryHooks.testDreamIntroLeavesTheFirstPublishedCursorUntouched()
    local first = { id = "dream-first", gameName = "Q_Intro" }
    local cursor = routeSessionModule.new({
        routeKey = "Dream", selectedOccurrenceIds = { first.id }, occurrencesById = { [first.id] = first },
    })
    lu.assertTrue(routeSessionModule.enterTransparent(cursor, "Dream_Intro"))
    lu.assertTrue(routeSessionModule.leaveTransparent(cursor, "Dream_Intro"))
    lu.assertEquals(cursor.index, 1)
    lu.assertNil(routeSessionModule.current(cursor))
    lu.assertEquals(routeSessionModule.expected(cursor), first)
end

function TestRoomEntryHooks.testRoomSessionAndEncounterBindingStartBeforeNativeLifecycle()
    local module, _, callbacks = capture()
    local entered, bound, proved = false, false, false
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local additional = { room = { id = "chaos", gameName = "Chaos_01" } }
    local session = stub()
    local route = {
        expected = function() return occurrence end,
        enter = function(_, id, gameName)
            lu.assertEquals(id, "opening")
            lu.assertEquals(gameName, "F_Opening01")
            return occurrence
        end,
    }
    local roomSession = {
        enter = function(_, enteredOccurrence)
            lu.assertEquals(enteredOccurrence, occurrence)
            entered = true
            return true
        end,
        bindEntryEncounters = function(_, nativeRoom)
            lu.assertTrue(entered)
            lu.assertEquals(nativeRoom.__runPlannerExecutionRoomId, "opening")
            bound = true
            return true
        end,
        additional = function()
            if entered then return additional.room, additional end
            return nil
        end,
        proveEntry = function(_, nativeRoom)
            proved = true
            lu.assertEquals(nativeRoom.__runPlannerExecutionRoomId, "opening")
            return true
        end,
    }
    local state = { state = "synchronized", route = {} }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntryStub, unusedLoadoutScope)

    local nativeRoom = { Name = "F_Opening01", __runPlannerExecutionRoomId = "opening" }
    local eligible
    callbacks.StartRoom(nil, {}, function()
        lu.assertTrue(bound)
        callbacks.HandleSecretSpawns(nil, {}, function()
            eligible = callbacks.IsSecretDoorEligible(nil, {}, function() return false end, {}, nativeRoom)
        end, {})
    end, {}, nativeRoom)

    lu.assertTrue(entered)
    lu.assertTrue(bound)
    lu.assertTrue(proved)
    lu.assertTrue(eligible)
end

function TestRoomEntryHooks.testRecoveredOccurrenceIdentitySurvivesThroughNativeRoomLifecycle()
    local module, _, callbacks = capture()
    local occurrence = { id = "story", gameName = "N_Story01" }
    local state = { state = "synchronized", route = {} }
    local route = {
        expected = function() return occurrence end,
        enter = function(_, id, gameName)
            lu.assertEquals(id, occurrence.id)
            lu.assertEquals(gameName, occurrence.gameName)
            return occurrence
        end,
    }
    local roomSession = {
        enter = function() return true end,
        bindEntryEncounters = function() return true end,
        proveEntry = function() return true end,
        additional = function() return nil end,
    }
    local featureScope = roomFeatureHooks.attach(module, stub(), function() return state end, function() end,
        roomSession)
    roomHooks.attach(module, stub(), function() return state end, function() end,
        route, roomSession, featureScope, navigationEntryStub, unusedLoadoutScope)

    local nativeRoom = { Name = occurrence.gameName }
    callbacks.StartRoom(nil, {}, function(_, enteredRoom)
        lu.assertEquals(enteredRoom.__runPlannerExecutionRoomId, occurrence.id)
    end, {}, nativeRoom)

    lu.assertEquals(nativeRoom.__runPlannerExecutionRoomId, occurrence.id)
end

function TestRoomEntryHooks.testStructuralShopEligibilityFollowsTheResolvedRoomOverview()
    local module, _, callbacks = capture()
    local active = { overview = {} }
    local destination = { overview = {
        stygianWell = { offers = {} }, purgingPool = { sales = {} }, hermesShrine = { offers = {} },
    } }
    local state = { state = "synchronized" }
    local roomSession = {
        occurrence = function(_, nativeRoom)
            return nativeRoom.destination and destination or active
        end,
    }
    roomFeatureHooks.attach(module, stub(), function() return state end, function() end, roomSession)

    lu.assertFalse(callbacks.IsWellShopEligible(nil, {}, function() return true end, {}, {}))
    lu.assertFalse(callbacks.IsSellTraitShopEligible(nil, {}, function() return true end, {}))
    lu.assertFalse(callbacks.IsSurfaceShopEligible(nil, {}, function() return true end, {}, {}))
    local nativeDestination = { destination = true }
    lu.assertTrue(callbacks.IsWellShopEligible(nil, {}, function() return false end, {}, nativeDestination))
    lu.assertTrue(callbacks.IsSellTraitShopEligible(nil, {}, function() return false end, nativeDestination))
    lu.assertTrue(callbacks.IsSurfaceShopEligible(nil, {}, function() return false end, {}, nativeDestination))
end

function TestRoomEntryHooks.testStructuralPresenceRetainsNativeShopAndFeatureConstruction()
    local module, _, callbacks = capture()
    local occurrence = { overview = { stygianWell = { offers = {} } } }
    local state = { state = "synchronized" }
    local roomSession = {
        occurrence = function() return occurrence end,
        additional = function() return nil end,
    }
    roomFeatureHooks.attach(module, stub(), function() return state end, function() end, roomSession)

    -- RunShopGeneration runs before HandleSecretSpawns. The predicates only
    -- open the published branches; native creation and bookkeeping remain
    -- the caller's responsibility.
    local wellRoom = {}
    local wellRun = { CurrentRoom = wellRoom, RunDepthCache = 7 }
    if callbacks.IsWellShopEligible(nil, {}, function() return false end, wellRun, wellRoom) then
        wellRoom.Store = { native = "well" }
    end
    callbacks.HandleSecretSpawns(nil, {}, function(currentRun)
        local room = currentRun.CurrentRoom
        if callbacks.IsWellShopEligible(nil, {}, function() return false end, currentRun, room) then
            room.WellShop = { native = true }
            currentRun.LastWellShopDepth = currentRun.RunDepthCache
        end
    end, wellRun)
    lu.assertEquals(wellRoom.Store, { native = "well" })
    lu.assertEquals(wellRoom.WellShop, { native = true })
    lu.assertEquals(wellRun.LastWellShopDepth, 7)

    occurrence = { overview = { hermesShrine = { offers = {} } } }
    local shrineRoom = {}
    local shrineRun = { CurrentRoom = shrineRoom }
    if callbacks.IsSurfaceShopEligible(nil, {}, function() return false end, shrineRun, shrineRoom) then
        shrineRoom.Store = { native = "shrine" }
    end
    callbacks.HandleSecretSpawns(nil, {}, function(currentRun)
        local room = currentRun.CurrentRoom
        if callbacks.IsSurfaceShopEligible(nil, {}, function() return false end, currentRun, room) then
            room.SurfaceShop = { native = true }
        end
    end, shrineRun)
    lu.assertEquals(shrineRoom.Store, { native = "shrine" })
    lu.assertEquals(shrineRoom.SurfaceShop, { native = true })

    occurrence = { overview = { purgingPool = { sales = {} } } }
    local poolRoom = {}
    callbacks.HandleSecretSpawns(nil, {}, function(currentRun)
        local room = currentRun.CurrentRoom
        if callbacks.IsSellTraitShopEligible(nil, {}, function() return false end, room) then
            room.SellTraitShop = { native = true }
            room.SellOptions = { "native-generated" }
        end
    end, { CurrentRoom = poolRoom })
    lu.assertEquals(poolRoom.SellTraitShop, { native = true })
    lu.assertEquals(poolRoom.SellOptions, { "native-generated" })
end

function TestRoomEntryHooks.testSecretPresenceScopeClearsAfterFaultAndPassesThroughOutsideOwnership()
    local module, _, callbacks = capture()
    local publishedChaos = true
    local state = { state = "synchronized" }
    local roomSession = {
        additional = function()
            return publishedChaos and {} or nil
        end,
    }
    roomFeatureHooks.attach(module, stub(), function() return state end, function() end, roomSession)

    local ok, message = pcall(callbacks.HandleSecretSpawns, nil, {}, function()
        lu.assertTrue(callbacks.IsSecretDoorEligible(nil, {}, function() return false end, {}, {}))
        error("native secret spawn failure")
    end, {})
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native secret spawn failure")

    local nativeCalls = 0
    lu.assertEquals(callbacks.IsSecretDoorEligible(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return "native"
    end, {}, {}), "native")
    lu.assertEquals(nativeCalls, 1)

    publishedChaos = false
    callbacks.HandleSecretSpawns(nil, {}, function()
        lu.assertFalse(callbacks.IsSecretDoorEligible(nil, {}, function() return true end, {}, {}))
    end, {})
end

function TestRoomEntryHooks.testIncomingRewardProofRemainsNavigationOwnedAtRoomEntry()
    local module, _, callbacks = capture()
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local state = { state = "synchronized", route = {} }
    local mismatch, roomProof
    local session = stub()
    session.mismatch = function(_, errorValue)
        mismatch = errorValue
        state.state = "desynchronized"
    end
    local route = {
        expected = function() return occurrence end,
        enter = function() return occurrence end,
    }
    local roomSession = {
        enter = function() return true end,
        bindEntryEncounters = function() return true end,
        proveEntry = function() roomProof = true; return true end,
    }
    local navigationEntry = {
        realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
        proveIncomingReward = function()
            return nil, { kind = "incomingReward", expected = "Boon", observed = "WeaponUpgrade" }
        end,
        proveOutgoingDoors = function() return true end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry, unusedLoadoutScope)

    callbacks.StartRoom(nil, {}, function() return true end, {}, {
        Name = "F_Opening01", __runPlannerExecutionRoomId = "opening",
    })

    lu.assertEquals(mismatch.kind, "incomingReward")
    lu.assertNil(roomProof)
end

function TestRoomEntryHooks.testZagreusContractRemainsAnAdditionalDoorDuringExitProof()
    local module, _, callbacks = capture()
    local additional = {
        owner = "contract-exit", kind = "zagreusContract",
        room = { id = "contract", gameName = "C_Boss01" },
    }
    local occurrence = {
        id = "shop", overview = { additional = { additional } },
        doors = { kind = "batch", targets = {
            { room = { id = "one", gameName = "F_One" } },
            { room = { id = "two", gameName = "F_Two" } },
        } },
    }
    local contractOccurrence = {
        id = "contract", gameName = "C_Boss01",
        overview = { encounterPhases = {}, requiredObjects = {} },
    }
    local state = { state = "synchronized", route = {}, plan = { occurrencesById = {
        shop = occurrence, contract = contractOccurrence, one = {}, two = {},
    } } }
    local active = { occurrence = occurrence }
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local roomSession = {
        current = function() return active end,
        additional = function()
            return additional, contractOccurrence
        end,
        realize = function(_, target, _, input)
            return { Name = target.gameName, GenusName = target.gameName,
                __runPlannerExecutionRoomId = target.id,
                __runPlannerExecutionZagreusContractPresent = input
                    and input.__runPlannerExecutionZagreusContractPresent }
        end,
        realizeFeatures = function(_, nativeRoom) return nativeRoom end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local route = {
        current = function() return active.occurrence end,
    }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    local navigationEntry = navigation.attach(module, session, function() return state end, function() end,
        route, roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntry, unusedLoadoutScope)

    local function createHost(present, nativeValue)
        return callbacks.CreateRoom(nil, {}, function(roomData)
            roomData.ZagreusContractSuccess = nativeValue
            return roomData
        end, {
            Name = "F_Shop01", __runPlannerExecutionRoomId = "shop",
            __runPlannerExecutionZagreusContractPresent = present,
        }, {})
    end

    local hostRoom = createHost(true, false)
    lu.assertTrue(hostRoom.ZagreusContractSuccess)

    local contractRoom
    local contractDoor = { ObjectId = 3 }
    callbacks.SpawnZagContract(nil, {}, function(nativeRoom)
        lu.assertTrue(nativeRoom.ZagreusContractSuccess)
        if not nativeRoom.ZagreusContractSuccess then return end
        contractRoom = callbacks.CreateRoom(nil, {}, function(roomData) return roomData end,
            { Name = "C_Boss01" }, {})
        callbacks.AssignRoomToExitDoor(nil, {}, function(door, createdRoom)
            door.Room = createdRoom
        end, contractDoor, contractRoom)
    end, hostRoom, {})
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalKind, "zagreusContract")
    lu.assertNil(contractRoom.ZagreusContractSuccess)
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")

    local absentHost = createHost(false, true)
    lu.assertFalse(absentHost.ZagreusContractSuccess)
    callbacks.SpawnZagContract(nil, {}, function(nativeRoom)
        lu.assertFalse(nativeRoom.ZagreusContractSuccess)
        if nativeRoom.ZagreusContractSuccess then error("native SpawnZagContract must not create a contract") end
    end, absentHost, {})

    local priorMap, priorCollapse, priorGame = _G.MapState, _G.CollapseTableOrdered, _G.game
    local oneDoor, twoDoor = { Room = { Name = "F_One" } }, { Room = { Name = "F_Two" } }
    _G.MapState = { OfferedExitDoors = { oneDoor, twoDoor, contractDoor } }
    _G.CollapseTableOrdered = function(value) return value end
    _G.game = { RoomData = { F_One = {}, F_Two = {} } }
    callbacks.DoUnlockRoomExits(nil, {}, function() return true end, {}, {})
    local proved, errorValue = navigationEntry.proveOutgoingDoors(state, {})
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertTrue(proved, errorValue)
    lu.assertNil(oneDoor.__runPlannerExecutionAdditionalKind)
    lu.assertNil(twoDoor.__runPlannerExecutionAdditionalKind)
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")
end

function TestRoomEntryHooks.testLeaveRoomProvesDoorsBeforeClosingTheRoomSession()
    local module, _, callbacks = capture()
    local state = { state = "synchronized", route = {} }
    local mismatch, closed, advanced, nativeCalled
    local session = stub()
    session.mismatch = function(_, errorValue)
        mismatch = errorValue
        state.state = "desynchronized"
    end
    local route = {
        exit = function() advanced = true; return true end,
        expected = function() return {} end,
    }
    local roomSession = {
        close = function() closed = true; return true end,
    }
    local navigationEntry = {
        realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
        proveIncomingReward = function() return true end,
        proveOutgoingDoors = function()
            return nil, { kind = "reward", expected = "Boon", observed = "WeaponUpgrade" }
        end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry, unusedLoadoutScope)

    local result = callbacks.LeaveRoom(nil, {}, function()
        nativeCalled = true
        return "native-exit"
    end, {}, {})

    lu.assertEquals(result, "native-exit")
    lu.assertEquals(mismatch.kind, "reward")
    lu.assertNil(closed)
    lu.assertNil(advanced)
    lu.assertTrue(nativeCalled)
end

function TestRoomEntryHooks.testLeaveRoomContinuesNativeAfterRoomCloseMismatch()
    local module, _, callbacks = capture()
    local state = { state = "synchronized", route = {} }
    local mismatch, closed, advanced, nativeCalled
    local session = stub()
    session.mismatch = function(_, errorValue)
        mismatch = errorValue
        state.state = "desynchronized"
    end
    local route = {
        exit = function() advanced = true; return true end,
        expected = function() return {} end,
    }
    local roomSession = {
        close = function()
            closed = true
            return session.mismatch(state, {
                checkpoint = "obligation:exitUsable", expected = "usable", observed = "incomplete",
            })
        end,
    }
    local navigationEntry = {
        proveOutgoingDoors = function() return true end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry, unusedLoadoutScope)

    local result = callbacks.LeaveRoom(nil, {}, function()
        nativeCalled = true
        return "native-exit"
    end, {}, {})

    lu.assertEquals(result, "native-exit")
    lu.assertTrue(closed)
    lu.assertEquals(mismatch.checkpoint, "obligation:exitUsable")
    lu.assertNil(advanced)
    lu.assertTrue(nativeCalled)
end

function TestRoomEntryHooks.testLeaveRoomAdvancesBeforeNativeLeaveCanEnterNextRoom()
    local module, _, callbacks = capture()
    local first = { id = "one", gameName = "F_One" }
    local second = { id = "two", gameName = "F_Two" }
    local plan = {
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    }
    local cursor = routeSessionModule.new(plan)
    assert(routeSessionModule.enter(cursor, "one", "F_One"))
    local nativeCalled, closed = false, false
    local state = { state = "synchronized", route = cursor }
    local session = stub()
    session.mismatch = function(_, errorValue)
        state.state, state.firstMismatch = "desynchronized", errorValue
    end
    local roomSession = {
        close = function() closed = true; return true end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomSession, nil, navigationEntryStub, unusedLoadoutScope)
    local result = callbacks.LeaveRoom(nil, {}, function()
        lu.assertTrue(closed)
        lu.assertNil(routeSessionModule.current(cursor))
        lu.assertEquals(routeSessionModule.expected(cursor), second)
        lu.assertEquals(routeSessionModule.enter(cursor, "two", "F_Two"), second)
        nativeCalled = true
        return "native-exit"
    end, {}, {})
    lu.assertEquals(result, "native-exit")
    lu.assertTrue(nativeCalled)
    lu.assertEquals(routeSessionModule.current(cursor), second)
    lu.assertEquals(routeSessionModule.expected(cursor), second)
end

function TestRoomEntryHooks.testLeaveRoomDoesNotRetainDepartingCursorAfterNestedMismatch()
    local module, _, callbacks = capture()
    local first = { id = "one", gameName = "F_One" }
    local second = { id = "two", gameName = "F_Two" }
    local plan = {
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    }
    local cursor = routeSessionModule.new(plan)
    assert(routeSessionModule.enter(cursor, "one", "F_One"))
    local state = { state = "synchronized", route = cursor }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        routeSessionModule, { close = function() return true end }, nil,
        navigationEntryStub, unusedLoadoutScope)

    callbacks.LeaveRoom(nil, {}, function()
        lu.assertNil(routeSessionModule.current(cursor))
        lu.assertEquals(routeSessionModule.expected(cursor), second)
        state.state = "desynchronized"
    end, {}, {})

    lu.assertNil(routeSessionModule.current(cursor))
    lu.assertEquals(routeSessionModule.expected(cursor), second)
end

function TestRoomEntryHooks.testEphyraRestoresStayTransparentWhileFreshRoomsAdvanceOnce()
    local module, _, callbacks = capture()
    local opening = { id = "opening", gameName = "N_Opening01", overview = {} }
    local chaos = {
        id = "chaos", gameName = "Chaos_03", biomeKey = "N",
        overview = { hub = {
            room = { gameName = "N_Hub" },
            slots = { {
                slotKey = "main", physicalDoorId = 101,
                room = { id = "main", biomeKey = "N", gameName = "N_Combat05" },
                reward = { rewardType = "Boon" },
            } },
            finalHandoff = { id = "next", biomeKey = "N", gameName = "N_PreBoss01" },
        } },
    }
    local side1 = { id = "side1", gameName = "N_Sub01", biomeKey = "N", overview = {} }
    local side2 = { id = "side2", gameName = "N_Sub02", biomeKey = "N", overview = {} }
    local main = {
        id = "main", gameName = "N_Combat05", biomeKey = "N",
        overview = { localSlots = {
            { slotKey = "side1", physicalDoorId = 201, generation = "generated",
                room = { id = "side1", biomeKey = "N", gameName = "N_Sub01" },
                reward = { rewardType = "MaxHealthDropSmall" } },
            { slotKey = "side2", physicalDoorId = 202, generation = "generated",
                room = { id = "side2", biomeKey = "N", gameName = "N_Sub02" },
                reward = { rewardType = "MaxManaDropSmall" } },
        } },
    }
    local nextRoom = { id = "next", gameName = "N_PreBoss01", biomeKey = "N", overview = {} }
    local plan = {
        selectedOccurrenceIds = { "opening", "chaos", "main", "side1", "side2", "next" },
        occurrencesById = {
            opening = opening, chaos = chaos, main = main,
            side1 = side1, side2 = side2, next = nextRoom,
        },
    }
    local cursor = routeSessionModule.new(plan)
    local state = { state = "synchronized", plan = plan, route = cursor }
    local entered, closed = {}, {}
    local roomSession = {
        enter = function(_, occurrence) entered[#entered + 1] = occurrence.id; return true end,
        bindEntryEncounters = function() return true end,
        proveEntry = function() return true end,
        close = function()
            local current = routeSessionModule.current(cursor)
            closed[#closed + 1] = current and current.id
            return true
        end,
    }
    local navigationEntry = {
        realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
        proveIncomingReward = function() return true end,
        proveOutgoingDoors = function() return true end,
    }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        routeSessionModule, roomSession, nil, navigationEntry, unusedLoadoutScope)

    local function enterFresh(occurrence)
        callbacks.StartRoom(nil, {}, function() return true end, {}, {
            Name = occurrence.gameName, __runPlannerExecutionRoomId = occurrence.id,
        })
    end
    local function leaveRoom()
        callbacks.LeaveRoom(nil, {}, function() return true end, {}, {})
    end
    local function passTransparent(gameName)
        callbacks.StartRoom(nil, {}, function() return true end, {}, { Name = gameName })
        callbacks.LeaveRoom(nil, {}, function() return true end, {}, {})
    end
    local function leaveTransparentWithoutStart(gameName)
        callbacks.LeaveRoom(nil, {}, function() return true end, {
            CurrentRoom = { Name = gameName },
        }, {})
    end

    enterFresh(opening); leaveRoom()
    enterFresh(chaos); leaveRoom()
    passTransparent("N_Hub")
    enterFresh(main); leaveRoom()
    enterFresh(side1); leaveRoom()
    passTransparent("N_Combat05")
    enterFresh(side2); leaveRoom()
    passTransparent("N_Combat05")
    leaveTransparentWithoutStart("N_Hub")
    enterFresh(nextRoom)

    lu.assertEquals(entered, { "opening", "chaos", "main", "side1", "side2", "next" })
    lu.assertEquals(closed, { "opening", "chaos", "main", "side1", "side2" })
    lu.assertEquals(routeSessionModule.current(cursor), nextRoom)
    lu.assertEquals(cursor.index, 6)
    lu.assertNil(cursor.firstMismatch)
end

function TestRoomEntryHooks.testFieldsDoorRewardsSurviveRoomCreationWithOrWithoutLayout()
    for _, hasLayout in ipairs({ true, false }) do
        local module, _, callbacks = capture()
        local destination = { id = "fields", gameName = "H_Combat07", biomeKey = "H", overview = {} }
        if hasLayout then
            destination.overview.fields = { entryPair = { startPointId = 1, endPointId = 2 } }
        end
        local state = { state = "synchronized", plan = { occurrencesById = { fields = destination } } }
        local navigationEntry = navigation.attach(module, stub(), function() return state end,
            function() end, routeSessionModule, roomCoordinatorModule)
        roomHooks.attach(module, stub(), function() return state end, function() end,
            routeSessionModule, roomCoordinatorModule, nil, navigationEntry, unusedLoadoutScope)
        local source = { doors = { kind = "batch", targets = { {
            room = { id = destination.id, gameName = destination.gameName },
            cageRewards = {
                { rewardType = "MaxManaDrop" },
                { rewardType = "Boon", source = "HeraUpgrade" },
            },
        } } } }
        local priorGame = _G.game
        _G.game = { RoomData = { H_Combat07 = { MaxCageRewards = 2 } } }
        local offered = doors.realize(source, {}, _G.game)
        local created = callbacks.CreateRoom(nil, {}, function(roomData)
            -- Native DoUnlockRoomExits rerolls cage rewards if this survives
            -- the declaration composition before CreateRoom.
            lu.assertNil(roomData.MaxCageRewards)
            return roomData
        end, offered[1].Room, {})
        lu.assertNil(created.MaxCageRewards)
        lu.assertEquals(created.CageRewards, {
            { RewardType = "MaxManaDrop" },
            { RewardType = "Boon", ForceLootName = "HeraUpgrade" },
        })
        lu.assertEquals(_G.game.RoomData.H_Combat07.MaxCageRewards, 2)
        _G.game = priorGame
    end
end

function TestRoomEntryHooks.testEphyraFinalHandoffIsBoundBeforeNativeRoomCreation()
    local module, _, callbacks = capture()
    local preboss = { id = "preboss", gameName = "N_PreBoss01", biomeKey = "N", overview = {} }
    local source = {
        id = "source", gameName = "N_PreHub01", biomeKey = "N",
        overview = { hub = {
            room = { gameName = "N_Hub" }, slots = {},
            finalHandoff = { id = "preboss", biomeKey = "N", gameName = "N_PreBoss01" },
        } },
    }
    local plan = {
        selectedOccurrenceIds = { "preboss" },
        occurrencesById = { source = source, preboss = preboss },
    }
    local state = { state = "synchronized", plan = plan, route = routeSessionModule.new(plan) }
    local roomSession = {
        current = function() return nil end,
        realize = function(_, occurrence)
            lu.assertEquals(occurrence, preboss)
            return { Name = occurrence.gameName, __runPlannerExecutionRoomId = occurrence.id }
        end,
        realizeFeatures = function(_, _, nativeRoom) return nativeRoom end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local navigationEntry = navigation.attach(module, stub(), function() return state end,
        function() end, routeSessionModule, roomSession)
    roomHooks.attach(module, stub(), function() return state end, function() end,
        routeSessionModule, roomSession, nil, navigationEntry, unusedLoadoutScope)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Name = "N_Hub" } }

    local result = callbacks.CreateRoom(nil, {}, function(roomData)
        lu.assertEquals(roomData.__runPlannerExecutionRoomId, "preboss")
        return roomData
    end, { Name = "N_PreBoss01" }, {})

    lu.assertEquals(result.__runPlannerExecutionRoomId, "preboss")
    _G.CurrentRun = priorRun
end

function TestRoomEntryHooks.testEncounterForcingKeepsNativeSetupAndGeneration()
    local module, _, callbacks = capture()
    local declaration = { Name = "OpeningGeneratedF", Generated = true }
    local occurrence = {
        id = "opening",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "OpeningGeneratedF" } } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { opening = occurrence } } }
    local active = { occurrence = occurrence }
    local session = stub()
    local boundEncounter
    local roomSession = {
        current = function() return active end,
        encounterAt = function(_, index) return active.occurrence.overview.encounterPhases[index] end,
        bindEncounter = function(_, native, slotKey)
            boundEncounter = { native = native, slotKey = slotKey }
            return active.occurrence.overview.encounterPhases[1]
        end,
        startEncounter = function() return true end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
        encounterIsFinal = function() return true end,
    }
    local priorGame, priorGlobalForce = _G.game, _G.ForceNextEncounter
    _G.game = { EncounterData = { OpeningGeneratedF = declaration } }
    _G.ForceNextEncounter = "DebugEncounter"
    encounterHooks.attach(module, session, function() return state end, function() end, roomSession)

    local run = { ForceNextEncounterData = { Name = "PriorEncounter" } }
    local nativeRoom = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseEncounter(nil, {}, function(currentRun, room, args)
        lu.assertEquals(currentRun.ForceNextEncounterData, declaration)
        lu.assertNil(_G.ForceNextEncounter)
        lu.assertEquals(room, nativeRoom)
        return { Name = declaration.Name, GeneratedWaves = true, Args = args }
    end, run, nativeRoom, { Source = "test" })

    lu.assertTrue(result.GeneratedWaves)
    lu.assertEquals(result.Args.Source, "test")
    lu.assertEquals(run.ForceNextEncounterData.Name, "PriorEncounter")
    lu.assertEquals(_G.ForceNextEncounter, "DebugEncounter")
    lu.assertEquals(boundEncounter.native, result)
    lu.assertEquals(boundEncounter.slotKey, "Encounter")
    _G.game, _G.ForceNextEncounter = priorGame, priorGlobalForce
end

function TestRoomEntryHooks.testEncounterChoiceUsesStampedDestinationInsteadOfActiveSourceRoom()
    local module, _, callbacks = capture()
    local source = {
        id = "source", gameName = "F_Source",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "SourceEncounter" } } },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
    }
    local target = {
        id = "target", gameName = "F_Target",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "TargetEncounter" } } },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { source = source, target = target } }
    local state = {
        state = "synchronized", plan = plan,
        room = roomCoordinatorModule.new(plan, function() end, {}),
    }
    assert(roomCoordinatorModule.enter(state, source))
    local priorGame = _G.game
    _G.game = { EncounterData = {
        SourceEncounter = { Name = "SourceEncounter" },
        TargetEncounter = { Name = "TargetEncounter" },
    } }
    encounterHooks.attach(module, stub(), function() return state end, function() end,
        roomCoordinatorModule)

    local nativeRoom = { __runPlannerExecutionRoomId = "target" }
    local result = callbacks.ChooseEncounter(nil, {}, function(run)
        return { Name = run.ForceNextEncounterData.Name }
    end, {}, nativeRoom, {})
    _G.game = priorGame

    lu.assertEquals(result.Name, "TargetEncounter")
end

function TestRoomEntryHooks.testRoomRewardForcingConsumesTheMatchingNativeBagEntry()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening",
        overview = { incomingReward = { rewardType = "WeaponUpgrade" } },
    }
    local state = {
        state = "synchronized",
        plan = { occurrencesById = { opening = occurrence } },
    }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = {},
        RewardStores = {
            RunProgress = { { Name = "Boon" }, { Name = "WeaponUpgrade" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, _, rewardStoreName)
        local selected
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                currentRun, room, reward, {}, {}) then
                selected = index
                break
            end
        end
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "WeaponUpgrade")
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "Boon" } })
end

function TestRoomEntryHooks.testStartingRoomRewardRemainsNativeUntilLoadoutIsSynchronized()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening", gameName = "F_Opening01",
        overview = { incomingReward = { rewardType = "WeaponUpgrade" } },
    }
    local state = {
        state = "starting",
        plan = { occurrencesById = { opening = occurrence } },
    }
    local session = stub()
    session.current = function() return nil end
    attachRewardHooks(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = {},
        RewardStores = {
            RunProgress = { { Name = "Boon" }, { Name = "WeaponUpgrade" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, nativeRoom, rewardStoreName)
        local reward = table.remove(currentRun.RewardStores[rewardStoreName], 1)
        nativeRoom.ChosenRewardType = reward.Name
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "Boon")
    lu.assertEquals(room.ChosenRewardType, "Boon")
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "WeaponUpgrade" } })
end

function TestRoomEntryHooks.testPublishedRewardStoreOverridesAStaleNativeStore()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "target",
        overview = {
            incomingReward = {
                rewardType = "MetaCurrencyDrop",
                resolvedStoreKey = "MetaProgress",
            },
        },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { target = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = { "MetaCardPointsCommonDrop", "MetaCurrencyDrop", "Boon" },
        RewardStores = {
            RunProgress = { { Name = "HermesUpgrade" } },
            MetaProgress = { { Name = "MetaCardPointsCommonDrop" }, { Name = "MetaCurrencyDrop" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "target", RewardStoreName = "RunProgress" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, nativeRoom, rewardStoreName)
        lu.assertEquals(rewardStoreName, "MetaProgress")
        lu.assertEquals(nativeRoom.RewardStoreName, "MetaProgress")
        local eligible = {}
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function()
                -- The native eligibility result is deliberately hostile: the
                -- published reward must own this scoped choice regardless.
                return false
            end, currentRun, nativeRoom, reward, {}, {}) then
                eligible[#eligible + 1] = index
            end
        end
        lu.assertEquals(eligible, { 2 })
        local selected = eligible[1]
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "MetaCurrencyDrop")
    lu.assertEquals(run.RewardStores.MetaProgress, { { Name = "MetaCardPointsCommonDrop" } })
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "HermesUpgrade" } })
    lu.assertEquals(run.RewardPriorities, { "MetaCardPointsCommonDrop", "MetaCurrencyDrop", "Boon" })
end

function TestRoomEntryHooks.testContractTraitAcquisitionDoesNotOwnTheNativeMetaRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "contract",
        overview = { incomingReward = { rewardType = "InfernalContractBoon" } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { contract = occurrence } } }
    local mismatches = {}
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    session.mismatch = function(_, checkpoint) mismatches[#mismatches + 1] = checkpoint end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "contract", ForcedReward = "GemPointsBigDrop" }
    local result = callbacks.ChooseRoomReward(nil, {}, function()
        return "GemPointsBigDrop"
    end, {}, room, "MetaProgress", {}, {})

    lu.assertEquals(result, "GemPointsBigDrop")
    lu.assertEquals(mismatches, {})
end

function TestRoomEntryHooks.testEffectNeutralBossRewardUsesNativeForcedRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "boss",
        overview = { effectNeutralRequiredReward = true },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { boss = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "boss", ForcedReward = "MixerFBossDrop" }
    local baseCalled = false
    local result = callbacks.ChooseRoomReward(nil, {}, function(_, nativeRoom)
        baseCalled = true
        return nativeRoom.ForcedReward
    end, {}, room, "RunProgress", {}, {})

    lu.assertTrue(baseCalled)
    lu.assertEquals(result, "MixerFBossDrop")
end

function TestRoomEntryHooks.testRewardSourceUsesTheTargetOccurrenceNotTheCurrentRoom()
    local module, _, callbacks = capture()
    local current = {
        id = "current",
        overview = { incomingReward = { rewardType = "Boon", source = "ApolloUpgrade" } },
    }
    local target = {
        id = "target",
        overview = { incomingReward = { rewardType = "Boon", source = "ZeusUpgrade" } },
    }
    local state = {
        state = "synchronized",
        plan = { occurrencesById = { current = current, target = target } },
    }
    local session = stub()
    session.current = function() return { occurrence = current } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "target" }
    callbacks.SetupRoomReward(nil, {}, function(_, nativeRoom)
        nativeRoom.ForceLootName = "RandomUpgrade"
        return true
    end, {}, room, {}, {})

    lu.assertEquals(room.ForceLootName, "ZeusUpgrade")
end
