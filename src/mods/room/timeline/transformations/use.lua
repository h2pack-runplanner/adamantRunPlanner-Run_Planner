-- Native consumable terminals shared by outcome transformations and Well item
-- effects.  Native acceptance remains authoritative; this only claims a ready
-- published outcome after the accepted presentation and settles after use.
local anvil = type(import) == "function" and import("mods/room/timeline/transformations/anvil.lua")
    or require("mods.room.timeline.transformations.anvil")
local twist = type(import) == "function" and import("mods/room/timeline/transformations/well_twist.lua")
    or require("mods.room.timeline.transformations.well_twist")

local use = {}

local function name(item)
    return type(item) == "table" and (item.Name or item.ItemName or item.LootName) or nil
end

local function outcome(transaction, contact)
    if type(transaction) ~= "table" then return nil end
    if transaction.kind == "itemEffect" and transaction.itemKey == contact.gameName then return true end
    if transaction.kind == "transformation" then
        local transformation = transaction.transformation
        if transformation and transformation.kind == "anvilOfFates" and contact.gameName == "ChaosWeaponUpgrade" then
            return true
        end
        if transformation and transformation.kind == "stygianWellTwist"
            and transformation.sourceItemKey == contact.gameName then return true end
    end
    return nil
end

local function transformation(transaction, contact)
    return type(transaction) == "table" and transaction.kind == "transformation"
        and outcome(transaction, contact) or nil
end

function use.attach(module, session, getState, report, room)
    local active = setmetatable({}, { __mode = "k" })
    local activeTwist
    local anvilScope = anvil.attach(module, session, report)
    twist.attachSelectionHooks(module, session, report, function() return activeTwist end)

    module.hooks.wrap("UseConsumableItem", "run-planner-outcome-use", function(_, runtime, base, item, args, user)
        local state = getState(runtime)
        local current = room.current(state)
        local handle = current and room.bound(state, current, item) or nil
        local payload = handle and room.peek(state, handle) or nil
        -- Transformations must steer their native random selection during use,
        -- before the accepted presentation fires. Claim their ready owner at
        -- this one native contact; direct item effects still claim only after
        -- native acceptance below.
        if handle == nil and current ~= nil then
            handle, payload = room.claimReady(state, current,
                { kind = "transformation", gameName = name(item) }, item, transformation)
        end
        if handle ~= nil and outcome(payload and payload.transaction, { gameName = name(item) }) == nil then
            return base(item, args, user)
        end
        local scope = { state = state, current = current, item = item, handle = handle, payload = payload }
        active[item] = scope
        local transformScope = anvilScope.beginUse(state, payload)
        local twistScope = twist.scope(state, handle, payload and payload.transaction)
        local priorTwist = activeTwist
        activeTwist = twistScope
        local ok, result = pcall(base, item, args, user)
        activeTwist = priorTwist
        local transformed = transformScope and anvilScope.finishUse(transformScope) or false
        if active[item] == scope then active[item] = nil end
        if not ok then error(result, 0) end
        if scope.accepted and result ~= false then
            if transformed or twistScope and twistScope.awarded
                or scope.payload and scope.payload.transaction.kind == "itemEffect" then
                session.complete(state, scope.handle)
            end
            report(runtime)
        end
        return result
    end)

    module.hooks.wrap("ConsumableUsedPresentation", "run-planner-outcome-accepted", function(_, _, base,
        currentRun, item, args)
        local result = base(currentRun, item, args)
        local scope = active[item]
        if scope ~= nil and result ~= false then
            if scope.handle == nil then
                scope.handle, scope.payload = room.claimReady(scope.state, scope.current,
                    { kind = "outcome", gameName = name(item) }, item, outcome)
            end
            if scope.handle ~= nil then
                scope.payload = room.begin(scope.state, scope.handle)
                scope.accepted = scope.payload ~= nil
            end
        end
        return result
    end)
end

return use
