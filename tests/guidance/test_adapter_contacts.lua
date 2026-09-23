-- Native-shaped menu construction through actual acquisition adapters and guidance.
-- luacheck: globals TestHighlightAdapterContacts
local lu = require("luaunit")
local highlights = require("mods.guidance.highlights")
local traits = require("mods.room.timeline.acquisitions.traits.hooks")
local chaos = require("mods.room.timeline.acquisitions.traits.chaos_offer")
local levels = require("mods.room.timeline.acquisitions.levels.hooks")
local npc = require("mods.room.timeline.acquisitions.npc.hooks")
local echo = require("mods.room.timeline.acquisitions.npc.echo")
local seaStar = require("mods.room.timeline.acquisitions.sea_star")
local nativeGame = require("tests.harness.native_game")

TestHighlightAdapterContacts = {}

function TestHighlightAdapterContacts:setUp()
    self.attached, self.destroyed, self.nextId = {}, {}, 1000
    self.restore = nativeGame.install({
        CurrentRun = { Hero = { Traits = { { Name = "Target" }, { Name = "Other" } } } },
        TraitData = nativeGame.anyTraitDeclarations(),
        IsTraitEligible = nativeGame.alwaysEligible,
        GetAllUpgradeableGodTraits = nativeGame.currentUpgradeableTraits,
        CreateScreenComponent = function()
            self.nextId = self.nextId + 1
            return { Id = self.nextId }
        end,
        Attach = function(args) self.attached[#self.attached + 1] = args end,
        Destroy = function(args) self.destroyed[#self.destroyed + 1] = args.Ids[1] end,
    })
end

function TestHighlightAdapterContacts:tearDown() self.restore() end

local function harness(payload, source, install)
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback)
        local prior = callbacks[name]
        callbacks[name] = function(runtime, base, ...)
            return callback(nil, runtime, function(...)
                if prior then return prior(runtime, base, ...) end
                return base(...)
            end, ...)
        end
    end } }
    local state = { state = "synchronized", route = {} }
    local runtime = { data = { read = function() return true end } }
    local guide = highlights.create({})
    local handle, current, completed = {}, { occurrence = { overview = {} } }, 0
    local room = {
        current = function() return current end,
        bound = function(_, _, native) return native == source and handle or nil end,
        peek = function() return payload end,
        begin = function() if completed == 0 then return payload end end,
        encounterHandle = function() return handle end,
    }
    local session = {
        complete = function() completed = completed + 1 end,
        diagnostic = function(_, checkpoint) error("unexpected diagnostic: " .. checkpoint) end,
    }
    local getState = function() return state end
    local report = function() guide.refresh(runtime, state) end
    install(module, session, getState, report, room, guide)
    guide.attach(module, getState)
    local function call(name, base, ...)
        if callbacks[name] then return callbacks[name](runtime, base, ...) end
        return base(...)
    end
    local function construct(screen, loot, reroll)
        call("CreateBoonLootButtons", function()
            screen.UpgradeButtons = {}
            for index, row in ipairs(loot.UpgradeOptions) do
                local button = call("CreateUpgradeChoiceButton", function(_, _, _, item)
                    local data = { Name = item.ItemName }
                    if item.SecondaryItemName then
                        data = { Name = item.SecondaryItemName, OnExpire = { TraitData = data } }
                    end
                    return { Id = index * 10, Data = data, PinIcon = { Id = index * 10 + 1 } }
                end, screen, loot, index, row, {})
                -- Native menu order need not be authored option order.
                table.insert(screen.UpgradeButtons, 1, button)
            end
        end, screen, loot, reroll, {})
    end
    return {
        call = call, construct = construct, guide = guide, state = state, runtime = runtime,
        completed = function() return completed end,
    }
end

local function offer(giver, selected)
    return { kind = "traits", giver = giver, selected = "option2",
        options = { { key = "Other", rarity = "Common" }, { key = selected or "Target", rarity = "Rare" } } }
end

function TestHighlightAdapterContacts:testOrdinaryHammerAndFallbackRemainMarkedAfterCompletion()
    for _, name in ipairs({ "ApolloUpgrade", "WeaponUpgrade", "HermesUpgrade" }) do
        local authored = name == "HermesUpgrade" and { kind = "fallbackGold" } or offer("Apollo")
        local source = { Name = name, GodLoot = name ~= "WeaponUpgrade", UpgradeOptions = {} }
        local h = harness({ transaction = { kind = "acquisition" },
            detail = { disposition = "normal", traitOffer = authored } }, source,
            function(module, session, getState, report, room, guide)
                traits.attach(module, session, getState, report, room, seaStar.create(), guide)
            end)
        local screen = { Source = source, Components = {} }
        h.construct(screen, source, false)
        lu.assertEquals(h.completed(), 1)
        lu.assertNotNil(screen.Components.RunPlannerPlannedChoiceMarker)
        local expectedId = name == "HermesUpgrade" and 10 or 20
        lu.assertEquals(self.attached[#self.attached].DestinationId, expectedId)
        h.runtime.data.read = function() return false end
        h.guide.refresh(h.runtime, h.state)
        lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
        h.runtime.data.read = function() return true end
        h.guide.refresh(h.runtime, h.state)
        lu.assertNotNil(screen.Components.RunPlannerPlannedChoiceMarker)
        lu.assertEquals(h.completed(), 1)
        h.call("CloseUpgradeChoiceScreen", function() end, screen)
    end
end

function TestHighlightAdapterContacts:testChaosRepeatedCursesAndNativeRerollAfterOwnerCompletion()
    local source = { Name = "TrialUpgrade", UpgradeOptions = {
        { ItemName = "PeerA" }, { ItemName = "PeerB" }, { ItemName = "ChaosElementalBlessing" },
    } }
    local authored = { kind = "chaos", selected = "option1", blessingKey = "ChaosElementalBlessing",
        rarity = "Rare", selectedCurseValues = {}, blessingValues = {}, curseOptions = {
            { curseKey = "ChaosNoMoneyCurse", requirementCount = 1 },
            { curseKey = "ChaosNoMoneyCurse", requirementCount = 2 },
            { curseKey = "ChaosNoMoneyCurse", requirementCount = 3 },
        } }
    local h = harness({ transaction = { kind = "acquisition" }, detail = {
        disposition = "normal", gameName = "TrialUpgrade", traitOffer = authored,
    } }, source, function(module, session, getState, report, room, guide)
        chaos.attach(module, session, getState, report, room, guide)
    end)
    local screen = { Source = source, Components = {} }
    h.call("HandleLootPickup", function() h.construct(screen, source, false) end, {}, source, {})
    lu.assertEquals(self.attached[#self.attached].DestinationId, 10)
    lu.assertEquals(h.completed(), 1)
    h.call("RerollBoonLoot", function()
        h.call("DestroyBoonLootButtons", function()
            lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
            h.guide.refresh(h.runtime, h.state)
            lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
            screen.UpgradeButtons = {}
        end, screen)
        source.UpgradeOptions = { { ItemName = "PeerA", SecondaryItemName = "ChaosNoMoneyCurse" } }
        h.construct(screen, source, true)
    end, screen, {})
    lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
    lu.assertEquals(h.completed(), 1)
end

function TestHighlightAdapterContacts:testVisiblePomUsesItsAcquisitionSelectedTarget()
    local source = { Name = "StackUpgrade", UpgradeOptions = {} }
    local h = harness({ transaction = { kind = "acquisition" }, detail = {
        disposition = "normal", gameName = "StackUpgrade", levelResolution = {
            selectedTarget = "Target", offeredTargets = { "Other", "Target" }, levelCount = 2,
        },
    } }, source, function(module, session, getState, report, room, guide)
        levels.attach(module, session, getState, report, room, seaStar.create(), guide)
    end)
    local screen = { Source = source, Components = {} }
    h.call("HandleLootPickup", function() h.construct(screen, source, false) end, {}, source, {})
    lu.assertEquals(self.attached[#self.attached].DestinationId, 20)
    lu.assertEquals(h.completed(), 1)
    h.guide.refresh(h.runtime, h.state)
    lu.assertNotNil(screen.Components.RunPlannerPlannedChoiceMarker)
end

function TestHighlightAdapterContacts:testNpcAndNestedEchoBindDuringVoidNativeMenuConstruction()
    local source = { Name = "Echo" }
    local authored = offer("Echo", "EchoLastRunBoon")
    authored.options[2].echoLastRunBoon = {
        selected = "option2", options = {
            { giver = "Hera", key = "Other", rarity = "Common" },
            { giver = "Zeus", key = "Target", rarity = "Rare" },
        },
    }
    local h = harness({ transaction = { kind = "encounterInteraction",
        resolution = { kind = "traitOffer", offer = authored } } }, source,
        function(module, session, getState, report, room, guide)
            local scope = npc.attach(module, session, getState, report, room, guide)
            echo.attach(module, session, report, scope, {}, guide, getState)
        end)
    local screen = { Source = source, Components = {} }
    h.call("EchoChoice", function(nativeSource, args)
        nativeSource.UpgradeOptions = args.UpgradeOptions
        h.call("OpenUpgradeChoiceMenu", function()
            h.construct(screen, source, false)
            lu.assertNotNil(screen.Components.RunPlannerPlannedChoiceMarker)
            h.call("HandleUpgradeChoiceSelection", function()
                h.call("CloseUpgradeChoiceScreen", function() end, screen)
                h.call("EchoLastRunBoon", function()
                    local nested = { OnPressedFunctionNameOverride = "SelectEchoBoon" }
                    h.call("OpenUpgradeChoiceMenu", function()
                        local nestedScreen = { Source = nested, Components = {} }
                        h.construct(nestedScreen, nested, false)
                        lu.assertNotNil(nestedScreen.Components.RunPlannerPlannedChoiceMarker)
                        lu.assertEquals(self.attached[#self.attached].DestinationId, 20)
                        h.call("CloseUpgradeChoiceScreen", function() end, nestedScreen)
                    end, nested, {})
                end, {}, {})
            end, screen, { Data = { Name = "EchoLastRunBoon" } }, {})
            -- Native OpenUpgradeChoiceMenu returns nil, not the constructed screen.
        end, source, {})
    end, source, { UpgradeOptions = { { ItemName = "Other" }, { ItemName = "EchoLastRunBoon" } } }, {})
    lu.assertEquals(h.completed(), 0) -- The real nested acquisition, not guidance, owns completion.
    local unrelated = { Source = {}, Components = {}, UpgradeButtons = {} }
    h.call("CreateBoonLootButtons", function() end, unrelated, {}, false, {})
    lu.assertNil(unrelated.Components.RunPlannerPlannedChoiceMarker)
end

return TestHighlightAdapterContacts
