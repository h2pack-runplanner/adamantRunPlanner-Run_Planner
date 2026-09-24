-- Install resolved composition at native fill contacts. Native generation keeps
-- templates/setup; native spawning keeps timing, caps, groups and retries.
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
local function preflight(decision, encounter, enemies, runBlacklist)
    if encounter.InfiniteSpawns then return "unsupported-infinite-spawns" end
    if encounter.SpawnWaves ~= nil and next(encounter.SpawnWaves) ~= nil then return "preexisting-waves" end
    for index, wave in ipairs(decision.waves) do
        local template = templateFor(encounter, index, decision.waveCount)
        if type(template) ~= "table" or type(template.Spawns) ~= "table" then return "unsupported-template" end
        local templateIndex = 1
        for _, entry in ipairs(wave.types) do
            local name, source = entry.nativeId, entry.source
            local count = wave.counts[name]
            if enemies[name] == nil then return "missing-enemy" end
            if enemies[name].BlacklistAfterFirstAppearance and runBlacklist[name] then
                return "run-blacklisted-enemy", name
            end
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
            local failure, enemy = preflight(decision, encounter, enemies, currentRun.Blacklist or {})
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
        module.hooks.wrap("HandleNextSpawn", "run-planner-generated-encounter-zero-menace", function(_, runtime, base,
            encounter, ignoreSpawnPreferences, spawnInfo, overrides, args)
            if owned(runtime, encounter) == nil then
                return base(encounter, ignoreSpawnPreferences, spawnInfo, overrides, args)
            end
            local copied = copy(args)
            copied.IgnoreShrineOverrides = true
            return base(encounter, ignoreSpawnPreferences, spawnInfo, overrides, copied)
        end)
    end
    return instance
end
return generated
