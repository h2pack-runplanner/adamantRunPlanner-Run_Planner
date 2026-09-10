-- Preserves planner bindings through native store button copies and applies
-- Hermes Shrine delivery disposition to the corresponding native rows.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local hooks = {}
local delayScope

local bindingFields = {
    "__runPlannerOfferKey", "__runPlannerGenerationKey", "__runPlannerTwistResultKey",
    "__runPlannerContractSourceOwner",
    "__runPlannerShrine", "__runPlannerShrineSourceKey",
}

local function capture()
    local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
    local bindings = {}
    for index, option in pairs(options or {}) do
        if type(option) == "table" then
            local binding = {}
            for _, field in ipairs(bindingFields) do binding[field] = option[field] end
            bindings[index] = binding
        end
    end
    return bindings
end

local function restore(bindings, screen)
    local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
    for index, binding in pairs(bindings or {}) do
        local option = options and options[index]
        local button = type(screen) == "table" and type(screen.Components) == "table"
            and screen.Components["PurchaseButton" .. index] or nil
        for _, target in ipairs({ option, button and button.Data }) do
            if type(target) == "table" then
                for _, field in ipairs(bindingFields) do target[field] = binding[field] end
            end
        end
    end
end

local function deliveryDelayChoices(active, options, room, state)
    local bySlot = {}
    local shrine = active and active.occurrence.overview.hermesShrine
    for _, offer in ipairs(shrine and shrine.offers or {}) do
        if offer.purchase ~= nil then bySlot[offer.slotIndex] = offer.purchase.roomDelay end
    end
    local refillHandle = active and room.resolve(state, active,
        { kind = "travelDealRefill", carrier = "hermesShrine" }) or nil
    local refillPayload = refillHandle and room.peek(state, refillHandle) or nil
    local refill = refillPayload and refillPayload.transaction and refillPayload.transaction.refill
    local replacement = refill and refill.replacement
    if replacement and replacement.purchase ~= nil then
        bySlot[replacement.slotIndex] = replacement.purchase.roomDelay
    end

    local indices = {}
    for index, option in pairs(options or {}) do
        if type(index) == "number" and type(option) == "table" and not option.Processed then
            indices[#indices + 1] = index
        end
    end
    table.sort(indices)
    local choices = {}
    for _, index in ipairs(indices) do choices[#choices + 1] = { delay = bySlot[index] } end
    return choices
end

function hooks.attach(module, _, getState, report, room, route)
    module.hooks.wrap("CreateStoreButtons", "run-planner-store-button-bindings", function(_, _, base, screen,
        instant)
        local bindings = capture()
        local result = base(screen, instant)
        restore(bindings, screen)
        return result
    end)

    module.hooks.wrap("CreateSurfaceShopButtons", "run-planner-shrine-disposition", function(_, runtime, base,
        screen, ...)
        local bindings = capture()
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
        local choices = deliveryDelayChoices(active, options, room, state)
        local priorDelayScope = delayScope
        delayScope = {
            choices = choices,
            index = 1,
            minimum = _G.SurfaceShopData.DelayMin,
            maximum = _G.SurfaceShopData.DelayMax,
        }
        local result = base(screen, ...)
        delayScope = priorDelayScope
        restore(bindings, screen)
        report(runtime)
        return result
    end)

    -- SurfaceShopLogic chooses the delay at this exact RNG contact before it derives
    -- the displayed duration, price, button payload, and pending-delivery trait.
    module.hooks.wrap("RandomInt", "run-planner-shrine-delivery-delay", function(_, _, base, minimum,
        maximum, ...)
        local scope = delayScope
        if scope ~= nil and minimum == scope.minimum and maximum == scope.maximum then
            local choice = scope.choices[scope.index]
            if choice ~= nil then
                scope.index = scope.index + 1
                if choice.delay ~= nil then return choice.delay end
            end
        end
        return base(minimum, maximum, ...)
    end)
end

return hooks
