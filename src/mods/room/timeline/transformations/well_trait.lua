-- Well traits are applied directly (or stacked) by HandleStorePurchase, not
-- through UseConsumableItem. Native presentation admits the action; returning
-- from purchase ends application. Conformance owns the resulting trait state.
local well = {}

local function matches(transaction, contact)
    return type(transaction) == "table" and transaction.kind == "itemEffect"
        and transaction.itemKey == contact.gameName or nil
end

function well.attach(module, session, getState, report, room)
    local active = setmetatable({}, { __mode = "k" })
    module.hooks.wrap("HandleStorePurchase", "run-planner-well-trait-use", function(_, runtime, base,
        screen, button, ...)
        local item = type(button) == "table" and button.Data or nil
        local state = getState(runtime)
        local current = room.current(state)
        if current == nil or type(item) ~= "table" or item.Type ~= "Trait" then
            return base(screen, button, ...)
        end
        local scope = { state = state, current = current }
        local previous = active[item]
        active[item] = scope
        local ok, result = pcall(base, screen, button, ...)
        active[item] = previous
        if not ok then error(result, 0) end
        if scope.accepted and result ~= false then
            session.complete(state, scope.handle)
            report(runtime)
        end
        return result
    end)

    module.hooks.wrap("StorePurchasePresentation", "run-planner-well-trait-accepted",
        function(_, _, base, screen, button, item, ...)
            local result = base(screen, button, item, ...)
            local scope = active[item]
            if scope ~= nil and not scope.accepted and result ~= false then
                local contact = { kind = "outcome", gameName = item.Name }
                local handle = room.bound(scope.state, scope.current, item)
                local payload = handle and room.peek(scope.state, handle) or nil
                if handle == nil then
                    handle, payload = room.claimReady(scope.state, scope.current, contact, item, matches)
                end
                if handle ~= nil and matches(payload and payload.transaction, contact) then
                    scope.handle = handle
                    scope.accepted = room.begin(scope.state, handle) ~= nil
                end
            end
            return result
        end)
end

return well
