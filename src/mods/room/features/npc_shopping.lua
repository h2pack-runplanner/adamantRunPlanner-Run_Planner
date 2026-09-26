-- Consume the planner's bounded Shop policy before native shopping flags or threads.
local shopping = {}

function shopping.attach(module, session, getState, report, room)
    local function protect(functionName, family)
        module.hooks.wrap(functionName, "run-planner-shopping-" .. family, function(_, runtime, base,
            eventSource, args)
            local state = getState(runtime)
            local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            if state == nil or state.state ~= "synchronized" or type(nativeRoom) ~= "table"
                or nativeRoom.__runPlannerExecutionRoomId == nil then
                return base(eventSource, args)
            end
            local occurrence = room.occurrence(state, nativeRoom)
            if occurrence ~= nil then
                for _, suppressed in ipairs(occurrence.suppressedNpcShopping or {}) do
                    if suppressed == family then
                        session.diagnostic(state, "npc-shopping-suppressed", { family = family }, occurrence)
                        report(runtime)
                        return
                    end
                end
            end
            return base(eventSource, args)
        end)
    end
    protect("CheckNemesisShoppingEvent", "Nemesis")
    protect("CheckHeraclesShoppingEvent", "Heracles")
end

return shopping
