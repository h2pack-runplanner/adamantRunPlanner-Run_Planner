-- luacheck: globals TestRoomGuide
local lu = require("luaunit")
local guide = require("mods.room.guide")
local json = require("mods.protocol.json")
local protocol = require("mods.protocol.decoder")
local route = require("mods.route.session")

TestRoomGuide = {}

function TestRoomGuide.tearDown()
    _G.GetDisplayName = nil
end

local function row(kind, owner, extra)
    local value = { key = kind, description = { kind = kind } }
    if owner ~= nil then value.transactionOwner = owner end
    for key, nested in pairs(extra or {}) do value.description[key] = nested end
    return value
end

local function room(rows, completed, nextOccurrence)
    return {
        kind = "room",
        occurrence = { gameName = "N_Combat01", roomGuide = rows },
        isCompleted = function(owner) return completed and completed[owner] == true end,
        navigation = nextOccurrence and { kind = "next", occurrence = nextOccurrence } or nil,
    }
end

function TestRoomGuide.testConversionsDescribeTheSourceAndKeepReplacementSeparate()
    for _, kind in ipairs({ "interactIncomingReward", "interactLocalReward", "interactWheelReward",
        "interactAcquisitionEntry" }) do
        local snapshot = room({
            row(kind, "convert", { reward = { rewardType = "MetaCardPointsCommonDrop" } }),
            row("interactAcquisitionEntry", "replacement", { reward = { rewardType = "WeaponUpgrade" } }),
            row(kind, nil, { conversion = "timePiece", reward = { rewardType = "StackUpgrade" } }),
        })
        snapshot.occurrence.transactionsByOwner = {
            convert = { kind = "acquisition", roles = { { disposition = "artificer" } } },
            replacement = { kind = "acquisition", roles = { { disposition = "normal",
                producer = { kind = "artificerReplacement" } } } },
        }
        lu.assertEquals(guide.project(snapshot).rows, {
            { number = "1.", instruction = "Use Artificer on Ashes" },
            { number = "2.", instruction = "Collect Hammer" },
            { number = "3.", instruction = "Use Time Piece on Pom" },
        })
    end
end

function TestRoomGuide.testShopLabelsUseResolvedGodWithoutDuplicatingCarrierName()
    for _, case in ipairs({
        { "BlindBoxLoot", "DemeterUpgrade", "RandomLootGiftItem", "Buy Mystery Boon — Demeter" },
        { "RandomLoot", "HeraUpgrade", "BoostedRandomLoot", "Buy Boosted Boon — Hera" },
        { "StackUpgradeBig", nil, "StackUpgradeBig", "Buy Double Pom" },
    }) do
        local snapshot = room({ row("interactShopOffer", "buy", { offerKey = "slot" }) })
        snapshot.occurrence.overview = { shop = { offers = {
            { offerKey = "slot", optionKey = case[3], rewardType = case[1], source = "BlindBoxLoot" },
        } } }
        snapshot.occurrence.transactionsByOwner = { buy = {
            kind = "acquisition", reward = { rewardType = case[1], source = case[2] }, roles = {},
        } }
        lu.assertEquals(guide.project(snapshot).rows[1].instruction, case[4])
    end
    local snapshot = room({ row("interactShopOffer", nil, { offerKey = "slot", conversion = "timePiece" }) })
    snapshot.occurrence.overview = { shop = { offers = {
        { offerKey = "slot", rewardType = "StackUpgrade" },
    } } }
    lu.assertEquals(guide.project(snapshot).rows[1].instruction, "Use Time Piece on Pom")
end

function TestRoomGuide.testNativeMarkupIsRemovedFromRowsAndNavigation()
    _G.GetDisplayName = function(args)
        return ({ GiftDrop = "{!Icons.Gift} {!Format.Bold}Nectar{!Format.Reset}",
            ExampleWellItem = "{!Icons.Health} Well Item",
            ExampleRoom = "{!Format.Bold}Next Room{!Format.Reset}" })[args.Text]
    end
    local snapshot = room({
        row("interactLocalReward", nil, { reward = { rewardType = "GiftDrop" } }),
        row("purchaseStygianWellOffer", nil, { itemKey = "ExampleWellItem" }),
    }, nil, { gameName = "ExampleRoom", overview = { incomingReward = { rewardType = "GiftDrop" } } })
    local projection = guide.project(snapshot)
    lu.assertEquals(projection.rows[1].instruction, "Collect Nectar")
    lu.assertEquals(projection.rows[2].instruction, "Buy Well Item")
    lu.assertEquals(projection.footer, "Next: Next Room — Nectar")
end

function TestRoomGuide.testWheelChoiceUsesThePublishedPickedReward()
    local snapshot = room({ row("chooseRewardWheel", "wheel", { wheelKey = "wheel2" }) })
    snapshot.occurrence.overview = { rewardWheels = {
        { wheelKey = "wheel2", pickedOfferKey = "offer2", offers = {
            { offerKey = "offer1", reward = { rewardType = "WeaponUpgrade" } },
            { offerKey = "offer2", reward = { rewardType = "Boon", source = "ZeusUpgrade" } },
        } },
    } }
    lu.assertEquals(guide.project(snapshot).rows[1].instruction, "Choose Boon — Zeus at wheel")
end

function TestRoomGuide.testHidesOutOfOrderCompletedOwnersWithoutCompletingInformation()
    local projection = guide.project(room({
        row("completeFieldsCage", nil, { phaseKey = "Cage01" }),
        row("interactLocalReward", "first"),
        row("completeFieldsCage", nil, { phaseKey = "Cage02" }),
        row("interactLocalReward", "later"),
    }, { later = true }))
    lu.assertEquals(projection.rows, {
        { number = "1.", instruction = "Clear Cage 1" },
        { number = "2.", instruction = "Collect reward" },
        { number = "3.", instruction = "Clear Cage 2" },
    })
end

function TestRoomGuide.testLongWindowAnchorsTheFirstPendingOwnerAndCountsOnlyOmittedReminders()
    local rows = {
        row("completeFieldsCage", nil, { phaseKey = "Cage01" }),
        row("completeFieldsCage", nil, { phaseKey = "Cage02" }),
        row("completeFieldsCage", nil, { phaseKey = "Cage03" }),
        row("completeFieldsCage", nil, { phaseKey = "Cage04" }),
        row("interactLocalReward", "pending"),
        row("completeFieldsCage", nil, { phaseKey = "Cage05" }),
        row("interactLocalReward", "later"),
        row("completeFieldsCage", nil, { phaseKey = "Cage06" }),
        row("interactLocalReward", "latest"),
    }
    local projection = guide.project(room(rows))
    lu.assertEquals(projection.rows[1].number, "4.")
    lu.assertEquals(projection.rows[2], { number = "5.", instruction = "Collect reward" })
    lu.assertEquals(#projection.rows, 6)
    lu.assertEquals(projection.footer, "3 additional reminders")
end

function TestRoomGuide.testTimePieceWordingAndGenericFallbackNeverExposeOpaqueKeys()
    local projection = guide.project(room({
        row("interactIncomingReward", nil, { conversion = "timePiece", reward = { source = "Opaque" } }),
        row("sellPurgingPoolTrait", nil, { traitKey = "OpaqueTrait" }),
    }))
    lu.assertEquals(projection.rows, {
        { number = "1.", instruction = "Use Time Piece on reward" },
        { number = "2.", instruction = "Sell trait at Pool" },
    })
    local shop = guide.project({
        kind = "room",
        occurrence = {
            gameName = "N_PreBoss01",
            roomGuide = { row("interactShopOffer", "shop", { offerKey = "MixedProgress2" }) },
            overview = { shop = { offers = {
                { offerKey = "MixedProgress2", optionKey = "BoostedRandomLoot", rewardType = "RandomLoot", source = "ApolloUpgrade" },
            } } },
        },
        isCompleted = function() return false end,
    })
    lu.assertEquals(shop.rows, { { number = "1.", instruction = "Buy Boosted Boon — Apollo" } })
end

function TestRoomGuide.testRoomReplacementNavigationAndSessionLossReplaceRatherThanReplayRows()
    local first = guide.project(room({ row("interactIncomingReward", "one") }, nil, {
        gameName = "N_Combat02", overview = { incomingReward = { rewardType = "Boon" } },
    }))
    local replacement = guide.project(room({ row("useFountain", "two") }))
    local restored = guide.project({
        kind = "navigation", nativeRoomName = "N_Hub",
        navigation = { kind = "next", occurrence = { gameName = "N_Combat02", overview = {} } },
    })
    lu.assertEquals(first.rows[1].number, "1.")
    lu.assertEquals(first.header, "Room guide: N_Combat01")
    lu.assertEquals(first.footer, "Next: N_Combat02 — Boon")
    lu.assertEquals(replacement.rows, { { number = "1.", instruction = "Use fountain" } })
    lu.assertEquals(restored.rows, {})
    lu.assertEquals(restored.footer, "Next: N_Combat02")
    lu.assertNil(guide.project(nil))
end

function TestRoomGuide.testRouteOwnedNavigationUsesPublishedHubAndSideRelationships()
    local side = { id = "side", gameName = "N_Sub01", overview = {} }
    local secondSide = { id = "second-side", gameName = "N_Sub02", overview = {} }
    local parent = {
        id = "parent", gameName = "N_Combat05",
        overview = { localSlots = { { room = { id = "side" } }, { room = { id = "second-side" } } } },
    }
    local nextMain = { id = "next-main", gameName = "N_Combat02", overview = {} }
    local preboss = { id = "preboss", gameName = "N_PreBoss01", overview = {} }
    local hub = {
        id = "prehub", gameName = "N_PreHub01",
        overview = { hub = { room = { gameName = "N_Hub" },
            slots = { { room = { id = "parent" } }, { room = { id = "next-main" } } },
            finalHandoff = { id = "preboss" },
        } },
    }
    local state = route.new({
        selectedOccurrenceIds = { "parent", "side", "second-side", "next-main", "preboss" },
        occurrencesById = {
            side = side, ["second-side"] = secondSide, parent = parent,
            prehub = hub, ["next-main"] = nextMain, preboss = preboss,
        },
    })
    assert(route.enter(state, "parent", "N_Combat05"))
    lu.assertEquals(route.guideNavigation(state), { kind = "next", occurrence = side })
    assert(route.exit(state))
    assert(route.enter(state, "side", "N_Sub01"))
    lu.assertEquals(route.guideNavigation(state), { kind = "return", gameName = "N_Combat05" })
    assert(route.exit(state))
    state.transparentNativeRoom = "N_Combat05"
    lu.assertEquals(route.guideNavigation(state), { kind = "next", occurrence = secondSide })
    assert(route.enter(state, "second-side", "N_Sub02"))
    assert(route.exit(state))
    state.transparentNativeRoom = "N_Combat05"
    lu.assertEquals(route.guideNavigation(state), { kind = "return", gameName = "N_Hub" })
    state.transparentNativeRoom = "N_Hub"
    lu.assertEquals(route.guideNavigation(state), { kind = "next", occurrence = nextMain })
    assert(route.enter(state, "next-main", "N_Combat02"))
    lu.assertEquals(route.guideNavigation(state), { kind = "return", gameName = "N_Hub" })
    assert(route.exit(state))
    state.transparentNativeRoom = "N_Hub"
    lu.assertEquals(route.guideNavigation(state), { kind = "next", occurrence = preboss })
end

function TestRoomGuide.testOPhaseProgressKeepsOneGuideAndTerminalPrefixHasNoFooter()
    local snapshot = room({
        row("chooseRewardWheel", "choice"),
        row("interactWheelReward", "reward"),
        row("interactEncounter", "encounter"),
    })
    local first = guide.project(snapshot)
    snapshot.isCompleted = function(owner) return owner == "choice" end
    local later = guide.project(snapshot)
    lu.assertEquals(first.header, later.header)
    lu.assertEquals(later.rows, {
        { number = "2.", instruction = "Collect reward" },
        { number = "3.", instruction = "Complete encounter" },
    })
    lu.assertNil(later.footer)
end

function TestRoomGuide.testRealFieldsSixRowGuideFitsTheCompactWindow()
    local file = assert(io.open("fixtures/execution-plan/underworld-fgh.execution.json", "rb"))
    local raw = file:read("*a")
    file:close()
    local plan = assert(protocol.decode(assert(json.decode(raw))))
    local fields
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.id == "golden-h-combat05" then fields = occurrence; break end
    end
    local projection = guide.project({
        kind = "room", occurrence = assert(fields), isCompleted = function() return false end,
    })
    lu.assertEquals(#projection.rows, 6)
    lu.assertNil(projection.footer)
    local reversed = assert(plan.occurrencesById["golden-h-combat02"])
    local reversedProjection = guide.project({
        kind = "room", occurrence = reversed, isCompleted = function() return false end,
    })
    lu.assertEquals(reversedProjection.rows[1].instruction, "Clear Cage 2 — Max Magick")
    lu.assertEquals(reversedProjection.rows[3].instruction, "Clear Cage 1 — Max Health")
end

function TestRoomGuide.testCageRewardNamesDoNotDependOnPickupTransactions()
    local snapshot = room({
        row("completeFieldsCage", nil, { phaseKey = "Cage01", reward = { rewardType = "Boon", source = "HeraUpgrade" } }),
        row("completeFieldsCage", nil, { phaseKey = "Cage02", reward = { rewardType = "StackUpgrade" } }),
        row("interactLocalReward", nil, { conversion = "timePiece", reward = { rewardType = "StackUpgrade" } }),
    })
    lu.assertEquals(guide.project(snapshot).rows, {
        { number = "1.", instruction = "Clear Cage 1 — Hera" },
        { number = "2.", instruction = "Clear Cage 2 — Pom" },
        { number = "3.", instruction = "Use Time Piece on Pom" },
    })
end

function TestRoomGuide.testOverlayRefreshesOnlyOnProjectionChangesAndClearsOnToggle()
    local callbacks, lines, tables, refreshes = {}, {}, {}, 0
    local enabled, snapshot, failInspection = true, room({ row("interactIncomingReward", "one") }), false
    local module = {
        overlays = {
            order = { module = 30 },
            createLine = function(name, spec) lines[name] = spec end,
            createTable = function(name, spec) tables[name] = spec end,
            onCommit = function(callback) callbacks.commit = callback end,
            onInterval = function(_, seconds, callback)
                callbacks.interval, callbacks.seconds = callback, seconds
            end,
        },
    }
    guide.attach(module, function()
        if failInspection then error("presentation failure") end
        return snapshot
    end)
    lu.assertNotNil(lines["room-guide-header"])
    local overlay = {
        setLine = function(name, value) lines[name].value = value end,
        setTable = function(name, value) tables[name].value = value end,
        refreshOwned = function() refreshes = refreshes + 1 end,
    }
    local runtime = { data = { read = function() return enabled end } }
    callbacks.commit(nil, runtime, overlay)
    callbacks.interval(nil, runtime, overlay)
    lu.assertEquals(callbacks.seconds, 0.25)
    lu.assertEquals(refreshes, 1)
    lu.assertEquals(tables["room-guide-rows"].value, {
        { number = "1.", instruction = "Collect reward" },
    })
    enabled = false
    callbacks.interval(nil, runtime, overlay)
    lu.assertEquals(refreshes, 2)
    lu.assertEquals(tables["room-guide-rows"].value, {})
    snapshot = nil
    enabled = true
    callbacks.interval(nil, runtime, overlay)
    lu.assertEquals(refreshes, 2)
    failInspection = true
    lu.assertTrue(pcall(callbacks.interval, nil, runtime, overlay))
    lu.assertEquals(refreshes, 2)
end
