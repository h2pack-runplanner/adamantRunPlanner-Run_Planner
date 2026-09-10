-- Icarus keeps every selected-trait effect in native game code. Latest Model
-- alone needs steering: this adapter scopes the native Hammer selector to the
-- exact Rank-I target published on the selected NPC option.
local icarus = {}

local function target(scope)
    return scope and scope.selectedOption and scope.selectedOption.icarusHammerTarget or nil
end

local function identity(value)
    if type(value) == "table" then return value.Name end
    return value
end

function icarus.attach(module, session, report, npcScope)
    local upgradeScope

    local function diagnostic(scope, expected, observed)
        if scope.failed then return end
        scope.failed = true
        session.diagnostic(scope.shared.state, "icarus-hammer-selection", {
            expected = expected, observed = observed,
        })
    end

    module.hooks.wrap("UpgradeHammers", "run-planner-icarus-latest-model", function(_, runtime,
        base, args)
        local shared = npcScope.current("Icarus")
        local expected = target(shared)
        if expected == nil then return base(args) end

        local scope = { shared = shared, expected = expected }
        local prior = upgradeScope
        upgradeScope = scope
        local ok, result = pcall(base, args)
        upgradeScope = prior
        if not ok then error(result, 0) end
        if not scope.contacted then
            diagnostic(scope, expected, "missing native Hammer selection")
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveRandomValue", "run-planner-icarus-hammer-target", function(_, _,
        base, values, ...)
        local scope = upgradeScope
        if scope == nil then return base(values, ...) end
        scope.contacted = true
        for index, value in ipairs(values or {}) do
            if identity(value) == scope.expected then
                table.remove(values, index)
                return value
            end
        end
        diagnostic(scope, scope.expected, "missing native candidate")
        return base(values, ...)
    end)
end

return icarus
