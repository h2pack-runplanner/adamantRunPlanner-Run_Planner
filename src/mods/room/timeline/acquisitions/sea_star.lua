-- Sea Star is a source-role collaborator, not a duplicate-object binder.
-- Each acquisition carrier supplies its bounded native call; this module
-- merely supplies the one published chance operand and verifies it was read.
local seaStar = {}

local function resultFor(payload)
    local detail = type(payload) == "table" and payload.detail or nil
    local result = type(detail) == "table" and detail.seaStarResult or nil
    if type(result) ~= "table" or (result.kind ~= "proc" and result.kind ~= "noProc") then return nil end
    return result
end

function seaStar.create()
    local instance = {}
    local active

    function instance.scope(state, payload)
        return { state = state, result = resultFor(payload), chanceRead = false }
    end

    -- An unbound generated object can become a planner carrier only after native
    -- accepted-use presentation.  It still shares this enclosing native call.
    function instance.activate(scope, payload)
        if scope ~= nil and scope.result == nil then scope.result = resultFor(payload) end
        return scope
    end

    function instance.call(scope, invoke, diagnostic)
        -- A generated object is unbound at call entry. Its accepted native
        -- presentation can claim the ready source and activate this scope before
        -- the game's chance contact later in the same call.
        if scope == nil then return invoke() end
        local prior = active
        active = scope
        local ok, result = pcall(invoke)
        active = prior
        if not ok then error(result, 0) end
        instance.requireConsumed(scope, diagnostic)
        return result
    end

    -- Some native carriers settle an inner screen/function before their enclosing
    -- native call returns.  They must invoke this immediately before completion.
    function instance.requireConsumed(scope, diagnostic)
        if scope == nil or scope.result == nil or scope.chanceRead then return true end
        if not scope.reportedMissing then
            scope.reportedMissing = true
            diagnostic(scope.state, "sea-star-chance", scope.result.kind, "missing")
        end
        return false
    end

    function instance.attach(module)
        module.hooks.wrap("GetTotalHeroTraitValue", "run-planner-sea-star-chance-operand", function(_, _, base,
            propertyName, args)
            if active ~= nil and active.result ~= nil and propertyName == "DoubleRewardChance" then
                active.chanceRead = true
                return active.result.kind == "proc" and 1 or -1
            end
            return base(propertyName, args)
        end)
    end

    return instance
end

return seaStar
