-- World Shop refill/contract construction and stable binding of materialized
-- world items for later Timeline-owned acquisition contacts.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local hooks = {}

local function materializedHandle(state, active, room, root, itemKey)
    if root == nil or itemKey == nil then return root end
    return room.resolve(state, active, {
        kind = "materialized", source = root, gameName = itemKey,
    }) or root
end

function hooks.attach(module, session, getState, report, room, route, scope)
    local creatingItems = setmetatable({}, { __mode = "k" })
    -- Native item setup can pregenerate outcomes before the spawn returns.
    -- Bind the concrete item before its own SetupEvents, once per construction.
    module.hooks.wrap("RunEventsGeneric", "run-planner-bind-world-item-setup", function(_, _, base,
        events, source, ...)
        local creating = creatingItems[coroutine.running()]
        if creating and not creating.bound and events ~= nil and type(source) == "table"
            and source.Name == creating.gameName and events == source.SetupEvents then
            creating.bound = true
            creating.bind(source)
        end
        return base(events, source, ...)
    end)

    module.hooks.wrap("RestockWorldItem", "run-planner-travel-deal-refill", function(_, runtime, base, index,
        kitId, args)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local handle = active and room.resolve(state, active,
            { kind = "travelDealRefill", carrier = "worldShop" }) or nil
        local payload = handle and room.peek(state, handle) or nil
        local refill = payload and payload.transaction and payload.transaction.refill
        local thread = coroutine.running()
        local refills = scope.worldShopRefills
        local prior = refills[thread]
        local refillScope = {
            nativeOnly = true,
            source = refill and refill.source or nil,
            index = index,
            kitId = kitId,
        }
        if refill ~= nil and index == refill.replacement.slotIndex + 1 then
            refillScope = {
                kind = "shop", handle = handle, refill = refill, source = refill.source,
                index = index, kitId = kitId, groupIndex = refill.replacement.groupIndex,
            }
        elseif refill ~= nil then
            session.diagnostic(state, "shop-refill-slot", {
                expected = refill.replacement.slotIndex + 1, observed = index,
            })
        end
        refills[thread] = refillScope
        local ok, result = pcall(base, index, kitId, args)
        refills[thread] = prior
        if not ok then error(result, 0) end
        if refillScope.begun then session.complete(state, handle) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnZagContractRewards", "run-planner-contract-inventory", function(_, runtime, base,
        nativeRoom, args)
        local prior = scope.contract
        scope.contract = true
        local ok, result = pcall(base, nativeRoom, args)
        scope.contract = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnStoreItemInWorld", "run-planner-bind-world-shop-item", function(_, runtime, base,
        itemData, kitId)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local bindItem, itemKey
        if active and type(itemData) == "table" then
            local generationKey = itemData.__runPlannerGenerationKey
            local transactionOwner = itemData.__runPlannerTransactionOwner
            local bindingKey = itemData.__runPlannerOfferKey or itemData.Name or itemData.ItemName
            itemKey = itemData.Name or itemData.ItemName or bindingKey
            local shrineDelivery = itemData.__runPlannerShrine == true
                and itemData.__runPlannerShrineSourceKey ~= nil
            local sourceKey = itemData.__runPlannerShrineSourceKey
            local handle
            if shrineDelivery then
                handle = room.resolve(state, active, { kind = "hermesShrineDelivery", sourceKey = sourceKey })
            elseif itemData.__runPlannerContractSourceOwner then
                handle = room.resolve(state, active,
                    { kind = "source", sourceOwner = itemData.__runPlannerContractSourceOwner })
            elseif itemData.__runPlannerWorldShop then
                -- A marked World Shop row binds only its published Timeline
                -- owner.  An unowned row remains native and cannot fall through.
                if transactionOwner ~= nil then
                    handle = room.resolve(state, active, { kind = "owner", owner = transactionOwner })
                end
            elseif generationKey then
                handle = room.resolve(state, active, { kind = "generation", generationKey = generationKey })
            elseif bindingKey then
                handle = room.resolve(state, active, { kind = "offer", offerKey = bindingKey })
            end
            handle = materializedHandle(state, active, room, handle, itemKey)
            bindItem = function(result)
                if itemData.__runPlannerWorldShop and type(result) == "table" then
                    result.__runPlannerWorldShop = true
                    result.__runPlannerTransactionOwner = transactionOwner
                end
                room.bind(state, active, handle, result)
            end
        end
        local thread = coroutine.running()
        local prior = creatingItems[thread]
        creatingItems[thread] = bindItem and { gameName = itemKey, bind = bindItem } or nil
        local ok, result = pcall(base, itemData, kitId)
        creatingItems[thread] = prior
        if not ok then error(result, 0) end
        if bindItem and result ~= nil then bindItem(result) end
        report(runtime)
        return result
    end)
end

return hooks
