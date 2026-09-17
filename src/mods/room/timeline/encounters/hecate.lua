-- Hecate's first transition chooses an interlude weapon, then native AI later
-- validates it again. Keep both interventions tied to the bound boss phase.
local hecate = {}

local hecateEncounters = { BossHecate01 = true, BossHecate02 = true }

local function selected(state, room, currentRun)
    if state == nil or state.state ~= "synchronized" then return nil end
    local nativeRoom = currentRun and currentRun.CurrentRoom
    local phase = room.encounterPhase(state, nativeRoom and nativeRoom.Encounter)
    if phase == nil or not hecateEncounters[phase.encounterKey] then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.decisionKey == "interlude" and decision.kind == "single" then return decision end
    end
    return nil
end

local function copyWeaponData(weaponData)
    local result = {}
    for key, value in pairs(weaponData) do result[key] = value end
    result.GameStateRequirements = nil
    return result
end

function hecate.attach(module, _session, getState, _report, room)
    module.hooks.wrap("HecateStageTransition1", "run-planner-hecate-interlude", function(_, runtime, base,
        enemy, currentRun, aiStage)
        local choice = selected(getState(runtime), room, currentRun)
        local result = base(enemy, currentRun, aiStage)
        if choice ~= nil then
            -- Native transition has synchronously chosen and inserted a weapon;
            -- Transition2 will reuse this remembered value without a new draw.
            enemy.MidPhaseWeapon = choice.nativeId
            enemy.WeaponOptions[#enemy.WeaponOptions] = choice.nativeId
        end
        return result
    end)

    module.hooks.wrap("IsEnemyWeaponEligible", "run-planner-hecate-interlude-eligibility", function(_, runtime,
        base, enemy, weaponData, requirements)
        local choice = selected(getState(runtime), room, _G.CurrentRun)
        local canonical = _G.WeaponData and choice and _G.WeaponData[choice.nativeId] or nil
        if choice == nil or enemy == nil or enemy.MidPhaseWeapon ~= choice.nativeId
            or weaponData ~= canonical then
            return base(enemy, weaponData, requirements)
        end
        return base(enemy, copyWeaponData(weaponData), requirements)
    end)
end

return hecate
