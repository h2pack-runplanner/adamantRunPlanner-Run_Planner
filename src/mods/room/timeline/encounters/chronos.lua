-- Chronos retains the native late-stage transition and summon execution. This
-- adapter narrows only the reached selector or its spawned enemy pool.
local chronos = {}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function selected(phase)
    if phase == nil then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.decisionKey == "lateSummon" and decision.kind == "single" then return decision end
    end
    return nil
end

local function contains(values, value)
    for _, candidate in ipairs(values or {}) do
        if candidate == value then return true end
    end
    return false
end

local function diagnostic(session, state, phase, choice, available)
    if session and session.diagnostic then
        session.diagnostic(state, "chronos-late-summon", {
            reason = "unavailable", encounterKey = phase.encounterKey, decisionKey = choice.decisionKey,
            requested = choice.nativeId, available = copy(available),
        })
    end
end

function chronos.attach(module, session, getState, _report, room)
    module.hooks.wrap("GetWeaponAIData", "run-planner-chronos-late-summon", function(_, runtime, base, enemy,
        weaponName)
        local result = base(enemy, weaponName)
        if type(enemy) ~= "table" or enemy.Name ~= "Chronos" or type(result) ~= "table" then return result end
        local resolvedWeapon = weaponName or enemy.WeaponName
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return result end
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local phase = room.encounterPhase(state, nativeRoom and nativeRoom.Encounter)
        local choice = selected(phase)
        if choice == nil then return result end

        if phase.encounterKey == "BossChronos01" and resolvedWeapon == "ChronosDefense3" then
            if not contains(result.PreAttackRandomDumbFireWeapon, choice.nativeId) then
                diagnostic(session, state, phase, choice, result.PreAttackRandomDumbFireWeapon)
                return result
            end
            local privateData = copy(result)
            privateData.PreAttackRandomDumbFireWeapon = { choice.nativeId }
            return privateData
        end
        if phase.encounterKey ~= "BossChronos02" or resolvedWeapon ~= "ChronosSuperEliteSpawn1" then return result end
        if not contains(result.SpawnerOptions, choice.nativeId) then
            diagnostic(session, state, phase, choice, result.SpawnerOptions)
            return result
        end
        local privateData = copy(result)
        privateData.SpawnerOptions = { choice.nativeId }
        return privateData
    end)
end

return chronos
