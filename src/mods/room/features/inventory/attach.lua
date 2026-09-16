-- Explicit assembly of feature-owned inventory contacts and their narrow
-- Timeline binding surface.
local inventoryHooks = type(import) == "function"
    and import("mods/room/features/inventory/hooks.lua")
    or require("mods.room.features.inventory.hooks")
local buttonHooks = type(import) == "function"
    and import("mods/room/features/inventory/button_hooks.lua")
    or require("mods.room.features.inventory.button_hooks")
local poolHooks = type(import) == "function"
    and import("mods/room/features/inventory/purging_pool_hooks.lua")
    or require("mods.room.features.inventory.purging_pool_hooks")
local worldItemHooks = type(import) == "function"
    and import("mods/room/features/inventory/world_item_hooks.lua")
    or require("mods.room.features.inventory.world_item_hooks")
local shrineRefill = type(import) == "function"
    and import("mods/room/features/inventory/shrine_refill.lua")
    or require("mods.room.features.inventory.shrine_refill")
local wellRefill = type(import) == "function"
    and import("mods/room/features/inventory/well_refill.lua")
    or require("mods.room.features.inventory.well_refill")
local attach = {}

function attach.attach(module, session, getState, report, room, route)
    local scope = { worldShopRefills = setmetatable({}, { __mode = "k" }) }
    inventoryHooks.attach(module, session, getState, report, room, route, scope)
    buttonHooks.attach(module, session, getState, report, room, route)
    poolHooks.attach(module, session, getState, report, room, route)
    worldItemHooks.attach(module, session, getState, report, room, route, scope)
    local refillScopes = {
        setWell = function(value) scope.wellRefill = value end,
        setShrine = function(value) scope.shrineRefill = value end,
    }
    shrineRefill.attach(module, getState, report, room, refillScopes)
    wellRefill.attach(module, getState, report, room, refillScopes)
end

return attach
