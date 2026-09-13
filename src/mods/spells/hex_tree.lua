-- One owner-agnostic native Hex-tree realization seam. Owners provide a
-- resolved tree; this module scopes only the native random construction.
local hexTree = {}

local function diagnostic(scope, checkpoint, expected, observed)
    if scope and scope.diagnostic then scope.diagnostic(checkpoint, expected, observed) end
end
local function keys(values)
    local result = {}
    for _, key in ipairs(values or {}) do result[key] = true end
    return result
end
local function removeExpected(values, remaining)
    for index, value in ipairs(values or {}) do
        if remaining[value] then remaining[value] = nil; return table.remove(values, index) end
    end
end

function hexTree.create()
    local tree = {}
    local pending, active

    function tree.prepare(expected, traitKey, diagnosticCallback)
        local scope = {
            prior = pending, expected = expected, traitKey = traitKey, diagnostic = diagnosticCallback,
            rare = keys(expected.rareTalentKeys), epic = keys(expected.epicTalentKeys),
        }
        pending = scope
        return scope
    end
    function tree.clear(scope)
        if pending ~= scope then return end
        pending = scope.prior
        if not scope.created then diagnostic(scope, "hex-tree-contact", "CreateTalentTree", "missing") end
    end
    function tree.realize(expected, traitKey, diagnosticCallback, action)
        local scope = tree.prepare(expected, traitKey, diagnosticCallback)
        local ok, result = pcall(action)
        tree.clear(scope)
        if not ok then error(result, 0) end
        return result
    end

    function tree.attach(module)
        module.hooks.wrap("CreateTalentTree", "run-planner-hex-tree", function(_, _, base, spellData)
            local scope = pending
            if scope == nil or spellData.TraitName ~= scope.traitKey then
                return base(spellData)
            end
            pending = scope.prior
            scope.created = true
            local prior = active; active = scope
            local ok, result = pcall(base, spellData)
            active = prior
            if not ok then error(result, 0) end
            for key in pairs(scope.rare) do diagnostic(scope, "hex-tree-rare", key, "missing") end
            for key in pairs(scope.epic) do diagnostic(scope, "hex-tree-epic", key, "missing") end
            return result
        end)
        module.hooks.wrap("GetRandomValue", "run-planner-hex-layout", function(_, _, base, values, ...)
            if active and type(values) == "table" then
                for _, value in ipairs(values) do
                    if type(value) == "table" and value.Name == active.expected.layoutKey then return value end
                end
                diagnostic(active, "hex-tree-layout", active.expected.layoutKey, "native-ineligible")
            end
            return base(values, ...)
        end)
        module.hooks.wrap("RemoveRandomValue", "run-planner-hex-special-talents", function(_, _, base, values, ...)
            if active and type(values) == "table" then
                local selected = removeExpected(values, active.rare) or removeExpected(values, active.epic)
                if selected then return selected end
            end
            return base(values, ...)
        end)
    end

    return tree
end

return hexTree
