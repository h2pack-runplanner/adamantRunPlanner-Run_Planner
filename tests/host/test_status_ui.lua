-- luacheck: globals TestStatusUi
local lu = require("luaunit")
local statusUi = require("mods.host.status_ui")
local hostData = require("mods.host.data")
local nativeGame = require("tests.harness.native_game")

TestStatusUi = {}

local function inactive()
    return { state = "inactive", reason = "not-started" }
end

local function canvas(lines, tab, detailTab)
    local bars = {}
    return {
        TextWrapped = function(text) lines[#lines + 1] = text end,
        BeginTabBar = function(id) bars[#bars + 1] = id; return true end,
        EndTabBar = function() table.remove(bars) end,
        BeginTabItem = function(label)
            local selected = bars[#bars] == "plan_details" and (detailTab or "Arcana") or (tab or "Plan")
            return label == selected
        end,
        EndTabItem = function() end,
        CollapsingHeader = function() return true end,
        PushID = function() end, PopID = function() end,
        Indent = function() end, Unindent = function() end,
    }
end

local function publishedPlan()
    local file = assert(io.open("fixtures/execution-plan/automatic-boss.execution.json", "rb"))
    local raw = file:read("*a")
    file:close()
    return assert(require("mods.protocol.decoder").decode(assert(require("mods.protocol.json").decode(raw))))
end

function TestStatusUi:setUp()
    self.labelCalls = 0
    self.restore = nativeGame.install({ GetDisplayName = function(args)
        self.labelCalls = self.labelCalls + 1
        local labels = {
            WeaponStaffSwing = "Witch's Staff", BaseStaffAspect = "Aspect of Melinoe",
            BossMetaUpgradeKeepsake = "Crystal Figurine", ChanneledCast = "The Sorceress",
            HealingReductionShrineUpgrade = "Vow of Scars",
        }
        return labels[args.Text] or args.Text
    end })
end

function TestStatusUi:tearDown()
    self.restore()
end

function TestStatusUi.testStorageIncludesTheDefaultDisabledRoomGuideSetting()
    local storage = hostData.buildStorage()
    lu.assertEquals(#storage, 2)
    lu.assertEquals(storage[1].alias, "ActivePlanSlot")
    lu.assertEquals(storage[1].default, 1)
    lu.assertEquals(storage[1].min, 1)
    lu.assertEquals(storage[1].max, 6)
    lu.assertNil(storage[1].persist)
    lu.assertEquals(storage[2], {
        type = "bool", alias = "ShowRoomGuide", label = "Show room guide",
        tooltip = "Show read-only planned room instructions on the HUD.", default = false,
    })
end

function TestStatusUi.testInspectionUsesTheBoundInboxCapabilityDirectly()
    local loads, statusReads, selections, drawn = 0, 0, {}, {}
    local inbox = {
        activeSlot = function() return 1 end,
        select = function(slot) selections[#selections + 1] = slot end,
        load = function(slot) loads = loads + 1; lu.assertEquals(slot, 1) end,
        plan = function() end,
        status = function()
            statusReads = statusReads + 1
            return { file = "present", inspection = "inspected", protocol = 10 }
        end,
    }
    local ui = statusUi.bind(inbox, inactive)
    local field, guideField, checkbox = { read = function() return 1 end }, { read = function() return false end }, nil
    local widgets = {
        dropdown = function(target) lu.assertEquals(target, field) end,
        checkbox = function(target, opts) checkbox = { target = target, opts = opts } end,
        button = function() return true end,
        text = function(value) drawn[#drawn + 1] = value end,
    }

    ui.drawTab(nil, {
        data = { get = function(alias)
            return alias == "ActivePlanSlot" and field or guideField
        end },
        draw = { widgets = widgets, imgui = canvas(drawn) },
    })

    lu.assertEquals(loads, 1)
    lu.assertEquals(statusReads, 2)
    lu.assertEquals(selections, {})
    lu.assertEquals(checkbox.target, guideField)
    lu.assertEquals(checkbox.opts, { id = "show_room_guide", label = "Show room guide" })
    lu.assertStrContains(table.concat(drawn, "\n"), "File: present | Protocol: 10")
end

function TestStatusUi.testActivePlanSlotIsSelectedFromThePersistentUiField()
    local selected, loaded, dropdown = nil, nil, nil
    local inbox = {
        activeSlot = function() return 1 end,
        select = function(slot) selected = slot end,
        load = function(slot) loaded = slot end,
        plan = function() end,
        status = function() return { file = "not-inspected", protocol = "unknown" } end,
    }
    local field = {
        read = function() return 4 end,
    }
    local ui = statusUi.bind(inbox, inactive)
    local widgets = {
        dropdown = function(target, opts)
            dropdown = { target = target, opts = opts }
        end,
        checkbox = function() end,
        button = function() return false end,
        text = function() end,
    }

    ui.drawTab(nil, { data = { get = function(alias)
        return alias == "ActivePlanSlot" and field or { read = function() return false end }
    end }, draw = { widgets = widgets, imgui = canvas({}) } })

    lu.assertEquals(dropdown.target, field)
    lu.assertEquals(dropdown.opts.values, { 1, 2, 3, 4, 5, 6 })
    lu.assertEquals(selected, 4)
    lu.assertNil(loaded)
end

local function inspect(plan, snapshot, tab, detailTab)
    local lines = {}
    local ui = statusUi.bind({
        activeSlot = function() return 6 end,
        select = function() error("unexpected slot selection") end,
        load = function() error("unexpected file read") end,
        plan = function() return plan end,
        status = function() return { file = "present", protocol = 37 } end,
    }, function() return snapshot end)
    local ctx = {
        data = { get = function() return { read = function() return 6 end } end },
        draw = { imgui = canvas(lines, tab, detailTab), widgets = {
            text = function(text) lines[#lines + 1] = text end,
            dropdown = function() end, checkbox = function() end,
            button = function() return false end,
        } },
    }
    ui.drawTab(nil, ctx)
    return table.concat(lines, "\n"), ui, ctx
end

function TestStatusUi:testPublishedLoadoutUsesReadableNamesAndCachesOnlyPlanPresentation()
    local plan = publishedPlan()
    plan.startingLoadout.fear.configuredRanks.HealingReductionShrineUpgrade = 2
    plan.startingLoadout.fear.effectiveRanks.HealingReductionShrineUpgrade = 1
    local postboss = plan.occurrences[#plan.occurrences]
    postboss.timeline.transactions[#postboss.timeline.transactions + 1] = {
        kind = "keepsakeChange", keepsakeKey = "UntranslatedKeepsake",
    }
    local text, ui, ctx = inspect(plan, inactive())
    lu.assertStrContains(text, "Weapon: Witch's Staff || Aspect: Aspect of Melinoe"
        .. " || Starting keepsake: Crystal Figurine")
    lu.assertStrContains(text, postboss.gameName .. ": UntranslatedKeepsake")
    lu.assertStrContains(text, "The Sorceress - Rank 3 (Epic, manual)")
    lu.assertNotStrContains(text, "Vow of Scars")
    local calls = self.labelCalls
    ui.drawTab(nil, ctx)
    lu.assertEquals(self.labelCalls, calls)
    local lines = {}
    ctx.draw.imgui = canvas(lines, "Plan", "Fear")
    ui.drawTab(nil, ctx)
    text = table.concat(lines, "\n")
    lu.assertStrContains(text, "Vow of Scars: Configured 2 / Effective 1")
    lu.assertNotStrContains(text, "EnemyHealthShrineUpgrade")
    lu.assertNotStrContains(text, "The Sorceress")
    lines = {}
    ctx.draw.imgui = canvas(lines, "Plan", "Technical details")
    ui.drawTab(nil, ctx)
    text = table.concat(lines, "\n")
    lu.assertStrContains(text, "Project: " .. plan.projectId)
    lu.assertStrContains(text, "Fingerprint: " .. plan.planFingerprint)
    lu.assertNotStrContains(text, "The Sorceress")
    lu.assertNotStrContains(text, "Vow of Scars")
    lu.assertEquals(self.labelCalls, calls)
end

function TestStatusUi.testRunningPlanStaysSeparateFromPreviewAndRetainsFailureDetails()
    local frozen, other = publishedPlan(), publishedPlan()
    other.startingLoadout.weaponKey = "OtherWeapon"
    local first, last = frozen.occurrences[2], frozen.occurrences[1]
    local snapshot = {
        state = "synchronized", reason = "ready", slot = 2, plan = frozen, index = 2,
        current = first, lastExited = last, postbossAdmission = { gameName = "F_PostBoss01" },
    }
    local text, ui, ctx = inspect(other, snapshot, "Current Run")
    lu.assertStrContains(text, "Run: Synchronized | Steering: active")
    lu.assertStrContains(text, "Running plan: Slot 2")
    lu.assertStrContains(text, "Tracked room: " .. first.gameName)
    lu.assertStrContains(text, "Postboss resync succeeded at F_PostBoss01")
    lu.assertStrContains(text, "Weapon: Witch's Staff")
    lu.assertNotStrContains(text, "OtherWeapon")
    snapshot.state, snapshot.reason, snapshot.checkpoint = "desynchronized", "first-mismatch", "room-exit"
    snapshot.issue = { expected = { count = 4 }, observed = { count = 3 } }
    local lines = {}
    ctx.draw.imgui = canvas(lines, "Current Run")
    ctx.draw.widgets.text = function(line) lines[#lines + 1] = line end
    ui.drawTab(nil, ctx)
    text = table.concat(lines, "\n")
    lu.assertStrContains(text, "Run: Desynchronized | Steering: off")
    lu.assertStrContains(text, "Checkpoint: room-exit")
    lu.assertStrContains(text, "count: 4")
    lu.assertStrContains(text, "count: 3")
end

function TestStatusUi.testStatusDistinguishesStartupAdmissionCompletionAndFaults()
    for _, case in ipairs({
        { "inactive", "not-started", "Inactive", "off" },
        { "inactive", "admission-rejected", "Inactive", "off" },
        { "inactive", "configured-prefix-complete", "Plan complete", "off" },
        { "starting", "ready", "Starting", "active" },
        { "faulted", "executor-fault", "Executor fault", "off" },
    }) do
        local snapshot = { state = case[1], reason = case[2] }
        local text = inspect(nil, snapshot, "Current Run")
        lu.assertStrContains(text, "Run: " .. case[3] .. " | Steering: " .. case[4])
        lu.assertEquals(snapshot, { state = case[1], reason = case[2] })
    end
end

function TestStatusUi.testBadPreviewReportsDecoderReasonWithoutChangingRunStatus()
    local inbox = {
        activeSlot = function() return 1 end,
        select = function() end,
        load = function() return false end,
        plan = function() end,
        status = function() return {
            file = "present", protocol = "error", error = { code = "malformed-plan", message = "Invalid contract" },
        } end,
    }
    local snapshot = { state = "synchronized", reason = "ready" }
    local ui = statusUi.bind(inbox, function() return snapshot end)
    local lines = {}
    ui.drawTab(nil, {
        data = { get = function() return { read = function() return 1 end } end },
        draw = { imgui = canvas(lines), widgets = {
            text = function(line) lines[#lines + 1] = line end,
            dropdown = function() end, checkbox = function() end, button = function() return true end,
        } },
    })
    local text = table.concat(lines, "\n")
    lu.assertStrContains(text, "Reason: Invalid contract")
    lu.assertStrContains(text, "Run: Synchronized | Steering: active")
    lu.assertEquals(snapshot.state, "synchronized")
end

return TestStatusUi
