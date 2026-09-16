local planSummary = type(import) == "function" and import("mods/host/plan_summary.lua")
    or require("mods.host.plan_summary")

local ui = {}

local SLOT_VALUES = { 1, 2, 3, 4, 5, 6 }
local SLOT_LABELS = {
    [1] = "Slot 1",
    [2] = "Slot 2",
    [3] = "Slot 3",
    [4] = "Slot 4",
    [5] = "Slot 5",
    [6] = "Slot 6",
}

local STATUS_LABELS = {
    inactive = "Inactive", starting = "Starting", synchronized = "Synchronized",
    desynchronized = "Desynchronized", faulted = "Executor fault",
}
local STATUS_COLORS = {
    inactive = { color = { 0.7, 0.7, 0.7, 1 } },
    starting = { color = { 1, 0.8, 0.3, 1 } },
    synchronized = { color = { 0.4, 0.9, 0.5, 1 } },
    desynchronized = { color = { 1, 0.4, 0.4, 1 } },
    faulted = { color = { 1, 0.6, 0.3, 1 } },
}
local REASONS = {
    ["not-started"] = "No run has been admitted.",
    ["admission-rejected"] = "The selected plan could not be admitted.",
    ["configured-prefix-complete"] = "The planned route is complete. Native gameplay continues.",
    ["first-mismatch"] = "A checkpoint diverged. Steering has stopped; native gameplay continues.",
    ["executor-fault"] = "An executor fault stopped steering. Native gameplay continues.",
}

local function drawValues(imgui, label, value, ancestors)
    if type(value) ~= "table" then
        local text = type(value) == "number" and string.format("%.17g", value) or tostring(value)
        imgui.TextWrapped(label .. ": " .. text)
        return
    end
    ancestors = ancestors or {}
    if ancestors[value] then imgui.TextWrapped(label .. ": <cycle>"); return end
    if not imgui.CollapsingHeader(label) then return end
    ancestors[value] = true
    imgui.PushID(label)
    imgui.Indent()
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    if #keys == 0 then imgui.TextWrapped("(empty)") end
    for _, key in ipairs(keys) do drawValues(imgui, tostring(key), value[key], ancestors) end
    imgui.Unindent()
    imgui.PopID()
    ancestors[value] = nil
end

function ui.bind(inbox, inspectSession)
    assert(type(inbox) == "table" and type(inbox.activeSlot) == "function"
        and type(inbox.select) == "function" and type(inbox.load) == "function"
        and type(inbox.status) == "function" and type(inbox.plan) == "function",
        "status UI inbox dependency is required")
    assert(type(inspectSession) == "function", "status UI session inspection is required")

    -- Plans are immutable after decoding. Cache their display-only projection,
    -- not player state, and let replaced slot previews be collected.
    local summaries = setmetatable({}, { __mode = "k" })
    local function summaryFor(plan)
        if summaries[plan] == nil then
            summaries[plan] = planSummary.build(plan, function(key)
                local label = _G.GetDisplayName({ Text = key })
                return label ~= nil and label ~= "" and label or key
            end)
        end
        return summaries[plan]
    end

    local function logInspectionFailure(status)
        if not status.error or not rom or not rom.log or not rom.log.info then return end
        rom.log.info(
            "[RunPlanner] published-plan inspection failed code="
                .. tostring(status.error.code)
                .. " reason=" .. tostring(status.error.message)
        )
    end

    local function drawPlan(imgui, plan)
        local summary = summaryFor(plan)
        imgui.TextWrapped(summary.route)
        imgui.TextWrapped("Weapon: " .. summary.weapon .. " || Aspect: " .. summary.aspect
            .. " || Starting keepsake: " .. summary.keepsake)
        if #summary.keepsakeChanges > 0 and imgui.CollapsingHeader("Planned keepsake changes") then
            for _, line in ipairs(summary.keepsakeChanges) do imgui.TextWrapped(line) end
        end
        if not imgui.BeginTabBar("plan_details") then return end
        if imgui.BeginTabItem("Arcana") then
            imgui.TextWrapped("Starting Arcana (" .. #summary.arcana .. ")")
            if #summary.arcana == 0 then imgui.TextWrapped("None") end
            for _, line in ipairs(summary.arcana) do imgui.TextWrapped(line) end
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem("Fear") then
            imgui.TextWrapped("Fear vows (" .. #summary.fear .. ")")
            if #summary.fear == 0 then imgui.TextWrapped("None") end
            for _, line in ipairs(summary.fear) do imgui.TextWrapped(line) end
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem("Technical details") then
            imgui.TextWrapped("Project: " .. plan.projectId)
            imgui.TextWrapped("Fingerprint: " .. tostring(plan.planFingerprint))
            imgui.TextWrapped("Protocol: " .. plan.protocolVersion .. " | Catalog: " .. plan.catalogVersion)
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end

    local function drawSession(drawApi, snapshot)
        local label = snapshot.reason == "configured-prefix-complete" and "Plan complete"
            or STATUS_LABELS[snapshot.state] or snapshot.state
        local active = snapshot.state == "synchronized" or snapshot.state == "starting"
        drawApi.widgets.text("Run: " .. label .. " | Steering: " .. (active and "active" or "off"),
            STATUS_COLORS[snapshot.state])
        if REASONS[snapshot.reason] then drawApi.imgui.TextWrapped(REASONS[snapshot.reason]) end
        if snapshot.checkpoint then drawApi.imgui.TextWrapped("Checkpoint: " .. snapshot.checkpoint) end
    end

    local function drawRun(imgui, snapshot)
        local plan = snapshot.plan
        if plan == nil then
            imgui.TextWrapped("No plan is attached to this run.")
        else
            imgui.TextWrapped("Running plan: " .. (SLOT_LABELS[snapshot.slot] or "Unknown slot"))
            imgui.TextWrapped(summaryFor(plan).route)
            imgui.TextWrapped("This is the frozen run plan; inspecting or publishing a slot does not replace it.")
            local total = #plan.selectedOccurrenceIds
            if snapshot.current then
                imgui.TextWrapped("Tracked room: " .. snapshot.current.gameName
                    .. " (" .. snapshot.index .. " / " .. total .. ")")
            else
                local completed = math.min((snapshot.index or 1) - 1, total)
                imgui.TextWrapped("Planned rooms exited: " .. completed .. " / " .. total)
                local nextId = plan.selectedOccurrenceIds[snapshot.index or 1]
                if nextId then imgui.TextWrapped("Next planned room: " .. plan.occurrencesById[nextId].gameName) end
            end
            if snapshot.restoredRoom then imgui.TextWrapped("Restored room: " .. snapshot.restoredRoom) end
            if snapshot.lastExited then imgui.TextWrapped("Last exited: " .. snapshot.lastExited.gameName) end
            if snapshot.postbossAdmission then
                imgui.TextWrapped("Postboss resync succeeded at " .. snapshot.postbossAdmission.gameName)
            end
            if imgui.CollapsingHeader("Frozen plan loadout") then
                imgui.PushID("frozen_plan")
                drawPlan(imgui, plan)
                imgui.PopID()
            end
        end
        if snapshot.issue then
            if imgui.CollapsingHeader("First failure details") then
                drawValues(imgui, "Expected", snapshot.issue.expected)
                drawValues(imgui, "Observed", snapshot.issue.observed)
            end
        elseif snapshot.state == "synchronized" then
            imgui.TextWrapped("No mismatch detected at the existing checkpoints.")
        end
    end

    local function drawPreview(ctx)
        local drawApi = ctx.draw
        local imgui = drawApi.imgui
        assert(ctx.data and type(ctx.data.get) == "function", "status UI data dependency is required")
        local field = ctx.data.get("ActivePlanSlot")
        assert(field ~= nil, "status UI ActivePlanSlot data field is required")
        drawApi.widgets.dropdown(field, {
            id = "active_plan_slot",
            label = "Plan for next run / resync",
            values = SLOT_VALUES,
            displayValues = SLOT_LABELS,
        })
        local selectedSlot = field:read()
        if inbox.activeSlot() ~= selectedSlot then inbox.select(selectedSlot) end
        if drawApi.widgets.button("Inspect / Reload Selected Plan", { id = "run_planner_inspect" }) then
            inbox.load(selectedSlot)
            logInspectionFailure(inbox.status())
        end
        local inboxStatus = inbox.status()
        drawApi.widgets.text(
            "File: " .. tostring(inboxStatus.file)
                .. " | Protocol: " .. tostring(inboxStatus.protocol))
        if inboxStatus.error then
            drawApi.widgets.text("Error: " .. tostring(inboxStatus.error.code))
            if inboxStatus.error.message then
                imgui.TextWrapped("Reason: " .. tostring(inboxStatus.error.message))
            end
        end
        local plan = inbox.plan()
        if plan then
            drawPlan(imgui, plan)
        elseif not inboxStatus.error then
            imgui.TextWrapped("Inspect this slot to preview its published loadout.")
        end
    end

    local function draw(_, ctx)
        local drawApi = ctx.draw
        local imgui = drawApi.imgui
        local snapshot = inspectSession()
        drawSession(drawApi, snapshot)
        if not imgui.BeginTabBar("run_planner_inspector") then return end
        if imgui.BeginTabItem("Plan") then
            drawPreview(ctx)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem("Current Run") then
            drawRun(imgui, snapshot)
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
    return { drawTab = draw, drawQuickContent = draw }
end

return ui
