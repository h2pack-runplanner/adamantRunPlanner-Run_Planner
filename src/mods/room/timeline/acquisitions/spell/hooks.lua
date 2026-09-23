-- SpellDrop owns its native screen and delegates only tree construction.
local hooks = {}
local function detail(payload) return type(payload) == "table" and payload.detail or nil end
local function offerFor(payload)
    local offer = detail(payload) and detail(payload).traitOffer
    return type(offer) == "table" and offer.kind == "traits" and offer.giver == "SpellDrop"
        and type(offer.hexTree) == "table" and offer or nil
end
local function spellRole(transaction, contact)
    if type(transaction) ~= "table" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        local offer = role.traitOffer
        if role.gameName == contact.gameName and role.disposition == "normal" and type(offer) == "table"
            and offer.kind == "traits" and offer.giver == "SpellDrop"
            and type(offer.hexTree) == "table" then return role end
    end
end
local function spellNames(offer)
    local names = {}
    for _, option in ipairs(offer.options) do
        local found
        for name, spell in pairs(_G.SpellData or {}) do
            if spell.TraitName == option.key then found = name; break end
        end
        if not found then return nil, option.key end
        names[#names + 1] = found
    end
    return names
end
function hooks.attach(module, session, getState, report, room, tree)
    assert(type(tree) == "table", "spell acquisition Hex Tree instance is required")
    local scopesByLoot = setmetatable({}, { __mode = "k" })
    local offerScope
    local function diagnosticFor(state)
        return function(checkpoint, expectedValue, observed)
            session.diagnostic(state, "spell-steering", {
                contact = checkpoint, expected = expectedValue, observed = observed,
            })
        end
    end
    local function resolveScope(runtime, spellItem)
        local scope = spellItem and scopesByLoot[spellItem] or nil
        if scope then return scope end
        local state = getState(runtime); local current = room.current(state)
        local handle = current and room.bound(state, current, spellItem) or nil
        local payload = handle and room.peek(state, handle) or nil
        if not handle and current and type(room.claimReady) == "function" then
            handle, payload = room.claimReady(state, current,
                { kind = "spell", gameName = spellItem and spellItem.Name }, spellItem, spellRole)
        end
        local offer = offerFor(payload)
        if not handle or not offer then return nil end
        scope = { state = state, handle = handle, offer = offer }
        scopesByLoot[spellItem] = scope
        return scope
    end
    local function clearScope(item, scope)
        if item and scopesByLoot[item] == scope then scopesByLoot[item] = nil end
    end
    module.hooks.wrap("GetEligibleSpells", "run-planner-spell-offer-install", function(_, _, base, screen, ...)
        if offerScope and screen == offerScope.screen then
            local values = _G.SessionMapState.SelectedSpells
            if offerScope.preparing then
                values = {}
                for index, name in ipairs(offerScope.names) do values[index] = name end
            end
            offerScope.pool = values
            return values
        end
        return base(screen, ...)
    end)
    module.hooks.wrap("RemoveRandomValue", "run-planner-spell-offer-order", function(_, _, base, values, ...)
        if offerScope and values == offerScope.pool then return table.remove(values, 1) end
        return base(values, ...)
    end)
    module.hooks.wrap("CreateSpellButtons", "run-planner-spell-offer-buttons", function(_, _, base, screen)
        local scope = screen and screen.Source and scopesByLoot[screen.Source] or nil
        if not scope then return base(screen) end
        local names, missing = spellNames(scope.offer)
        if not names then
            diagnosticFor(scope.state)("spell-offer-install", missing, "unknown-spell")
            return base(screen)
        end
        local prior = offerScope
        offerScope = { screen = screen, names = names, preparing = true }
        local ok, result = pcall(function()
            -- Refresh offer-dependent God Sent facts through the native routine.
            -- Spawn-time random offers may predate this acquisition's DAG readiness.
            _G.SessionMapState.DuoTalentEligible = nil
            _G.SessionMapState.DuoTalentEligibleSpell = {}
            _G.SessionMapState.DuoTalentEligibleGender = {}
            _G.PregenerateSpells(screen)
            offerScope.preparing = false
            return base(screen)
        end)
        offerScope = prior
        if not ok then error(result, 0) end
        return result
    end)
    module.hooks.wrap("OpenSpellScreen", "run-planner-spell-begin", function(_, runtime, base, spellItem, args, user)
        local scope = resolveScope(runtime, spellItem)
        if not scope then return base(spellItem, args, user) end
        if not room.begin(scope.state, scope.handle) then return base(spellItem, args, user) end
        local ok, result = pcall(base, spellItem, args, user)
        if not ok then
            clearScope(spellItem, scope)
            error(result, 0)
        end
        if scopesByLoot[spellItem] == scope then
            clearScope(spellItem, scope)
        end
        report(runtime); return result
    end)
    module.hooks.wrap("AcceptAndCloseSpellScreen", "run-planner-spell-selection",
        function(_, runtime, base, screen, button)
        local item = screen and screen.Source
        local scope = item and scopesByLoot[item] or nil
        if not scope then return base(screen, button) end
        local ok, result = pcall(function()
            return tree.realize(scope.offer.hexTree, button.TraitName, diagnosticFor(scope.state),
                function() return base(screen, button) end)
        end)
        if not ok then clearScope(item, scope); error(result, 0) end
        session.complete(scope.state, scope.handle); clearScope(item, scope)
        report(runtime); return result
        end)
end
return hooks
