-- luacheck: globals TestExitProtection
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local overview = require("mods.room.overview")
local routeSession = require("mods.route.session")
local support = require("tests.harness.hook_composition")
local nativeGame = require("tests.harness.native_game")

TestExitProtection = {}

function TestExitProtection:setUp()
    local occurrence = { id = "current", gameName = "G_Combat01", biomeKey = "G" }
    local plan = {
        selectedOccurrenceIds = { "current", "picked" },
        occurrencesById = { current = occurrence },
    }
    self.state = { state = "synchronized", route = routeSession.new(plan), plan = plan }
    assert(routeSession.enter(self.state.route, "current", "G_Combat01"))
    local module, _, callbacks = support.capture()
    navigation.attach(module, support.stub(), function() return self.state end, function() end, routeSession, {})
    self.callbacks = callbacks
    self.other = { ObjectId = 11, Room = { Name = "G_Combat02", __runPlannerExecutionRoomId = "other" },
        LockedWithEncounterChance = 0.8 }
    self.picked = { ObjectId = 12, Room = { Name = "G_Combat02", __runPlannerExecutionRoomId = "picked" },
        LockedWithEncounterChance = 0.8 }
    self.third = { ObjectId = 13, Room = { Name = "G_Combat03", __runPlannerExecutionRoomId = "third" },
        LockedWithEncounterChance = 0.8 }
    self.restore = nativeGame.install({
        MapState = { OfferedExitDoors = { [11] = self.other, [12] = self.picked, [13] = self.third } },
    })
end

function TestExitProtection:tearDown()
    self.restore()
end

-- RoomLogic.CheckExitPreUnlock's native branching, with a deterministic roll.
-- It retains the first-exit guarantee and the lock's encounter/presentation facts.
local function preUnlock(room)
    return function(door, args, index)
        room.FirstExitChosen = room.FirstExitChosen or false
        if room.LockExtraExitsWithEncounter and room.LockExtraExits and room.FirstExitChosen then
            if door.LockedWithEncounterChance and 0 <= door.LockedWithEncounterChance then
                door.SkipUnlock = true
                door.ReadyToUse = true
                door.CanBeRerolled = false
                door.EncounterCost = room.LockExtraExitsWithEncounter
            end
        else
            room.FirstExitChosen = true
        end
        return args, nil, index
    end
end

function TestExitProtection:testOceanusRetainsNativeLockingExceptOnThePickedOccurrence()
    local declaration = { Name = "G_Combat01", LockExtraExitsChance = 0.35,
        LockExtraExits = true, LockExtraExitsWithEncounter = "GeneratedG_ExtraDoor" }
    local room = assert(overview.realize(self.state.route.currentOccurrence, { RoomData = { G_Combat01 = declaration } }))
    lu.assertEquals(room.LockExtraExitsChance, 0.35)
    lu.assertTrue(room.LockExtraExits)
    local args = {}
    for index, door in ipairs({ self.other, self.picked, self.third }) do
        local returned, middle, returnedIndex = self.callbacks.CheckExitPreUnlock(nil, {}, preUnlock(room), door, args, index)
        lu.assertIs(returned, args)
        lu.assertNil(middle)
        lu.assertEquals(returnedIndex, index)
        lu.assertEquals(door.LockedWithEncounterChance, 0.8)
    end
    lu.assertNil(self.other.EncounterCost) -- native first-exit guarantee
    lu.assertNil(self.picked.EncounterCost)
    lu.assertEquals(self.third.EncounterCost, "GeneratedG_ExtraDoor")
    lu.assertTrue(self.third.SkipUnlock)
    lu.assertFalse(self.third.CanBeRerolled)
    lu.assertEquals(declaration.LockExtraExitsChance, 0.35)
end

function TestExitProtection:testLockOverrideRestoresTheOperandOnNativeError()
    local ok, message = pcall(self.callbacks.CheckExitPreUnlock, nil, {}, function(door)
        lu.assertNil(door.LockedWithEncounterChance)
        error("native lock fault")
    end, self.picked, {}, 2)
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native lock fault")
    lu.assertEquals(self.picked.LockedWithEncounterChance, 0.8)
end

function TestExitProtection:choose(values, choose)
    return self.callbacks.GetRandomValue(nil, {}, choose or function(pool) return pool[1] end, values, "native-rng")
end

-- EncounterLogic.NemesisTakeRoomExit builds its eligible list after waiting,
-- teleports for <= 1 candidate, then selects before movement and takeover.
function TestExitProtection:nativeDeparture(choose, waitAfterSelection)
    return function()
        coroutine.yield("waiting")
        local available = {}
        for _, door in ipairs({ self.picked, self.other, self.third }) do
            if door.EncounterCost == nil and (door.HealthCost == nil or 100 > door.HealthCost) then
                available[#available + 1] = door
            end
        end
        if #available <= 1 then return "teleport" end
        local selected = self:choose(available, choose)
        if waitAfterSelection then coroutine.yield(selected) end
        selected.OnUsedFunctionName = "AttemptUseDoorNemesisTookPresentation"
        return selected
    end
end

function TestExitProtection:departure(base)
    return coroutine.create(function()
        return self.callbacks.NemesisTakeRoomExit(nil, {}, base, {}, {})
    end)
end

function TestExitProtection:testNemesisSelectsOnlyOtherNativeCandidatesWithoutMutatingTheBoard()
    local calls = 0
    local thread = self:departure(self:nativeDeparture(function(pool, rng)
        calls = calls + 1
        lu.assertEquals(rng, "native-rng")
        lu.assertEquals(pool, { self.other, self.third })
        return pool[2]
    end))
    lu.assertEquals({ coroutine.resume(thread) }, { true, "waiting" })
    local ok, selected = coroutine.resume(thread)
    lu.assertTrue(ok, selected)
    lu.assertIs(selected, self.third)
    lu.assertEquals(calls, 1)
    lu.assertNil(self.picked.OnUsedFunctionName)
    lu.assertEquals(self.third.OnUsedFunctionName, "AttemptUseDoorNemesisTookPresentation")
    lu.assertIs(_G.MapState.OfferedExitDoors[12], self.picked)
end

function TestExitProtection:testNativeEligibilityAndSingleDoorTeleportRemainNative()
    self.third.EncounterCost = "GeneratedG_ExtraDoor"
    local thread = self:departure(self:nativeDeparture())
    assert(coroutine.resume(thread))
    local ok, selected = coroutine.resume(thread)
    lu.assertTrue(ok, selected)
    lu.assertIs(selected, self.other) -- exactly two native eligible doors

    self.other.HealthCost = 100 -- not native-eligible at 100 health
    thread = self:departure(self:nativeDeparture(function() error("must teleport without selecting") end))
    assert(coroutine.resume(thread))
    lu.assertEquals({ coroutine.resume(thread) }, { true, "teleport" })
    lu.assertNil(self.picked.OnUsedFunctionName)
end

function TestExitProtection:testAdditionalDestinationUsesTheSameOccurrenceBinding()
    self.picked.Room = { Name = "Chaos", __runPlannerExecutionRoomId = "picked",
        __runPlannerExecutionAdditionalOwner = "chaos", __runPlannerExecutionAdditionalKind = "chaos" }
    local thread = self:departure(self:nativeDeparture())
    assert(coroutine.resume(thread))
    local ok, selected = coroutine.resume(thread)
    lu.assertTrue(ok, selected)
    lu.assertIs(selected, self.other)
    lu.assertNil(self.picked.OnUsedFunctionName)
end

function TestExitProtection:testSelectionScopeDoesNotLeakAcrossThreadsOrIntoPresentation()
    local list = { self.picked, self.other }
    local thread = self:departure(function()
        lu.assertNil(self:choose(nil, function(pool) return pool end))
        lu.assertEquals(self:choose({ "unrelated", "presentation" }), "unrelated")
        coroutine.yield("waiting")
        lu.assertIs(self:choose(list), self.other)
        lu.assertIs(self:choose(list), self.picked) -- scope retired after the door selection
    end)
    assert(coroutine.resume(thread))
    lu.assertIs(self:choose(list), self.picked) -- different coroutine
    lu.assertTrue(coroutine.resume(thread))
    lu.assertEquals(list, { self.picked, self.other })
end

function TestExitProtection:testSelectionScopeIsClearedOnError()
    local ok, message = pcall(self.callbacks.NemesisTakeRoomExit, nil, {}, function()
        error("native Nemesis fault")
    end)
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native Nemesis fault")
    lu.assertIs(self:choose({ self.picked, self.other }), self.picked)
end

function TestExitProtection:testDepartureBecomesPassiveIfSessionOrRoomChangesWhileWaiting()
    for _, change in ipairs({
        function() self.state.state = "desynchronized" end,
        function() assert(routeSession.exit(self.state.route)) end,
    }) do
        local thread = self:departure(self:nativeDeparture())
        assert(coroutine.resume(thread))
        change()
        local ok, selected = coroutine.resume(thread)
        lu.assertTrue(ok, selected)
        lu.assertIs(selected, self.picked)
        self.state.state = "synchronized"
    end
end

function TestExitProtection:testNoPlanOrNoContinuationLeavesBothMechanismsNative()
    for _, change in ipairs({
        function() self.state.route.plan.selectedOccurrenceIds = { "current" } end,
        function() self.state.state = "desynchronized" end,
        function() self.state = nil end,
    }) do
        change()
        self.callbacks.CheckExitPreUnlock(nil, {}, function(door)
            lu.assertEquals(door.LockedWithEncounterChance, 0.8)
        end, self.picked, {}, 2)
        local selected = self.callbacks.NemesisTakeRoomExit(nil, {}, function()
            return self:choose({ self.picked, self.other })
        end)
        lu.assertIs(selected, self.picked)
    end
end

return TestExitProtection
