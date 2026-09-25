-- Aromatic Phial's exact fountain-rarity selector. UseHealthFountain remains
-- the lifecycle and mutation owner; this scope survives its threaded native
-- AddRarityToTraits contact and constrains only the Phial source.
local phial = {}

local function traitKey(value)
    return type(value) == "table" and (value.Name or value.TraitName) or value
end

local function findTrait(run, key)
    local hero = type(run) == "table" and run.Hero or nil
    for _, trait in pairs(type(hero) == "table" and hero.Traits or {}) do
        if traitKey(trait) == key then return trait end
    end
    return nil
end

function phial.attach(module, options)
    local active

    module.hooks.wrap("AddRarityToTraits", "run-planner-aromatic-phial-target", function(_, runtime,
        base, source, args)
        local scope = active
        if scope == nil or traitKey(source) ~= options.phialTraitKey then
            return base(source, args)
        end
        -- Consumed before the native mutation, so a failure cannot leak it.
        active = nil
        local state = options.getState(runtime)
        if state ~= scope.state or state.state ~= "synchronized" or not scope.binding.owns(state) then
            return base(source, args)
        end

        local target = findTrait(_G.CurrentRun, scope.target)
        if target == nil then
            options.session.diagnostic(state, "aromatic-phial-target", "missing trait",
                scope.binding.occurrence)
            local result = base(source, args)
            scope.binding.complete(state)
            options.report(runtime)
            return result
        end
        local forced = {}
        for key, value in pairs(args or {}) do forced[key] = value end
        forced.ForceUpgrade = { target }
        local ok, result = pcall(base, source, forced)
        if not ok then error(result, 0) end
        if traitKey(result) ~= scope.target then
            options.session.diagnostic(state, "aromatic-phial-target", traitKey(result),
                scope.binding.occurrence)
        end
        scope.binding.complete(state)
        options.report(runtime)
        return result
    end)

    return {
        -- Every fountain use replaces any earlier scope whose callback never came.
        -- The binding supplies owns(state), complete(state) and its occurrence.
        begin = function(state, target, binding)
            active = nil
            if target == nil or binding == nil then return nil end
            local scope = { state = state, target = target, binding = binding }
            active = scope
            return scope
        end,
        cancel = function(scope)
            if active == scope then active = nil end
        end,
    }
end

return phial
