-- luacheck: globals TestChoiceScreenGuidance
local lu = require("luaunit")
local screenGuidance = require("mods.guidance.choice_screen")

TestChoiceScreenGuidance = {}

function TestChoiceScreenGuidance:setUp()
    self.priorCreate, self.priorAttach, self.priorDestroy = _G.CreateScreenComponent, _G.Attach, _G.Destroy
    self.created, self.attached, self.destroyed = {}, {}, {}
    _G.CreateScreenComponent = function(_args)
        local result = { Id = #self.created + 501 }
        self.created[#self.created + 1] = result
        return result
    end
    _G.Attach = function(args) self.attached[#self.attached + 1] = args end
    _G.Destroy = function(args) self.destroyed[#self.destroyed + 1] = args.Ids[1] end
    self.runtime = { data = { read = function() return true end } }
    self.state = { state = "synchronized" }
    self.guidance = screenGuidance.create()
end

function TestChoiceScreenGuidance:tearDown()
    _G.CreateScreenComponent, _G.Attach, _G.Destroy = self.priorCreate, self.priorAttach, self.priorDestroy
end

function TestChoiceScreenGuidance:testMarksOnlyExactChaosBlessingAndRegistersOwnedComponent()
    local screen = { Components = {}, UpgradeButtons = {
        { Id = 10, Data = { OnExpire = { TraitData = { Name = "RepeatedBlessing" } } } },
        { Id = 11, Data = { OnExpire = { TraitData = { Name = "ChosenBlessing" } } } },
    } }
    self.guidance.present(self.runtime, self.state, screen, "ChosenBlessing", true)
    lu.assertEquals(self.attached, { { Id = 501, DestinationId = 11, OffsetX = -24, OffsetY = 0 } })
    lu.assertEquals(screen.Components.RunPlannerPlannedChoiceMarker.Id, 501)
    self.guidance.clear(screen)
    lu.assertEquals(self.destroyed, { 501 })
    lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
end

function TestChoiceScreenGuidance:testRetainsSourceContextWhileDisabledThenRendersOnRefresh()
    local source = {}
    local screen = { Source = source, Components = {}, UpgradeButtons = { { Id = 7, Data = { Name = "Target" } } } }
    self.runtime.data.read = function() return false end
    self.guidance.bindSource(self.runtime, self.state, source, "Target", false)
    self.guidance.constructed(self.runtime, screen)
    lu.assertEquals(#self.created, 0)
    self.runtime.data.read = function() return true end
    self.guidance.refresh(self.runtime, self.state)
    lu.assertEquals(self.attached[1].DestinationId, 7)
end

function TestChoiceScreenGuidance:testSpellButtonsUseTraitIdentityAndClearOnAccept()
    local screen = { Source = {}, Components = {
        PurchaseButton1 = { Id = 11, TraitName = "Other" },
        PurchaseButton2 = { Id = 12, TraitName = "Chosen" },
        PurchaseButton3 = { Id = 13, TraitName = "Third" },
    } }
    self.guidance.present(self.runtime, self.state, screen, "Chosen", false)
    lu.assertEquals(self.attached[1].DestinationId, 12)
    local callbacks = {}
    self.guidance.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } },
        function() return self.state end)
    callbacks.AcceptAndCloseSpellScreen(nil, self.runtime, function() return true end, screen, {})
    lu.assertEquals(self.destroyed, { 501 })
    self.guidance.refresh(self.runtime, self.state)
    lu.assertEquals(#self.created, 1)
end

function TestChoiceScreenGuidance:testAmbiguousOrMissingRowsSafelyOmitMarker()
    local screen = { Components = {}, UpgradeButtons = {
        { Id = 1, Data = { Name = "Same" } }, { Id = 2, Data = { Name = "Same" } },
    } }
    self.guidance.present(self.runtime, self.state, screen, "Same", false)
    lu.assertEquals(self.created, {})
    screen.UpgradeButtons = { { Id = 3, Data = { Name = "Different" } } }
    self.guidance.refresh(self.runtime, self.state)
    lu.assertEquals(self.created, {})
    screen.UpgradeButtons = { { Id = 4, InteractBlocks = { TraitLocked = true }, Data = { Name = "Same" } } }
    self.guidance.present(self.runtime, self.state, screen, "Same", false)
    lu.assertEquals(self.created, {})
end

function TestChoiceScreenGuidance:testSessionReplacementRetiresTheOwnedMarker()
    local screen = { Components = {}, UpgradeButtons = { { Id = 4, Data = { Name = "Target" } } } }
    self.state.route = {}
    self.guidance.present(self.runtime, self.state, screen, "Target", false)
    self.guidance.refresh(self.runtime, { state = "synchronized", route = {} })
    lu.assertEquals(self.destroyed, { 501 })
    lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
end

function TestChoiceScreenGuidance:testRegisteredConstructionAndRarifyHooksUseTheSourceBoundContext()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    self.guidance.attach(module, function() return self.state end)
    local source = {}
    local screen = { Source = source, Components = {}, UpgradeButtons = { { Id = 8, Data = { Name = "Target" } } } }
    self.guidance.bindSource(self.runtime, self.state, source, "Target", false)
    callbacks.CreateBoonLootButtons(nil, self.runtime, function() return nil end, screen, {}, false, {})
    lu.assertEquals(self.attached[1].DestinationId, 8)
    callbacks.TryUpgradeBoon(nil, self.runtime, function(_, currentScreen)
        currentScreen.UpgradeButtons = { { Id = 9, Data = { Name = "Target" } } }
        return currentScreen.UpgradeButtons[1]
    end, {}, screen, {})
    lu.assertEquals(self.destroyed, { 501 })
    lu.assertEquals(self.attached[2].DestinationId, 9)
    callbacks.CloseUpgradeChoiceScreen(nil, self.runtime, function() return true end, screen, {})
    lu.assertEquals(self.destroyed, { 501, 502 })
end

function TestChoiceScreenGuidance:testRegisteredNativeRerollRetainsContextUntilRebuiltRowsExist()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    self.guidance.attach(module, function() return self.state end)
    local screen = { Components = {}, UpgradeButtons = { { Id = 4, Data = { Name = "Target" } } } }
    self.guidance.present(self.runtime, self.state, screen, "Target", false)
    callbacks.RerollBoonLoot(nil, self.runtime, function(currentScreen)
        callbacks.DestroyBoonLootButtons(nil, self.runtime, function() return true end, currentScreen, {})
        currentScreen.UpgradeButtons = { { Id = 5, Data = { Name = "Target" } } }
        callbacks.CreateBoonLootButtons(nil, self.runtime, function() return true end, currentScreen, {}, true, {})
        return true
    end, screen, {})
    lu.assertEquals(self.destroyed, { 501 })
    lu.assertEquals(self.attached[2].DestinationId, 5)
end

function TestChoiceScreenGuidance:testBoonInfoSuspendsAcrossSettingCommitsWithoutTouchingNativePins()
    local callbacks = {}
    self.guidance.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } },
        function() return self.state end)
    local pin, hover = { Id = 91, Alpha = 0 }, { Id = 92 }
    local screen = { Components = {}, PinOffsetX = 30, PinOffsetY = 4, ButtonOffsetX = 10,
        UpgradeButtons = { { Id = 4, PinIcon = pin, Highlight = hover, Data = { Name = "Target" } } } }
    self.guidance.present(self.runtime, self.state, screen, "Target", false)
    lu.assertEquals(self.attached[1], { Id = 501, DestinationId = 4, OffsetX = -4, OffsetY = 4 })
    callbacks.AttemptOpenUpgradeChoiceBoonInfo(nil, self.runtime, function()
        self.guidance.refresh(self.runtime, self.state)
        lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
        self.runtime.data.read = function() return false end
        self.guidance.refresh(self.runtime, self.state)
        self.runtime.data.read = function() return true end
        self.guidance.refresh(self.runtime, self.state)
        lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
    end, screen, {})
    callbacks.UpgradeChoiceScreenCloseBoonInfo(nil, self.runtime, function() end, {}, { Screen = screen })
    lu.assertNotNil(screen.Components.RunPlannerPlannedChoiceMarker)
    lu.assertEquals(pin, { Id = 91, Alpha = 0 })
    lu.assertEquals(hover, { Id = 92 })
    lu.assertEquals(self.destroyed, { 501 })
end

function TestChoiceScreenGuidance:testPendingSourceSurvivesDisabledRefreshButNotNewAdmission()
    local source = {}
    local screen = { Source = source, Components = {}, UpgradeButtons = { { Id = 4, Data = { Name = "Target" } } } }
    self.state.route = {}
    self.runtime.data.read = function() return false end
    self.guidance.bindSource(self.runtime, self.state, source, "Target", false)
    self.guidance.refresh(self.runtime, self.state)
    self.guidance.constructed(self.runtime, screen, self.state)
    self.runtime.data.read = function() return true end
    self.guidance.refresh(self.runtime, self.state)
    lu.assertNotNil(screen.Components.RunPlannerPlannedChoiceMarker)
    self.guidance.clear(screen)
    self.guidance.bindSource(self.runtime, self.state, source, "Target", false)
    self.state.route = {}
    self.guidance.constructed(self.runtime, screen, self.state)
    lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
end

function TestChoiceScreenGuidance:testPresentationFaultDoesNotStopGameplayOrKeepAnUnattachedMarker()
    local screen = { Components = {}, UpgradeButtons = { { Id = 4, Data = { Name = "Target" } } } }
    _G.Attach = function() error("unavailable native attachment") end
    self.guidance.present(self.runtime, self.state, screen, "Target", false)
    lu.assertNil(screen.Components.RunPlannerPlannedChoiceMarker)
    lu.assertEquals(self.destroyed, { 501 })
end

return TestChoiceScreenGuidance
