-- Icarus keeps every selected-trait effect in native game code. Latest Model
-- alone needs steering: this adapter scopes the native Hammer selector to the
-- ordered Rank-I targets published on the selected NPC option.
local icarus = {}

local function targets(scope)
    return scope and scope.selectedOption and scope.selectedOption.icarusHammerTargets or nil
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
        local expected = targets(shared)
        if expected == nil then return base(args) end

        local scope = { shared = shared, expected = expected, index = 1 }
        local prior = upgradeScope
        upgradeScope = scope
        local ok, result = pcall(base, args)
        upgradeScope = prior
        if not ok then error(result, 0) end
        if not scope.failed and scope.index <= #expected then
            diagnostic(scope, expected[scope.index], "missing native Hammer selection")
        elseif scope.index <= #expected then
            diagnostic(scope, expected[scope.index], "missing native Hammer selection")
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRarityToTraits", "run-planner-icarus-native-upgrade", function(_, _,
        base, ...)
        -- Native rarity mutation selects again from its ForceUpgrade singleton.
        -- That inner selection is not another Latest Model draw.
        local prior = upgradeScope
        upgradeScope = nil
        local ok, result = pcall(base, ...)
        upgradeScope = prior
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("RemoveRandomValue", "run-planner-icarus-hammer-target", function(_, _,
        base, values, ...)
        local scope = upgradeScope
        if scope == nil or scope.nested then return base(values, ...) end
        local expected = scope.expected[scope.index]
        if expected == nil then
            diagnostic(scope, "no additional Hammer target", "additional native selection")
            return base(values, ...)
        end
        for index, value in ipairs(values or {}) do
            if identity(value) == expected then
                table.remove(values, index)
                scope.index = scope.index + 1
                return value
            end
        end
        diagnostic(scope, expected, "missing native candidate")
        return base(values, ...)
    end)

    module.hooks.wrap("AddRarityToTraits", "run-planner-icarus-hammer-rarity", function(_, _,
        base, ...)
        local scope = upgradeScope
        if scope == nil then return base(...) end
        local prior = scope.nested
        scope.nested = true
        local ok, result = pcall(base, ...)
        scope.nested = prior
        if not ok then error(result, 0) end
        return result
    end)
end

return icarus
