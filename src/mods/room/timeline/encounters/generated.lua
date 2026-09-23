-- Optional generated-composition steering stays inside the synchronous native
-- encounter preparation call. The planner supplies only sparse operands; the
-- game still owns eligibility, type side effects, rounding, caps and spawning.
local generated = {}

local function compositionFor(phase)
    for _, decision in ipairs(phase and phase.customization or {}) do
        if decision.kind == "generated" and decision.decisionKey == "generatedComposition" then
            return decision
        end
    end
    return nil
end

local function waveFor(decision, index)
    for _, wave in ipairs(decision.waves or {}) do
        if wave.waveIndex == index then return wave end
    end
    return nil
end

local function nativeId(entry)
    return type(entry) == "table" and entry.nativeId or nil
end

-- Highlight is published first in each generated wave, while fixed template
-- entries are intentionally absent from the authored generated list.
local function additionsFor(decision, index)
    local wave = waveFor(decision, index)
    if wave == nil then return nil end
    local start = decision.highlight ~= nil and 2 or 1
    local result = {}
    for position = start, #(wave.types or {}) do
        result[#result + 1] = nativeId(wave.types[position])
    end
    return result, wave
end

-- FillEnemyCounts uses the full spawn-array index against generated-entry
-- count to identify the native remainder branch. Its preceding RandomNormal
-- calls each begin at the equal native slice, so multiplying that slice by the
-- generated-entry count restores the full wave budget before the published
-- relative share is applied.
local function countSampleBranches(wave)
    local generatedCount, result = 0, {}
    for _, spawn in ipairs(wave.Spawns or {}) do
        local fixed = not spawn.Generated and ((spawn.CountMin and spawn.CountMax) or spawn.TotalCount)
        if not fixed then generatedCount = generatedCount + 1 end
    end
    for index, spawn in ipairs(wave.Spawns or {}) do
        local isGenerated = spawn.Generated or not ((spawn.CountMin and spawn.CountMax) or spawn.TotalCount)
        if isGenerated and spawn.TotalCount == nil and index ~= generatedCount then
            result[#result + 1] = { index = index, enemyName = spawn.Name }
        end
    end
    return generatedCount, result
end

local function shareFor(wave, enemyName)
    for index, entry in ipairs(wave and wave.types or {}) do
        if nativeId(entry) == enemyName then return wave.shares and wave.shares[index] end
    end
    return nil
end

local function withScope(stack, scope, action)
    stack[#stack + 1] = scope
    local ok, result = pcall(action)
    stack[#stack] = nil
    if not ok then error(result, 0) end
    return result
end

function generated.create()
    local instance = {}
    local stack = {}
    local function current() return stack[#stack] end

    local function diagnostic(owner, observed)
        if owner.session and owner.state and owner.occurrence then
            owner.session.diagnostic(owner.state, "encounter-composition", observed, owner.occurrence)
        end
    end

    function instance.withPhase(state, room, phase, nativeRoom, action)
        local decision = compositionFor(phase)
        -- A nested native or unsupported setup must not inherit its caller's
        -- same-name override while that outer preparation scope is active.
        if decision == nil then
            return withScope(stack, { kind = "native" }, action)
        end
        local occurrence = state and room.occurrence(state, nativeRoom) or nil
        if occurrence == nil then return withScope(stack, { kind = "native" }, action) end
        return withScope(stack, {
            kind = "preparation", state = state, session = instance.session, occurrence = occurrence,
            phase = phase, nativeRoom = nativeRoom, encounterKey = phase.encounterKey, decision = decision,
        }, action)
    end

    -- Reward-owned Devotion selects inside SetupRoomReward. Its native
    -- generation context remains the predecessor; this only provides the
    -- stamped destination identity that owns the sparse override.
    function instance.withRewardDestination(state, room, nativeRoom, action)
        local phase = state and room.encounterAt(state, 1, nativeRoom)
        return instance.withPhase(state, room, phase, nativeRoom, action)
    end

    function instance.attach(module, session)
        instance.session = session

        module.hooks.wrap("SetupEncounter", "run-planner-generated-encounter-setup", function(_, _, base,
            encounterData, nativeRoom)
            local parent = current()
            if parent == nil or parent.kind ~= "preparation" or parent.encounterKey ~= encounterData.Name then
                return withScope(stack, { kind = "native" }, function() return base(encounterData, nativeRoom) end)
            end
            return withScope(stack, { kind = "setup", owner = parent }, function()
                return base(encounterData, nativeRoom)
            end)
        end)

        module.hooks.wrap("GenerateEncounter", "run-planner-generated-encounter-generate", function(_, _, base,
            currentRun, nativeRoom, encounter)
            local parent = current()
            if parent == nil or parent.kind ~= "setup" or parent.owner.encounterKey ~= encounter.Name then
                return withScope(stack, { kind = "native" }, function()
                    return base(currentRun, nativeRoom, encounter)
                end)
            end
            local owner, decision = parent.owner, parent.owner.decision
            if decision.waveCount ~= nil then
                encounter.MinWaves, encounter.MaxWaves = decision.waveCount, decision.waveCount
                -- GenerateEncounter applies this copied table before reading
                -- bounds for hard encounters. Keep every native override, but
                -- retain the explicit count on this encounter copy.
                if type(encounter.HardEncounterOverrideValues) == "table" then
                    local overrides = {}
                    for key, value in pairs(encounter.HardEncounterOverrideValues) do overrides[key] = value end
                    overrides.MinWaves, overrides.MaxWaves = decision.waveCount, decision.waveCount
                    encounter.HardEncounterOverrideValues = overrides
                end
            end
            return withScope(stack, {
                kind = "generate", owner = owner, encounter = encounter, nativeRoom = nativeRoom,
            }, function()
                local result = base(currentRun, nativeRoom, encounter)
                local waves = {}
                for index, wave in ipairs(encounter.SpawnWaves or {}) do
                    local spawns, requested = {}, {}
                    for _, spawn in ipairs(wave.Spawns or {}) do
                        spawns[#spawns + 1] = {
                            name = spawn.Name, count = spawn.TotalCount,
                            countMin = spawn.CountMin, countMax = spawn.CountMax,
                        }
                    end
                    local authored = waveFor(decision, index)
                    for position, entry in ipairs(authored and authored.types or {}) do
                        requested[#requested + 1] = {
                            name = nativeId(entry), share = authored.shares and authored.shares[position],
                        }
                    end
                    waves[#waves + 1] = { wave = index, spawns = spawns, requested = requested }
                end
                diagnostic(owner, {
                    kind = "generated-result", phase = owner.phase.slotKey,
                    encounterKey = owner.encounterKey, requestedWaveCount = decision.waveCount,
                    waveCount = #waves, waves = waves,
                })
                return result
            end)
        end)

        module.hooks.wrap("FillEnemyTypes", "run-planner-generated-encounter-types", function(_, _, base,
            encounter, wave, nativeRoom)
            local parent = current()
            if parent == nil or parent.kind ~= "generate" or parent.encounter ~= encounter
                or encounter.SpawnWaves[wave.WaveIndex] ~= wave then
                return withScope(stack, { kind = "native" }, function() return base(encounter, wave, nativeRoom) end)
            end
            local additions = additionsFor(parent.owner.decision, wave.WaveIndex)
            if additions ~= nil and not encounter.EscalateTypeCount and wave.TypeCount == nil then
                local named = 0
                for _, spawn in ipairs(wave.Spawns or {}) do if spawn.Name then named = named + 1 end end
                wave.TypeCount = named + #additions
            end
            return withScope(stack, {
                kind = "types", owner = parent.owner, encounter = encounter, wave = wave, additions = additions,
            }, function() return base(encounter, wave, nativeRoom) end)
        end)

        module.hooks.wrap("FillEnemyCounts", "run-planner-generated-encounter-counts", function(_, _, base,
            encounter, wave, nativeRoom)
            local parent = current()
            if parent == nil or parent.kind ~= "generate" or parent.encounter ~= encounter
                or encounter.SpawnWaves[wave.WaveIndex] ~= wave then
                return withScope(stack, { kind = "native" }, function() return base(encounter, wave, nativeRoom) end)
            end
            local generatedCount, samples = countSampleBranches(wave)
            return withScope(stack, {
                kind = "counts", owner = parent.owner, encounter = encounter, wave = wave,
                generatedCount = generatedCount, samples = samples, sampleIndex = 0,
            }, function() return base(encounter, wave, nativeRoom) end)
        end)

        module.hooks.wrap("IsEnemyEligible", "run-planner-generated-encounter-highlight", function(_, _, base,
            enemyName, encounter, wave)
            local result = base(enemyName, encounter, wave)
            local scope = current()
            if scope and scope.kind == "generate" and scope.encounter == encounter
                and wave == encounter.SpawnWaves[1] and wave.TypeCount == 1 and #(wave.Spawns or {}) == 0 then
                scope.highlightReady = true
            end
            return result
        end)

        module.hooks.wrap("RemoveRandomValue", "run-planner-generated-encounter-selection", function(_, _, base,
            values, ...)
            local scope, owner = current(), current() and current().owner
            local requested, kind
            if scope and scope.kind == "generate" and scope.highlightReady then
                requested, kind, scope.highlightReady = nativeId(owner.decision.highlight), "highlight", false
            elseif scope and scope.kind == "types" then
                scope.typeIndex = (scope.typeIndex or 0) + 1
                requested, kind = scope.additions and scope.additions[scope.typeIndex], "type"
            end
            if requested == nil then return base(values, ...) end
            for index, candidate in ipairs(values or {}) do
                if candidate == requested then return table.remove(values, index) end
            end
            diagnostic(owner, {
                phase = owner.phase.slotKey, encounterKey = owner.encounterKey,
                wave = scope.wave and scope.wave.WaveIndex or 0, kind = kind,
                requested = requested, reason = "native-ineligible",
            })
            return base(values, ...)
        end)

        module.hooks.wrap("RandomNormal", "run-planner-generated-encounter-allocation", function(_, _, base,
            mean, deviation, ...)
            local scope = current()
            if scope == nil or scope.kind ~= "counts" then return base(mean, deviation, ...) end
            scope.sampleIndex = scope.sampleIndex + 1
            local branch = scope.samples[scope.sampleIndex]
            local wave = waveFor(scope.owner.decision, scope.wave.WaveIndex)
            local share = branch and shareFor(wave, branch.enemyName)
            if share == nil then return base(mean, deviation, ...) end
            return mean * scope.generatedCount * share
        end)
    end

    return instance
end

return generated
