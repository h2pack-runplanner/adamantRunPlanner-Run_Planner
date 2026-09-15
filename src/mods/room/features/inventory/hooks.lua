-- Single coordinator for the shared native inventory-construction callback.
-- Carrier modules decide which native rows participate.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local worldShop = type(import) == "function"
    and import("mods/room/features/inventory/world_shop.lua")
    or require("mods.room.features.inventory.world_shop")
local shrineInventory = type(import) == "function"
    and import("mods/room/features/inventory/hermes_shrine.lua")
    or require("mods.room.features.inventory.hermes_shrine")
local wellInventory = type(import) == "function"
    and import("mods/room/features/inventory/stygian_well.lua")
    or require("mods.room.features.inventory.stygian_well")
local hooks = {}

local function currentRefill(scope)
    local worldRefills = scope.worldShopRefills
    local world = worldRefills and worldRefills[coroutine.running()] or nil
    return scope.shrineRefill or scope.wellRefill or world
end

local function completeRefill(session, state, refillScope)
    if refillScope and refillScope.handle ~= nil and refillScope.begun and not refillScope.completed
        and refillScope.kind ~= "shop" then
        refillScope.completed = true
        session.complete(state, refillScope.handle)
    end
end

local function prepareInventory(occurrence, args, refillScope, contractOnly)
    local expected = occurrence and occurrence.overview or {}
    local storeData = primitives.copy(type(args) == "table" and args.StoreData or nil)
    if type(storeData) ~= "table" then return nil end
    local prepared, errorValue
    if type(refillScope) == "table" and refillScope.kind == "shop" then
        prepared, errorValue = worldShop.prepareRefill(storeData, args, refillScope)
    elseif type(refillScope) == "table" and refillScope.kind == "well" then
        prepared, errorValue = wellInventory.prepareRefill(storeData, args, refillScope)
    elseif type(refillScope) == "table" and refillScope.kind == "shrine" then
        prepared, errorValue = shrineInventory.prepareRefill(storeData, args, refillScope)
    end
    if prepared ~= nil or errorValue ~= nil then return prepared, errorValue end
    if contractOnly then return worldShop.prepareContract(expected.shop, storeData, args) end
    if expected.shop ~= nil then return worldShop.prepare(expected.shop, storeData, args) end
    if expected.hermesShrine ~= nil then
        return shrineInventory.prepare(expected.hermesShrine, storeData, args)
    end
    return wellInventory.prepare(expected.stygianWell, storeData, args)
end

function hooks.attach(module, session, getState, report, room, route, scope)
    module.hooks.wrap("FillInShopOptions", "run-planner-inventory", function(_, runtime, base, args)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local activeRefill = currentRefill(scope)
        if activeRefill and activeRefill.nativeOnly then
            local result = base(args)
            report(runtime)
            return result
        end
        if activeRefill and activeRefill.handle ~= nil and not activeRefill.beginAttempted then
            activeRefill.beginAttempted = true
            if room.begin(state, activeRefill.handle) ~= nil then
                activeRefill.begun = true
            else
                activeRefill.nativeOnly = true
            end
        end
        if activeRefill and activeRefill.nativeOnly then
            local result = base(args)
            report(runtime)
            return result
        end
        local prepared, errorValue = prepareInventory(active and active.occurrence, args, activeRefill,
            scope.contract ~= nil)
        if errorValue then
            session.diagnostic(state, errorValue.checkpoint, {
                expected = errorValue.expected, observed = errorValue.observed,
            }, active and active.occurrence)
            local result = base(args)
            completeRefill(session, state, activeRefill)
            report(runtime)
            return result
        end
        scope.inventorySources = {}
        for _, offer in ipairs(prepared and prepared.expected or {}) do
            if offer.source then scope.inventorySources[#scope.inventorySources + 1] = offer.source end
            if offer.reward and offer.reward.source then
                scope.inventorySources[#scope.inventorySources + 1] = offer.reward.source
            end
        end
        local baseOk, result = pcall(base, prepared and prepared.args or args)
        if not baseOk then scope.inventorySources = nil; error(result, 0) end
        scope.inventorySources = nil
        result = primitives.placeRefill(prepared, result)
        result = primitives.order(prepared, result)
        local ok, verifyError = primitives.verify(prepared, result)
        if not ok then
            session.diagnostic(state, verifyError.checkpoint, {
                expected = verifyError.expected, observed = verifyError.observed,
            }, active and active.occurrence)
        end
        completeRefill(session, state, activeRefill)
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetEligibleInteractedGod", "run-planner-inventory-source", function(_, _, base, ignored)
        if scope.inventorySources and scope.inventorySources[1] then
            return table.remove(scope.inventorySources, 1)
        end
        return base(ignored)
    end)
end

return hooks
