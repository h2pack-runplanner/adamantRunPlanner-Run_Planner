-- luacheck: globals TestHubFountain
local lu = require("luaunit")
local json = require("mods/protocol/json")
local protocol = require("mods.protocol.decoder")
local route = require("mods.route.session")
local fountain = require("mods.room.timeline.interactions.fountain")
local readers = require("mods.room.conformance.readers")
local guide = require("mods.room.guide")
local navigationHooks = require("mods.navigation.hooks")
local roomHooks = require("mods.room.hooks")
local runtimeSession = require("mods.runtime.session")
local coordinator = require("mods.room.coordinator")

TestHubFountain = {}

local HUB_FOUNTAIN = 664734
local PHIAL_FIXTURE = "surface-n-phial-intermediate-fountain"

local function loadPlan(name)
    local file = assert(io.open("fixtures/execution-plan/" .. name .. ".execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return assert(protocol.decode(value))
end

local function hubOf(plan)
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.hub ~= nil then return occurrence.overview.hub end
    end
end

-- Enter and exit selected occurrences until the cursor waits at `index`.
local function advance(state, index)
    while state.route.index < index do
        local occurrence = route.expected(state.route)
        assert(route.enter(state.route, occurrence.id, occurrence.gameName))
        assert(route.exit(state.route))
    end
end

local function trait(name, rarity) return { Name = name, Rarity = rarity } end

local function attach(state, options)
    options = options or {}
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local roomCompleted, diagnostics, reports = 0, {}, 0
    local active = options.active
    local room = {
        current = function() return active end,
        resolve = function(_, context, contact)
            if context ~= nil and contact.interactionKey == "fountain" then return context.handle end
        end,
        bind = function(_, _, handle) return handle end,
        begin = function(_, handle)
            if active ~= nil and handle == active.handle then return { transaction = active.transaction } end
        end,
    }
    local session = {
        complete = function(_, handle)
            lu.assertEquals(handle, active.handle)
            roomCompleted = roomCompleted + 1
        end,
        diagnostic = function(_, checkpoint, observed)
            diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed }
        end,
    }
    fountain.attach(module, session, function() return state end, function() reports = reports + 1 end,
        room, route)
    return {
        callbacks = callbacks,
        setActive = function(value) active = value end,
        roomCompleted = function() return roomCompleted end,
        diagnostics = function() return diagnostics end,
        reports = function() return reports end,
    }
end

-- Native fountain use whose Phial rarity mutation is threaded after return.
local function useFountain(hooks, source, phial, mutate)
    local delayed
    local result = hooks.callbacks.UseHealthFountain(nil, {}, function()
        delayed = function(nativeRarity)
            return hooks.callbacks.AddRarityToTraits(nil, {}, nativeRarity or function(_, args)
                local upgraded = args.ForceUpgrade and args.ForceUpgrade[1]
                if mutate then mutate(upgraded) end
                return upgraded
            end, phial, { NumTraits = 1 })
        end
        local nativeRoom = _G.CurrentRun.CurrentRoom
        nativeRoom.ObjectStates = nativeRoom.ObjectStates or {}
        nativeRoom.ObjectStates[source.ObjectId] = { UseableOff = true }
        return "used"
    end, source, {})
    return result, delayed
end

local function hubState(plan)
    return { state = "synchronized", plan = plan, route = route.new(plan) }
end

local function withRun(traits, fn)
    local prior = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Name = "N_Hub" }, Hero = { Traits = traits } }
    local ok, errorValue = pcall(fn, _G.CurrentRun)
    _G.CurrentRun = prior
    if not ok then error(errorValue, 0) end
end

local function phialTrait() return { Name = "FountainRarityKeepsake", Uses = 1, FountainRarity = {} } end

function TestHubFountain.testExportedPhialPlanClaimsAfterThirdVisitAndNextRoomConformanceSeesTarget()
    local plan = loadPlan(PHIAL_FIXTURE)
    local hub = hubOf(plan)
    lu.assertEquals(hub.fountain.precedingVisitCount, 3)
    lu.assertEquals(hub.fountain.aromaticPhialTarget, "AresSpecialBoon")
    local state = hubState(plan)
    local hooks = attach(state)
    local target, other, phial = trait("AresSpecialBoon", "Common"), trait("ApolloWeaponBoon", "Common"),
        phialTrait()
    withRun({ other, target, phial }, function()
        -- Initial Hub entry and the first two returns do not own the use.
        for _, index in ipairs({ 3, 6, 7 }) do
            advance(state, index)
            lu.assertNil(route.dueHubFountain(state.route))
        end
        advance(state, 9)
        lu.assertEquals(route.expected(state.route).id, "surface-n-combat11")
        lu.assertEquals(route.dueHubFountain(state.route), hub)

        local result, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial, function(upgraded)
            upgraded.Rarity = "Heroic"
        end)
        lu.assertEquals(result, "used")
        lu.assertFalse(state.route.hubFountainClaim.completed)
        lu.assertEquals(delayed(), target)
        lu.assertTrue(state.route.hubFountainClaim.completed)
        lu.assertEquals(other.Rarity, "Common")
    end)
    lu.assertEquals(hooks.diagnostics(), {})

    local nextRoom = plan.occurrencesById["surface-n-combat11"]
    local expected = nextRoom.conformanceExpected.traitInventory
    local levels = {}
    local traits = {}
    for _, row in ipairs(expected.present) do
        levels[row.traitKey] = row.level
        traits[#traits + 1] = row.traitKey == "AresSpecialBoon" and target or trait(row.traitKey, row.rarity)
    end
    local priorCount = _G.GetTraitCount
    _G.GetTraitCount = function(_, args) return levels[args.Name] end
    local observed = readers.read("traitInventory", { Hero = { Traits = traits } }, nil, expected)
    _G.GetTraitCount = priorCount
    lu.assertEquals(observed, expected)
end

function TestHubFountain.testInitialAndFinalHubUsesBindWithoutTarget()
    for _, case in ipairs({ { count = 0, index = 3 }, { count = 6, index = 13 } }) do
        local plan = loadPlan("surface-n")
        local hub = hubOf(plan)
        hub.fountain.precedingVisitCount = case.count
        local state = hubState(plan)
        local hooks = attach(state)
        withRun({}, function()
            advance(state, case.index)
            lu.assertEquals(route.dueHubFountain(state.route), hub)
            lu.assertEquals(useFountain(hooks, { ObjectId = HUB_FOUNTAIN }), "used")
            lu.assertTrue(state.route.hubFountainClaim.completed)
            lu.assertNil(route.dueHubFountain(state.route))
        end)
        lu.assertEquals(hooks.reports(), 1)
    end
end

function TestHubFountain.testOneClaimAndUnrelatedFountainsAndRarityEffectsKeepNativeBehavior()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    local hooks = attach(state)
    local target, phial = trait("AresSpecialBoon", "Common"), phialTrait()
    withRun({ target, phial }, function(run)
        advance(state, 9)
        -- A different obstacle, and the Hub fountain outside a synchronized session.
        useFountain(hooks, { ObjectId = 1 }, phial)
        state.state = "desynchronized"
        useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
        state.state = "synchronized"
        lu.assertNil(state.route.hubFountainClaim)
        run.CurrentRoom = { Name = "N_Combat11" }
        useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
        lu.assertNil(state.route.hubFountainClaim)
        run.CurrentRoom = { Name = "N_Hub" }

        local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
        local claim = state.route.hubFountainClaim
        lu.assertNotNil(claim)
        local unrelated = hooks.callbacks.AddRarityToTraits(nil, {}, function(source, args)
            lu.assertEquals(source.Name, "OtherRaritySource")
            lu.assertNil(args.ForceUpgrade)
            return "native"
        end, { Name = "OtherRaritySource" }, {})
        lu.assertEquals(unrelated, "native")
        lu.assertEquals(delayed(), target)
        lu.assertTrue(claim.completed)
        useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
        lu.assertEquals(state.route.hubFountainClaim, claim)
    end)
end

local function assertNativeRarity(delayed)
    local calls = 0
    delayed(function(_, args)
        calls = calls + 1
        lu.assertNil(args.ForceUpgrade)
        return "native"
    end)
    lu.assertEquals(calls, 1)
end

function TestHubFountain.testScopeCancelsOnReplacementResyncDesyncAndHubLoss()
    for _, invalidate in ipairs({
        function(state) state.route = route.new(state.plan) end,
        function(state) state.route = assert(route.newAt(state.plan, 9)) end,
        function(state) state.state = "desynchronized" end,
        function() _G.CurrentRun.CurrentRoom = { Name = "N_Combat11" } end,
        function(state)
            local occurrence = route.expected(state.route)
            assert(route.enter(state.route, occurrence.id, occurrence.gameName))
        end,
    }) do
        local plan = loadPlan(PHIAL_FIXTURE)
        local state = hubState(plan)
        local hooks = attach(state)
        local phial = phialTrait()
        withRun({ trait("AresSpecialBoon", "Common"), phial }, function()
            advance(state, 9)
            local routeState = state.route
            local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
            invalidate(state)
            assertNativeRarity(delayed)
            lu.assertFalse(routeState.hubFountainClaim.completed)
        end)
    end
end

function TestHubFountain.testFailuresReleaseOrRetainTheClaimWithoutLeakingScope()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    local hooks = attach(state)
    local phial = phialTrait()
    withRun({ trait("AresSpecialBoon", "Common"), phial }, function()
        advance(state, 9)
        local ok = pcall(hooks.callbacks.UseHealthFountain, nil, {}, function() error("native") end,
            { ObjectId = HUB_FOUNTAIN }, {})
        lu.assertFalse(ok)
        lu.assertNil(state.route.hubFountainClaim)

        local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
        local threaded = pcall(delayed, function() error("threaded rarity") end)
        lu.assertFalse(threaded)
        lu.assertFalse(state.route.hubFountainClaim.completed)
        assertNativeRarity(delayed)
        lu.assertFalse(state.route.hubFountainClaim.completed)
    end)
end

function TestHubFountain.testMissingCallbackDoesNotLeakIntoALaterFountain()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    local hooks = attach(state)
    local phial = phialTrait()
    withRun({ trait("AresSpecialBoon", "Common"), phial }, function(run)
        advance(state, 9)
        local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, phial)
        lu.assertNotNil(delayed)
        local claim = state.route.hubFountainClaim
        -- The Phial callback never arrives; an unrelated fountain in the same Hub follows.
        local _, unrelated = useFountain(hooks, { ObjectId = 2 }, phial)
        assertNativeRarity(unrelated)
        run.CurrentRoom = { Name = "N_Reprieve01" }
        hooks.setActive({ handle = {}, transaction = { kind = "fountainUse", interactionKey = "fountain" } })
        local _, later = useFountain(hooks, { ObjectId = 5 }, phial)
        lu.assertEquals(hooks.roomCompleted(), 1)
        assertNativeRarity(later)
        lu.assertFalse(claim.completed)
    end)
end

function TestHubFountain.testGuideShowsTheHubUseOnlyAtItsOrderedPosition()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    local hooks = attach(state)
    local function project()
        state.route.transparentNativeRoom = "N_Hub"
        return guide.project({ kind = "navigation", nativeRoomName = "N_Hub",
            navigation = route.guideNavigation(state.route) })
    end
    withRun({ phialTrait() }, function()
        advance(state, 7)
        lu.assertEquals(project().rows, {})
        advance(state, 9)
        local projection = project()
        lu.assertEquals(projection.rows, { { instruction = "Use fountain — Phial: planned trait" } })
        lu.assertStrContains(projection.footer, "Next visit")
        useFountain(hooks, { ObjectId = HUB_FOUNTAIN })
        lu.assertEquals(project().rows, {})
    end)
end

-- Hub LeaveRoom through the real room and navigation contacts and runtime session.
local function leaveHub(state)
    local diagnostics = {}
    local session = setmetatable({
        diagnostic = function(_, checkpoint, observed, occurrence)
            diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, observed = observed,
                occurrenceId = occurrence and occurrence.id }
        end,
    }, { __index = runtimeSession })
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local navigation = navigationHooks.attach(module, session, function() return state end, function() end,
        route, {})
    roomHooks.attach(module, session, function() return state end, function() end, route, {}, nil,
        navigation, { synchronizeStartingRoom = function() return true end })
    state.route.transparentNativeRoom = "N_Hub"
    local priorCount = _G.GetTraitCount
    _G.GetTraitCount = function(hero, args)
        local count = 0
        for _, value in ipairs(hero.Traits) do if value.Name == args.Name then count = count + 1 end end
        return count
    end
    callbacks.LeaveRoom(nil, {}, function() return "left" end, _G.CurrentRun, {})
    _G.GetTraitCount = priorCount
    return diagnostics
end

local function missed(observed)
    return { { checkpoint = "hub-fountain", observed = observed or "missed", occurrenceId = "surface-n-prehub" } }
end

-- The Phial fixture's traits before its Hub fountain use.
local function phialTraits()
    return {
        trait("ApolloWeaponBoon", "Common"), trait("AresSpecialBoon", "Common"),
        trait("HermesWeaponBoon", "Common"), trait("HephaestusCastBoon", "Common"), phialTrait(),
    }
end

local function heroic(value) value.Rarity = "Heroic" end

local function assertTraitMismatch(state)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "hub-departure-conformance:traitInventory")
end

local function upgradeNatively(name)
    return function()
        for _, value in ipairs(_G.CurrentRun.Hero.Traits) do
            if value.Name == name then value.Rarity = "Heroic"; return value end
        end
    end
end

function TestHubFountain.testDueForcedUseMatchesTheHubDepartureInventory()
    local plan = loadPlan(PHIAL_FIXTURE)
    lu.assertNotNil(hubOf(plan).fountain.departureConformance)
    local state = hubState(plan)
    local hooks = attach(state)
    withRun(phialTraits(), function(run)
        advance(state, 9)
        local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, run.Hero.Traits[5], heroic)
        delayed()
        lu.assertEquals(leaveHub(state), {})
        lu.assertEquals(state.state, "synchronized")
        lu.assertNil(state.firstMismatch)
    end)
end

function TestHubFountain.testSkippedPhialUseIsATraitInventoryMismatchAtItsDeparture()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    withRun(phialTraits(), function()
        advance(state, 7)
        lu.assertEquals(leaveHub(state), {})
        lu.assertEquals(state.state, "synchronized")
        advance(state, 9)
        lu.assertEquals(leaveHub(state), missed())
        assertTraitMismatch(state)
    end)
end

function TestHubFountain.testEarlyPhialUseIsJudgedByItsUpgradeAtTheDueDeparture()
    for _, case in ipairs({ { "ApolloWeaponBoon", false }, { "AresSpecialBoon", true } }) do
        local plan = loadPlan(PHIAL_FIXTURE)
        local state = hubState(plan)
        local hooks = attach(state)
        withRun(phialTraits(), function(run)
            advance(state, 7)
            local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, run.Hero.Traits[5])
            delayed(upgradeNatively(case[1]))
            lu.assertNil(state.route.hubFountainClaim)
            leaveHub(state)
            advance(state, 9)
            lu.assertEquals(leaveHub(state), missed())
            if case[2] then
                lu.assertEquals(state.state, "synchronized")
            else
                assertTraitMismatch(state)
            end
        end)
    end
end

function TestHubFountain.testUseWithoutPublishedInventoryIsOnlyDiagnosticWhenSkippedOrMisordered()
    local plan = loadPlan("surface-n")
    lu.assertNil(hubOf(plan).fountain.departureConformance)
    local state = hubState(plan)
    local hooks = attach(state)
    withRun({}, function()
        advance(state, 3)
        lu.assertEquals(leaveHub(state), missed())
        advance(state, 6)
        useFountain(hooks, { ObjectId = HUB_FOUNTAIN })
        lu.assertEquals(leaveHub(state), {})
        lu.assertEquals(state.state, "synchronized")
    end)
end

function TestHubFountain.testUnfinishedClaimIsDiagnosticAndItsInventoryStillDecides()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    local hooks = attach(state)
    withRun(phialTraits(), function(run)
        advance(state, 9)
        local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, run.Hero.Traits[5])
        lu.assertFalse(pcall(delayed, function() error("threaded rarity") end))
        lu.assertEquals(leaveHub(state), missed("incomplete"))
        assertTraitMismatch(state)
    end)
end

-- A resynchronized route cannot know whether a spent fountain honored the Phial.
function TestHubFountain.testSpentFountainAfterResyncIsDiagnosticAndStillChecksItsInventory()
    for _, case in ipairs({ { "surface-n", 3, {} }, { PHIAL_FIXTURE, 9, phialTraits() } }) do
        local plan = loadPlan(case[1])
        local state = hubState(plan)
        withRun(case[3], function(run)
            advance(state, case[2])
            for _, value in ipairs(run.Hero.Traits) do
                if value.Name == "AresSpecialBoon" then value.Rarity = "Heroic" end
            end
            run.CurrentRoom.ObjectStates = { [HUB_FOUNTAIN] = { UseableOff = true } }
            state.route = assert(route.newAt(plan, case[2]))
            lu.assertNil(route.dueHubFountain(state.route, true))
            state.route.transparentNativeRoom = "N_Hub"
            lu.assertEquals(guide.project({ kind = "navigation", nativeRoomName = "N_Hub",
                navigation = route.guideNavigation(state.route, true) }).rows, {})
            lu.assertEquals(leaveHub(state), missed("unobserved"))
            lu.assertEquals(state.state, "synchronized")
            lu.assertNil(state.route.hubFountainClaim)
        end)
    end
end

-- Room exits compare their own entry and exit, planned against the pre-fountain rarity.
function TestHubFountain.testEarlyMatchingUpgradeBeforeAnInventoryVisitMismatchesThatRoomExit()
    local plan = loadPlan(PHIAL_FIXTURE)
    local state = hubState(plan)
    state.room = coordinator.new(plan, function(errorValue, expected, observed)
        return runtimeSession.mismatch(state, errorValue, expected, observed)
    end, {
        onFault = function(errorValue) return runtimeSession.fault(state, errorValue) end,
        readConformance = runtimeSession.readConformance,
    })
    local hooks = attach(state)
    withRun(phialTraits(), function(run)
        advance(state, 6)
        local ares = run.Hero.Traits[2]
        local _, delayed = useFountain(hooks, { ObjectId = HUB_FOUNTAIN }, run.Hero.Traits[5])
        delayed(upgradeNatively("AresSpecialBoon"))
        lu.assertEquals(ares.Rarity, "Heroic")
        lu.assertEquals(leaveHub(state), {})

        local visit = route.expected(state.route)
        lu.assertEquals(visit.id, "surface-n-miniBoss01")
        assert(route.enter(state.route, visit.id, visit.gameName))
        assert(coordinator.enter(state, visit))
        run.CurrentRoom = { Name = visit.gameName }
        local expected = visit.conformanceExpected
        local traits = {}
        for _, row in ipairs(expected.traitInventory.present) do
            traits[#traits + 1] = row.traitKey == "AresSpecialBoon" and ares or trait(row.traitKey, row.rarity)
        end
        run.Hero.Traits, run.Hero.Elements = traits, expected.elementCounts

        local callbacks = {}
        local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
        roomHooks.attach(module, runtimeSession, function() return state end, function() end, route,
            coordinator, nil, { proveOutgoingDoors = function() return true end },
            { synchronizeStartingRoom = function() return true end })
        local priorCount = _G.GetTraitCount
        _G.GetTraitCount = function() return 1 end
        callbacks.LeaveRoom(nil, {}, function() return "left" end, run, {})
        _G.GetTraitCount = priorCount
    end)
    lu.assertEquals(state.state, "desynchronized")
    local mismatch = state.firstMismatch
    lu.assertEquals(mismatch.checkpoint, "room-exit-conformance:traitInventory")
    local function rarity(inventory)
        for _, row in ipairs(inventory.present) do
            if row.traitKey == "AresSpecialBoon" then return row.rarity end
        end
    end
    lu.assertEquals(rarity(mismatch.expected), "Common")
    lu.assertEquals(rarity(mismatch.observed), "Heroic")
end
