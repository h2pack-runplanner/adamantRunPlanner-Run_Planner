-- Install the authored pool once, where native room setup creates it.
local poolInventory = type(import) == "function"
    and import("mods/room/features/inventory/purging_pool.lua")
    or require("mods.room.features.inventory.purging_pool")
local hooks = {}

function hooks.attach(module, session, getState, report, room)
    module.hooks.wrap("HandleSecretSpawns", "run-planner-pool-inventory", function(_, runtime, base,
        currentRun)
        local nativeRoom = currentRun and currentRun.CurrentRoom
        local state = getState(runtime)
        local occurrence
        if state ~= nil and state.state == "synchronized" and type(nativeRoom) == "table"
            and nativeRoom.__runPlannerExecutionRoomId ~= nil and nativeRoom.SellTraitShop == nil
            and not nativeRoom.__runPlannerPoolInventoryInstalled then
            occurrence = room.occurrence(state, nativeRoom)
        end
        local result = base(currentRun)
        local pool = occurrence and occurrence.overview.purgingPool
        if pool ~= nil and pool.interacted and nativeRoom.SellTraitShop ~= nil
            and getState(runtime) == state and state.state == "synchronized" then
            local ok, errorValue = poolInventory.steer(occurrence, nativeRoom)
            if ok then
                nativeRoom.__runPlannerPoolInventoryInstalled = true
            else
                session.diagnostic(state, errorValue.checkpoint, {
                    expected = errorValue.expected, observed = errorValue.observed,
                })
            end
            report(runtime)
        end
        return result
    end)
end

return hooks
