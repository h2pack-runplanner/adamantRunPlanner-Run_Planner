-- Exact screen/source-local markers; native hover and pins remain untouched.
local guidance = {}

function guidance.create()
    local instance = {}
    local screens = setmetatable({}, { __mode = "k" })
    local sources = setmetatable({}, { __mode = "k" })
    local function enabled(runtime, state)
        return state and state.state == "synchronized" and runtime and runtime.data
            and runtime.data.read("HighlightPlannedChoices") == true
    end

    local function hide(screen)
        local context = screens[screen]
        if context and context.marker and _G.Destroy then
            pcall(_G.Destroy, { Ids = { context.marker.Id } })
        end
        if context then context.marker = nil end
        if type(screen) == "table" and type(screen.Components) == "table" then
            screen.Components.RunPlannerPlannedChoiceMarker = nil
        end
    end

    local function retire(screen)
        hide(screen)
        screens[screen] = nil
    end

    local function suspend(screen, reason)
        hide(screen)
        if screens[screen] then screens[screen][reason] = true end
    end

    local function valid(context, state)
        return state and state.state == "synchronized" and context.state == state
            and context.route == state.route
    end

    local function render(runtime, state, screen, context)
        if not valid(context, state) or context.source ~= screen.Source
            or not enabled(runtime, state) or context.marker or context.rebuilding or context.infoOpen then return end
        local matches = {}
        local buttons = screen.UpgradeButtons or {
            screen.Components and screen.Components.PurchaseButton1,
            screen.Components and screen.Components.PurchaseButton2,
            screen.Components and screen.Components.PurchaseButton3,
        }
        for _, button in ipairs(buttons) do
            local data = button and button.Data
            local key = context.chaos and data and data.OnExpire and data.OnExpire.TraitData
                and data.OnExpire.TraitData.Name or data and data.Name or button.TraitName
            if key == context.selected then
                matches[#matches + 1] = button
            end
        end
        if #matches ~= 1 or (matches[1].InteractBlocks and next(matches[1].InteractBlocks))
            or type(_G.CreateScreenComponent) ~= "function" or type(_G.Attach) ~= "function" then return end
        local ok, marker = pcall(_G.CreateScreenComponent, {
            Name = "BlankObstacle", Group = "Combat_Menu_Overlay", Animation = "StoreItemPin", Alpha = 1,
        })
        if not ok then return end
        if marker and type(_G.Attach) == "function" then
            -- Spell rows reuse the upgrade-choice button geometry, but their
            -- screen does not copy its pin offsets.
            local layout = screen.UpgradeButtons and screen
                or (_G.ScreenData and _G.ScreenData.UpgradeChoice) or screen
            local attached = pcall(_G.Attach, {
                Id = marker.Id, DestinationId = matches[1].Id,
                OffsetX = (layout.PinOffsetX or 0) - (layout.ButtonOffsetX or 0) - 24,
                OffsetY = layout.PinOffsetY or 0,
            })
            if not attached then
                if _G.Destroy then pcall(_G.Destroy, { Ids = { marker.Id } }) end
                return
            end
        end
        if marker then
            context.marker = marker
            screen.Components = screen.Components or {}
            screen.Components.RunPlannerPlannedChoiceMarker = marker
        end
    end

    function instance.present(runtime, state, screen, selected, chaos)
        retire(screen)
        if type(screen) ~= "table" or type(selected) ~= "string" then return end
        if not state or state.state ~= "synchronized" then return end
        local context = { state = state, route = state.route, source = screen.Source,
            selected = selected, chaos = chaos }
        screens[screen] = context
        render(runtime, state, screen, context)
    end

    function instance.bindSource(runtime, state, source, selected, chaos)
        if type(source) == "table" and type(selected) == "string" then
            sources[source] = {
                runtime = runtime, state = state, route = state and state.route, selected = selected, chaos = chaos,
            }
        end
    end

    function instance.constructed(runtime, screen, state)
        local context = type(screen) == "table" and sources[screen.Source] or nil
        if context then
            sources[screen.Source] = nil
            if valid(context, state or context.state) then
                instance.present(runtime, state or context.state, screen, context.selected, context.chaos)
            end
        end
    end

    function instance.clear(screen)
        if screen then
            if screen.Source then sources[screen.Source] = nil end
            retire(screen)
            return
        end
        for value in pairs(screens) do retire(value) end
        for value in pairs(sources) do sources[value] = nil end
    end

    function instance.refresh(runtime, state)
        for screen, context in pairs(screens) do
            if not valid(context, state) or context.source ~= screen.Source then
                retire(screen)
            elseif enabled(runtime, state) then
                render(runtime, state, screen, context)
            else
                hide(screen)
            end
        end
        for source, context in pairs(sources) do
            if not valid(context, state) then sources[source] = nil end
        end
    end

    function instance.attach(module, getState)
        module.hooks.wrap("AcceptAndCloseSpellScreen", "run-planner-highlight-spell-close", function(_, _, base,
            screen, button)
            instance.clear(screen)
            return base(screen, button)
        end)
        module.hooks.wrap("CreateBoonLootButtons", "run-planner-highlight-source-screen", function(_, runtime,
            base, screen, loot, reroll, args)
            suspend(screen, "rebuilding")
            local result = base(screen, loot, reroll, args)
            instance.constructed(runtime, screen, getState(runtime))
            local context = screens[screen]
            if context then
                context.rebuilding = nil
                render(runtime, getState(runtime), screen, context)
            end
            return result
        end)
        module.hooks.wrap("CloseUpgradeChoiceScreen", "run-planner-highlight-choice-close", function(_, _, base,
            screen, button)
            instance.clear(screen)
            return base(screen, button)
        end)
        module.hooks.wrap("TryUpgradeBoon", "run-planner-highlight-choice-rarify", function(_, runtime,
            base, loot, screen, button)
            suspend(screen, "rebuilding")
            local result = base(loot, screen, button)
            if screens[screen] then
                screens[screen].rebuilding = nil
                instance.refresh(runtime, getState(runtime))
            end
            return result
        end)
        module.hooks.wrap("UpgradeChoiceScreenCloseBoonInfo", "run-planner-highlight-choice-boon-info", function(_, runtime,
            base, info, args)
            local result = base(info, args)
            if type(args) == "table" and screens[args.Screen] then
                screens[args.Screen].infoOpen = nil
                instance.refresh(runtime, getState(runtime))
            end
            return result
        end)
        module.hooks.wrap("AttemptOpenUpgradeChoiceBoonInfo", "run-planner-highlight-choice-boon-info-open", function(_, _,
            base, screen, button)
            suspend(screen, "infoOpen")
            return base(screen, button)
        end)
        module.hooks.wrap("RerollBoonLoot", "run-planner-highlight-choice-reroll", function(_, runtime, base,
            screen, button)
            suspend(screen, "rebuilding")
            local result = base(screen, button)
            if screens[screen] then
                screens[screen].rebuilding = nil
                instance.refresh(runtime, getState(runtime))
            end
            return result
        end)
        module.hooks.wrap("DestroyBoonLootButtons", "run-planner-highlight-choice-rows-destroy", function(_, _,
            base, screen, loot)
            suspend(screen, "rebuilding")
            return base(screen, loot)
        end)
        module.hooks.wrap("DestroyBoonLootButton", "run-planner-highlight-choice-row-destroy", function(_, _,
            base, screen, index)
            suspend(screen, "rebuilding")
            return base(screen, index)
        end)
        module.hooks.wrap("LeaveRoom", "run-planner-highlight-choice-room-leave", function(_, _, base,
            currentRun, door)
            instance.clear()
            return base(currentRun, door)
        end)
    end
    return instance
end
return guidance
