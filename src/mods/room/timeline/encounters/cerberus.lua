-- Cerberus uses native stage spawning and chained-weapon application. Supply
-- only the published burrow/howl operands at their existing local seams.
local cerberus = {}

local cerberusEncounters = { BossInfestedCerberus01 = true, BossInfestedCerberus02 = true }
local howlSelector = "InfestedCerberusHowlSummonSelector"

local function selected(state, room, decisionKey)
    if state == nil or state.state ~= "synchronized" then return nil end
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local phase = room.encounterPhase(state, nativeRoom and nativeRoom.Encounter)
    if phase == nil or not cerberusEncounters[phase.encounterKey] then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.decisionKey == decisionKey and decision.kind == "single" then return decision end
    end
    return nil
end

local function isCerberus(enemy)
    return type(enemy) == "table" and enemy.Name == "InfestedCerberus"
end

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

-- StagedAI overwrites the phase's normal values with its EM table before it
-- reads RandomSpawnEncounter. Keep both local sources aligned to the choice.
local function stagesForBurrow(stages, nativeId)
    if type(stages) ~= "table" then return nil end
    for index, stage in ipairs(stages) do
        if type(stage) == "table" and stage.TransitionFunction == "CerberusStageExit"
            and type(stage.RandomSpawnEncounter) == "table" then
            local result = copy(stages)
            local privateStage = copy(stage)
            privateStage.RandomSpawnEncounter = { nativeId }
            if type(stage.EMStageDataOverrides) == "table" then
                privateStage.EMStageDataOverrides = copy(stage.EMStageDataOverrides)
                privateStage.EMStageDataOverrides.RandomSpawnEncounter = { nativeId }
            end
            result[index] = privateStage
            return result
        end
    end
    return nil
end

function cerberus.attach(module, _session, getState, _report, room)
    module.hooks.wrap("StagedAI", "run-planner-cerberus-burrow", function(_, runtime, base, enemy)
        local choice = isCerberus(enemy) and selected(getState(runtime), room, "burrow") or nil
        local privateStages = choice and stagesForBurrow(enemy.AIStages, choice.nativeId) or nil
        if privateStages == nil then return base(enemy) end
        enemy.AIStages = privateStages
        return base(enemy)
    end)

    module.hooks.wrap("GetWeaponAIData", "run-planner-cerberus-howl", function(_, runtime, base, enemy,
        weaponName)
        local result = base(enemy, weaponName)
        local choice = isCerberus(enemy) and selected(getState(runtime), room, "howl") or nil
        local resolvedWeapon = weaponName or (type(enemy) == "table" and enemy.WeaponName)
        if choice == nil or resolvedWeapon ~= howlSelector or type(result) ~= "table"
            or type(result.ChainedWeaponOptions) ~= "table" then
            return result
        end
        local nativeData = copy(result)
        nativeData.ChainedWeaponOptions = { choice.nativeId }
        return nativeData
    end)
end

return cerberus
