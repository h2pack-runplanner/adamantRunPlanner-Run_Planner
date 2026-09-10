-- Concave Stone's bounded secondary trait-screen state. The ordinary trait
-- carrier still owns the outer offer and menu terminal; this module owns only
-- the Stone roll, its residual button, and the native callbacks that bridge
-- those two screens.
local stoneModule = {}

function stoneModule.create(options)
    local pendingByHandle = {}
    local active

    local function scopeIsCurrent(state, pending)
        return pending ~= nil and pending.context == options.room.current(state)
            and state.state == "synchronized"
    end

    local function discard(pending)
        if pending == nil then return end
        pendingByHandle[pending.handle] = nil
        if active == pending then active = nil end
    end

    local function completeOuter(state, handle)
        local pending = pendingByHandle[handle]
        if pending ~= nil then
            if not pending.outerReturned then return end
            discard(pending)
        end
        options.session.complete(state, handle)
    end

    local function steerResidual(runtime, base, candidates, rng)
        local pending = active
        if pending == nil or pending.result.kind ~= "proc" or not pending.rollConsumed
            or pending.residualButton ~= nil then
            return base(candidates, rng)
        end
        local state = options.getState(runtime)
        if not scopeIsCurrent(state, pending) then
            discard(pending)
            return base(candidates, rng)
        end
        local expected = options.ordinary.optionForOptionKey(pending.payload, pending.result.optionKey)
        local expectedKey = expected and expected.key or nil
        local sawButton, selected = false, nil
        for _, candidate in pairs(candidates or {}) do
            if type(candidate) == "table" and type(candidate.Data) == "table" then
                sawButton = true
                if candidate.Data.Name == expectedKey then selected = candidate end
            end
        end
        if not sawButton then return base(candidates, rng) end
        if selected == nil then
            discard(pending)
            options.session.diagnostic(state, "concave-stone-residual", "native-ineligible")
            return base(candidates, rng)
        end
        pending.residualButton = selected
        return selected
    end

    local function installHooks(module)
        module.hooks.wrap("HasHeroTraitValue", "run-planner-scope-concave-stone-roll", function(_, runtime, base,
            traitName, ...)
            local result = base(traitName, ...)
            local pending = active
            if pending == nil or traitName ~= "DoubleBoonChance" then return result end
            local state = options.getState(runtime)
            if not scopeIsCurrent(state, pending) then
                discard(pending)
            else
                pending.rollTraitObserved = true
            end
            return result
        end)

        module.hooks.wrap("RandomChance", "run-planner-steer-concave-stone-roll", function(_, runtime, base,
            chance, args)
            local pending = active
            if pending == nil or not pending.rollTraitObserved or pending.rollConsumed then
                return base(chance, args)
            end
            local state = options.getState(runtime)
            if not scopeIsCurrent(state, pending) then
                discard(pending)
                return base(chance, args)
            end
            pending.rollConsumed = true
            return pending.result.kind == "proc"
        end)
    end

    installHooks(options.module)

    return {
        active = function() return active end,
        begin = function(handle, context, payload, result)
            local pending = {
                handle = handle,
                context = context,
                payload = payload,
                result = result,
                outerReturned = false,
                rollTraitObserved = false,
                rollConsumed = false,
                residualReturned = result.kind == "noProc",
            }
            pendingByHandle[handle] = pending
            active = pending
            return pending
        end,
        discard = discard,
        completeOuter = completeOuter,
        steerResidual = steerResidual,
        validateResidual = function(state)
            local pending = active
            if pending == nil then return nil, nil end
            if not scopeIsCurrent(state, pending) then
                discard(pending)
                return false, pending
            end
            if not pending.rollConsumed or pending.result.kind ~= "proc" or pending.residualButton == nil then
                discard(pending)
                options.session.diagnostic(state, "concave-stone-residual", "missing")
                return false, pending
            end
            return true, pending
        end,
        markResidualReturned = function(pending)
            pending.residualReturned = true
        end,
        finishOuter = function(state, pending)
            if pending == nil then return end
            if active == pending then active = nil end
            pending.outerReturned = true
            if not pending.rollConsumed then
                discard(pending)
                options.session.diagnostic(state, "concave-stone-roll", "missing")
            elseif pending.result.kind == "proc" and not pending.residualReturned then
                discard(pending)
                options.session.diagnostic(state, "concave-stone-residual", "missing")
            end
        end,
    }
end

return stoneModule
