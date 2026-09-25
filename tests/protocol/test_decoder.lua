-- luacheck: globals TestProtocol
local lu = require("luaunit")
local json = require("mods/protocol/json")
local protocol = require("mods.protocol.decoder")
local rewards = require("mods.protocol.rewards")
local conformance = require("mods.protocol.conformance")
local overview = require("mods.protocol.overview")
local generated = require("mods.protocol.generated_encounter")

TestProtocol = {}

function TestProtocol.testMenaceStrictSourceCoverageAndOmittedZero()
    local function value()
        return assert(json.decode([[{"kind":"generated","decisionKey":"generatedComposition","expectedBudget":40,"waveCount":1,"waves":[{"waveIndex":1,"types":[{"choiceKey":"Guard","nativeId":"Guard","source":"addition"}],"counts":{"Guard":4}}]}]]))
    end
    local function conversion(count)
        local entry = assert(json.decode('{"source":{"choiceKey":"Guard","nativeId":"Guard"},"count":0,"target":{"choiceKey":"Guard2","nativeId":"Guard2"}}'))
        entry.count = count
        return entry
    end
    local function menace(count)
        local waves = assert(json.decode(' [{"waveIndex":1,"conversions":[{}]}] '))
        waves[1].conversions[1] = conversion(count)
        return waves
    end
    lu.assertNotNil(generated.decode(value(), "test"))
    for _, count in ipairs({ 0, 1, 4 }) do
        local row = value()
        row.menace = menace(count)
        if count == 0 then row.menace[1].conversions[1].target = nil end
        lu.assertNotNil(generated.decode(row, "test"))
    end
    for _, mutate in ipairs({
        function(row) row.menace[2] = row.menace[1] end,
        function(row) row.menace[1].waveIndex = 2 end,
        function(row) row.menace[1].conversions[2] = row.menace[1].conversions[1] end,
        function(row) row.menace[1].conversions[1].count = 5 end,
        function(row) row.menace[1].conversions[1].count = -1 end,
        function(row) row.menace[1].conversions[1].count = 0.5 end,
        function(row) row.menace[1].conversions[1].target = nil end,
        function(row) row.menace[1].conversions[1].source.choiceKey = "Other" end,
        function(row) row.menace[1].conversions[1].source.nativeId = "Other" end,
        function(row) row.menace[1].conversions[1].extra = true end,
    }) do
        local row = value()
        row.menace = menace(1)
        mutate(row)
        lu.assertNil(generated.decode(row, "test"))
    end
end

function TestProtocol.testPublishedCompatibilityMatchesDecoder()
    local file = assert(io.open("src/execution-compatibility.json", "r"))
    local contents = file:read("*a")
    file:close()
    lu.assertEquals(assert(json.decode(contents)), {
        format = protocol.FORMAT,
        protocolVersion = protocol.VERSION,
        catalogVersion = protocol.CATALOG_VERSION,
    })
end
local root = "fixtures/execution-plan/"

function TestProtocol.testGeneratedEncounterRequiresACompleteProvenancedComposition()
    local function value()
        return assert(json.decode([[{
            "kind":"generated","decisionKey":"generatedComposition","expectedBudget":72.5,"waveCount":3,
            "highlight":{"choiceKey":"Guard","nativeId":"Guard"},
            "waves":[
                {"waveIndex":1,"types":[{"choiceKey":"Guard","nativeId":"Guard","source":"highlight"},{"choiceKey":"Mage","nativeId":"Mage","source":"addition"}],"counts":{"Guard":2,"Mage":3}},
                {"waveIndex":2,"types":[{"choiceKey":"Guard","nativeId":"Guard","source":"highlight"},{"choiceKey":"Mage","nativeId":"Mage","source":"addition"}],"counts":{"Guard":2,"Mage":3}},
                {"waveIndex":3,"types":[{"choiceKey":"Guard","nativeId":"Guard","source":"highlight"},{"choiceKey":"Mage","nativeId":"Mage","source":"addition"}],"counts":{"Guard":2,"Mage":3}}
            ]
        }]]))
    end
    lu.assertNotNil(generated.decode(value(), "generated"))
    for _, mutate in ipairs({
        function(row) row.waveCount = 6 end,
        function(row) row.waveCount = 1 end,
        function(row) row.unknown = true end,
        function(row) row.expectedBudget = nil end,
        function(row) row.expectedBudget = -1 end,
        function(row) row.expectedBudget = 0 / 0 end,
        function(row) row.expectedBudget = math.huge end,
        function(row) row.expectedBudget = "72.5" end,
        function(row) row.waves[2] = row.waves[1] end,
        function(row) row.waves[1].waveIndex = 4 end,
        function(row) row.waves[1].counts.Unknown = 0 end,
        function(row) row.waves[1].counts.Mage = 0 end,
        function(row) row.waves[1].types[2] = row.waves[1].types[1] end,
        function(row) row.waves[1].types[1], row.waves[1].types[2] = row.waves[1].types[2], row.waves[1].types[1] end,
        function(row) row.waves[1].types[1].source = "addition" end,
        function(row) row.waves[1].types[2].source = "highlight" end,
    }) do
        local row = value()
        mutate(row)
        lu.assertNil(generated.decode(row, "generated"))
    end
end

function TestProtocol.testEncounterCustomizationWireIsClosedAndBounded()
    local value = assert(json.decode([[{
        "encounterPhases":[{
            "slotKey":"Encounter","encounterKey":"BossEris01","kind":"boss",
            "customization":[
                {"decisionKey":"earlySummons","kind":"orderedPrefix","choices":[
                    {"choiceKey":"harpy","nativeId":"ErisSummonHarpy"},
                    {"choiceKey":"swab","nativeId":"ErisSummonSwab"}
                ]},
                {"decisionKey":"lateSummons","kind":"single","choiceKey":"fish","nativeId":"ErisSummonFish"}
            ]
        }],
        "requiredObjects":[]
    }]]))
    local decoded, errorMessage = overview.decode(value, "overview")
    lu.assertNotNil(decoded, errorMessage)

    local duplicate = assert(json.decode([[{
        "encounterPhases":[{"slotKey":"Encounter","encounterKey":"BossEris01","kind":"boss","customization":[
            {"decisionKey":"early","kind":"orderedPrefix","choices":[
                {"choiceKey":"harpy","nativeId":"ErisSummonHarpy"},
                {"choiceKey":"harpy","nativeId":"ErisSummonHarpy"}
            ]}
        ]}],"requiredObjects":[]
    }]]))
    lu.assertNil(overview.decode(duplicate, "overview"))
end

function TestProtocol.testCocoonCountWireIsClosedAndPositive()
    local function value(decision)
        return assert(json.decode([[{
            "encounterPhases":[{"slotKey":"Encounter","encounterKey":"ArachneCombatF","kind":"combat",
                "customization":[]] .. decision .. [[]}],
            "requiredObjects":[]
        }]]))
    end
    lu.assertNotNil(overview.decode(value('{"decisionKey":"cocoonCount","kind":"cocoonCount","count":8}'), "overview"))
    for _, decision in ipairs({
        '{"decisionKey":"cocoonCount","kind":"cocoonCount","count":0}',
        '{"decisionKey":"cocoonCount","kind":"cocoonCount","count":8.5}',
        '{"decisionKey":"cocoonCount","kind":"cocoonCount","count":"8"}',
        '{"decisionKey":"cocoonCount","kind":"cocoonCount"}',
        '{"decisionKey":"cocoonCount","kind":"cocoonCount","count":8,"minimum":8}',
    }) do
        lu.assertNil(overview.decode(value(decision), "overview"))
    end
end

function TestProtocol.testConformanceResolverProjectsNamedFactsAndRejectsUnknownOrDuplicateKinds()
    local state = assert(json.decode([[{
        "retainedEffects": {
            "steadyGrowth": [{"traitKey":"Trait"}],
            "keepsakes": {"currentKey":"Keepsake"},
            "stygianWell": {"sparkUses":1}
        },
        "chaos": {"active":[]},
        "rewardPriorities": ["boon"],
        "hexProgress": {"investedPathPoints":2},
        "forfeit": "inactive"
        ,"traits": {"elements": {"Aether":0,"Earth":0,"Air":0,"Fire":0,"Water":0}}
    }]]))
    local expected, errorMessage = conformance.resolve(assert(json.decode([[{
        "facts": [
            {"kind":"steadyGrowth"},
            {"kind":"chaos"},
            {"kind":"keepsakeEffects"},
            {"kind":"rewardPriorities"},
            {"kind":"pathOfStars"},
            {"kind":"forfeit"},
            {"kind":"stygianWell"},
            {"kind":"elementCounts"}
        ]
    }]])), state, "roomExitConformance")
    lu.assertNotNil(expected, errorMessage)
    lu.assertEquals(expected.steadyGrowth, state.retainedEffects.steadyGrowth)
    lu.assertEquals(expected.chaos, state.chaos)
    lu.assertEquals(expected.keepsakeEffects, state.retainedEffects.keepsakes)
    lu.assertEquals(expected.rewardPriorities, state.rewardPriorities)
    lu.assertEquals(expected.pathOfStars, state.hexProgress)
    lu.assertEquals(expected.forfeit, state.forfeit)
    lu.assertEquals(expected.stygianWell, state.retainedEffects.stygianWell)
    lu.assertEquals(expected.elementCounts, state.traits.elements)

    local unknown = conformance.resolve(assert(json.decode([[{
        "facts": [{"kind":"unknown"}]
    }]])), state, "roomExitConformance")
    lu.assertNil(unknown)
    local duplicate = conformance.resolve(assert(json.decode([[{
        "facts": [{"kind":"chaos"},{"kind":"chaos"}]
    }]])), state, "roomExitConformance")
    lu.assertNil(duplicate)
end

function TestProtocol.testSpellOfferWireRequiresCompleteTreeAndThreeOptions()
    local offer = assert(json.decode('{"kind":"traits","giver":"SpellDrop","selected":"option1","options":[{"key":"one"},{"key":"two"},{"key":"three"}],"hexTree":{"layoutKey":"Lung","rareTalentKeys":["rare"],"epicTalentKeys":["epic"]}}'))
    lu.assertNotNil(rewards.traitOffer(offer, "spell"))
    local missing = assert(json.decode('{"kind":"traits","giver":"SpellDrop","selected":"option1","options":[{"key":"one"},{"key":"two"},{"key":"three"}]}'))
    lu.assertNil(rewards.traitOffer(missing, "spell"))
    local short = assert(json.decode('{"kind":"traits","giver":"SpellDrop","selected":"option1","options":[{"key":"one"}],"hexTree":{"layoutKey":"Lung","rareTalentKeys":["rare"],"epicTalentKeys":["epic"]}}'))
    lu.assertNil(rewards.traitOffer(short, "spell"))
    local foreign = assert(json.decode('{"kind":"traits","giver":"Zeus","selected":"option1","options":[{"key":"one"},{"key":"two"},{"key":"three"}],"hexTree":{"layoutKey":"Lung","rareTalentKeys":["rare"],"epicTalentKeys":["epic"]}}'))
    lu.assertNil(rewards.traitOffer(foreign, "spell"))
end

local function decode(name)
    local file = assert(io.open(root .. name .. ".execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return value
end

local function decodeWithIndependentJsonModule(name)
    local independentJson = assert(loadfile("src/mods/protocol/json.lua"))()
    local file = assert(io.open(root .. name .. ".execution.json", "rb"))
    local value = assert(independentJson.decode(file:read("*a")))
    file:close()
    lu.assertFalse(rawequal(independentJson.null, json.null))
    return value
end

local function mirroredFixtureNames()
    local listing = assert(io.popen("ls " .. root))
    local names = {}
    for file in listing:lines() do
        local name = file:match("^(.+)%.execution%.json$")
        if name then names[#names + 1] = name end
    end
    listing:close()
    return names
end

local function generatedDecisions(plan)
    local result = {}
    for _, occurrence in ipairs(plan.occurrences) do
        for _, phase in ipairs(occurrence.overview.encounterPhases) do
            for _, decision in ipairs(phase.customization or {}) do
                if decision.kind == "generated" then result[#result + 1] = decision end
            end
        end
    end
    return result
end

function TestProtocol.testEveryMirroredPlannerFixtureDecodes()
    local names = mirroredFixtureNames()
    lu.assertTrue(#names >= 17)
    for _, name in ipairs(names) do
        local decoded, errorMessage = protocol.decode(decode(name))
        lu.assertNotNil(decoded, name .. ": " .. tostring(errorMessage))
    end
end

function TestProtocol.testMirroredGeneratedCompositionsCarryExpectedBudgetsAndOutcomes()
    local underworld = generatedDecisions(assert(protocol.decode(decode("underworld-generated-composition"))))
    lu.assertEquals(#underworld, 4)
    local budgets, highlight, fangs, template, positiveMenace = {}, false, 0, false, false
    for _, decision in ipairs(underworld) do
        budgets[#budgets + 1] = decision.expectedBudget
        highlight = highlight or decision.highlight ~= nil
        if decision.fangs then fangs = fangs + 1 end
        for _, wave in ipairs(decision.waves) do
            for _, entry in ipairs(wave.types) do template = template or entry.source == "template" end
        end
        for _, wave in ipairs(decision.menace or {}) do
            for _, conversion in ipairs(wave.conversions) do positiveMenace = positiveMenace or conversion.count > 0 end
        end
    end
    lu.assertEquals(budgets, { 100, 130, 160, 782 })
    lu.assertEquals({ highlight, fangs, template, positiveMenace }, { true, 2, true, true })
    local precombat = generatedDecisions(assert(protocol.decode(decode("surface-generated-precombat"))))
    lu.assertEquals(#precombat, 1)
    lu.assertEquals({ precombat[1].baseRoll, precombat[1].expectedBudget }, { 412, 412 })
end

function TestProtocol.testMirroredArachneFixtureCarriesOnlyTheAuthoredCocoonCount()
    local plan = assert(protocol.decode(decode("underworld-arachne-cocoons")))
    local arachne = {}
    for _, occurrence in ipairs(plan.occurrences) do
        for _, phase in ipairs(occurrence.overview.encounterPhases) do
            if phase.encounterKey == "ArachneCombatF" or phase.encounterKey == "ArachneCombatG" then
                arachne[phase.encounterKey] = phase.customization or false
            end
        end
    end
    lu.assertEquals(arachne.ArachneCombatF, {
        { decisionKey = "cocoonCount", kind = "cocoonCount", count = 11 },
    })
    lu.assertEquals(arachne.ArachneCombatG, false)
end

function TestProtocol.testScheduledLifecycleKeepsHermesAndEchoStateDiagnosticOnly()
    local decoded, errorMessage = protocol.decode(decode("surface-scheduled-lifecycle"))
    lu.assertNotNil(decoded, errorMessage)

    local sawHermesDiagnostic = false
    for _, occurrence in ipairs(decoded.occurrences) do
        local diagnostics = occurrence.diagnostics
        if diagnostics ~= nil then
            for _, checkpoint in ipairs({ "roomEntered", "beforeRoomExit" }) do
                local frame = diagnostics[checkpoint]
                local retained = frame ~= nil and frame.retainedEffects or nil
                if retained ~= nil and #retained.hermesShrineDeliveries > 0 then
                    sawHermesDiagnostic = true
                end
            end
        end
        local exitConformance = occurrence.roomExitConformance
        if exitConformance ~= nil then
            for _, fact in ipairs(exitConformance.facts) do
                lu.assertNotEquals(fact.kind, "hermesShrineDeliveries")
                lu.assertNotEquals(fact.kind, "echoShopDuplicate")
            end
        end
    end
    lu.assertTrue(sawHermesDiagnostic)
end

local function refreshFingerprint(plan)
    plan.planFingerprint = protocol.fingerprint({
        format = plan.format, protocolVersion = plan.protocolVersion,
        catalogVersion = plan.catalogVersion, projectId = plan.projectId,
        routeKey = plan.routeKey, startingLoadout = plan.startingLoadout, startingKeepsake = plan.startingKeepsake,
        extent = plan.extent, selectedOccurrenceIds = plan.selectedOccurrenceIds, resources = plan.resources,
        occurrences = plan.occurrences,
    })
end

local function automatic(plan)
    for _, occurrence in ipairs(plan.occurrences) do
        for _, transaction in ipairs(occurrence.timeline.transactions) do
            if transaction.kind == "automatic" then return transaction end
        end
    end
end

local function window(kind)
    if kind == "encounterEnd" or kind == "bossDefeated" then
        return { kind = kind, phaseKey = "phase" }
    end
    if kind == "postOutgoing" then return { kind = kind } end
    return { kind = "standard", phase = kind or "beforeCombat" }
end

local function reward()
    return { rewardType = "boon", producerLifecycleKey = "pickup" }
end

local function role()
    return {
        role = "self",
        disposition = "normal",
        lifecyclePoint = "pickup",
        kind = "trait",
        gameName = "ZeusWeaponBoon",
    }
end

local function traitOffer()
    return {
        kind = "traits",
        giver = "Zeus",
        options = {
            { key = "one", baseRarity = "Common", rarity = "Rare" },
            { key = "two" },
            { key = "three" },
        },
        selected = "option1",
    }
end

local objectMeta = getmetatable(assert(json.decode("{}")))
local arrayMeta = getmetatable(assert(json.decode("[]")))
local arrayFields = {
    biomeKeys = true,
    selectedOccurrenceIds = true,
    occurrences = true,
    unmodeledEncounterKeys = true,
    encounterPhases = true,
    requiredObjects = true,
    transactions = true,
    dependencies = true,
    obligations = true,
    roomGuide = true,
    roles = true,
    options = true,
    arcana = true,
    arcanaKeys = true,
}

local function tagged(value, field, forceArray)
    if type(value) ~= "table" or json.isNull(value) then return value end
    if getmetatable(value) == nil then
        local isArray = forceArray or arrayFields[field] or #value > 0
        setmetatable(value, isArray and arrayMeta or objectMeta)
    end
    for key, item in pairs(value) do tagged(item, key, false) end
    return value
end

local function minimalPlan(transactions)
    local obligations = {}
    for _, transaction in ipairs(transactions) do
        if transaction.kind ~= "acquisition" then
            obligations[#obligations + 1] = { owner = transaction.owner, checkpoint = "exitUsable" }
        end
    end
    local plan = tagged({
        format = "run-planner-execution",
        protocolVersion = protocol.VERSION,
        catalogVersion = "0.55.0-anvil-of-fates",
        projectId = "test-project",
        planFingerprint = "00000000",
        routeKey = "Underworld",
        startingLoadout = {
            weaponKey = "WeaponStaffSwing", aspectKey = "BaseStaffAspect", arcana = {},
            fear = { configuredRanks = {}, effectiveRanks = {} },
        },
        startingKeepsake = { keepsakeKey = "None" },
        extent = { kind = "configuredPrefix", biomeKeys = { "F" }, terminalBiomeKey = "F" },
        selectedOccurrenceIds = { "opening" },
        resources = { occurrences = { {
            occurrenceId = "opening",
            pointDispositions = {
                Pickaxe = "native", Exorcism = "native", Shovel = "native", Fishing = "native",
            },
        } } },
        occurrences = {
            {
                id = "opening",
                owner = "opening-owner",
                biomeKey = "F",
                gameName = "F_Opening01",
                kind = "opening",
                overview = { encounterPhases = {}, requiredObjects = {} },
                timeline = { transactions = transactions, dependencies = {}, obligations = obligations },
                roomGuide = {},
                doors = { kind = "terminal", owner = "doors-owner" },
            },
        },
    })
    refreshFingerprint(plan)
    return plan
end

function TestProtocol.testRoomGuideRequiresUniqueKeysAndLocalTransactionOwners()
    local plan = minimalPlan({ {
        kind = "acquisition", owner = "source", sourceOwner = "source", reward = reward(),
        producerLifecycleKey = "pickup", roles = { role() }, window = window(),
    } })
    plan.occurrences[1].roomGuide = tagged({ {
        key = "incoming", transactionOwner = "source",
        description = { kind = "interactIncomingReward", reward = reward() },
    } }, "roomGuide", true)
    refreshFingerprint(plan)
    local decoded, errorMessage = protocol.decode(plan)
    lu.assertNotNil(decoded, errorMessage)

    plan.occurrences[1].roomGuide[1].transactionOwner = "missing"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan.occurrences[1].roomGuide[1].transactionOwner = "source"
    plan.occurrences[1].roomGuide[2] = plan.occurrences[1].roomGuide[1]
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan.occurrences[1].roomGuide[2] = nil
    plan.occurrences[1].roomGuide[1].description.unexpected = true
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

local function minimalShrinePlan()
    local plan = minimalPlan({ {
        kind = "travelDealRefill", owner = "shrine-refill", window = window("postOutgoing"),
        refill = {
            carrier = "hermesShrine",
            source = { generationKey = "initial:first", slotIndex = 1 },
            replacement = {
                generationKey = "travelDealRefill", slotIndex = 1,
                optionKey = "Armor", rewardType = "ArmorDrop",
                purchase = { roomDelay = 8, rushed = false },
                deliverySourceKey = "hermesShrineDelivery:source:refill",
            },
        },
    } })
    plan.occurrences[1].overview.hermesShrine = tagged({
        offers = {
            {
                generationKey = "initial:first", optionKey = "Heal", rewardType = "HealBigDrop",
                slotIndex = 1, purchase = { roomDelay = 2, rushed = true },
                deliverySourceKey = "hermesShrineDelivery:source:first",
            },
            {
                generationKey = "initial:secondLeft", optionKey = "Health", rewardType = "MaxHealthDrop",
                slotIndex = 2,
            },
            {
                generationKey = "initial:secondRight", optionKey = "Mana", rewardType = "MaxManaDrop",
                slotIndex = 3,
            },
        },
    })
    refreshFingerprint(plan)
    return plan
end

function TestProtocol.testHermesShrinePurchaseRequiresDeliverySourcePair()
    local decoded, errorMessage = protocol.decode(minimalShrinePlan())
    lu.assertNotNil(decoded, errorMessage)
    local mutations = {
        function(plan)
            plan.occurrences[1].overview.hermesShrine.offers[1].deliverySourceKey = nil
        end,
        function(plan)
            plan.occurrences[1].overview.hermesShrine.offers[1].purchase = nil
        end,
        function(plan)
            plan.occurrences[1].timeline.transactions[1].refill.replacement.deliverySourceKey = nil
        end,
        function(plan)
            plan.occurrences[1].timeline.transactions[1].refill.replacement.purchase = nil
        end,
    }
    for _, mutate in ipairs(mutations) do
        local plan = minimalShrinePlan()
        mutate(plan)
        refreshFingerprint(plan)
        lu.assertNil(protocol.decode(plan))
    end
end

function TestProtocol.testWellOverviewCannotRetainTheMovedTravelDealRefill()
    local plan = minimalPlan({})
    plan.occurrences[1].overview.stygianWell = tagged({
        interacted = true,
        offers = { { generationKey = "travelDealRefill", offerKey = "RandomStoreItem" } },
    })
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testArtificerRoleCarriesSourceOwnedReplacement()
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "artificer", lifecyclePoint = "pickup",
            kind = "trait", gameName = "MetaCurrencyDrop",
            replacement = { reward = reward(), gameName = "RoomRewardConsolationPrize" },
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].replacement.gameName,
        "RoomRewardConsolationPrize")

    value.occurrences[1].timeline.transactions[1].roles[1].disposition = "normal"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testSeaStarResultIsAClosedNormalSourceField()
    local value = minimalPlan({ {
        kind = "acquisition", owner = "source", sourceOwner = "source", reward = reward(),
        producerLifecycleKey = "pickup", roles = { role() }, window = window(),
    } })
    local source = value.occurrences[1].timeline.transactions[1].roles[1]
    source.seaStarResult = { kind = "noProc" }
    tagged(source.seaStarResult, "seaStarResult", false)
    refreshFingerprint(value)
    lu.assertNotNil(protocol.decode(value))
    source.seaStarResult = { kind = "random" }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
    source.seaStarResult = { kind = "proc" }
    tagged(source.seaStarResult, "seaStarResult", false)
    source.disposition = "artificer"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
    source.disposition = "normal"
    source.producer = { kind = "seaStarDuplicate", sourceOwner = "source", sourceRole = "self" }
    tagged(source.producer, "producer", false)
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
    source.producer = nil
    local transaction = value.occurrences[1].timeline.transactions[1]
    transaction.kind = "shopPurchase"
    transaction.offerKey = "offer"
    transaction.rewardType = "boon"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testNaturalSelectionTargetsDecodeAsOneBoundedNestedResult()
    local offer = traitOffer()
    offer.options[1].naturalSelectionTargets = { "one", "two", "one" }
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "ZeusUpgrade", traitOffer = offer,
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[1]
        .naturalSelectionTargets, { "one", "two", "one" })

    value.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[1]
        .naturalSelectionTargets = {}
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testTargetedAcquisitionTargetBelongsOnlyToItsSelectedOption()
    local offer = traitOffer()
    offer.options[1].targetTraitKey = "ApolloSprintBoon"
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.options[1].targetTraitKey = 3
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].targetTraitKey = nil
    offer.options[2].targetTraitKey = "ApolloSprintBoon"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testConcaveStoneDispositionDecodesOnlyOnItsSelectedSourceOption()
    local offer = traitOffer()
    offer.options[1].concaveStoneResult = { kind = "proc", optionKey = "option2" }
    offer.options[2].targetTraitKey = "ApolloSprintBoon"
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "ZeusUpgrade", traitOffer = offer,
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[1]
        .concaveStoneResult.optionKey, "option2")
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[2]
        .targetTraitKey, "ApolloSprintBoon")

    offer.options[1].concaveStoneResult.optionKey = "option1"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    offer.options[1].concaveStoneResult = nil
    offer.options[2].targetTraitKey = nil
    offer.options[2].concaveStoneResult = { kind = "noProc" }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testCirceResolutionIsClosedAndBelongsOnlyToTheSelectedCirceOption()
    local offer = traitOffer()
    offer.giver = "Circe"
    offer.options[1].circeResolution = {
        kind = "promoteArcana", arcanaKeys = { "CastCount", "CardDraw" },
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.options[1].circeResolution.arcanaKeys = {
        "CastCount", "CardDraw", "ChanneledCast", "DoorReroll", "TradeOff", "ManaOverTime",
    }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution.arcanaKeys = { "CastCount", "CastCount" }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution = {
        kind = "disableFear", vowKeys = { "EnemyDamageShrineUpgrade", "EnemyHealthShrineUpgrade" },
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution.vowKeys = {}
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution.vowKeys = { "EnemyDamageShrineUpgrade", "EnemyDamageShrineUpgrade" }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution.vowKeys = { "EnemyDamageShrineUpgrade", "EnemyHealthShrineUpgrade" }
    offer.options[1].circeResolution.extra = true
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution = nil
    offer.options[2].circeResolution = { kind = "activateArcana", arcanaKeys = { "CardDraw" } }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[2].circeResolution = nil
    offer.options[1].circeResolution = { kind = "activateArcana", arcanaKeys = { "CardDraw" } }
    offer.giver = "Zeus"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testIcarusHammerTargetBelongsOnlyToSelectedLatestModel()
    local offer = traitOffer()
    offer.giver = "Icarus"
    offer.options[1].key = "UpgradeHammerBoon"
    offer.options[1].icarusHammerTargets = { "StaffDoubleAttackTrait", "StaffFastSpecialTrait" }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.options[1].icarusHammerTargets = 3
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].icarusHammerTargets = { "StaffDoubleAttackTrait", "StaffDoubleAttackTrait" }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].icarusHammerTargets = {}
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].icarusHammerTargets = { "StaffDoubleAttackTrait" }
    offer.options[1].key = "IcarusUpgradeBoon"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].key = "UpgradeHammerBoon"
    offer.giver = "Circe"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.giver = "Icarus"
    offer.options[1].icarusHammerTargets = nil
    offer.options[2].icarusHammerTargets = { "StaffDoubleAttackTrait" }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testEchoVolatileResultsBelongOnlyToTheirSelectedOuterRows()
    local offer = traitOffer()
    offer.giver = "Echo"
    offer.options[1].key = "EchoLastRunBoon"
    offer.options[1].echoLastRunBoon = {
        options = {
            {
                giver = "Hera", key = "HeraWeaponBoon", rarity = "Rare",
                lootHistorySource = "HeraUpgrade",
            },
            { giver = "Zeus", key = "ZeusSpecialBoon", rarity = "Epic" },
        },
        selected = "option2",
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[2].allTogetherResult = {
        earth = "Earth", fire = "Fire", air = "Air", water = "Water",
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[2].allTogetherResult = nil
    offer.options[1].echoLastRunBoon.options[1].allTogetherResult = {
        earth = "Earth", fire = "Fire", air = "Air", water = "Water",
    }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[1].allTogetherResult = nil
    offer.options[1].echoLastRunBoon.options[1].lootHistorySource = 7
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[1].lootHistorySource = "HeraUpgrade"
    offer.selected = "option2"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.selected = "option1"
    offer.options[1].echoLastRunBoon = nil
    offer.options[1].key = "EchoDoubleLevelBoon"
    offer.options[1].echoPomTarget = "ZeusWeaponBoon"
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.giver = "Icarus"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testTimePieceDispositionIsNotPublished()
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "timePiece", lifecyclePoint = "pickup",
            kind = "trait", gameName = "MetaCurrencyDrop",
        } },
        window = window(),
    } })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testPoolSalesAreNotExecutionTransactions()
    local value = minimalPlan({ {
        kind = "poolSale",
        owner = "sale",
        window = window("postOutgoing"),
        slotKey = "left",
        traitKey = "trait",
    } })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testAcquisitionsAreNotObligations()
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { role() },
        window = window(),
    } })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.obligations = {
        { owner = "source", checkpoint = "exitUsable" },
    }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testEveryNonAcquisitionHasExactlyOneObligation()
    local transaction = {
        kind = "fountainUse", owner = "fountain", interactionKey = "fountain", window = window(),
    }
    local value = minimalPlan({ transaction })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.obligations = {}
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ transaction })
    value.occurrences[1].timeline.obligations[2] = {
        owner = "fountain", checkpoint = "roomExit",
    }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testLegacyProtocolVectorsAreRejected()
    for _, name in ipairs({ "f-opening", "fg", "fg-ixion-chaos", "fg-anomaly", "automatic-boss" }) do
        local plan = decode(name)
        plan.protocolVersion = 24
        plan.resources = nil
        refreshFingerprint(plan)
        lu.assertNil(protocol.decode(plan))
    end
end

function TestProtocol.testProtocolRejectsLegacyVectorsFromAnIndependentDecoderModule()
    local plan = decodeWithIndependentJsonModule("f-opening")
    plan.protocolVersion = 24
    plan.resources = nil
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testCurrentProtocolRequiresCompleteOrderedRouteResourcePolicyAndRejectsLegacyOverview()
    local plan = minimalPlan({})
    lu.assertNotNil(protocol.decode(plan))

    plan.resources = nil
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.occurrences[1].overview.resources = {}
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.resources.occurrences[1].pointDispositions.Pickaxe = "selected"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.resources.occurrences[1].postExitElementCounts = {}
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.occurrences[1].overview.unmodeledEncounterKeys = { "Empty" }
    plan.occurrences[1].overview.encounterPhases = { { slotKey = "Encounter", encounterKey = "Empty", kind = "nonCombat" } }
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decodeWithIndependentJsonModule("f-opening")
    plan.occurrences[1].diagnostics.roomEntered.replace.traits.elements.Water = nil
    lu.assertNil(protocol.decode(plan))

    plan = decodeWithIndependentJsonModule("f-opening")
    plan.occurrences[1].diagnostics.roomEntered.replace.traits.elements.Unknown = 0
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testShipWheelRequiresOneCompletePickedCohortAndMatchingLifecycle()
    local function shipPlan()
        local wheelOwner = '["rewardWheel","Underworld","F","opening","wheel1"]'
        local offerOwner = '["rewardWheelOffer","Underworld","F","opening","wheel1","offer2"]'
        local choice = {
            kind = "chooseRewardWheel", owner = wheelOwner,
            window = { kind = "shipPreCombat", wheelKey = "wheel1" },
            wheelKey = "wheel1", pickedOfferKey = "offer2",
        }
        local acquisition = {
            kind = "acquisition", owner = offerOwner, sourceOwner = offerOwner,
            reward = reward(), producerLifecycleKey = "pickup", roles = { role() },
            window = { kind = "shipPostCombat", wheelKey = "wheel1" },
        }
        local plan = minimalPlan({ choice, acquisition })
        plan.occurrences[1].kind = "ShipEncounter"
        plan.occurrences[1].owner = '["occurrence","Underworld","F","opening"]'
        plan.occurrences[1].overview.encounterPhases = tagged({
            { slotKey = "Intro", encounterKey = "Intro", kind = "combat" },
            { slotKey = "Combat1", encounterKey = "Combat", kind = "combat" },
        }, "encounterPhases", true)
        plan.occurrences[1].overview.rewardWheels = tagged({ {
            wheelKey = "wheel1", phaseKey = "Combat1",
            phaseOwner = '["encounterPhase","Underworld","F",{"kind":"occurrence","occurrenceId":"opening"},"Combat1"]',
            offerCount = 2, storeKey = "RunProgress", pickedOfferKey = "offer2",
            offers = {
                { offerKey = "offer1", reward = reward() },
                { offerKey = "offer2", reward = reward() },
            },
        } }, "rewardWheels", true)
        plan.occurrences[1].timeline.dependencies = tagged({ {
            owner = offerOwner, afterOwner = wheelOwner,
        } }, "dependencies", true)
        return plan
    end

    local plan = shipPlan()
    refreshFingerprint(plan)
    lu.assertNotNil(protocol.decode(plan))

    plan = shipPlan()
    table.remove(plan.occurrences[1].timeline.transactions, 2)
    plan.occurrences[1].timeline.dependencies = tagged({}, "dependencies", true)
    refreshFingerprint(plan)
    lu.assertNotNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].overview.rewardWheels[1].offerCount = 1
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].overview.rewardWheels[1].offerCount = 3
    plan.occurrences[1].overview.rewardWheels[1].offers[3] = tagged({
        offerKey = "offer3", reward = reward(),
    }, "offer", false)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].overview.rewardWheels[1].storeKey = "HubRewards"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].timeline.transactions[1].window.wheelKey = "wheel2"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].overview.rewardWheels[1].phaseOwner = "wrong-phase"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].timeline.transactions[2].sourceOwner = "wrong-source"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].timeline.dependencies = tagged({}, "dependencies", true)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = shipPlan()
    plan.occurrences[1].overview.rewardWheels = tagged({}, "rewardWheels", true)
    plan.occurrences[1].timeline.transactions = tagged({}, "transactions", true)
    plan.occurrences[1].timeline.dependencies = tagged({}, "dependencies", true)
    plan.occurrences[1].timeline.obligations = tagged({}, "obligations", true)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testProtocolAcceptsClosedOrdinaryPrefixesAndBoundedDreamExtents()
    local plan = minimalPlan({})
    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "F", "G", "H", "I" }, terminalBiomeKey = "I" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNotNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "F", "G", "I" }, terminalBiomeKey = "I" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "F", "G", "H", "I", "N" }, terminalBiomeKey = "N" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.routeKey = "Surface"
    plan.occurrences[1].biomeKey = "N"
    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "N", "O", "P", "Q" }, terminalBiomeKey = "Q" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNotNil(protocol.decode(plan))

    plan.occurrences[1].biomeKey = "O"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.routeKey = "Surface"
    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "N", "O", "Q" }, terminalBiomeKey = "Q" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.routeKey = "Surface"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.routeKey = "Dream"
    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "Q", "F", "N", "H" }, terminalBiomeKey = "H" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNotNil(protocol.decode(plan))

    plan.extent = tagged({ kind = "configuredPrefix", biomeKeys = { "Q", "F", "F" }, terminalBiomeKey = "F" }, "extent", false)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testFGHIFixtureCarriesClockworkGoalsThroughTheOrdinaryRewardShape()
    local plan = decode("underworld-fghi")
    local decoded, errorMessage = protocol.decode(plan)
    lu.assertNotNil(decoded, errorMessage)
    lu.assertEquals(decoded.extent.biomeKeys, { "F", "G", "H", "I" })
    lu.assertEquals(decoded.extent.terminalBiomeKey, "I")

    local goal, nonGoal
    for _, occurrence in ipairs(decoded.occurrences) do
        if occurrence.biomeKey == "I" and occurrence.overview.incomingReward then
            local reward = occurrence.overview.incomingReward
            if reward.rewardType == "ClockworkGoal" then goal = reward else nonGoal = reward end
        end
    end
    lu.assertEquals(goal, { rewardType = "ClockworkGoal", producerLifecycleKey = "ClockworkGoalRoom" })
    lu.assertNotNil(nonGoal)
    lu.assertNotEquals(nonGoal.rewardType, "ClockworkGoal")
end

function TestProtocol.testWorldShopOffersAllowUnownedRowsAndRequireUniquePublishedTransactionOwners()
    local transaction = {
        kind = "acquisition", owner = "normal", sourceOwner = "shop:normal",
        reward = reward(), producerLifecycleKey = "pickup", roles = { role() }, window = window(),
    }
    local plan = minimalPlan({ transaction })
    plan.occurrences[1].overview.shop = tagged({
        profileKey = "WorldShop",
        offers = {
            { offerKey = "normal", optionKey = "RandomLoot", rewardType = "RandomLoot", transactionOwner = "normal" },
            { offerKey = "unselected", optionKey = "MaxHealthDrop", rewardType = "MaxHealthDrop" },
        },
    })
    refreshFingerprint(plan)
    lu.assertNotNil(protocol.decode(plan))

    plan.occurrences[1].overview.shop.offers[1].transactionOwner = "missing"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan.occurrences[1].overview.shop.offers[1].transactionOwner = "normal"
    plan.occurrences[1].overview.shop.offers[2].transactionOwner = "normal"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testSelectedNormalAndBoostedWorldShopFixtureDecodesExactTransactionOwners()
    local plan, errorMessage = protocol.decode(decode("surface-q-shop-correlation"))
    lu.assertNotNil(plan, errorMessage)
    local rows
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.id == "surface-q-preboss" then
            rows = occurrence.overview.shop.offers
            break
        end
    end
    lu.assertNotNil(rows)
    local owners, options = {}, {}
    for _, row in ipairs(rows) do
        if row.offerKey == "MixedProgress1" or row.offerKey == "MixedProgress2" then
            owners[#owners + 1] = row.transactionOwner
            options[#options + 1] = row.optionKey
        end
    end
    table.sort(options)
    lu.assertEquals(options, { "BoostedRandomLoot", "RandomLoot" })
    lu.assertEquals(#owners, 2)
    lu.assertNotNil(owners[1])
    lu.assertNotNil(owners[2])
    lu.assertNotEquals(owners[1], owners[2])
end

function TestProtocol.testPostbossBoundariesExposeExpandedRoomEntryDiagnostics()
    local plan = decode("underworld-fghi")
    local decoded, errorMessage = protocol.decode(plan)
    lu.assertNotNil(decoded, errorMessage)
    local selected = {}
    for _, occurrenceId in ipairs(decoded.selectedOccurrenceIds) do
        selected[occurrenceId] = true
    end
    local marked = 0
    for _, occurrence in ipairs(decoded.occurrences) do
        if occurrence.resumeBoundary ~= nil then
            marked = marked + 1
            lu.assertEquals(occurrence.resumeBoundary, "postbossEntry")
            lu.assertTrue(selected[occurrence.id])
            lu.assertNotNil(occurrence.diagnostics)
            lu.assertNotNil(occurrence.diagnostics.roomEntered)
            lu.assertNotNil(occurrence.diagnostics.roomEntered.traits)
        end
        if occurrence.biomeKey == "I" then
            lu.assertNil(occurrence.resumeBoundary)
        end
    end
    lu.assertEquals(marked, 3)
end

function TestProtocol.testPostbossBoundaryRejectsUnsupportedValue()
    local plan = decode("fg")
    local boundary
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.resumeBoundary ~= nil then
            boundary = occurrence
        end
    end
    lu.assertNotNil(boundary)
    boundary.resumeBoundary = "postbossExit"
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testPostbossBoundaryRequiresEntryDiagnostics()
    local plan = decode("fg")
    local boundary
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.resumeBoundary ~= nil then
            boundary = occurrence
        end
    end
    lu.assertNotNil(boundary)
    boundary.diagnostics = tagged({}, "diagnostics", false)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testSurfaceNFixtureClosesHubAndNativeRestoreReferences()
    local plan = decode("surface-n")
    local decoded, errorMessage = protocol.decode(plan)
    lu.assertNotNil(decoded, errorMessage)
    lu.assertEquals(decoded.extent.biomeKeys, { "N" })

    -- Admission attaches runtime indexes in place; mutate fresh wire input,
    -- not the already-admitted runtime product.
    plan = decode("surface-n")

    local parentsBySide = {}
    for _, occurrence in ipairs(plan.occurrences) do
        for _, slot in ipairs(occurrence.overview.localSlots or {}) do
            if slot.room ~= nil then
                parentsBySide[slot.room.id] = occurrence.id
            end
        end
    end
    local mutated = false
    for index = 1, #plan.selectedOccurrenceIds - 1 do
        local priorId = plan.selectedOccurrenceIds[index]
        local parentId = parentsBySide[priorId]
        if parentId ~= nil then
            for sideId, candidateParent in pairs(parentsBySide) do
                if candidateParent ~= parentId then
                    plan.selectedOccurrenceIds[index + 1] = sideId
                    mutated = true
                    break
                end
            end
        end
        if mutated then break end
    end
    lu.assertTrue(mutated)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testSurfaceNOFixtureCarriesCompleteShipWheelProducts()
    local decoded, errorMessage = protocol.decode(decode("surface-no"))
    lu.assertNotNil(decoded, errorMessage)
    lu.assertEquals(decoded.extent.biomeKeys, { "N", "O" })
    local wheelCount, choiceCount = 0, 0
    for _, occurrence in ipairs(decoded.occurrences) do
        for _, wheel in ipairs(occurrence.overview.rewardWheels or {}) do
            wheelCount = wheelCount + 1
            lu.assertEquals(wheel.offerCount, #wheel.offers)
        end
        for _, transaction in ipairs(occurrence.timeline.transactions) do
            if transaction.kind == "chooseRewardWheel" then choiceCount = choiceCount + 1 end
        end
    end
    lu.assertTrue(wheelCount > 0)
    lu.assertEquals(choiceCount, wheelCount)
end

function TestProtocol.testSurfaceNOPQFixturesCarryOnlyTheirPublishedPAndQNavigationFacts()
    local pPlan = decode("surface-nop")
    local pDecoded, pError = protocol.decode(pPlan)
    lu.assertNotNil(pDecoded, pError)
    lu.assertEquals(pDecoded.extent.biomeKeys, { "N", "O", "P" })

    local pEncounter, pBoss
    for _, occurrence in ipairs(pDecoded.occurrences) do
        if occurrence.biomeKey == "P" and occurrence.kind == "PEncounter" then
            pEncounter = occurrence
        elseif occurrence.gameName == "P_PreBoss01" and occurrence.doors.kind == "fixed" then
            pBoss = occurrence
        end
    end
    lu.assertNotNil(pEncounter)
    lu.assertEquals(pEncounter.overview.encounterPhases, {
        { slotKey = "Intro", encounterKey = "GeneratedP_PreCombat", kind = "combat" },
        { slotKey = "Combat", encounterKey = "GeneratedP", kind = "combat" },
    })
    lu.assertEquals(pBoss.doors.target.gameName, "P_Boss01")

    local qPlan = decode("surface-nopq")
    local qDecoded, qError = protocol.decode(qPlan)
    lu.assertNotNil(qDecoded, qError)
    lu.assertEquals(qDecoded.extent.biomeKeys, { "N", "O", "P", "Q" })
    local widths = {}
    local qShop, qBoss
    for _, occurrence in ipairs(qDecoded.occurrences) do
        if occurrence.biomeKey == "Q" and occurrence.doors.kind == "batch" then
            widths[#widths + 1] = #occurrence.doors.targets
        elseif occurrence.gameName == "Q_PreBoss01" then
            qShop = occurrence
        elseif occurrence.gameName == "Q_Boss01" then
            qBoss = occurrence
        end
    end
    lu.assertTrue(#widths > 0)
    lu.assertTrue(table.concat(widths, ","):match("1") ~= nil)
    lu.assertTrue(table.concat(widths, ","):match("2") ~= nil)
    lu.assertEquals(qShop.overview.shop.profileKey, "Q_WorldShop")
    lu.assertEquals(qShop.doors.target.gameName, "Q_Boss01")
    lu.assertEquals(qBoss.doors.kind, "terminal")
    for _, occurrence in ipairs(qDecoded.occurrences) do
        lu.assertNotEquals(occurrence.gameName, "Q_PostBoss01")
    end
end

function TestProtocol.testFieldsFixturePublishesBoundedDistinctPlacementFacts()
    local plan = decode("underworld-fgh")
    local selected = {}
    for _, id in ipairs(plan.selectedOccurrenceIds) do selected[id] = true end
    local unpickedCount = 0
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.kind == "FieldsEncounter" and not selected[occurrence.id] then
            lu.assertNil(occurrence.overview.fields)
            unpickedCount = unpickedCount + 1
        end
    end
    lu.assertTrue(unpickedCount > 0)
    local fieldsOccurrence
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    lu.assertNotNil(fieldsOccurrence)
    lu.assertTrue(#fieldsOccurrence.overview.fields.cagePoints >= 2)
    lu.assertTrue(#fieldsOccurrence.overview.fields.cagePoints <= 3)
    lu.assertNotNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.kind == "FieldsEncounter" and selected[occurrence.id] then
            occurrence.overview.fields = nil
            break
        end
    end
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    fieldsOccurrence = nil
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    table.remove(fieldsOccurrence.overview.fields.cagePoints)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    fieldsOccurrence = nil
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    fieldsOccurrence.overview.fields.optionalRewards[1].pointId =
        fieldsOccurrence.overview.fields.cagePoints[1].pointId
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testFieldsFixtureRequiresCanonicalOrderedCageSlots()
    local plan = decode("underworld-fgh")
    local fieldsOccurrence
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    lu.assertNotNil(fieldsOccurrence)
    local fields = fieldsOccurrence.overview.fields
    fields.cagePoints[1].slotKey, fields.cagePoints[2].slotKey =
        fields.cagePoints[2].slotKey, fields.cagePoints[1].slotKey
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    fieldsOccurrence = nil
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    lu.assertNotNil(fieldsOccurrence)
    fieldsOccurrence.overview.fields.cagePoints[1].slotKey = "cage4"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testDoorCageRewardsMatchTheirReferencedFieldsTarget()
    local function fieldsTarget(plan, selected)
        local selectedIds = {}
        for _, id in ipairs(plan.selectedOccurrenceIds) do selectedIds[id] = true end
        local fieldsOccurrence
        for _, occurrence in ipairs(plan.occurrences) do
            if occurrence.kind == "FieldsEncounter" and (selectedIds[occurrence.id] == true) == selected then
                fieldsOccurrence = occurrence
                break
            end
        end
        lu.assertNotNil(fieldsOccurrence)
        for _, source in ipairs(plan.occurrences) do
            if source.doors.kind == "batch" then
                for _, target in ipairs(source.doors.targets) do
                    if target.room.id == fieldsOccurrence.id then return target end
                end
            end
        end
        error("fixture lacks a door target for the Fields occurrence")
    end

    for _, selected in ipairs({ true, false }) do
        local missing = decode("underworld-fgh")
        fieldsTarget(missing, selected).cageRewards = nil
        refreshFingerprint(missing)
        lu.assertNil(protocol.decode(missing))

        local short = decode("underworld-fgh")
        local shortTarget = fieldsTarget(short, selected)
        table.remove(shortTarget.cageRewards)
        refreshFingerprint(short)
        lu.assertNil(protocol.decode(short))
    end

    local illegal = decode("underworld-fgh")
    local occurrencesById = {}
    for _, occurrence in ipairs(illegal.occurrences) do occurrencesById[occurrence.id] = occurrence end
    local nonFieldsTarget
    for _, source in ipairs(illegal.occurrences) do
        if source.doors.kind == "batch" then
            for _, target in ipairs(source.doors.targets) do
                if occurrencesById[target.room.id].kind ~= "FieldsEncounter" then
                    nonFieldsTarget = target
                    break
                end
            end
        end
        if nonFieldsTarget ~= nil then break end
    end
    lu.assertNotNil(nonFieldsTarget)
    nonFieldsTarget.cageRewards = {}
    refreshFingerprint(illegal)
    lu.assertNil(protocol.decode(illegal))
end

function TestProtocol.testDestinationContractPresenceIsStrictAndMatchesItsOverview()
    local function firstBatchTarget(plan)
        for _, occurrence in ipairs(plan.occurrences) do
            if occurrence.doors.kind == "batch" and occurrence.doors.targets[1] ~= nil then
                return occurrence.doors.targets[1]
            end
        end
        error("fixture lacks a batch target")
    end

    local missing = decode("fg")
    firstBatchTarget(missing).zagreusContractPresent = nil
    refreshFingerprint(missing)
    lu.assertNil(protocol.decode(missing))

    local nonBoolean = decode("fg")
    firstBatchTarget(nonBoolean).zagreusContractPresent = "true"
    refreshFingerprint(nonBoolean)
    lu.assertNil(protocol.decode(nonBoolean))

    local disagreement = decode("fg")
    firstBatchTarget(disagreement).zagreusContractPresent = true
    refreshFingerprint(disagreement)
    lu.assertNil(protocol.decode(disagreement))
end

function TestProtocol.testOpaqueOwnerReferencesAreLocalAndLaterContactsAreRejected()
    local value = decode("f-opening")
    local room = value.occurrences[1]
    room.timeline.dependencies[1] = { owner = "missing", afterOwner = room.timeline.transactions[1].owner }
    lu.assertNil(protocol.decode(value))
    value = decode("f-opening")
    value.occurrences[1].roomExitConformance = { facts = { { kind = "echoShopDuplicate" } } }
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testNestedSemanticOwnersUseTheOwnerSpecificBound()
    local owner = string.rep("o", 420)
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = owner,
        sourceOwner = owner,
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { role() },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].owner, owner)

    value.occurrences[1].timeline.transactions[1].owner = string.rep("o", 2049)
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testForcedShortageTraitOfferSelectsAnExistingOption()
    local offer = traitOffer()
    offer.options = { { key = "one" } }
    offer.selected = "option1"
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "acquisition",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "AllElementalBoon", traitOffer = offer,
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)

    offer.selected = "option2"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testAllTogetherRequiresFourExplicitDirectGrantOutcomes()
    local offer = traitOffer()
    offer.options[1].allTogetherResult = {
        earth = "ElementalDamageBoon", fire = "ElementalBaseDamageBoon",
        air = "ElementalDamageFloorBoon", water = json.null,
    }
    local value = minimalPlan({ {
        kind = "acquisition", owner = "acquisition", sourceOwner = "source",
        reward = reward(), producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "HeraUpgrade", traitOffer = offer,
        } }, window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertTrue(json.isNull(plan.occurrences[1].timeline.transactions[1].roles[1]
        .traitOffer.options[1].allTogetherResult.water))

    offer.options[1].allTogetherResult.water = nil
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testRecomputedFingerprintCannotHideClosedUnionViolations()
    local value = decode("automatic-boss")
    local transaction = automatic(value)
    transaction.source = "not-valid-on-judgment"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.occurrences[1].overview.unknown = true
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.occurrences[1].overview.effectNeutralRequiredReward = false
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.startingKeepsake.equipResults = { experimentalHammer = { kind = "selected" } }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.occurrences[1].diagnostics.roomEntered.replace.counters.routeEncounterDepth = "one"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testEveryTimelineTransactionUnionDecodes()
    local transactions = {
        {
            kind = "acquisition",
            owner = "acquisition",
            sourceOwner = "source",
            reward = reward(),
            producerLifecycleKey = "pickup",
            roles = { role() },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "trait-offer",
            phaseKey = "phase",
            resolution = { kind = "traitOffer", offer = traitOffer() },
            window = window("encounterEnd"),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-free-item",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = {
                    kind = "freeItem",
                    itemGameName = "EmptyMaxHealthDrop",
                },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-gold",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "goldTrade", response = "accept" },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-damage",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "damageTrade", response = "decline" },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-trait",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "traitTrade", traitKey = "trait", response = "accept" },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-contest",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "damageContest", result = "success" },
            },
            window = window(),
        },
        {
            kind = "automatic",
            owner = "growth",
            effect = "steadyGrowth",
            phaseKey = "phase",
            source = "source",
            target = "target",
            window = window("encounterEnd"),
        },
        {
            kind = "automatic",
            owner = "embryo",
            effect = "transcendentEmbryo",
            phaseKey = "phase",
            source = "source",
            target = "target",
            rarity = "Rare",
            blessingValues = { damageBonus = 0.7 },
            window = window("encounterEnd"),
        },
        {
            kind = "automatic",
            owner = "judgment",
            effect = "judgment",
            phaseKey = "phase",
            arcanaKeys = { "one", "two" },
            rarity = "Rare",
            window = window("bossDefeated"),
        },
        {
            kind = "automatic",
            owner = "figurine",
            effect = "crystalFigurine",
            phaseKey = "phase",
            arcanaKeys = { "three" },
            rarity = "Epic",
            window = window("bossDefeated"),
        },
        {
            kind = "itemEffect", owner = "well", window = window("postOutgoing"),
            itemKey = "LastStandDrop", effect = "lastStand", extended = false,
        },
        {
            kind = "transformation", owner = "twist", window = window("postOutgoing"),
            transformation = { kind = "stygianWellTwist", sourceItemKey = "RandomStoreItem", resultItemKey = "HealDropRange" },
        },
        {
            kind = "travelDealRefill", owner = "refill", window = window("postOutgoing"),
            refill = { carrier = "stygianWell", source = { owner = "well", generationKey = "initial:secondLeft" },
                replacement = { generationKey = "travelDealRefill", offerKey = "item", effect = "neutral" } },
        },
        {
            kind = "travelDealRefill", owner = "shop-refill", window = window("postOutgoing"),
            refill = {
                carrier = "worldShop", source = { owner = "shop-source", offerKey = "Boon" },
                replacement = { slotIndex = 0, groupIndex = 0, optionKey = "ArmorBoost", reward = reward() },
            },
        },
        {
            kind = "travelDealRefill", owner = "shrine-refill", window = window("postOutgoing"),
            refill = {
                carrier = "hermesShrine",
                source = { generationKey = "initial:first", slotIndex = 1 },
                replacement = {
                    generationKey = "travelDealRefill", slotIndex = 1,
                    optionKey = "TalentDrop", rewardType = "TalentDrop",
                },
            },
        },
        {
            kind = "keepsakeChange",
            owner = "rack",
            window = window("postOutgoing"),
            keepsakeKey = "hammer",
            equipResults = {
                experimentalHammer = { kind = "selected", traitKey = "hammerTrait" },
            },
        },
        {
            kind = "keepsakeReplay",
            owner = "echo-replay",
            window = window("beforeCombat"),
            keepsakeKey = "hammer",
            equipResults = {
                experimentalHammer = { kind = "exhausted" },
            },
        },
        {
            kind = "fountainUse",
            owner = "fountain",
            window = window("postOutgoing"),
            interactionKey = "fountain",
            aromaticPhialTarget = "trait",
        },
    }
    local plan, errorMessage = protocol.decode(minimalPlan(transactions))
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(#plan.occurrences[1].timeline.transactions, #transactions)
end

function TestProtocol.testFountainUseRequiresItsPublishedInteractionContact()
    local value = minimalPlan({ {
        kind = "fountainUse",
        owner = "fountain",
        window = window("postOutgoing"),
        interactionKey = "fountain",
    } })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.transactions[1].interactionKey = nil
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value.occurrences[1].timeline.transactions[1].interactionKey = "other"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testAnvilResultExistsOnlyOnTheTransformationTransaction()
    local transaction = {
        kind = "transformation",
        owner = "anvil",
        window = window("postOutgoing"),
        transformation = {
            kind = "anvilOfFates",
            removedTraitKey = json.null,
            addedTraitKeys = { "HammerA", "HammerB" },
        },
    }
    lu.assertNotNil(protocol.decode(minimalPlan({ transaction })))

    transaction.transformation = nil
    lu.assertNil(protocol.decode(minimalPlan({ transaction })))

    transaction.transformation = { kind = "stygianWellTwist", sourceItemKey = "A" }
    lu.assertNil(protocol.decode(minimalPlan({ transaction })))
end

function TestProtocol.testKeepsakeReplayIsAClosedBeforeCombatEquipTransaction()
    local value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = { experimentalHammer = { kind = "exhausted" } },
    } })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.transactions[1].equipResults = nil
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = { jeweledPom = { traitKey = "PomTrait" } },
    } })
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = {
            experimentalHammer = { kind = "exhausted" },
            transcendentEmbryo = { blessingKey = "Blessing", blessingValues = {} },
        },
    } })
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("postOutgoing"),
        keepsakeKey = "hammer",
        equipResults = { experimentalHammer = { kind = "exhausted" } },
    } })
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = { experimentalHammer = { kind = "exhausted" } },
        extra = true,
    } })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testEncounterPhaseAcceptsOnlyTheOptionalFigLeafDecision()
    local value = minimalPlan({})
    value.occurrences[1].overview.encounterPhases[1] = tagged(
        { slotKey = "phase", encounterKey = "Encounter", kind = "combat", figLeafSkip = false },
        "phaseRow"
    )
    refreshFingerprint(value)
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertFalse(plan.occurrences[1].overview.encounterPhases[1].figLeafSkip)

    local invalidValue = minimalPlan({})
    invalidValue.occurrences[1].overview.encounterPhases[1] = tagged(
        { slotKey = "phase", encounterKey = "Encounter", kind = "combat", figLeafSkip = "false" },
        "phaseRow"
    )
    refreshFingerprint(invalidValue)
    local invalid, invalidError = protocol.decode(invalidValue)
    lu.assertNil(invalid)
    lu.assertStrContains(invalidError, "encounterPhases[1].figLeafSkip")
end
