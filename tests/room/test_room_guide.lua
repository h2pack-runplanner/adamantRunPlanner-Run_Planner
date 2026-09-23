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
            { instruction = "Use Artificer on Ashes" },
            { instruction = "Collect Hammer" },
            { instruction = "Use Time Piece on Pom" },
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
    snapshot.navigation.reward = { rewardType = "GiftDrop" }
    local projection = guide.project(snapshot)
    lu.assertEquals(projection.rows[1].instruction, "Collect Nectar")
    lu.assertEquals(projection.rows[2].instruction, "Buy Well Item")
    lu.assertEquals(projection.footer, "Next door: Nectar")
end

function TestRoomGuide.testWheelChoiceUsesThePublishedPickedReward()
    local snapshot = room({ row("chooseRewardWheel", "wheel", { wheelKey = "wheel2" }) })
    snapshot.occurrence.overview = { rewardWheels = {
        { wheelKey = "wheel2", pickedOfferKey = "offer2", offers = {
            { offerKey = "offer1", reward = { rewardType = "WeaponUpgrade" } },
            { offerKey = "offer2", reward = { rewardType = "Boon", source = "ZeusUpgrade" } },
        } },
    } }
    lu.assertEquals(guide.project(snapshot).rows[1].instruction, "Wheel: Zeus boon")
end

function TestRoomGuide.testHidesOutOfOrderCompletedOwnersWithoutCompletingInformation()
    local projection = guide.project(room({
        row("completeFieldsCage", nil, { phaseKey = "Cage01" }),
        row("interactLocalReward", "first"),
        row("completeFieldsCage", nil, { phaseKey = "Cage02" }),
        row("interactLocalReward", "later"),
    }, { later = true }))
    lu.assertEquals(projection.rows, {
        { instruction = "Clear Cage 1" },
        { instruction = "Collect reward" },
        { instruction = "Clear Cage 2" },
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
    lu.assertEquals(projection.rows[1].instruction, "Clear Cage 4")
    lu.assertEquals(projection.rows[2], { instruction = "Collect reward" })
    lu.assertEquals(#projection.rows, 6)
    lu.assertEquals(projection.footer, "3 hidden reminders")
end

function TestRoomGuide.testTimePieceWordingAndGenericFallbackNeverExposeOpaqueKeys()
    local projection = guide.project(room({
        row("interactIncomingReward", nil, { conversion = "timePiece", reward = { source = "Opaque" } }),
        row("sellPurgingPoolTrait", nil, { traitKey = "OpaqueTrait" }),
    }))
    lu.assertEquals(projection.rows, {
        { instruction = "Use Time Piece on reward" },
        { instruction = "Sell trait" },
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
    lu.assertEquals(shop.rows, { { instruction = "Buy Boosted Boon — Apollo" } })
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
    lu.assertEquals(first.rows[1].instruction, "Collect reward")
    lu.assertEquals(first.header, "Ephyra · Combat 01")
    lu.assertEquals(first.footer, "Next: Ephyra · Combat 02")
    lu.assertEquals(replacement.rows, { { instruction = "Use fountain" } })
    lu.assertEquals(restored.rows, {})
    lu.assertEquals(restored.footer, "Next: Ephyra · Combat 02")
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
    lu.assertEquals(route.guideNavigation(state), { kind = "next", occurrence = nextMain, hubVisit = true })
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
        { instruction = "Collect reward" },
        { instruction = "Complete encounter" },
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
        { instruction = "Clear Cage 1 — Hera" },
        { instruction = "Clear Cage 2 — Pom" },
        { instruction = "Use Time Piece on Pom" },
    })
end

function TestRoomGuide.testNpcNamesUsePublishedGiverAndGorgonDoesNotBorrowTheRoomEncounter()
    local snapshot = room({
        row("interactEncounter", "story"),
        row("interactEncounter", nil, { encounterKey = "IcarusCombatO" }),
        row("interactGorgon", nil, { encounterKey = "GeneratedH" }),
        row("interactEncounter", nil, { encounterKey = "UnknownInternalEncounter" }),
    })
    snapshot.occurrence.transactionsByOwner = {
        story = { kind = "encounterInteraction",
            resolution = { kind = "traitOffer", offer = { giver = "Narcissus" } } },
    }
    lu.assertEquals(guide.project(snapshot).rows, {
        { instruction = "Talk to Narcissus" },
        { instruction = "Talk to Icarus" },
        { instruction = "Talk to Athena" },
        { instruction = "Complete encounter" },
    })
end

function TestRoomGuide.testEquipmentPoolAndPhialCopyUsesDisplayNamesWithoutInternalKeyFallbacks()
    _G.GetDisplayName = function(args)
        return ({ KeepsakeKey = "Aromatic Phial", TraitKey = "{#BoldFormat}Nova Strike{#Prev}",
            TemporaryForcedSecretDoorTrait = "Spark of Ixion" })[args.Text] or args.Text
    end
    lu.assertEquals(guide.project(room({
        row("interactKeepsakeRack", nil, { keepsakeKey = "KeepsakeKey" }),
        row("sellPurgingPoolTrait", nil, { traitKey = "TraitKey" }),
        row("useFountain", nil, { aromaticPhialTarget = "TraitKey" }),
        row("purchaseStygianWellOffer", nil, { itemKey = "TemporaryForcedSecretDoorTrait" }),
        row("purchaseStygianWellOffer", nil, { itemKey = "UnknownInternalItem" }),
        row("interactKeepsakeRack", nil, { keepsakeKey = "UnknownInternalKeepsake" }),
    })).rows, {
        { instruction = "Equip Aromatic Phial" },
        { instruction = "Sell Nova Strike" },
        { instruction = "Use fountain — Phial: Nova Strike" },
        { instruction = "Buy Spark of Ixion" },
        { instruction = "Buy Well item" },
        { instruction = "Equip planned keepsake" },
    })
end

function TestRoomGuide.testConciseRoomAndRewardLabelsKeepMeaningfulDistinctions()
    local snapshot = room({
        row("interactIncomingReward", nil, { reward = { rewardType = "Boon", source = "HeraUpgrade" } }),
        row("interactLocalReward", nil, { reward = { rewardType = "MaxManaDropSmall" } }),
        row("collectRequiredReward"),
    })
    snapshot.occurrence.gameName = "H_Combat15"
    local projection = guide.project(snapshot)
    lu.assertEquals(projection.header, "Fields · Combat 15")
    for name, expected in pairs({
        Chaos_01 = "Chaos · 01", Dream_PostBoss02 = "Dream · Postboss 02",
        N_Sub03 = "Ephyra · Side room 03", UnknownInternalRoom = "Current room",
    }) do
        lu.assertEquals(guide.project({ kind = "navigation", nativeRoomName = name }).header, expected)
    end
    lu.assertEquals(projection.rows, {
        { instruction = "Collect Hera boon" },
        { instruction = "Collect Max Magick" },
        { instruction = "Collect boss reward" },
    })
    lu.assertEquals(guide.project({
        kind = "navigation", nativeRoomName = "N_Combat05",
        navigation = { kind = "return", gameName = "N_Hub" },
    }).footer, "Return to Hub")
end

function TestRoomGuide.testNextDoorUsesSelectedDoorPreviewNotTheDestinationAcquisition()
    local target = { id = "picked", gameName = "F_Combat04",
        overview = { incomingReward = { rewardType = "WeaponUpgrade" } } }
    local current = { id = "current", gameName = "F_Combat01", overview = {},
        doors = { kind = "batch", targets = {
            { room = { id = "other" }, reward = { rewardType = "MetaCurrencyDrop" } },
            { room = { id = "picked" }, reward = { rewardType = "MetaCardPointsCommonDrop" } },
        } } }
    local state = route.new({ selectedOccurrenceIds = { "current", "picked" },
        occurrencesById = { current = current, picked = target } })
    assert(route.enter(state, "current", "F_Combat01"))
    local snapshot = { kind = "room", occurrence = current, isCompleted = function() return false end,
        navigation = route.guideNavigation(state) }
    lu.assertEquals(guide.project(snapshot).footer, "Next door: Ashes")
    lu.assertEquals(state.index, 1)
end

function TestRoomGuide.testHubVisitUsesBoardRewardAndSpecialDestinationsKeepTheirNames()
    local target = { id = "picked", gameName = "N_Combat12", overview = {} }
    local state = route.new({ selectedOccurrenceIds = { "picked" }, occurrencesById = {
        picked = target, prehub = { id = "prehub", overview = { hub = {
            room = { gameName = "N_Hub" }, slots = {
                { room = { id = "picked" }, reward = { rewardType = "Boon", source = "HeraUpgrade" } },
            },
        } } },
    } })
    state.transparentNativeRoom = "N_Hub"
    local snapshot = { kind = "navigation", nativeRoomName = "N_Hub", navigation = route.guideNavigation(state) }
    lu.assertEquals(guide.project(snapshot).footer, "Next visit: Room 12 — Hera")
    for _, case in ipairs({
        { "F_Shop01", { shop = {} }, "Next: Shop" },
        { "F_Reprieve01", {}, "Next: Fountain" },
        { "Chaos_01", {}, "Next: Chaos" },
        { "C_Boss01", {}, "Next: Zagreus" },
    }) do
        snapshot.navigation = { kind = "next", occurrence = { gameName = case[1], overview = case[2] } }
        lu.assertEquals(guide.project(snapshot).footer, case[3])
    end
end

function TestRoomGuide.testStoryAndMinibossTitlesNameTheirOccupants()
    local expected = {
        F_Story01 = "Erebus · Arachne", G_Story01 = "Oceanus · Narcissus",
        H_Bridge01 = "Fields · Echo", I_Story01 = "Tartarus · Hades",
        N_Story01 = "Ephyra · Medea", O_Story01 = "Thessaly · Circe", P_Story01 = "Olympus · Dionysus",
        F_MiniBoss01 = "Erebus · Root-Stalker", F_MiniBoss02 = "Erebus · Shadow-Spiller",
        F_MiniBoss03 = "Erebus · Master-Slicer", G_MiniBoss01 = "Oceanus · Deep Serpent",
        G_MiniBoss02 = "Oceanus · King Vermin", G_MiniBoss03 = "Oceanus · Hellifish",
        H_MiniBoss01 = "Fields · Phantom", H_MiniBoss02 = "Fields · Queen Lamia",
        I_MiniBoss01 = "Tartarus · The Verminancer", I_MiniBoss02 = "Tartarus · Goldwrath",
        N_MiniBoss01 = "Ephyra · Satyr Champion", N_MiniBoss02 = "Ephyra · Erymanthian Boar",
        O_MiniBoss01 = "Thessaly · Charybdis", O_MiniBoss02 = "Thessaly · The Yargonaut",
        P_MiniBoss01 = "Olympus · Talos", P_MiniBoss02 = "Olympus · Mega-Dracon",
        Q_MiniBoss02 = "Summit · Brute", Q_MiniBoss03 = "Summit · Tail",
        Q_MiniBoss04 = "Summit · Eye", Q_MiniBoss05 = "Summit · Stalker",
    }
    for name, title in pairs(expected) do
        lu.assertEquals(guide.project({ kind = "navigation", nativeRoomName = name }).header, title)
    end
    for _, name in ipairs({ "F_MiniBoss01", "N_MiniBoss02" }) do
        local projection = guide.project({ kind = "navigation", nativeRoomName = "N_Hub",
            navigation = { kind = "next", hubVisit = name == "N_MiniBoss02",
                occurrence = { gameName = name }, reward = { rewardType = "Boon", source = "HeraUpgrade" } } })
        lu.assertEquals(projection.footer, "Next door: Hera")
    end
end

function TestRoomGuide.testFooterNamesStoryAndRewardlessDestinationsAndShortensCages()
    local function footer(name, reward, cages)
        return guide.project({ kind = "navigation", nativeRoomName = "H_Combat02",
            navigation = { kind = "next", occurrence = { gameName = name },
                reward = reward, cageRewards = cages } }).footer
    end
    for name, npc in pairs({ F_Story01 = "Arachne", G_Story01 = "Narcissus", H_Bridge01 = "Echo",
        I_Story01 = "Hades", N_Story01 = "Medea", O_Story01 = "Circe", P_Story01 = "Dionysus" }) do
        lu.assertEquals(footer(name, { rewardType = "Story" }), "Next: " .. npc)
        lu.assertEquals(footer(name), "Next: " .. npc)
    end
    lu.assertEquals(footer("I_Combat05", { rewardType = "ClockworkGoal" }), "Next: Tartarus · Combat 05")
    lu.assertEquals(footer("O_Combat04"), "Next: Thessaly · Combat 04")
    lu.assertEquals(footer("Q_Combat11"), "Next: Summit · Combat 11")
    lu.assertEquals(footer("H_Combat02", nil, {
        { rewardType = "Boon", source = "DemeterUpgrade" },
        { rewardType = "Boon", source = "HeraUpgrade" },
        { rewardType = "Boon", source = "AphroditeUpgrade" },
    }), "Next door: Demeter / Hera / Aphrodite")
    lu.assertEquals(footer("H_Combat02", nil, {
        { rewardType = "WeaponUpgrade" }, { rewardType = "StackUpgrade" }, { rewardType = "MaxHealthDrop" },
    }), "Next door: Hammer / Pom / Max Health")
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
    lu.assertEquals(lines["room-guide-header"].hudVisibility, "independent")
    lu.assertEquals(lines["room-guide-footer"].hudVisibility, "independent")
    lu.assertEquals(tables["room-guide-rows"].hudVisibility, "independent")
    lu.assertEquals(tables["room-guide-rows"].columns, { { key = "instruction", minWidth = 240 } })
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
        { instruction = "Collect reward" },
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
