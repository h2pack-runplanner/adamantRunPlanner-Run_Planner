-- Hermes Shrine keeps its native delay/rush mechanics.  Travel Deal is the
-- sole dynamic inventory contact: compare only its published source position
-- and hand the replacement construction to the shared inventory callback.
local shrine = {}

function shrine.attach(module, session, getState, report, room, refillScopes)
    module.hooks.wrap("HandleSurfaceShopAction", "run-planner-shrine-refill", function(_, runtime, base,
        screen, button, args)
        local state = getState(runtime)
        local active = room.current(state)
        local handle = active and room.resolve(state, active,
            { kind = "travelDealRefill", carrier = "hermesShrine" }) or nil
        local payload = handle and room.peek(state, handle) or nil
        local refill = payload and payload.transaction and payload.transaction.refill
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = item and item.__runPlannerGenerationKey
        local purchased = type(item) == "table" and item.Purchased == true
        local scope
        if purchased then
            if refill ~= nil and generationKey ~= refill.source.generationKey then
                session.diagnostic(state, "shrine-refill-source", {
                    expected = refill.source.generationKey, observed = generationKey,
                })
            elseif refill ~= nil then
                scope = { kind = "shrine", refill = refill, handle = handle }
                refillScopes.setShrine(scope)
            end
        end
        local ok, result = pcall(base, screen, button, args)
        if scope ~= nil then refillScopes.setShrine(nil) end
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)
end

return shrine
