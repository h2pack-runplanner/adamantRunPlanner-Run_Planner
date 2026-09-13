-- Nemesis encounter realization. The planner chooses the event; native text,
-- trade, removal, contest, and reward callbacks remain the carriers.
local nemesis = {}
local unpackValues = table.unpack

local function packValues(...)
    return { n = select("#", ...), ... }
end

local function currentThread()
    return coroutine.running() or nemesis
end

local function isTradeSellShop(nativeRoom, args)
    return nativeRoom == (_G.CurrentRun and _G.CurrentRun.CurrentRoom)
        and type(args) == "table" and args.SellOptionCount == 1 and args.PrioritizeCommonTraits == true
end

function nemesis.attach(module, session, getState, report, room)
    local nemesisSpawnDepth = 0
    local npcRewardSource
    local tradeTargets = setmetatable({}, { __mode = "k" })
    local tradeExchanges = setmetatable({}, { __mode = "k" })
    local damageContests = setmetatable({}, { __mode = "k" })

    local function interactionHandle(state, source)
        return room.encounterHandle(state, source)
    end

    local function row(state, source)
        local handle = interactionHandle(state, source)
        local payload = handle and room.peek(state, handle) or nil
        local resolution = payload and payload.transaction.resolution
        if resolution and resolution.kind == "nemesisRandomEvent" then
            return handle, payload, resolution.outcome
        end
        return nil
    end

    local function freeItemAvailable(item, itemGameName)
        if type(item) ~= "table" or (item.Name ~= itemGameName and item.ItemName ~= itemGameName) then
            return false
        end
        if item.GameStateRequirements == nil then return true end
        return _G.IsGameStateEligible(item, item.GameStateRequirements) == true
    end

    local function constrainConsumables(consumables, matches)
        local constrained = {}
        for key, value in pairs(consumables) do
            if type(key) ~= "number" then constrained[key] = value end
        end
        for _, item in ipairs(matches) do constrained[#constrained + 1] = item end
        return constrained
    end

    module.hooks.wrap("SpawnNemesisForRandomEvents", "run-planner-nemesis-spawn", function(_, _, base, source, args)
        nemesisSpawnDepth = nemesisSpawnDepth + 1
        local ok, result = pcall(base, source, args)
        nemesisSpawnDepth = nemesisSpawnDepth - 1
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("CheckAvailableTextLines", "run-planner-nemesis-family", function(_, runtime, base, source,
        args)
        if nemesisSpawnDepth == 0 then return base(source, args) end
        local state = getState(runtime)
        local handle, _, outcome = row(state, source)
        local prefixes = {
            freeItem = "NemesisGetFreeItem", goldTrade = "NemesisBuyItem",
            damageTrade = "NemesisTakeDamageForItem", traitTrade = "NemesisGiveTraitForItem",
            damageContest = "NemesisDamageContest",
        }
        local original, prefix = source and source.InteractTextLineSets, outcome and prefixes[outcome.kind]
        if handle == nil or type(original) ~= "table" or prefix == nil then return base(source, args) end
        local filtered = {}
        for key, value in pairs(original) do
            if type(key) == "string" and key:sub(1, #prefix) == prefix then filtered[key] = value end
        end
        if next(filtered) == nil then
            session.diagnostic(state, "nemesis-event-family", "unavailable")
            report(runtime)
            return base(source, args)
        end
        source.InteractTextLineSets = filtered
        local ok, result = pcall(base, source, args)
        source.InteractTextLineSets = original
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("NemesisTradeChoice", "run-planner-nemesis-trade", function(_, runtime, base, source, args,
        screen)
        local state = getState(runtime)
        local handle, payload, outcome = row(state, source)
        if handle ~= nil then payload = room.begin(state, handle) end
        if payload == nil then handle, outcome = nil, nil end
        local thread = currentThread()
        local prior = tradeTargets[thread]
        if handle and outcome and outcome.kind == "traitTrade" then
            tradeTargets[thread] = { state = state, traitKey = outcome.traitKey }
        else
            tradeTargets[thread] = nil
        end
        local results = packValues(pcall(base, source, args, screen))
        tradeTargets[thread] = prior
        if not results[1] then error(results[2], 0) end
        if handle and outcome then
            local accepted = source and source.Accepted == true
            if (outcome.response == "accept") ~= accepted then
                session.diagnostic(state, "nemesis-trade-response", accepted)
            end
            if outcome.kind == "traitTrade" and accepted then
                tradeExchanges[screen] = { state = state, handle = handle }
            else
                session.complete(state, handle)
            end
        end
        report(runtime)
        return unpackValues(results, 2, results.n)
    end)

    module.hooks.wrap("GenerateSellTraitShop", "run-planner-nemesis-trait-trade", function(_, runtime, base,
        nativeRoom, args)
        local thread = currentThread()
        local target = tradeTargets[thread]
        if target == nil or not isTradeSellShop(nativeRoom, args) then return base(nativeRoom, args) end
        tradeTargets[thread] = nil
        local results = packValues(base(nativeRoom, args))
        local selected
        for _, option in ipairs(nativeRoom.SellOptions or {}) do
            if type(option) == "table" and option.Name == target.traitKey then selected = option; break end
        end
        if selected == nil and type(nativeRoom.SellValues) == "table" then
            selected = nativeRoom.SellValues[target.traitKey]
        end
        if selected == nil then
            session.diagnostic(target.state, "nemesis-trait-trade", "unavailable")
        else
            nativeRoom.SellOptions = { selected }
            if type(nativeRoom.SellValues) == "table" then nativeRoom.SellValues[target.traitKey] = nil end
        end
        report(runtime)
        return unpackValues(results, 1, results.n)
    end)

    module.hooks.wrap("TradeDoExchange", "run-planner-nemesis-trade-terminal", function(_, runtime, base,
        screen, args)
        local pending = tradeExchanges[screen]
        tradeExchanges[screen] = nil
        local results = packValues(base(screen, args))
        if pending then session.complete(pending.state, pending.handle) end
        report(runtime)
        return unpackValues(results, 1, results.n)
    end)

    module.hooks.wrap("StartNemesisDamageContest", "run-planner-nemesis-contest-start", function(_, runtime,
        base, source, args)
        local state = getState(runtime)
        local handle, _, outcome = row(state, source)
        local pending
        if handle and outcome and outcome.kind == "damageContest" then
            if room.begin(state, handle) ~= nil then
                pending = { state = state, handle = handle, result = outcome.result }
                damageContests[source] = pending
            end
        end
        local ok, result = pcall(base, source, args)
        if not ok then
            if damageContests[source] == pending then damageContests[source] = nil end
            error(result, 0)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("NemesisDamageContestTimer", "run-planner-nemesis-contest", function(_, runtime, base, source,
        args)
        local pending = damageContests[source]
        damageContests[source] = nil
        local result = base(source, args)
        if pending then
            local details = source.DamageContestArgs or {}
            local success = type(source.DamageContestAmount) == "number"
                and type(details.DamageGoal) == "number"
                and source.DamageContestAmount >= details.DamageGoal
            if (pending.result == "success") ~= success then
                session.diagnostic(pending.state, "nemesis-damage-contest", success)
            end
            session.complete(pending.state, pending.handle)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("NPCRewardDropPreProcess", "run-planner-nemesis-reward-source", function(_, _runtime,
        base, source, args, line)
        local priorSource = npcRewardSource
        npcRewardSource = source
        local ok, result = pcall(base, source, args, line)
        npcRewardSource = priorSource
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("NPCRewardDropPreProcessArgs", "run-planner-nemesis-reward-options", function(_, runtime,
        base, args, choice, line)
        local state = getState(runtime)
        local source = npcRewardSource or type(args) == "table" and args.Source or nil
        local handle, _, outcome = row(state, source)
        if handle and outcome and outcome.kind == "freeItem" then
            local matches = {}
            local consumables = type(args) == "table" and type(args.Consumables) == "table"
                and args.Consumables or {}
            for _, item in ipairs(consumables) do
                if freeItemAvailable(item, outcome.itemGameName) then
                    matches[#matches + 1] = item
                end
            end
            if #matches == 0 then
                session.diagnostic(state, "nemesis-free-item", "unavailable")
            else
                args.Consumables = constrainConsumables(consumables, matches)
            end
        end
        local result = base(args, choice, line)
        report(runtime)
        return result
    end)

    module.hooks.wrap("NPCRewardDrop", "run-planner-nemesis-reward", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local handle, _, outcome = row(state, source)
        local begun = handle and outcome and outcome.kind == "freeItem"
            and room.begin(state, handle) ~= nil
        local result = base(source, args)
        if begun then session.complete(state, handle) end
        report(runtime)
        return result
    end)
end

return nemesis
