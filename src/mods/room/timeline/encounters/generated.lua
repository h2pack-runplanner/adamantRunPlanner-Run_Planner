-- Install resolved composition at native fill contacts. Native generation keeps
-- templates/setup; native spawning keeps timing, caps, groups and retries.
-- A finite composition owns waves and counts; an infinite roster owns only the
-- ordered FillEnemyTypes draws, which native FillEnemyCounts marks infinite.
-- luacheck: globals GetNextSpawn MetaUpgradeData
local generated = {}
local fangs = type(import) == "function" and import("mods/room/timeline/encounters/fangs.lua")
    or require("mods.room.timeline.encounters.fangs")
local proof = type(import) == "function" and import("mods/room/conformance/proof.lua")
    or require("mods.room.conformance.proof")

local function compositionFor(phase)
    for _, decision in ipairs(phase and phase.customization or {}) do
        if decision.kind == "generated" and decision.decisionKey == "generatedComposition" then return decision end
    end
end

local function rosterFor(phase)
    for _, decision in ipairs(phase and phase.customization or {}) do
        if decision.kind == "infiniteRoster" and decision.decisionKey == "infiniteRoster" then return decision end
    end
end

local function isRoster(decision) return decision.kind == "infiniteRoster" end

local function copy(value)
    local result = {}
    for key, entry in pairs(value or {}) do result[key] = entry end
    return result
end

local function nativeValue(gameValue, name)
    local value = gameValue[name]
    if value == nil then value = _G[name] end
    return value
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

-- Native wave template choice over the effective (hard-overridden) encounter.
local function templateFor(encounter, index, count)
    local manual = encounter.ManualWaveTemplates or {}
    return manual[index] or manual[-1 * (count - index)] or encounter.WaveTemplate
end

-- GenerateEncounter applies hard overrides before rolling RandomInt(BaseDifficultyMin,
-- BaseDifficultyMax). A "nil" override clears the range; it fails the numeric check below.
local function effectiveBase(encounter, key)
    local hard = encounter.IsHardEncounter and encounter.HardEncounterOverrideValues or {}
    if hard[key] ~= nil then return hard[key] end
    return encounter[key]
end

-- Native still makes exactly one RandomInt call for the base roll, over a
-- single-value range. The returned function restores native post-generation fields.
local function supplyBaseRoll(encounter, roll)
    local minimum, maximum = effectiveBase(encounter, "BaseDifficultyMin"), effectiveBase(encounter, "BaseDifficultyMax")
    if type(minimum) ~= "number" or type(maximum) ~= "number" or roll < minimum or roll > maximum then
        return nil, { reason = "base-roll-out-of-range", expected = { min = minimum, max = maximum }, observed = roll }
    end
    local priorHard = encounter.HardEncounterOverrideValues
    encounter.BaseDifficultyMin, encounter.BaseDifficultyMax = roll, roll
    if encounter.IsHardEncounter and priorHard then
        encounter.HardEncounterOverrideValues = copy(priorHard)
        encounter.HardEncounterOverrideValues.BaseDifficultyMin = roll
        encounter.HardEncounterOverrideValues.BaseDifficultyMax = roll
    end
    return function()
        encounter.HardEncounterOverrideValues = priorHard
        encounter.BaseDifficultyMin, encounter.BaseDifficultyMax = minimum, maximum
    end
end

-- Live declaration facts the installer relies on, read from the effective encounter.
local function installable(decision, encounter, enemies)
    if encounter.InfiniteSpawns then return "unsupported-infinite-spawns" end
    if encounter.SpawnWaves ~= nil and next(encounter.SpawnWaves) ~= nil then return "preexisting-waves" end
    if encounter.BuildCustomEnemySet ~= nil then return "unsupported-custom-enemy-set" end
    for index, wave in ipairs(decision.waves) do
        local template = templateFor(encounter, index, decision.waveCount)
        if type(template) ~= "table" or type(template.Spawns) ~= "table" then return "unsupported-template", { wave = index } end
        local templateIndex = 1
        for _, entry in ipairs(wave.types) do
            local name, source = entry.nativeId, entry.source
            if enemies[name] == nil then return "missing-enemy", { wave = index, enemy = name } end
            if source == "fixed" or source == "template" then
                local seed = template.Spawns[templateIndex]
                if seed == nil then return "missing-template-entry", { wave = index, enemy = name } end
                if source == "fixed" then
                    if seed.Name ~= name or seed.Generated or seed.TotalCount ~= wave.counts[name] then
                        return "fixed-template-changed", { wave = index, enemy = name, observed = seed.Name }
                    end
                elseif seed.Name ~= nil or not seed.Generated then
                    return "unsupported-placeholder", { wave = index, enemy = name }
                end
                templateIndex = templateIndex + 1
            end
        end
        if templateIndex <= #template.Spawns then return "unowned-template-entry", { wave = index } end
    end
end

-- GenerateEncounter's wave RequireCompletedIntro, including the shallow-depth override.
local function requireCompletedIntro(encounter, nativeRoom, currentRun, gameValue)
    local requireIntro = encounter.RequireCompletedIntro or nativeRoom.RequireCompletedIntro
    local roomData = nativeValue(gameValue, "RoomData")
    local depth = nativeValue(gameValue, "GetBiomeDepth")
    local minDepth = nativeRoom.MinDepthBeforeIntros or (roomData and roomData.BaseRoom.MinDepthBeforeIntros)
    if minDepth and depth and depth(currentRun) < minDepth then requireIntro = true end
    return requireIntro
end

-- A detached encounter view with the run blacklist; live tables stay untouched.
local function eligibilityView(encounter, currentRun)
    local view = copy(encounter)
    view.Blacklist = copy(view.Blacklist)
    for name, blocked in pairs(currentRun.Blacklist or {}) do
        if blocked then view.Blacklist[name] = true end
    end
    return view
end

-- Native eligibility reads global CurrentRun.Blacklist. Leave it untouched:
-- carry only prospective exclusions in the detached encounter view instead.
-- Ordinary candidates are sampled before placeholders/additions in each wave;
-- fixed seeds and replicated highlight seeds are never sampled again.
local function eligibleComposition(decision, encounter, nativeRoom, currentRun, gameValue)
    local eligible = nativeValue(gameValue, "IsEnemyEligible")
    if type(eligible) ~= "function" then return "missing-enemy-eligibility" end
    local view = eligibilityView(encounter, currentRun)
    local enemies = gameValue.EnemyData or {}
    local requireIntro = requireCompletedIntro(view, nativeRoom, currentRun, gameValue)
    local function check(name, index, wave, enemySet)
        local member = false
        for _, candidate in pairs(enemySet or view.EnemySet or {}) do
            if candidate == name then member = true end
        end
        if not member then return "enemy-set-changed", { wave = index, enemy = name } end
        local ok, verdict = pcall(eligible, name, view, wave)
        if not ok then return "native-enemy-check-error", { wave = index, enemy = name, observed = tostring(verdict) } end
        if not verdict then return "native-enemy-ineligible", { wave = index, enemy = name } end
    end
    local function waveView(index)
        local template = templateFor(view, index, decision.waveCount)
        local wave = copy(template)
        wave.Spawns = {}
        for _, spawn in ipairs(template.Spawns) do wave.Spawns[#wave.Spawns + 1] = copy(spawn) end
        wave.WaveIndex, wave.TypeCount = index, #decision.waves[index].types
        wave.RequireCompletedIntro = wave.RequireCompletedIntro or requireIntro
        if decision.highlight and index == 1 then wave.BlockEliteTypes = view.BlockHighlightEliteTypes end
        return wave
    end
    local highlight = decision.highlight and decision.highlight.nativeId
    if highlight then
        local wave = waveView(1)
        wave.TypeCount, wave.BlockEliteTypes = 1, view.BlockHighlightEliteTypes
        local reason, evidence = check(highlight, 1, wave)
        if reason then return reason, evidence end
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
                local reason, evidence = check(entry.nativeId, index, wave)
                if reason then return reason, evidence end
            end
            if entry.source == "fixed" or entry.source == "template" then templateIndex = templateIndex + 1 end
        end
        templateIndex = 1
        for _, entry in ipairs(published.types) do
            if entry.source == "fixed" or entry.source == "template" then
                local seed = wave.Spawns[templateIndex]
                if entry.source == "template" then
                    if seed.EnemySet then
                        local reason, evidence = check(entry.nativeId, index, wave, seed.EnemySet)
                        if reason then return reason, evidence end
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
                if excluded[name] then return "native-enemy-ineligible", { wave = index, enemy = name } end
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

-- Native HandleNextSpawn converts only without encounter/source blocks, under an
-- active vow, once the next biome was visited; targets come from SwapMap, else the
-- room-set pool. Chance and counts are the planner's; zero conversions need nothing.
local function menaceAdmissible(decision, encounter, nativeRoom, gameValue)
    local positive = {}
    for _, wave in ipairs(decision.menace or {}) do
        for _, conversion in ipairs(wave.conversions) do
            if conversion.count > 0 then positive[#positive + 1] = { wave = wave.waveIndex, conversion = conversion } end
        end
    end
    if #positive == 0 then return nil end
    local encounterData = (nativeValue(gameValue, "EncounterData") or {})[encounter.Name] or encounter
    if encounterData.BlockNextBiomeEnemyShrineUpgrade then return "menace-encounter-blocked" end
    local vow = nativeValue(gameValue, "GetShrineUpgradeChangeValue")("NextBiomeEnemyShrineUpgrade")
    if type(vow) ~= "number" or vow <= 0 then return "menace-vow-inactive", { observed = vow } end
    local roomSet = nativeRoom.RoomSetName
    local nextRoomSet = (nativeValue(gameValue, "NextRoomSets") or {})[roomSet]
    local visits = (nativeValue(gameValue, "GameState") or {}).BiomeVisits or {}
    if nextRoomSet ~= nil and (visits[nextRoomSet] or 0) <= 0 then
        return "menace-next-biome-unvisited", { expected = nextRoomSet }
    end
    local enemies = gameValue.EnemyData or {}
    local upgrade = (nativeValue(gameValue, "MetaUpgradeData") or {}).NextBiomeEnemyShrineUpgrade or {}
    for _, entry in ipairs(positive) do
        local source, target = entry.conversion.source.nativeId, entry.conversion.target.nativeId
        if enemies[source].BlockNextBiomeEnemyShrineUpgrade then
            return "menace-source-blocked", { wave = entry.wave, enemy = source }
        end
        local swap, mapped = (upgrade.SwapMap or {})[source], false
        if swap ~= nil then
            mapped = swap.Name == target
        else
            for _, candidate in pairs((upgrade.BiomeEnemySets or {})[roomSet] or {}) do
                if candidate == target then mapped = true end
            end
        end
        if not mapped then
            return "menace-target-unmapped", { wave = entry.wave, enemy = source, expected = swap and swap.Name, observed = target }
        end
        if enemies[target] == nil then return "missing-menace-enemy", { wave = entry.wave, enemy = target } end
    end
end

-- SetupEncounter replaces a generated encounter afterwards when a spawned enemy's
-- introduction is incomplete and eligible, unless SkipIntroEncounterCheck is set.
local function introSubstitution(waves, encounter, gameValue)
    if encounter.SkipIntroEncounterCheck then return nil end
    local enemies, encounters = gameValue.EnemyData or {}, nativeValue(gameValue, "EncounterData") or {}
    local completed, eligible = nativeValue(gameValue, "HasEncounterBeenCompleted"), nativeValue(gameValue, "IsGameStateEligible")
    for index, wave in ipairs(waves) do
        for _, entry in ipairs(wave.types) do
            local intro = enemies[entry.nativeId].IntroEncounterName
            if intro ~= nil and not completed(intro) then
                local data = encounters[intro]
                if data.GameStateRequirements == nil or eligible(data, data.GameStateRequirements) then
                    return "intro-substitution", { wave = index, enemy = entry.nativeId, observed = intro }
                end
            end
        end
    end
end

-- One whole-encounter decision after native DifficultyRating and before wave
-- construction; nothing live is mutated here.
local function admission(decision, encounter, nativeRoom, currentRun, gameValue)
    local enemies = gameValue.EnemyData or {}
    local _, budget = proof.compare("encounterBudget", decision.expectedBudget, encounter.DifficultyRating)
    if budget then return "budget-mismatch", { expected = budget.expected, observed = budget.observed } end
    local minimum, maximum = encounter.MinWaves or 1, encounter.MaxWaves or 1
    if decision.waveCount < minimum or decision.waveCount > maximum then
        return "wave-count-out-of-range", { expected = { min = minimum, max = maximum }, observed = decision.waveCount }
    end
    local reason, evidence = installable(decision, encounter, enemies)
    if reason then return reason, evidence end
    reason, evidence = eligibleComposition(decision, encounter, nativeRoom, currentRun, gameValue)
    if reason then return reason, evidence end
    reason, evidence = fangs.admit(decision, encounter, enemies, nativeValue(gameValue, "IsEliteAttributeEligible"))
    if reason then return reason, evidence end
    reason, evidence = menaceAdmissible(decision, encounter, nativeRoom, gameValue)
    if reason then return reason, evidence end
    return introSubstitution(decision.waves, encounter, gameValue)
end

-- FillEnemyTypes draw count for the one roster wave: MinTypes..MaxTypes capped by
-- MaxTypesCap. Escalated, template-fixed or depth-dependent counts are not admitted.
local function rosterTypeBounds(encounter, template)
    if encounter.EscalateTypeCount or template.TypeCount ~= nil or encounter.UseEncounterDepthForTypes
        or (encounter.TypeCountDepthRamp or 0) ~= 0 then
        return nil
    end
    local minimum = template.MinTypes or encounter.MinTypes
    local maximum = template.MaxTypes or (type(encounter.MaxTypes) == "number" and math.floor(encounter.MaxTypes))
    if type(minimum) ~= "number" or type(maximum) ~= "number" then return nil end
    if encounter.MaxTypesCap then
        minimum, maximum = math.min(minimum, encounter.MaxTypesCap), math.min(maximum, encounter.MaxTypesCap)
    end
    return minimum, maximum
end

-- One roster decision at the pre-wave cap contact; nothing live is mutated. Each
-- draw is checked against the wave already holding the earlier draws, so native
-- IsEnemyEligible applies duplicates, earlier BlockEnemyTypes and the elite cap in order.
local function rosterAdmission(decision, encounter, nativeRoom, currentRun, gameValue)
    local enemies = gameValue.EnemyData or {}
    if not encounter.InfiniteSpawns then return "unsupported-finite-spawns" end
    local minimum, maximum = encounter.MinWaves or 1, encounter.MaxWaves or 1
    if minimum ~= 1 or maximum ~= 1 then
        return "wave-count-out-of-range", { expected = { min = 1, max = 1 }, observed = { min = minimum, max = maximum } }
    end
    if encounter.SpawnWaves ~= nil and next(encounter.SpawnWaves) ~= nil then return "preexisting-waves" end
    if encounter.BuildCustomEnemySet ~= nil then return "unsupported-custom-enemy-set" end
    if encounter.MaxTypesPerGroup ~= nil and next(encounter.MaxTypesPerGroup) ~= nil then
        return "unsupported-type-groups"
    end
    local template = templateFor(encounter, 1, 1)
    if type(template) ~= "table" or type(template.Spawns) ~= "table" then return "unsupported-template" end
    if next(template.Spawns) ~= nil then return "unowned-template-entry" end
    local typeMinimum, typeMaximum = rosterTypeBounds(encounter, template)
    if typeMinimum == nil then return "unsupported-type-bounds" end
    if #decision.types < typeMinimum or #decision.types > typeMaximum then
        return "type-count-out-of-range", { expected = { min = typeMinimum, max = typeMaximum }, observed = #decision.types }
    end
    local eligible = nativeValue(gameValue, "IsEnemyEligible")
    if type(eligible) ~= "function" then return "missing-enemy-eligibility" end
    local view = eligibilityView(encounter, currentRun)
    local wave = copy(template)
    wave.Spawns, wave.WaveIndex, wave.TypeCount = {}, 1, #decision.types
    wave.RequireCompletedIntro = wave.RequireCompletedIntro or requireCompletedIntro(view, nativeRoom, currentRun, gameValue)
    for position, entry in ipairs(decision.types) do
        local name = entry.nativeId
        if enemies[name] == nil then return "missing-enemy", { position = position, enemy = name } end
        local member = false
        for _, candidate in pairs(view.EnemySet or {}) do
            if candidate == name then member = true end
        end
        if not member then return "enemy-set-changed", { position = position, enemy = name } end
        local ok, verdict = pcall(eligible, name, view, wave)
        if not ok then
            return "native-enemy-check-error", { position = position, enemy = name, observed = tostring(verdict) }
        end
        if not verdict then return "native-enemy-ineligible", { position = position, enemy = name } end
        wave.Spawns[#wave.Spawns + 1] = { Name = name }
    end
    return introSubstitution({ { types = decision.types } }, encounter, gameValue)
end

-- Native FillEnemyTypes side effects of one ordinary draw.
local function applyDraw(scope, encounter, name)
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

function generated.create()
    local instance, stack = {}, {}
    local function current() return stack[#stack] end
    local function diagnostic(owner, observed)
        if owner and owner.session and owner.state and owner.occurrence then
            owner.session.diagnostic(owner.state, "encounter-composition", observed, owner.occurrence)
        end
    end
    local function kindFor(owner, suffix)
        return (isRoster(owner.decision) and "roster-" or "generated-") .. suffix
    end
    local function decline(owner, reason, evidence)
        owner.declined = reason
        local observed = copy(evidence)
        observed.kind, observed.reason = kindFor(owner, "admission"), reason
        diagnostic(owner, observed)
    end
    function instance.withPhase(state, room, phase, nativeRoom, action)
        local decision = compositionFor(phase) or rosterFor(phase)
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
            -- A substitution already predicted by the admission decline is native continuation.
            if (not ok or actual ~= parent.encounterKey) and not (ok and parent.declined == "intro-substitution") then
                if parent.prepared then
                    parent.prepared.__runPlannerGeneratedComposition = nil
                end
                diagnostic(parent, { kind = kindFor(parent, "not-realized"), reason = ok and "intro-substitution" or "setup-error",
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
            local decision = owner.decision
            -- A new owned preparation supersedes any restored realization. A
            -- failed attempt must fall back natively rather than leave a stale
            -- marker for Fangs or zero-Menace spawn interception.
            if encounter.__runPlannerGeneratedComposition ~= nil then
                encounter.__runPlannerGeneratedComposition = nil
            end
            local restoreRoll
            if decision.baseRoll ~= nil then
                local rejection
                restoreRoll, rejection = supplyBaseRoll(encounter, decision.baseRoll)
                if not restoreRoll then
                    decline(owner, rejection.reason, rejection)
                    return scoped(stack, { kind = "native" }, function() return base(currentRun, nativeRoom, encounter) end)
                end
            end
            local scope = { kind = "generate", owner = owner, encounter = encounter, run = currentRun,
                gameValue = gameValue, enemies = gameValue.EnemyData or {}, installed = {} }
            local ok, result = pcall(function()
                return scoped(stack, scope, function() return base(currentRun, nativeRoom, encounter) end)
            end)
            if restoreRoll then restoreRoll() end
            if scope.priorWaves then
                encounter.BlockHighlightEncounter = scope.priorHighlight
                encounter.MinWaves, encounter.MaxWaves = scope.priorWaves[1], scope.priorWaves[2]
            end
            if not ok then
                diagnostic(owner, { kind = kindFor(owner, "not-realized"), reason = "generation-error",
                    admitted = scope.admitted == true, observed = tostring(result) })
                error(result, 0)
            end
            if scope.admission == nil then
                diagnostic(owner, { kind = kindFor(owner, "not-realized"), reason = "missing-admission-contact" })
                return result
            end
            if not scope.admitted then return result end
            local missing = {}
            for index = 1, isRoster(decision) and 1 or decision.waveCount do
                if not scope.installed[index] then missing[#missing + 1] = index end
            end
            if #missing > 0 then
                -- Admitted roster mutation may already be partial; this is not native fallback.
                diagnostic(owner, { kind = kindFor(owner, "not-realized"), reason = "missing-fill-contact",
                    admitted = true, missingWaves = missing })
                return result
            end
            if isRoster(decision) then
                -- No finite marker: Fangs and Menace overrides never claim a roster.
                local names, finite = {}, {}
                for _, spawn in ipairs(encounter.SpawnWaves[1].Spawns) do
                    names[#names + 1] = spawn.Name
                    if not spawn.InfiniteSpawns then finite[#finite + 1] = spawn.Name end
                end
                if #finite > 0 then
                    diagnostic(owner, { kind = "roster-not-realized", reason = "finite-spawns", admitted = true,
                        types = names, finite = finite })
                    return result
                end
                diagnostic(owner, { kind = "roster-installed", phase = owner.phase.slotKey,
                    encounterKey = owner.encounterKey, types = names })
                return result
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
        -- GenerateEncounter calls the cap once after its final DifficultyRating and
        -- before the wave-count draw; mid-combat recalculations are outside this scope.
        module.hooks.wrap("CalculateActiveEnemyCap", "run-planner-generated-encounter-admission", function(_, _, base,
            currentRun, nativeRoom, encounter)
            local result = base(currentRun, nativeRoom, encounter)
            local scope = current()
            if scope == nil or scope.kind ~= "generate" or scope.encounter ~= encounter or scope.admission ~= nil then
                return result
            end
            local decision = scope.owner.decision
            local ok, reason, evidence = pcall(isRoster(decision) and rosterAdmission or admission, decision, encounter,
                nativeRoom or currentRun.CurrentRoom or {}, currentRun, scope.gameValue)
            if not ok then reason, evidence = "admission-check-error", { observed = tostring(reason) } end
            if reason then
                scope.admission = reason
                decline(scope.owner, reason, evidence)
                return result
            end
            scope.admission, scope.admitted = "accepted", true
            if isRoster(decision) then return result end
            scope.priorWaves = { encounter.MinWaves, encounter.MaxWaves }
            encounter.MinWaves, encounter.MaxWaves = decision.waveCount, decision.waveCount
            scope.priorHighlight, encounter.BlockHighlightEncounter = encounter.BlockHighlightEncounter, true
            return result
        end)
        module.hooks.wrap("FillEnemyTypes", "run-planner-generated-encounter-types", function(_, _, base,
            encounter, wave, nativeRoom)
            local scope = current()
            if scope == nil or scope.kind ~= "generate" or not scope.admitted or scope.encounter ~= encounter
                or encounter.SpawnWaves[wave.WaveIndex] ~= wave then return base(encounter, wave, nativeRoom) end
            local decision = scope.owner.decision
            local index = wave.WaveIndex
            if scope.installed[index] then return end
            if isRoster(decision) then
                -- Generated entries without counts; native FillEnemyCounts marks them infinite.
                local spawns = {}
                for _, entry in ipairs(decision.types) do
                    spawns[#spawns + 1] = { Name = entry.nativeId, Generated = true }
                    applyDraw(scope, encounter, entry.nativeId)
                end
                wave.Spawns, wave.TypeCount, scope.installed[index] = spawns, #spawns, true
                return
            end
            local published = decision.waves[index]
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
                    applyDraw(scope, encounter, name)
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
            if conversion ~= nil and progress < conversion.count then
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
