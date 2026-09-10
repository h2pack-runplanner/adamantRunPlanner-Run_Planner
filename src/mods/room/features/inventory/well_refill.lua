-- Stygian Well's shared native store callback can create a Travel Deal
-- replacement.  It observes only the published source generation; native
-- purchase acceptance and every ordinary item outcome remain elsewhere.
local refill = {}

local function buttonIndex(button, item)
    if type(button) == "table" and type(button.Index) == "number" then return button.Index end
    if type(item) == "table" and type(item.Index) == "number" then return item.Index end
    local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
    for index, option in pairs(options or {}) do if option == item then return index end end
    return nil
end

function refill.attach(module, session, getState, report, room, refillScopes)
    module.hooks.wrap("HandleStorePurchase", "run-planner-well-refill", function(_, runtime, base,
        screen, button, args)
        local state = getState(runtime)
        local active = room.current(state)
        local handle = active and room.resolve(state, active,
            { kind = "travelDealRefill", carrier = "stygianWell" }) or nil
        local payload = handle and room.peek(state, handle) or nil
        local expected = payload and payload.transaction and payload.transaction.refill
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = type(item) == "table" and item.__runPlannerGenerationKey or nil
        local scope
        if expected ~= nil then
            if generationKey ~= expected.source.generationKey then
                session.mismatch(state, "well-refill-source", expected.source.generationKey, generationKey)
            else
                local slotIndex = buttonIndex(button, item)
                if slotIndex == nil then
                    session.mismatch(state, "well-refill-slot", "native store slot", nil)
                else
                    scope = { kind = "well", refill = expected, handle = handle, slotIndex = slotIndex }
                end
                refillScopes.setWell(scope)
            end
        end
        local ok, result = pcall(base, screen, button, args)
        if scope ~= nil then refillScopes.setWell(nil) end
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)
end

return refill
