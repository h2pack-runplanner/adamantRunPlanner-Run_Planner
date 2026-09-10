-- Producer-agnostic execution boundary for Mystery Box acquisitions. Native
-- unwrap and trait effects remain authoritative; this adapter claims at the
-- native unwrap, forces the published provider, and retains one owner handle.
local mystery = {}

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function nativeName(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) or nil
end

local function lifecycleRole(payload, point)
    for _, role in ipairs(payload and payload.transaction and payload.transaction.roles or {}) do
        if role.lifecyclePoint == point then return role end
    end
    return nil
end

function mystery.attach(module, session, getState, report, room)
    local unwrapScope

    module.hooks.wrap("CreateLoot", "run-planner-mystery-provider-bind", function(_, _, base, args)
        local result = base(args)
        local scope = unwrapScope
        if scope ~= nil and type(result) == "table"
            and nativeName(result) == scope.forcedName then
            if room.bind(scope.state, scope.current, scope.handle, result) == nil
                and type(session.mismatch) == "function" then
                session.mismatch(scope.state, "timeline-binding", "published Mystery provider", nativeName(result))
            end
        end
        return result
    end)

    local function boundScope(state, item)
        local current = room.current(state)
        local handle = current and room.bound(state, current, item) or nil
        local payload = handle and room.peek(state, handle) or nil
        local transaction = payload and payload.transaction
        local box
        for _, role in ipairs(transaction and transaction.roles or {}) do
            if role.role == "box" then box = role; break end
        end
        local hidden = lifecycleRole(payload, "afterUnwrap")
        if transaction == nil or box == nil or box.role ~= "box"
            or box.gameName ~= nativeName(item) or hidden == nil
            or hidden.role ~= "hiddenSource" or hidden.gameName == nil then
            return nil
        end
        return {
            state = state, current = current, handle = handle, item = item,
            payload = payload,
        }
    end

    local function boxRole(transaction, contact)
        if type(transaction) ~= "table" then return nil end
        for _, role in ipairs(transaction.roles or {}) do
            if role.role == "box" and role.gameName == contact.gameName then
                return role
            end
        end
        return nil
    end

    module.hooks.wrap("UnwrapRandomLoot", "run-planner-mystery-unwrap", function(_, runtime, base, source)
        local state = getState(runtime)
        local scope = boundScope(state, source)
        if scope == nil and nativeName(source) == "BlindBoxLoot" then
            local current = room.current(state)
            local handle, payload = room.claimReady(state, current, {
                kind = "mysteryBox", gameName = nativeName(source),
            }, source, boxRole)
            if handle ~= nil then
                scope = {
                    state = state, current = current, handle = handle,
                    item = source, payload = payload,
                }
            end
        end
        if scope == nil then return base(source) end
        scope.payload = room.begin(scope.state, scope.handle)
        if scope.payload == nil then return base(source) end
        local hidden = lifecycleRole(scope.payload, "afterUnwrap")
        if hidden == nil then return base(source) end
        local prior = unwrapScope
        unwrapScope = {
            state = scope.state, current = scope.current, handle = scope.handle,
            lifecyclePoint = "afterUnwrap", forcedName = hidden.gameName,
        }
        local ok, result = pcall(base, source)
        unwrapScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GiveLoot", "run-planner-mystery-provider", function(_, _, base, args)
        if unwrapScope == nil or unwrapScope.forcedName == nil then return base(args) end
        local forcedArgs = copy(args)
        forcedArgs.ForceLootName = unwrapScope.forcedName
        return base(forcedArgs)
    end)
end

return mystery
