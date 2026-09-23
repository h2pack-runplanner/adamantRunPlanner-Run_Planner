-- Install once at the first pool screen, after native stale-inventory refresh.
local poolInventory = type(import) == "function"
    and import("mods/room/features/inventory/purging_pool.lua")
    or require("mods.room.features.inventory.purging_pool")
local hooks = {}

function hooks.attach(module, session, getState, report, room)
    local openings = setmetatable({}, { __mode = "k" })
    local function currentThread() return coroutine.running() or hooks end
    module.hooks.wrap("OpenSellTraitMenu", "run-planner-pool-open", function(_, runtime, base, ...)
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local state = getState(runtime)
        local occurrence
        if state ~= nil and state.state == "synchronized" and type(nativeRoom) == "table"
            and nativeRoom.__runPlannerExecutionRoomId ~= nil and nativeRoom.SellTraitShop ~= nil
            and not nativeRoom.__runPlannerPoolInventoryHandled then
            occurrence = room.occurrence(state, nativeRoom)
        end
        local pool = occurrence and occurrence.overview.purgingPool
        local thread = currentThread()
        local prior = openings[thread]
        openings[thread] = pool and pool.interacted
            and { state = state, nativeRoom = nativeRoom, occurrence = occurrence } or nil
        local results = table.pack(pcall(base, ...))
        openings[thread] = prior
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end)
    module.hooks.wrap("CreateSellButtons", "run-planner-pool-inventory", function(_, runtime, base, ...)
        local thread = currentThread()
        local opening = openings[thread]
        -- Consume before rendering: rerolls rebuild buttons within the same open menu.
        openings[thread] = nil
        if opening and _G.CurrentRun and _G.CurrentRun.CurrentRoom == opening.nativeRoom
            and getState(runtime) == opening.state and opening.state.state == "synchronized"
            and not opening.nativeRoom.__runPlannerPoolInventoryHandled then
            opening.nativeRoom.__runPlannerPoolInventoryHandled = true
            -- Phial may change a planned trait outside the native random three;
            -- that does not trigger OpenSellTraitMenu's stale-row regeneration.
            _G.GenerateSellTraitValues(opening.nativeRoom)
            local ok, errorValue = poolInventory.steer(opening.occurrence, opening.nativeRoom)
            if not ok then
                session.diagnostic(opening.state, errorValue.checkpoint, {
                    expected = errorValue.expected, observed = errorValue.observed,
                })
            end
            report(runtime)
        end
        return base(...)
    end)
end

return hooks
