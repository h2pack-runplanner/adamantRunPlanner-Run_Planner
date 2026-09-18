-- Typhon's native staged AI applies Rival overrides before it invokes
-- BossStageTransition. Supply a private reached stage so native timing and
-- egg attacks remain intact while its random weapon pool is narrowed.
local typhon = {}

local stageChoices = {
    BossTyphonHead01 = {
        { decisionKey = "firstEggWave", options = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03" } },
        { decisionKey = "secondEggWave", options = { "TyphonHeadCastSummon02", "TyphonHeadCastSummon05" } },
    },
    BossTyphonHead02 = {
        { decisionKey = "secondEggWave", options = { "TyphonHeadCastSummonBoar", "TyphonHeadCastSummonDragon" } },
    },
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function contains(values, value)
    for _, candidate in ipairs(values or {}) do
        if candidate == value then return true end
    end
    return false
end

local function selected(phase, decisionKey)
    if phase == nil then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.decisionKey == decisionKey and decision.kind == "single" then return decision end
    end
    return nil
end

local function reachedDecision(encounterKey, aiStage)
    for _, stage in ipairs(stageChoices[encounterKey] or {}) do
        local matches = true
        for _, nativeId in ipairs(stage.options) do
            if not contains(aiStage.FireRandomWeapon, nativeId) then matches = false; break end
        end
        if matches then return stage.decisionKey end
    end
    return nil
end

function typhon.attach(module, session, getState, _report, room)
    module.hooks.wrap("BossStageTransition", "run-planner-typhon-egg-wave", function(_, runtime, base, enemy,
        currentRun, aiStage)
        if type(enemy) ~= "table" or enemy.Name ~= "TyphonHead" or type(aiStage) ~= "table" then
            return base(enemy, currentRun, aiStage)
        end
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(enemy, currentRun, aiStage) end
        local nativeRoom = currentRun and currentRun.CurrentRoom
        local phase = room.encounterPhase(state, nativeRoom and nativeRoom.Encounter)
        local encounterKey = phase and phase.encounterKey
        local decisionKey = encounterKey and reachedDecision(encounterKey, aiStage) or nil
        local choice = decisionKey and selected(phase, decisionKey) or nil
        if choice == nil then return base(enemy, currentRun, aiStage) end
        if not contains(aiStage.FireRandomWeapon, choice.nativeId) then
            if session and session.diagnostic then
                session.diagnostic(state, "typhon-egg-wave", {
                    reason = "unavailable", encounterKey = encounterKey, decisionKey = decisionKey,
                    requested = choice.nativeId, available = copy(aiStage.FireRandomWeapon),
                })
            end
            return base(enemy, currentRun, aiStage)
        end
        local privateStage = copy(aiStage)
        privateStage.FireRandomWeapon = { choice.nativeId }
        -- A reused native stage may retain its prior resolved weapon. Clear it
        -- only on the private stage so BossStageTransition draws from the
        -- authored one-item pool; Default keeps native state untouched.
        privateStage.FireWeapon = nil
        return base(enemy, currentRun, privateStage)
    end)
end

return typhon
