-- Arachne combat setup keeps native RandomInt, placement, sizes, contents, and
-- reward-cocoon selection. This adapter only equalizes the count bounds it reads.
local arachne = {}

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function selected(state, room, encounter)
    if state == nil or state.state ~= "synchronized" then return nil end
    local phase = room.encounterPhase(state, encounter)
    if phase == nil then return nil end
    for _, decision in ipairs(phase.customization or {}) do
        if decision.kind == "cocoonCount" then return phase, decision end
    end
    return nil
end

local function diagnostic(session, state, phase, observed)
    if session and session.diagnostic then
        observed.encounterKey = phase.encounterKey
        session.diagnostic(state, "arachne-cocoon-count", observed)
    end
end

function arachne.attach(module, session, getState, _report, room)
    module.hooks.wrap("SetupArachneCombatEncounter", "run-planner-arachne-cocoon-count", function(_, runtime,
        base, eventSource, args)
        local state = getState(runtime)
        local phase, decision = selected(state, room, eventSource)
        if decision == nil then return base(eventSource, args) end
        local source = type(eventSource) == "table" and eventSource or {}
        local nativeArgs = type(args) == "table" and args or {}
        local minimum = nativeArgs.CocoonCountMin or source.CocoonCountMin
        local maximum = nativeArgs.CocoonCountMax or source.CocoonCountMax
        if type(minimum) ~= "number" or type(maximum) ~= "number"
            or decision.count < minimum or decision.count > maximum then
            diagnostic(session, state, phase, {
                reason = "outside-native-range", requested = decision.count, minimum = minimum, maximum = maximum,
            })
            return base(eventSource, args)
        end
        local scoped = copy(nativeArgs)
        scoped.CocoonCountMin = decision.count
        scoped.CocoonCountMax = decision.count
        local ok, result = pcall(base, eventSource, scoped)
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local placed = nativeRoom and type(nativeRoom.CoocoonIds) == "table" and #nativeRoom.CoocoonIds or 0
        if not ok then
            diagnostic(session, state, phase, {
                reason = "setup-error", requested = decision.count, placed = placed, error = tostring(result),
            })
            error(result, 0)
        end
        if placed < decision.count then
            diagnostic(session, state, phase, {
                reason = "placement-shortfall", requested = decision.count, placed = placed,
            })
        end
        return result
    end)
end

return arachne
