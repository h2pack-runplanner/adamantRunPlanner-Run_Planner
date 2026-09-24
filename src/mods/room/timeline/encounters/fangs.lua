-- Fangs steers the native encounter type draw and its subsequent attribute
-- draws. Native eligibility, caps, squad lookup and attribute application stay
-- in RoomLogic. Encounter table identity keeps same-name cages apart.
-- luacheck: globals EnemyData
local fangs = {}

local function hasEliteSpawn(encounter, requested)
    for _, wave in ipairs(encounter.SpawnWaves or {}) do
        for _, spawn in ipairs(wave.Spawns or {}) do
            if spawn.Name == requested and EnemyData[requested] and EnemyData[requested].IsElite then return true end
        end
    end
    return false
end

local function removeRequested(values, requested)
    for index, value in ipairs(values or {}) do
        if value == requested then return table.remove(values, index) end
    end
    return nil
end

function fangs.create()
    local instance = {}
    local bound = setmetatable({}, { __mode = "k" })
    local stack = {}
    local function current() return stack[#stack] end
    local function withScope(scope, action)
        stack[#stack + 1] = scope
        local ok, result = pcall(action)
        stack[#stack] = nil
        if not ok then error(result, 0) end
        return result
    end
    local function diagnostic(owner, observed)
        if owner and owner.session and owner.state and owner.occurrence then
            owner.session.diagnostic(owner.state, "encounter-composition", observed, owner.occurrence)
        end
    end

    function instance.bind(encounter, selection, owner)
        bound[encounter] = { selection = selection, owner = owner }
    end

    function instance.attach(module)
        module.hooks.wrap("PickEncounterEliteAttributes", "run-planner-fangs-encounter", function(_, _, base, encounter, ...)
            local args = { ... }
            local binding = bound[encounter]
            local selected = binding and binding.selection.type and binding.selection.type.nativeId
            -- Every call has a fresh scope. In particular, a nested native
            -- preparation cannot inherit an outer encounter's RNG ordinal.
            if selected == nil then
                return withScope({ kind = "native" }, function() return base(encounter, table.unpack(args)) end)
            end
            if not hasEliteSpawn(encounter, selected) then
                diagnostic(binding.owner, { kind = "fangs", requested = selected, reason = "selected-type-absent" })
                bound[encounter] = nil
                return withScope({ kind = "native" }, function() return base(encounter, table.unpack(args)) end)
            end
            return withScope({
                kind = "encounter", encounter = encounter, selected = selected,
                perks = binding.selection.perks or {}, owner = binding.owner, steeredType = false,
            }, function()
                -- Preserve the complete native loop: it removes duplicate
                -- encounter types and performs the native per-type call.
                return base(encounter, table.unpack(args))
            end)
        end)

        module.hooks.wrap("PickEliteAttributes", "run-planner-fangs-attributes", function(_, _, base, encounter, enemyType, ...)
            local args = { ... }
            local parent = current()
            local active = parent and parent.kind == "encounter" and parent.encounter == encounter
                and parent.steeredType and parent.selected == enemyType
            if parent and parent.kind == "encounter" and parent.encounter == encounter
                and parent.selected ~= enemyType and not parent.nativeFallback then
                parent.nativeFallback = true
                diagnostic(parent.owner, { kind = "fangs", requested = parent.selected, reason = "native-type-fallback" })
            end
            return withScope({ kind = active and "attributes" or "native", parent = parent, index = 0 }, function()
                return base(encounter, enemyType, table.unpack(args))
            end)
        end)

        module.hooks.wrap("RemoveRandomValue", "run-planner-fangs-rng", function(_, _, base, values, ...)
            local scope = current()
            if scope and scope.kind == "encounter" and not scope.steeredType then
                local selected = removeRequested(values, scope.selected)
                if selected ~= nil then
                    scope.steeredType = true
                    return selected
                end
                -- A nested unrelated bag does not establish fallback or
                -- consume a perk. The actual native PickEliteAttributes call
                -- will attest a fallback by its enemyType.
                return base(values, ...)
            end
            if scope == nil or scope.kind ~= "attributes" then return base(values, ...) end
            if scope.parent and scope.parent.perkFallback then return base(values, ...) end
            local requested = scope.parent and scope.parent.perks[scope.index + 1]
            if requested == nil then return base(values, ...) end
            local selected = removeRequested(values, requested)
            if selected == nil then
                scope.parent.perkFallback = true
                diagnostic(scope.parent.owner, { kind = "fangs", requested = requested, reason = "native-perk-ineligible" })
                return base(values, ...)
            end
            scope.index = scope.index + 1
            return selected
        end)
    end
    return instance
end

return fangs
