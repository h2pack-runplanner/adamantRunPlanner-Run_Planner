local lu = require("luaunit")
local tree = require("mods.spells.hex_tree").create()
local spell = require("mods.room.timeline.acquisitions.spell.hooks")

TestSpellAcquisitions = {}

function TestSpellAcquisitions:setUp()
    self.oldSession = _G.SessionMapState
    self.oldPregenerate = _G.PregenerateSpells
end

function TestSpellAcquisitions:tearDown()
    _G.SessionMapState = self.oldSession
    _G.PregenerateSpells = self.oldPregenerate
end

-- Native pregeneration consumes GetEligibleSpells and records offer-dependent
-- God Sent eligibility. Tests supply the native eligibility result, not planner policy.
local function nativePregeneration(callbacks)
    _G.SessionMapState = { SelectedSpells = { "Other" },
        DuoTalentEligible = true, DuoTalentEligibleSpell = { Other = true },
        DuoTalentEligibleGender = { Stale = true } }
    _G.PregenerateSpells = function(screen)
        _G.SessionMapState.SelectedSpells = {}
        local pool = callbacks.GetEligibleSpells(nil, nil, function() return { "Other" } end, screen)
        while #pool > 0 do
            local name = callbacks.RemoveRandomValue(nil, nil,
                function(values) return table.remove(values) end, pool)
            table.insert(_G.SessionMapState.SelectedSpells, name)
            if _G.SpellData[name].nativeGodSent then
                _G.SessionMapState.DuoTalentEligible = true
                _G.SessionMapState.DuoTalentEligibleSpell[name] = true
                _G.SessionMapState.DuoTalentEligibleGender.Female = true
            end
        end
    end
end

local function assertScreenInstallation(isShop)
    local room = require("mods.room.coordinator")
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback)
        local prior = callbacks[name]
        callbacks[name] = function(host, runtime, base, ...)
            return callback(host, runtime, function(...)
                if prior then return prior(host, runtime, base, ...) end
                return base(...)
            end, ...)
        end
    end } }
    local function invoke(name, base, ...)
        if callbacks[name] then return callbacks[name](nil, {}, base, ...) end
        return base(...)
    end
    local offer = {
        kind = "traits", giver = "SpellDrop", selected = "option1",
        options = {
            { key = "SpellPolymorphTrait" }, { key = "SpellMeteorTrait" }, { key = "SpellSummonTrait" },
        },
        hexTree = { layoutKey = "Nacelle", rareTalentKeys = { "PolymorphBossDamageTalent" },
            epicTalentKeys = { "PolymorphSandwichTalent" } },
    }
    local transaction = { kind = "acquisition", owner = "shop-spell", sourceOwner = "shop-spell",
        window = { kind = "postOutgoing" }, roles = { {
            role = "self", kind = "loot", gameName = "SpellDrop", disposition = "normal", traitOffer = offer,
        } } }
    local occurrence = { id = "preboss", overview = {}, transactionsByOwner = { [transaction.owner] = transaction },
        timeline = { transactions = { transaction }, dependencies = {}, obligations = {} } }
    local plan = { occurrencesById = { [occurrence.id] = occurrence } }
    local diagnostics, completions = {}, 0
    local state = { state = "synchronized", plan = plan, room = room.new(plan, function(errorValue)
        error(errorValue.checkpoint)
    end) }
    local active = assert(room.enter(state, occurrence))
    local session = {
        diagnostic = function(_, checkpoint, value) diagnostics[#diagnostics + 1] = { checkpoint, value } end,
        complete = function(value, handle) completions = completions + 1; return room.complete(value, handle) end,
    }
    local getState, report = function() return state end, function() end
    require("mods.room.features.inventory.world_item_hooks").attach(module, session, getState, report, room, nil, {})
    local hexTree = require("mods.spells.hex_tree").create()
    hexTree.attach(module)
    local markedScreen, markedTrait
    spell.attach(module, session, getState, report, room, hexTree, {
        screen = function(_, observedState, screen, selected)
            lu.assertIs(observedState, state)
            lu.assertNotNil(screen.Components[1])
            markedScreen, markedTrait = screen, selected
        end,
    })
    local restore = require("tests.harness.native_game").install({
        SpellData = {
            Heal = { TraitName = "SpellHealTrait" }, Beam = { TraitName = "SpellLaserTrait" },
            Polymorph = { TraitName = "SpellPolymorphTrait", nativeGodSent = isShop },
            Meteor = { TraitName = "SpellMeteorTrait" }, Summon = { TraitName = "SpellSummonTrait" },
        },
        SessionMapState = {},
    })
    local function removeRandom(values)
        return invoke("RemoveRandomValue", function(pool) return table.remove(pool, 1) end, values)
    end
    local ok, failure = pcall(function()
        nativePregeneration(callbacks)
        local function spawn()
            local native = { Name = "SpellDrop", SetupEvents = { { FunctionName = "PregenerateSpells" } } }
            -- Native CreateConsumableItemFromData runs SetupEvents before returning the item.
            invoke("RunEventsGeneric", function(_, source)
                invoke("PregenerateSpells", function()
                    _G.SessionMapState.SelectedSpells = {}
                    local eligible = { "Heal", "Beam", "Polymorph", "Meteor", "Summon" }
                    for index = 1, 3 do _G.SessionMapState.SelectedSpells[index] = removeRandom(eligible) end
                end, source)
            end, native.SetupEvents, native)
            return native
        end
        local item
        if isShop then
            item = invoke("SpawnStoreItemInWorld", spawn, { Name = "SpellDrop", __runPlannerWorldShop = true,
                __runPlannerTransactionOwner = transaction.owner }, 10)
        else
            item = spawn()
        end
        lu.assertEquals(_G.SessionMapState.SelectedSpells, { "Heal", "Beam", "Polymorph" })
        if isShop then lu.assertNotNil(room.bound(state, active, item))
        else lu.assertNil(room.bound(state, active, item)) end
        lu.assertEquals(completions, 0)
        assert(room.window(state, "postOutgoing"))
        local installed
        invoke("OpenSpellScreen", function(source)
            local screen = { Source = source, Components = {} }
            invoke("CreateSpellButtons", function(value)
                lu.assertEquals(_G.SessionMapState.SelectedSpells, { "Polymorph", "Meteor", "Summon" })
                lu.assertEquals(_G.SessionMapState.DuoTalentEligibleSpell,
                    isShop and { Polymorph = true } or {})
                lu.assertEquals(_G.SessionMapState.DuoTalentEligibleGender,
                    isShop and { Female = true } or {})
                lu.assertEquals(_G.SessionMapState.DuoTalentEligible, isShop and true or nil)
                local unrelated = { "native-first", "native-last" }
                lu.assertEquals(invoke("RemoveRandomValue", function(values) return table.remove(values) end,
                    unrelated), "native-last")
                -- GetEligibleSpells returns the cached list; button creation consumes it in place.
                local pool = invoke("GetEligibleSpells", function() return _G.SessionMapState.SelectedSpells end, value)
                for index = 1, 3 do
                    local name = removeRandom(pool)
                    value.Components[index] = { TraitName = _G.SpellData[name].TraitName, SpellName = name }
                end
            end, screen)
            lu.assertEquals(screen.Components[1].TraitName, "SpellPolymorphTrait")
            lu.assertIs(markedScreen, screen)
            lu.assertEquals(markedTrait, "SpellPolymorphTrait")
            lu.assertEquals(screen.Components[3].TraitName, "SpellSummonTrait")
            lu.assertEquals(_G.SessionMapState.SelectedSpells, {})
            invoke("AcceptAndCloseSpellScreen", function(_, button)
                installed = invoke("CreateTalentTree", function()
                    local layout = invoke("GetRandomValue", function(values) return values[1] end,
                        { { Name = "Maze" }, { Name = "Nacelle" } })
                    return { layout = layout.Name,
                        rare = removeRandom({ "PolymorphTauntTalent", "PolymorphBossDamageTalent" }),
                        epic = removeRandom({ "PolymorphCurseTalent", "PolymorphSandwichTalent" }) }
                end, _G.SpellData[button.SpellName])
            end, screen, screen.Components[1])
        end, item, {})
        lu.assertEquals(installed, { layout = "Nacelle", rare = "PolymorphBossDamageTalent",
            epic = "PolymorphSandwichTalent" })
        lu.assertEquals(completions, 1)
        lu.assertEquals(diagnostics, {})
        lu.assertEquals(invoke("GetEligibleSpells", function() return { "native" } end, {}),
            { "native" })
    end)
    restore()
    if not ok then error(failure, 0) end
end

function TestSpellAcquisitions.testShopSpellInstallsAtScreenOpeningInsteadOfSpawn()
    assertScreenInstallation(true)
end

function TestSpellAcquisitions.testCageSpellSpawnedBeforeAcquisitionReadinessReplacesNativeOffersAtScreen()
    assertScreenInstallation(false)
end

function TestSpellAcquisitions.testCreatedHexTreesDoNotSharePendingScopes()
    local definition = require("mods.spells.hex_tree")
    local first, second = definition.create(), definition.create()
    local firstCallbacks, secondCallbacks = {}, {}
    first.attach({ hooks = { wrap = function(name, _, callback) firstCallbacks[name] = callback end } })
    second.attach({ hooks = { wrap = function(name, _, callback) secondCallbacks[name] = callback end } })
    local mismatches = {}
    local scope = first.prepare({
        layoutKey = "FirstLayout", rareTalentKeys = {}, epicTalentKeys = {},
    }, "FirstTrait", function(checkpoint) mismatches[#mismatches + 1] = checkpoint end)
    lu.assertEquals(secondCallbacks.CreateTalentTree(nil, {}, function() return "native" end,
        { TraitName = "OtherTrait" }), "native")
    first.clear(scope)
    lu.assertEquals(mismatches, { "hex-tree-contact" })
    lu.assertNotNil(firstCallbacks.CreateTalentTree)
end

function TestSpellAcquisitions.testNativeGodSentPresenceDoesNotSteerThePublishedPairOrSpecialTalents()
    local callbacks = {}
    tree.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } })
    for _, nativeDuo in ipairs({ "NativeDuo", false }) do
        local diagnostics = {}
        local result = tree.realize({
            layoutKey = "ExpectedLayout", rareTalentKeys = { "RareExpected" },
            epicTalentKeys = { "EpicExpected" },
            godSent = { olympianTalentKey = "PublishedDuo" },
        }, "SpellTrait", function(checkpoint) diagnostics[#diagnostics + 1] = checkpoint end, function()
            return callbacks.CreateTalentTree(nil, nil, function()
                local layout = callbacks.GetRandomValue(nil, nil, function(values) return values[1] end,
                    { { Name = "NativeLayout" }, { Name = "ExpectedLayout" } })
                local rare = callbacks.RemoveRandomValue(nil, nil, function(values) return table.remove(values, 1) end,
                    { "RareOther", "RareExpected" })
                local epic = callbacks.RemoveRandomValue(nil, nil, function(values) return table.remove(values, 1) end,
                    { "EpicExpected" })
                local duo
                if nativeDuo then
                    duo = callbacks.RemoveRandomValue(nil, nil, function(values) return table.remove(values, 1) end,
                        { nativeDuo, "PublishedDuo" })
                end
                return { layout.Name, rare, epic, duo }
            end, { TraitName = "SpellTrait" })
        end)
        lu.assertEquals(result, { "ExpectedLayout", "RareExpected", "EpicExpected", nativeDuo or nil })
        lu.assertEquals(diagnostics, {})
    end
end

function TestSpellAcquisitions.testNativeGodSentEligibilityRemainsActiveWithoutAPublishedPair()
    local callbacks = {}
    tree.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } })
    local priorTalentData = _G.SpellTalentData
    local requirements = {}
    _G.SpellTalentData = { ServeDuoGameRequirements = requirements }
    for _, nativeEligible in ipairs({ true, false }) do
        local diagnostics = {}
        local result = tree.realize({
            layoutKey = "ExpectedLayout", rareTalentKeys = { "RareExpected" }, epicTalentKeys = { "EpicExpected" },
        }, "SpellTrait", function(checkpoint) diagnostics[#diagnostics + 1] = checkpoint end, function()
            return callbacks.CreateTalentTree(nil, nil, function()
                local layout = callbacks.GetRandomValue(nil, nil, function(values) return values[1] end,
                    { { Name = "NativeLayout" }, { Name = "ExpectedLayout" } })
                local rare = callbacks.RemoveRandomValue(nil, nil, function(values) return table.remove(values, 1) end,
                    { "RareOther", "RareExpected" })
                local epic = callbacks.RemoveRandomValue(nil, nil, function(values) return table.remove(values, 1) end,
                    { "EpicExpected" })
                local nativeEligibility = function(_, receivedRequirements)
                    lu.assertIs(receivedRequirements, requirements)
                    return nativeEligible
                end
                local eligible = callbacks.IsGameStateEligible
                    and callbacks.IsGameStateEligible(nil, nil, nativeEligibility, {}, requirements)
                    or nativeEligibility({}, requirements)
                local duo
                if eligible then
                    duo = callbacks.RemoveRandomValue(nil, nil, function(values) return table.remove(values, 1) end,
                        { "NativeDuo" })
                end
                return { layout.Name, rare, epic, duo }
            end, { TraitName = "SpellTrait" })
        end)
        lu.assertEquals(result, { "ExpectedLayout", "RareExpected", "EpicExpected", nativeEligible and "NativeDuo" or nil })
        lu.assertEquals(diagnostics, {})
    end
    _G.SpellTalentData = priorTalentData
end

local function capture(state, payload, treeAdapter, spellAdapter, isBound)
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback)
        local prior = callbacks[name]
        callbacks[name] = function(_, runtime, base, ...)
            return callback(nil, runtime, function(...)
                if prior then return prior(nil, runtime, base, ...) end
                return base(...)
            end, ...)
        end
    end } }
    local completed, mismatches, claims = {}, {}, 0
    local handle = {}
    local claimed = {}
    local room = {
        current = function() return { id = "room" } end,
        bound = function(_, _, item)
            if isBound == false then return claimed[item] end
            return item and handle or nil
        end,
        peek = function() return payload end,
        begin = function() return true end,
        claimReady = function(_, _, contact, item, compatible)
            if isBound ~= false or compatible(payload.transaction, contact) == nil then return nil end
            claims = claims + 1
            claimed[item] = handle
            return handle, payload
        end,
    }
    local session = {
        complete = function(_, value) completed[#completed + 1] = value end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint, expected, observed }
        end,
    }
    treeAdapter = treeAdapter or tree
    spellAdapter = spellAdapter or spell
    treeAdapter.attach(module)
    spellAdapter.attach(module, session, function() return state end, function() end, room, treeAdapter)
    nativePregeneration(callbacks)
    return callbacks, completed, mismatches, function() return claims end
end

function TestSpellAcquisitions.testUnboundSpellSteersTheTreeWithoutComparingTheLaterPlayerSelection()
    local prior = _G.SpellData
    _G.SpellData = {
        SpellOne = { TraitName = "SpellOneTrait" }, SpellTwo = { TraitName = "SpellTwoTrait" },
        SpellThree = { TraitName = "SpellThreeTrait" },
    }
    local offer = {
        kind = "traits", giver = "SpellDrop", selected = "option-1",
        options = {
            { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" },
        },
        hexTree = { layoutKey = "Lung", rareTalentKeys = {}, epicTalentKeys = {} },
    }
    local detail = {
        disposition = "normal", lifecyclePoint = "roomRewardPickup", gameName = "SpellDrop", traitOffer = offer,
    }
    local payload = { transaction = { kind = "acquisition", roles = { detail } }, detail = detail }
    local callbacks, completed, mismatches, claims = capture(
        { state = "synchronized" }, payload, nil, nil, false)
    local item = { Name = "SpellDrop" }
    callbacks.OpenSpellScreen(nil, nil, function(source)
        local screen = { Source = source, Components = {} }
        callbacks.CreateSpellButtons(nil, nil, function(value)
            local values = callbacks.GetEligibleSpells(nil, nil, function() return { "Other" } end, value)
            for index = 1, 3 do
                local name = callbacks.RemoveRandomValue(nil, nil,
                    function(pool) return table.remove(pool, 1) end, values)
                value.Components[index] = { TraitName = _G.SpellData[name].TraitName }
            end
        end, screen)
        callbacks.AcceptAndCloseSpellScreen(nil, nil, function()
            return callbacks.CreateTalentTree(nil, nil, function()
                return { Name = "Lung", {} }
            end, _G.SpellData.SpellTwo)
        end, screen, screen.Components[2])
    end, item, {}, nil)
    lu.assertEquals(claims(), 1)
    lu.assertEquals(#completed, 1)
    lu.assertEquals(mismatches, {})
    _G.SpellData = prior
end

function TestSpellAcquisitions.testFreshImportedSpellAdapterUsesTheProvidedHexTree()
    local prior = _G.SpellData
    _G.SpellData = {
        SpellOne = { TraitName = "SpellOneTrait" }, SpellTwo = { TraitName = "SpellTwoTrait" },
        SpellThree = { TraitName = "SpellThreeTrait" }, Other = { TraitName = "OtherTrait" },
    }
    for selected = 1, 3 do
        local state = { state = "synchronized" }
        local payload = { detail = { traitOffer = {
            kind = "traits", giver = "SpellDrop", selected = "option-" .. selected,
            options = {
                { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" },
            },
            hexTree = { layoutKey = "Lung", rareTalentKeys = { "Rare" }, epicTalentKeys = { "Epic" } },
        } } }
        local freshTree = assert(loadfile("src/mods/spells/hex_tree.lua"))().create()
        local freshSpell = assert(loadfile("src/mods/room/timeline/acquisitions/spell/hooks.lua"))()
        local callbacks, completed, mismatches = capture(state, payload, freshTree, freshSpell)
        local item, screen = { Name = "SpellDrop" }, nil
        lu.assertNil(callbacks.PregenerateSpells)
        local installed, bonus
        callbacks.OpenSpellScreen(nil, nil, function(source)
            screen = { Source = source, Components = {} }
            callbacks.CreateSpellButtons(nil, nil, function(value)
                local pool = callbacks.GetEligibleSpells(nil, nil, function() return { "Other" } end, value)
                for index = 1, 3 do
                    local name = callbacks.RemoveRandomValue(nil, nil,
                        function(values) return table.remove(values, 1) end,
                        pool)
                    value.Components[index] = {
                        TraitName = _G.SpellData[name].TraitName, BonusTalentPoints = index - 1,
                    }
                end
            end, screen)
            callbacks.AcceptAndCloseSpellScreen(nil, nil, function(_, button)
                installed, bonus = button.TraitName, button.BonusTalentPoints
                return callbacks.CreateTalentTree(nil, nil, function()
                    local rare = callbacks.RemoveRandomValue(nil, nil,
                        function(values) return table.remove(values, 1) end, { "Rare" })
                    local epic = callbacks.RemoveRandomValue(nil, nil,
                        function(values) return table.remove(values, 1) end, { "Epic" })
                    return { Name = "Lung", { { Name = rare }, { Name = epic } } }
                end, { TraitName = button.TraitName })
            end, screen, screen.Components[selected])
        end, item, {}, nil)
        lu.assertEquals(installed, payload.detail.traitOffer.options[selected].key)
        lu.assertEquals(bonus, selected - 1)
        lu.assertEquals(#completed, 1)
        lu.assertEquals(mismatches, {})
    end
    _G.SpellData = prior
end

function TestSpellAcquisitions.testSelectedSpellTreeConsumesItsScopeBetweenNativePresentationWaits()
    local prior = _G.SpellData
    _G.SpellData = {
        SpellOne = { TraitName = "SpellOneTrait" },
        SpellTwo = { TraitName = "SpellTwoTrait" },
        SpellThree = { TraitName = "SpellThreeTrait" },
        Other = { TraitName = "OtherTrait" },
    }
    local offer = {
        kind = "traits", giver = "SpellDrop", selected = "option2",
        options = {
            { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" },
        },
        hexTree = { layoutKey = "ExpectedLayout", rareTalentKeys = {}, epicTalentKeys = {} },
    }
    local detail = {
        disposition = "normal", lifecyclePoint = "roomRewardPickup", gameName = "SpellDrop", traitOffer = offer,
    }
    local payload = { transaction = { kind = "acquisition", roles = { detail } }, detail = detail }
    local callbacks, completed, mismatches = capture({ state = "synchronized" }, payload)
    local item = { Name = "SpellDrop" }
    local selectedTrees, selectedLayout = 0, nil
    local native = coroutine.create(function()
        callbacks.OpenSpellScreen(nil, nil, function(source)
            local screen = { Source = source, Components = {
                { TraitName = "SpellTwoTrait", SpellName = "SpellTwo" },
            } }
            return callbacks.AcceptAndCloseSpellScreen(nil, nil, function(_, button)
                coroutine.yield("before-selected-tree")
                local result = callbacks.CreateTalentTree(nil, nil, function()
                    selectedTrees = selectedTrees + 1
                    selectedLayout = callbacks.GetRandomValue(nil, nil,
                        function(values) return values[1] end,
                        { { Name = "NativeLayout" }, { Name = "ExpectedLayout" } })
                    return "selected-tree"
                end, _G.SpellData[button.SpellName])
                coroutine.yield("after-selected-tree")
                return result
            end, screen, screen.Components[1])
        end, item, {}, nil)
    end)
    local resumed, yielded = coroutine.resume(native)
    lu.assertTrue(resumed)
    lu.assertEquals(yielded, "before-selected-tree")
    local before = callbacks.CreateTalentTree(nil, nil, function()
        return callbacks.GetRandomValue(nil, nil, function(values) return values[1] end,
            { { Name = "NativeBefore" }, { Name = "ExpectedLayout" } })
    end, _G.SpellData.Other)
    lu.assertEquals(before.Name, "NativeBefore")

    resumed, yielded = coroutine.resume(native)
    lu.assertTrue(resumed)
    lu.assertEquals(yielded, "after-selected-tree")
    lu.assertEquals(selectedTrees, 1)
    lu.assertEquals(selectedLayout.Name, "ExpectedLayout")
    local after = callbacks.CreateTalentTree(nil, nil, function()
        return callbacks.GetRandomValue(nil, nil, function(values) return values[1] end,
            { { Name = "NativeAfter" }, { Name = "ExpectedLayout" } })
    end, _G.SpellData.SpellTwo)
    lu.assertEquals(after.Name, "NativeAfter")

    resumed = coroutine.resume(native)
    lu.assertTrue(resumed)
    lu.assertEquals(coroutine.status(native), "dead")
    lu.assertEquals(#completed, 1)
    lu.assertEquals(mismatches, {})
    _G.SpellData = prior
end

function TestSpellAcquisitions.testSelectedSpellTreeErrorRetiresItsNativeConstructionScope()
    local prior = _G.SpellData
    _G.SpellData = {
        SpellTwo = { TraitName = "SpellTwoTrait" }, Other = { TraitName = "OtherTrait" },
    }
    local offer = {
        kind = "traits", giver = "SpellDrop", selected = "option2",
        options = { { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" } },
        hexTree = { layoutKey = "ExpectedLayout", rareTalentKeys = {}, epicTalentKeys = {} },
    }
    local detail = {
        disposition = "normal", lifecyclePoint = "roomRewardPickup", gameName = "SpellDrop", traitOffer = offer,
    }
    local payload = { transaction = { kind = "acquisition", roles = { detail } }, detail = detail }
    local callbacks = capture({ state = "synchronized" }, payload)
    local item = { Name = "SpellDrop" }
    local ok = pcall(callbacks.OpenSpellScreen, nil, nil, function(source)
        local screen = { Source = source, Components = {
            { TraitName = "SpellTwoTrait", SpellName = "SpellTwo" },
        } }
        return callbacks.AcceptAndCloseSpellScreen(nil, nil, function(_, button)
            return callbacks.CreateTalentTree(nil, nil, function()
                error("native tree failure")
            end, _G.SpellData[button.SpellName])
        end, screen, screen.Components[1])
    end, item, {}, nil)
    lu.assertFalse(ok)

    local unrelated = callbacks.CreateTalentTree(nil, nil, function()
        return callbacks.GetRandomValue(nil, nil, function(values) return values[1] end,
            { { Name = "NativeAfterError" }, { Name = "ExpectedLayout" } })
    end, _G.SpellData.Other)
    lu.assertEquals(unrelated.Name, "NativeAfterError")
    _G.SpellData = prior
end

function TestSpellAcquisitions.testOpenReturnWithoutSelectionSilentlyClearsTheNonObligatedScope()
    local prior = _G.SpellData
    _G.SpellData = { SpellOne = { TraitName = "SpellOneTrait" } }
    local payload = { detail = { traitOffer = {
        kind = "traits", giver = "SpellDrop", selected = "option1",
        options = { { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" } },
        hexTree = { layoutKey = "Lung", rareTalentKeys = {}, epicTalentKeys = {} },
    } } }
    local callbacks, completed, mismatches = capture({ state = "synchronized" }, payload)
    local item = { Name = "SpellDrop" }
    callbacks.OpenSpellScreen(nil, nil, function() return "native-return" end, item, {}, nil)
    lu.assertEquals(completed, {})
    lu.assertEquals(mismatches, {})
    local delegated = false
    callbacks.OpenSpellScreen(nil, nil, function() delegated = true end, item, {}, nil)
    lu.assertTrue(delegated)
    _G.SpellData = prior
end

function TestSpellAcquisitions.testAspectRoutedSpellDropPassesThroughWithoutAnOffer()
    local callbacks, completed = capture({ state = "synchronized" }, { detail = {} })
    local called = false
    callbacks.OpenSpellScreen(nil, nil, function() called = true end, { Name = "SpellDrop" }, {}, nil)
    lu.assertTrue(called)
    lu.assertEquals(completed, {})
end
