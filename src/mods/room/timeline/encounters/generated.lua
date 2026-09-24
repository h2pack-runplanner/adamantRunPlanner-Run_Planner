-- Install resolved composition at native fill contacts. Native generation keeps
-- templates/setup; native spawning keeps timing, caps, groups and retries.
-- luacheck: globals GetNextSpawn MetaUpgradeData
local generated = {}
local fangs = type(import) == "function" and import("mods/room/timeline/encounters/fangs.lua")
    or require("mods.room.timeline.encounters.fangs")

local function compositionFor(phase)
    for _, decision in ipairs(phase and phase.customization or {}) do
        if decision.kind == "generated" and decision.decisionKey == "generatedComposition" then return decision end
    end
end

local function copy(value)
    local result = {}
    for key, entry in pairs(value or {}) do result[key] = entry end
    return result
end

local function menaceConversion(encounter, decision, spawnInfo)
    if spawnInfo == nil then return nil end
    for waveIndex, wave in ipairs(encounter.SpawnWaves or {}) do
        for _, source in ipairs(wave.Spawns or {}) do
            if source == spawnInfo then
                for _, menaceWave in ipairs(decision.menace or {}) do
                    if menaceWave.waveIndex == waveIndex then
                        for _, conversion in ipairs(menaceWave.conversions or {}) do
                            if conversion.source.nativeId == source.Name then return conversion end
                        end
                    end
                end
            end
        end
    end
end

local function scoped(stack, scope, action)
    stack[#stack + 1] = scope
    local result = table.pack(pcall(action))
    stack[#stack] = nil
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

local function templateFor(encounter, index, count)
    local hard = encounter.IsHardEncounter and encounter.HardEncounterOverrideValues or {}
    local manual = hard.ManualWaveTemplates or encounter.ManualWaveTemplates or {}
    return manual[index] or manual[-1 * (count - index)] or hard.WaveTemplate or encounter.WaveTemplate
end

-- Admission validates the payload. Only live declaration compatibility belongs here.
local function preflight(decision, encounter, enemies)
    if encounter.InfiniteSpawns then return "unsupported-infinite-spawns" end
    if encounter.SpawnWaves ~= nil and next(encounter.SpawnWaves) ~= nil then return "preexisting-waves" end
    for _, wave in ipairs(decision.menace or {}) do
        for _, conversion in ipairs(wave.conversions) do
            if conversion.count > 0 and enemies[conversion.target.nativeId] == nil then
                return "missing-menace-enemy", conversion.target.nativeId
            end
        end
    end
    for index, wave in ipairs(decision.waves) do
        local template = templateFor(encounter, index, decision.waveCount)
        if type(template) ~= "table" or type(template.Spawns) ~= "table" then return "unsupported-template" end
        local templateIndex = 1
        for _, entry in ipairs(wave.types) do
            local name, source = entry.nativeId, entry.source
            local count = wave.counts[name]
            if enemies[name] == nil then return "missing-enemy" end
            if source == "fixed" or source == "template" then
                local seed = template.Spawns[templateIndex]
                if seed == nil then return "missing-template-entry" end
                if source == "fixed" then
                    if seed.Name ~= name or seed.Generated or seed.TotalCount ~= count then
                        return "fixed-template-changed"
                    end
                elseif seed.Name ~= nil or not seed.Generated then return "unsupported-placeholder" end
                templateIndex = templateIndex + 1
            end
        end
        if templateIndex <= #template.Spawns then return "unowned-template-entry" end
    end
end

-- Native eligibility reads global CurrentRun.Blacklist. Leave it untouched:
-- carry only prospective exclusions in the detached encounter view instead.
-- Ordinary candidates are sampled before placeholders/additions in each wave;
-- fixed seeds and replicated highlight seeds are never sampled again.
local function eligibleComposition(decision, encounter, nativeRoom, currentRun, gameValue)
    nativeRoom = nativeRoom or currentRun.CurrentRoom or {}
    local eligible = gameValue.IsEnemyEligible or _G.IsEnemyEligible
    if type(eligible) ~= "function" then return "missing-enemy-eligibility" end
    local view = copy(encounter)
    if encounter.IsHardEncounter then
        for key, value in pairs(encounter.HardEncounterOverrideValues or {}) do view[key] = value end
    end
    if view.UseRoomEncounterEnemySet then view.EnemySet = nativeRoom.Encounter and nativeRoom.Encounter.EnemySet end
    if view.BuildCustomEnemySet then return "unsupported-custom-enemy-set" end
    view.Blacklist = copy(view.Blacklist)
    for name, blocked in pairs(currentRun.Blacklist or {}) do
        if blocked then view.Blacklist[name] = true end
    end
    local enemies = gameValue.EnemyData or {}
    local requireIntro = view.RequireCompletedIntro or nativeRoom.RequireCompletedIntro
    local roomData = gameValue.RoomData or _G.RoomData
    local depth = gameValue.GetBiomeDepth or _G.GetBiomeDepth
    local minDepth = nativeRoom.MinDepthBeforeIntros or (roomData and roomData.BaseRoom.MinDepthBeforeIntros)
    if minDepth and depth and depth(currentRun) < minDepth then requireIntro = true end
    local function check(name, wave, enemySet)
        local member = false
        for _, candidate in pairs(enemySet or view.EnemySet or {}) do
            if candidate == name then member = true end
        end
        if not member then return "enemy-set-changed", name end
        local ok, verdict = pcall(eligible, name, view, wave)
        if not ok then return "native-enemy-check-error", name end
        if not verdict then return "native-enemy-ineligible", name end
    end
    local function waveView(index)
        local wave = copy(templateFor(view, index, decision.waveCount))
        wave.Spawns = {}
        for _, spawn in ipairs(templateFor(view, index, decision.waveCount).Spawns) do
            wave.Spawns[#wave.Spawns + 1] = copy(spawn)
        end
        wave.WaveIndex, wave.TypeCount = index, #decision.waves[index].types
        wave.RequireCompletedIntro = wave.RequireCompletedIntro or requireIntro
        if decision.highlight and index == 1 then wave.BlockEliteTypes = view.BlockHighlightEliteTypes end
        return wave
    end
    local highlight = decision.highlight and decision.highlight.nativeId
    if highlight then
        local wave = waveView(1)
        wave.TypeCount, wave.BlockEliteTypes = 1, view.BlockHighlightEliteTypes
        local reason, name = check(highlight, wave)
        if reason then return reason, name end
        view.Blacklist[highlight] = true
    end
    for index, published in ipairs(decision.waves) do
        local wave = waveView(index)
        if highlight then wave.Spawns[#wave.Spawns + 1] = { Name = highlight } end
        -- These selections come from the one ordinary pool sampled before any
        -- placeholder gets a name. Unique placeholder pools are sampled later.
        local templateIndex = 1
        for _, entry in ipairs(published.types) do
            local seed = wave.Spawns[templateIndex]
            if entry.source == "addition" or (entry.source == "template" and not seed.EnemySet) then
                local reason, name = check(entry.nativeId, wave)
                if reason then return reason, name end
            end
            if entry.source == "fixed" or entry.source == "template" then templateIndex = templateIndex + 1 end
        end
        templateIndex = 1
        for _, entry in ipairs(published.types) do
            if entry.source == "fixed" or entry.source == "template" then
                local seed = wave.Spawns[templateIndex]
                if entry.source == "template" then
                    if seed.EnemySet then
                        local reason, name = check(entry.nativeId, wave, seed.EnemySet)
                        if reason then return reason, name end
                    end
                    seed.Name = entry.nativeId
                end
                templateIndex = templateIndex + 1
            end
        end
        local excluded = {}
        for _, entry in ipairs(published.types) do
            if entry.source == "addition" then
                local name, enemy = entry.nativeId, enemies[entry.nativeId]
                if excluded[name] then return "native-enemy-ineligible", name end
                if enemy.BlacklistAfterFirstAppearance then view.Blacklist[name] = true end
                for _, blocked in pairs((enemy.GeneratorData or {}).BlockEnemyTypes or {}) do
                    excluded[blocked] = true
                    if view.BlockTypesAcrossWaves then view.Blacklist[blocked] = true end
                end
                wave.Spawns[#wave.Spawns + 1] = { Name = name }
                -- Native prunes the already-sampled pool after each addition.
                -- Check only published subsequent members, without resampling
                -- against the now-populated wave or this wave's run blacklist.
                local elites, groups = 0, {}
                for _, spawn in ipairs(wave.Spawns) do
                    local selected = enemies[spawn.Name]
                    if selected.IsElite then elites = elites + 1 end
                    for _, group in pairs(selected.Groups or {}) do groups[group] = (groups[group] or 0) + 1 end
                end
                for _, candidate in ipairs(published.types) do
                    local candidateEnemy = enemies[candidate.nativeId]
                    if view.MaxEliteTypes and elites >= view.MaxEliteTypes and candidateEnemy.IsElite then
                        excluded[candidate.nativeId] = true
                    end
                    for _, group in pairs(candidateEnemy.Groups or {}) do
                        local cap = (view.MaxTypesPerGroup or {})[group]
                        if cap and (groups[group] or 0) >= cap then excluded[candidate.nativeId] = true end
                    end
                end
            end
        end
    end
end

function generated.create()
    local instance, stack = {}, {}
    local function current() return stack[#stack] end
    local function diagnostic(owner, observed)
        if owner and owner.session and owner.state and owner.occurrence then
            owner.session.diagnostic(owner.state, "encounter-composition", observed, owner.occurrence)
        end
    end
    function instance.withPhase(state, room, phase, nativeRoom, action)
        local decision = compositionFor(phase)
        local occurrence = state and room.occurrence and room.occurrence(state, nativeRoom)
        if decision == nil or occurrence == nil then return scoped(stack, { kind = "native" }, action) end
        return scoped(stack, {
            kind = "preparation", state = state, session = instance.session, occurrence = occurrence,
            phase = phase, encounterKey = phase.encounterKey, decision = decision,
        }, action)
    end
    function instance.withRewardDestination(state, room, nativeRoom, action)
        return instance.withPhase(state, room, state and room.encounterAt(state, 1, nativeRoom), nativeRoom, action)
    end
    function instance.attach(module, session, getState, room)
        instance.session = session
        local function owned(runtime, encounter)
            if type(encounter) ~= "table" then return nil end
            local marker = encounter.__runPlannerGeneratedComposition
            if marker == nil then return nil end
            local state = getState(runtime)
            if state == nil or state.state ~= "synchronized" then return nil end
            local phase = room.encounterPhase(state, encounter)
            local occurrence = room.occurrence(state)
            if phase == nil or occurrence == nil or marker.occurrenceId ~= occurrence.id
                or marker.slotKey ~= phase.slotKey or marker.encounterKey ~= phase.encounterKey then return nil end
            return compositionFor(phase)
        end
        fangs.attach(module, owned)
        module.hooks.wrap("SetupEncounter", "run-planner-generated-encounter-setup", function(_, _, base,
            encounterData, nativeRoom)
            local parent = current()
            if parent == nil or parent.kind ~= "preparation" or parent.encounterKey ~= encounterData.Name then
                return scoped(stack, { kind = "native" }, function() return base(encounterData, nativeRoom) end)
            end
            local ok, result = pcall(function()
                return scoped(stack, { kind = "setup", owner = parent }, function()
                    return base(encounterData, nativeRoom)
                end)
            end)
            local actual = type(result) == "table" and (result.GenusName or result.Name or result.EncounterName)
            if not ok or actual ~= parent.encounterKey then
                if parent.prepared then
                    parent.prepared.__runPlannerGeneratedComposition = nil
                end
                diagnostic(parent, { kind = "generated-not-realized", reason = ok and "intro-substitution" or "setup-error",
                    encounterKey = parent.encounterKey, observed = ok and actual or tostring(result) })
            end
            if not ok then error(result, 0) end
            return result
        end)
        module.hooks.wrap("GenerateEncounter", "run-planner-generated-encounter-generate", function(_, _, base,
            currentRun, nativeRoom, encounter)
            local parent = current()
            if parent == nil or parent.kind ~= "setup" or parent.owner.encounterKey ~= encounter.Name then
                return scoped(stack, { kind = "native" }, function() return base(currentRun, nativeRoom, encounter) end)
            end
            local owner, gameValue = parent.owner, _G.game or game or _G
            local decision, enemies = owner.decision, gameValue.EnemyData or {}
            -- A new owned preparation supersedes any restored realization. A
            -- failed attempt must fall back natively rather than leave a stale
            -- marker for Fangs or zero-Menace spawn interception.
            if encounter.__runPlannerGeneratedComposition ~= nil then
                encounter.__runPlannerGeneratedComposition = nil
            end
            local failure, enemy = preflight(decision, encounter, enemies)
            if not failure then
                local ok
                ok, failure, enemy = pcall(eligibleComposition, decision, encounter, nativeRoom, currentRun, gameValue)
                if not ok then failure, enemy = "native-enemy-check-error", nil end
            end
            if failure then
                diagnostic(owner, { kind = "generated-preflight", reason = failure, enemy = enemy })
                return scoped(stack, { kind = "native" }, function() return base(currentRun, nativeRoom, encounter) end)
            end
            encounter.MinWaves, encounter.MaxWaves = decision.waveCount, decision.waveCount
            if decision.baseRoll ~= nil then
                encounter.BaseDifficultyMin, encounter.BaseDifficultyMax = decision.baseRoll, decision.baseRoll
            end
            local previousHighlight, previousHard = encounter.BlockHighlightEncounter, encounter.HardEncounterOverrideValues
            encounter.BlockHighlightEncounter = true
            if previousHard then
                encounter.HardEncounterOverrideValues = copy(previousHard)
                encounter.HardEncounterOverrideValues.MinWaves = decision.waveCount
                encounter.HardEncounterOverrideValues.MaxWaves = decision.waveCount
                encounter.HardEncounterOverrideValues.BlockHighlightEncounter = true
                if decision.baseRoll ~= nil then
                    encounter.HardEncounterOverrideValues.BaseDifficultyMin = decision.baseRoll
                    encounter.HardEncounterOverrideValues.BaseDifficultyMax = decision.baseRoll
                end
            end
            local scope = { kind = "generate", owner = owner, encounter = encounter, run = currentRun,
                enemies = enemies, installed = {} }
            local ok, result = pcall(function()
                return scoped(stack, scope, function() return base(currentRun, nativeRoom, encounter) end)
            end)
            encounter.BlockHighlightEncounter, encounter.HardEncounterOverrideValues = previousHighlight, previousHard
            if not ok then
                diagnostic(owner, { kind = "generated-not-realized", reason = "generation-error" })
                error(result, 0)
            end
            for index = 1, decision.waveCount do
                if not scope.installed[index] then
                    diagnostic(owner, { kind = "generated-not-realized", reason = "missing-fill-contact", wave = index })
                    return result
                end
            end
            encounter.__runPlannerGeneratedComposition = {
                occurrenceId = owner.occurrence.id, slotKey = owner.phase.slotKey, encounterKey = owner.encounterKey,
            }
            owner.prepared = encounter
            local waves = {}
            for index, wave in ipairs(encounter.SpawnWaves) do
                local spawns = {}
                for _, spawn in ipairs(wave.Spawns) do
                    spawns[#spawns + 1] = { name = spawn.Name, count = spawn.TotalCount }
                end
                waves[index] = { wave = index, spawns = spawns }
            end
            diagnostic(owner, { kind = "generated-installed", phase = owner.phase.slotKey,
                encounterKey = owner.encounterKey, waveCount = #waves, waves = waves })
            return result
        end)
        module.hooks.wrap("FillEnemyTypes", "run-planner-generated-encounter-types", function(_, _, base,
            encounter, wave, nativeRoom)
            local scope = current()
            if scope == nil or scope.kind ~= "generate" or scope.encounter ~= encounter
                or encounter.SpawnWaves[wave.WaveIndex] ~= wave then return base(encounter, wave, nativeRoom) end
            local index, published = wave.WaveIndex, scope.owner.decision.waves[wave.WaveIndex]
            if scope.installed[index] then return end
            local spawns, templateIndex = {}, 1
            for _, entry in ipairs(published.types) do
                local name, source = entry.nativeId, entry.source
                if source == "fixed" or source == "template" then
                    local spawn = wave.Spawns[templateIndex]
                    templateIndex = templateIndex + 1
                    spawn.Name = name
                    spawns[#spawns + 1] = spawn
                else
                    spawns[#spawns + 1] = { Name = name, Generated = true }
                end
                -- Native FillEnemyCounts attaches metadata without reallocating
                -- entries whose TotalCount is already installed.
                spawns[#spawns].TotalCount = published.counts[name]
                if source == "highlight" then
                    encounter.Blacklist[name] = true
                elseif source == "addition" then
                    local enemy = scope.enemies[name]
                    if enemy.BlacklistAfterFirstAppearance then scope.run.Blacklist[name] = true end
                    local generator = enemy.GeneratorData or {}
                    if encounter.BlockTypesAcrossWaves then
                        for _, excluded in pairs(generator.BlockEnemyTypes or {}) do encounter.Blacklist[excluded] = true end
                    end
                    if generator.ActiveEnemyCapBonus then
                        encounter.ActiveEnemyCapBonus = (encounter.ActiveEnemyCapBonus or 0) + generator.ActiveEnemyCapBonus
                    end
                end
            end
            wave.Spawns, wave.TypeCount, scope.installed[index] = spawns, #spawns, true
        end)
        module.hooks.wrap("HandleNextSpawn", "run-planner-generated-encounter-menace", function(_, runtime, base,
            encounter, ignoreSpawnPreferences, spawnInfo, overrides, args)
            local decision = owned(runtime, encounter)
            -- SpawnUnitGroup re-enters HandleNextSpawn with this flag. Those
            -- child requests are native realization of one source request.
            if decision == nil or (args and args.IgnoreShrineOverrides) then
                return base(encounter, ignoreSpawnPreferences, spawnInfo, overrides, args)
            end
            local copied = copy(args)
            copied.IgnoreShrineOverrides = true
            -- Native obtains a request only once. Pull it before conversion so
            -- the bound source table remains the accounting/progress owner.
            if spawnInfo == nil then
                if type(GetNextSpawn) ~= "function" then return base(encounter, ignoreSpawnPreferences, nil, overrides, copied) end
                spawnInfo = GetNextSpawn(encounter)
                if spawnInfo == nil then return nil end
            end
            local conversion = menaceConversion(encounter, decision, spawnInfo)
            local remaining = spawnInfo and (spawnInfo.RemainingSpawns or spawnInfo.TotalCount) or 0
            local progress = spawnInfo and (spawnInfo.TotalCount or remaining) - remaining or 0
            if conversion ~= nil and progress < conversion.count and conversion.target ~= nil then
                -- Keep the source entry intact: group expansion can yield and
                -- recurse, so a temporary source rename is unsafe. Native
                -- decrements the transformed copy; reflect that success back
                -- to the source after the call returns.
                local originalName = spawnInfo.Name
                local transformedOverrides = copy(spawnInfo.SpawnOverrides)
                local transformed = copy(spawnInfo)
                local sourceRemaining = spawnInfo.RemainingSpawns or spawnInfo.TotalCount
                transformed.Name = conversion.target.nativeId
                transformed.SpawnOverrides = transformedOverrides
                transformedOverrides.IsFromNextBiomeEnemyShrineUpgrade = true
                transformedOverrides.RequiredSpawnPoint = "nil"
                local swap = ((_G.MetaUpgradeData or MetaUpgradeData).NextBiomeEnemyShrineUpgrade.SwapMap or {})[originalName]
                if swap ~= nil then
                    transformedOverrides.RequiredSpawnPoint = swap.RequiredSpawnPoint or "nil"
                    transformedOverrides.ActiveCapWeight = swap.ActiveCapWeight
                end
                local result = table.pack(pcall(base, encounter, ignoreSpawnPreferences, transformed, overrides, copied))
                if not result[1] then error(result[2], 0) end
                local realizedRemaining = transformed.RemainingSpawns
                if sourceRemaining ~= nil and realizedRemaining ~= nil and not spawnInfo.InfiniteSpawns then
                    spawnInfo.RemainingSpawns = sourceRemaining - math.max(0, sourceRemaining - realizedRemaining)
                end
                return table.unpack(result, 2, result.n)
            end
            return base(encounter, ignoreSpawnPreferences, spawnInfo, overrides, copied)
        end)
    end
    return instance
end
return generated
