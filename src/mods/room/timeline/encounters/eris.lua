-- Eris selectors retain native readiness, use limits, chained execution, and
-- spawn behavior. This adapter only narrows a reached selector's local result.
local eris = {}

local selectors = {
    ErisSummonSelector = {
        encounterKey = "BossEris01", decisionKey = "earlySummons",
    },
    ErisSummonSelector2 = {
        encounterKey = "BossEris01", decisionKey = "lateSummons",
    },
    ErisEMSummonSelector = {
        encounterKey = "BossEris02", decisionKey = "earlySummons",
    },
    ErisEMSummonSelector2 = {
        encounterKey = "BossEris02", decisionKey = "lateSummons",
    },
}

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function prefix(state, room, selector)
    if state == nil or state.state ~= "synchronized" then return nil end
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local phase = room.encounterPhase(state, nativeRoom and nativeRoom.Encounter)
    if phase == nil or phase.encounterKey ~= selector.encounterKey then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.decisionKey == selector.decisionKey and decision.kind == "orderedPrefix" then
            return decision.choices
        end
    end
    return nil
end

local function priorVariantUses(enemy, options)
    local variants = {}
    for _, weaponName in ipairs(options) do variants[weaponName] = true end
    local count = 0
    for _, weaponName in ipairs(enemy.WeaponHistory or {}) do
        if variants[weaponName] then count = count + 1 end
    end
    return count
end

function eris.attach(module, _session, getState, _report, room)
    module.hooks.wrap("GetWeaponAIData", "run-planner-eris-summons", function(_, runtime, base, enemy,
        weaponName)
        local result = base(enemy, weaponName)
        local resolvedWeapon = weaponName or (type(enemy) == "table" and enemy.WeaponName)
        local selector = resolvedWeapon and selectors[resolvedWeapon] or nil
        if type(enemy) ~= "table" or enemy.Name ~= "Eris" or selector == nil
            or type(result) ~= "table" or type(result.ChainedWeaponOptions) ~= "table" then
            return result
        end
        local choices = prefix(getState(runtime), room, selector)
        local options = result.ChainedWeaponOptions
        local choice = choices and choices[priorVariantUses(enemy, options) + 1] or nil
        local allowed = false
        for _, optionName in ipairs(options) do
            if optionName == (choice and choice.nativeId) then allowed = true end
        end
        if not allowed then return result end
        local nativeData = copy(result)
        nativeData.ChainedWeaponOptions = { choice.nativeId }
        return nativeData
    end)
end

return eris
