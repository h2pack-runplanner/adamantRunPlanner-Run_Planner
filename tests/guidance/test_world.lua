-- luacheck: globals TestGuidanceWorld
local lu = require("luaunit")
local world = require("mods.guidance.world")

TestGuidanceWorld = {}

function TestGuidanceWorld:setUp()
    self.priorAdd, self.priorDestroy = _G.AddDoorInfoIcon, _G.Destroy
    self.created, self.destroyed = {}, {}
    _G.AddDoorInfoIcon = function(args)
        args.Door.AdditionalIcons[args.Name] = #self.created + 101
        self.created[#self.created + 1] = args
    end
    _G.Destroy = function(args) self.destroyed[#self.destroyed + 1] = args.Ids[1] end
    self.route = { next = function(value) return value.nextTarget end }
    self.guidance = world.create(self.route)
    self.runtime = { data = { read = function() return true end } }
    self.state = { state = "synchronized", route = self.route }
end

function TestGuidanceWorld:tearDown()
    _G.AddDoorInfoIcon, _G.Destroy = self.priorAdd, self.priorDestroy
end

function TestGuidanceWorld:testMarksOnlyTheExactNormalDoorAndRetiresIt()
    local target = { id = "next", gameName = "F_Combat02" }
    local other = { __runPlannerExecutionDoorTarget = "other", RewardPreviewIconIds = { 1 }, AdditionalIcons = {} }
    local chosen = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 2 }, AdditionalIcons = {} }
    self.guidance.doors(self.runtime, self.state, { other, chosen }, target, { gameName = "F_Combat01" })
    lu.assertEquals(#self.created, 1)
    lu.assertIs(self.created[1].Door, chosen)
    self.guidance.clear()
    lu.assertEquals(self.destroyed, { 101 })
    lu.assertNil(chosen.AdditionalIcons.RunPlannerPlannedChoice)
end

function TestGuidanceWorld:testHubUsesPhysicalSlotForNWithoutAdvancingSideCursor()
    self.route.nextTarget = { id = "visit-two", gameName = "N_Combat02" }
    local side = { ObjectId = 1, RewardPreviewIconIds = { 1 }, AdditionalIcons = {} }
    local chosen = { ObjectId = 2, RewardPreviewIconIds = { 2 }, AdditionalIcons = {} }
    self.guidance.hub(self.runtime, self.state, { side, chosen }, { slots = {
        { physicalDoorId = 2, room = { id = "visit-two" } },
    } })
    lu.assertEquals(#self.created, 1)
    lu.assertIs(self.created[1].Door, chosen)
    self.route.nextTarget = { id = "side", gameName = "N_Side01" }
    self.guidance.hub(self.runtime, self.state, { side, chosen }, { slots = {
        { physicalDoorId = 2, room = { id = "visit-two" } },
    } })
    lu.assertEquals(self.destroyed, { 101 })
end

function TestGuidanceWorld:testMapSubiconsFollowNextVisitAndPreserveNativeIcons()
    local first, second = { ObjectId = 1 }, { ObjectId = 2 }
    local hub = { slots = {
        { physicalDoorId = 1, room = { id = "first" } },
        { physicalDoorId = 2, room = { id = "second" } },
    } }
    local native = { { Name = "NativePin" } }
    self.route.nextTarget = { id = "first" }
    self.guidance.hub(self.runtime, self.state, { first, second }, hub)
    local icons = self.guidance.mapIcons(self.runtime, self.state, first, native)
    lu.assertEquals(#icons, 2)
    lu.assertEquals(#native, 1)
    lu.assertEquals(icons[2].Animation, "RoomRewardSubIcon_ForgetMeNot")
    self.route.nextTarget = { id = "second" }
    self.guidance.hub(self.runtime, self.state, { first, second }, hub)
    lu.assertIs(self.guidance.mapIcons(self.runtime, self.state, first, native), native)
    lu.assertEquals(#self.guidance.mapIcons(self.runtime, self.state, second, native), 2)
    self.runtime.data.read = function() return false end
    lu.assertIs(self.guidance.mapIcons(self.runtime, self.state, second, native), native)
end

function TestGuidanceWorld:testMapHookOnlyAddsIconsDuringNativeMapConstruction()
    local highlights = require("mods.guidance.highlights").create(self.route)
    local callbacks = {}
    highlights.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } },
        function() return self.state end)
    local door = { ObjectId = 2 }
    self.route.nextTarget = { id = "visit" }
    highlights.hub(self.runtime, self.state, { door }, { slots = {
        { physicalDoorId = 2, room = { id = "visit" } },
    } })
    local function icons()
        return callbacks.PopulateDoorRewardPreviewSubIcons(nil, self.runtime,
            function() return { { Name = "NativePin" } } end, door, {})
    end
    lu.assertEquals(#icons(), 1)
    callbacks.EphyraZoomOut(nil, self.runtime, function() lu.assertEquals(#icons(), 2) end, {})
    lu.assertEquals(#icons(), 1)
    local ok = pcall(callbacks.EphyraZoomOut, nil, self.runtime, function() error("native error") end, {})
    lu.assertFalse(ok)
    lu.assertEquals(#icons(), 1)
end

function TestGuidanceWorld:testWheelRetainsSelectedOfferAcrossOtherPreviewAndClearsOnDisable()
    local selected = { __runPlannerOfferKey = "offer1", RewardPreviewIconIds = { 3 }, AdditionalIcons = {} }
    local other = { __runPlannerOfferKey = "offer2", RewardPreviewIconIds = { 4 }, AdditionalIcons = {} }
    self.guidance.wheel(self.runtime, self.state, selected, "offer1")
    self.guidance.wheel(self.runtime, self.state, other, "offer1")
    lu.assertEquals(#self.created, 1)
    self.runtime.data.read = function() return false end
    self.guidance.refresh(self.runtime, self.state)
    lu.assertEquals(self.destroyed, { 101 })
    self.runtime.data.read = function() return true end
    self.guidance.refresh(self.runtime, self.state)
    lu.assertEquals(#self.created, 2)
    lu.assertIs(self.created[2].Door, selected)
end

function TestGuidanceWorld:testDisabledNormalDoorRetainsItsExactBoundObjectForEnable()
    local target = { id = "next", gameName = "F_Combat02" }
    local chosen = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 2 }, AdditionalIcons = {} }
    self.runtime.data.read = function() return false end
    self.guidance.doors(self.runtime, self.state, { chosen }, target, { gameName = "F_Combat01" })
    lu.assertEquals(self.created, {})
    self.runtime.data.read = function() return true end
    self.guidance.refresh(self.runtime, self.state)
    lu.assertIs(self.created[1].Door, chosen)
end

function TestGuidanceWorld:testRouteReplacementClearsStaleWorldContextWithoutStateReplacement()
    local target = { id = "next", gameName = "F_Combat02" }
    local chosen = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 2 }, AdditionalIcons = {} }
    self.guidance.doors(self.runtime, self.state, { chosen }, target, { gameName = "F_Combat01" })
    self.state.route = {}
    self.guidance.refresh(self.runtime, self.state)
    lu.assertEquals(self.destroyed, { 101 })
end

function TestGuidanceWorld:testNormalDoorScopeRejectsNAndAmbiguousMatches()
    local target = { id = "next", gameName = "F_Combat02" }
    local first = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 2 }, AdditionalIcons = {} }
    local second = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 3 }, AdditionalIcons = {} }
    self.guidance.doors(self.runtime, self.state, { first }, target, { gameName = "N_Hub" })
    lu.assertEquals(self.created, {})
    self.guidance.doors(self.runtime, self.state, { first, second }, target, { gameName = "F_Combat01" })
    lu.assertEquals(self.created, {})
end

function TestGuidanceWorld:testGlobalPreviewAndRoomHooksRetireMarkersBeforeNativeTeardown()
    local callbacks = {}
    local guide = require("mods.guidance.highlights").create(self.route)
    guide.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } },
        function() return self.state end)
    local door = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 20 },
        AdditionalIcons = { RoomRewardSubIcon_ForgetMeNot = 80 } }
    for _, name in ipairs({ "RemoveRoomRewardPreviews", "LeaveRoom", "StartRoom" }) do
        guide.doors(self.runtime, self.state, { door }, { id = "next", gameName = "F_Combat02" },
            { gameName = "F_Combat01" })
        lu.assertNotNil(door.AdditionalIcons.RunPlannerPlannedChoice)
        lu.assertEquals(self.created[#self.created].IsoOffset, 60)
        callbacks[name](nil, self.runtime, function()
            lu.assertNil(door.AdditionalIcons.RunPlannerPlannedChoice)
            lu.assertEquals(door.AdditionalIcons.RoomRewardSubIcon_ForgetMeNot, 80)
        end, {}, {})
        guide.refresh(self.runtime, self.state)
        lu.assertNil(door.AdditionalIcons.RunPlannerPlannedChoice)
    end
end

function TestGuidanceWorld:testDesynchronizationDiscardsContextInsteadOfReplayingItLater()
    local door = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 20 } }
    self.guidance.doors(self.runtime, self.state, { door }, { id = "next", gameName = "F_Combat02" },
        { gameName = "F_Combat01" })
    self.state.state = "desynchronized"
    self.guidance.refresh(self.runtime, self.state)
    self.state.state = "synchronized"
    self.guidance.refresh(self.runtime, self.state)
    lu.assertNil(door.AdditionalIcons.RunPlannerPlannedChoice)
end

function TestGuidanceWorld:testSharedRoomNormalExitsUseTheExistingDoorSurface()
    for _, name in ipairs({ "Chaos_01", "Chaos_02", "Chaos_03", "Chaos_04", "Chaos_05", "Chaos_06",
        "C_Boss01", "B_Combat01" }) do
        local source = { gameName = name, overview = {} }
        local chosen = { __runPlannerExecutionDoorTarget = "next", RewardPreviewIconIds = { 20 } }
        local other = { __runPlannerExecutionDoorTarget = "other", RewardPreviewIconIds = { 21 } }
        local normal = require("mods.navigation.doors").partition(source, { other, chosen })
        self.guidance.doors(self.runtime, self.state, normal, { id = "next", gameName = "F_Combat02" }, source)
        lu.assertIs(self.created[#self.created].Door, chosen)
        lu.assertNotNil(chosen.AdditionalIcons.RunPlannerPlannedChoice)
        lu.assertNil(other.AdditionalIcons)
        self.guidance.clear()
    end
end

function TestGuidanceWorld:testEnteringSpecialGatesRemainsExcludedByNavigationPartition()
    for _, name in ipairs({ "Chaos_01", "C_Boss01" }) do
        local source = { gameName = "F_Combat01", overview = { additional = { { room = { id = "special" } } } } }
        local gate = { __runPlannerExecutionDoorTarget = "special", RewardPreviewIconIds = { 20 } }
        local normalDoor = { __runPlannerExecutionDoorTarget = "normal", RewardPreviewIconIds = { 21 } }
        local normal = require("mods.navigation.doors").partition(source, { normalDoor, gate })
        self.guidance.doors(self.runtime, self.state, normal, { id = "special", gameName = name }, source)
        lu.assertNil(gate.AdditionalIcons)
        lu.assertEquals(self.created, {})
    end
end

return TestGuidanceWorld
