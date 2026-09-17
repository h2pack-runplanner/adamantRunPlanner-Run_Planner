-- Scylla's native spotlight application owns all effects and presentation.
-- This adapter supplies its resolved performer through a private argument copy.
local scylla = {}

local scyllaEncounters = { BossScylla01 = true, BossScylla02 = true }

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function selected(state, room)
    if state == nil or state.state ~= "synchronized" then return nil end
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local phase = room.encounterPhase(state, nativeRoom and nativeRoom.Encounter)
    if phase == nil or not scyllaEncounters[phase.encounterKey] then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.decisionKey == "featuredPerformer" and decision.kind == "single" then return decision end
    end
    return nil
end

local function nativeArgs(args, choice)
    if type(args) ~= "table" or type(args.Flags) ~= "table" then return nil end
    local flag = args.Flags[choice.nativeId]
    if type(flag) ~= "table" then return nil end
    local nativeFlag = copy(flag)
    if type(flag.ApplyEffect) == "table" then
        nativeFlag.ApplyEffect = copy(flag.ApplyEffect)
        if type(flag.ApplyEffect.DataProperties) == "table" then
            nativeFlag.ApplyEffect.DataProperties = copy(flag.ApplyEffect.DataProperties)
        end
    end
    local result = copy(args)
    -- Native first-normal and first-Rival branches use these names after its draw.
    result.Flags = {
        [choice.nativeId] = nativeFlag,
        Keytarist = nativeFlag,
        Charybdis = nativeFlag,
    }
    return result
end

function scylla.attach(module, _session, getState, _report, room)
    module.hooks.wrap("ApplyScyllaFightSpotlight", "run-planner-scylla-featured-performer", function(_, runtime,
        base, source, args)
        local choice = selected(getState(runtime), room)
        return base(source, choice and nativeArgs(args, choice) or args)
    end)
end

return scylla
