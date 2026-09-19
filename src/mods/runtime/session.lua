-- Thin coordinator for the current route and room execution protocol. Semantic
-- comparison stays in the native fact adapters; this module only propagates
-- their exact owner contacts and the first mismatch that disables enforcement.
local route = type(import) == "function" and import("mods/route/session.lua")
    or require("mods.route.session")
local room = type(import) == "function" and import("mods/room/coordinator.lua")
    or require("mods.room.coordinator")
local conformance = type(import) == "function" and import("mods/room/conformance/readers.lua")
    or require("mods.room.conformance.readers")
local admission = type(import) == "function" and import("mods/room/conformance/admission.lua")
    or require("mods.room.conformance.admission")

local runtime = {}
local maxDiagnostics = 16

function runtime.create()
    return {
        initialized = false,
        state = "inactive",
        reason = "not-started",
        diagnostics = {},
        admissionAttempted = false,
        postbossAdmission = nil,
    }
end

local function fail(state, errorValue, expected, observed)
    if state.firstMismatch == nil then
        state.firstMismatch = type(errorValue) == "table" and errorValue or {
            checkpoint = errorValue, expected = expected, observed = observed,
        }
    end
    state.state, state.reason = "desynchronized", "first-mismatch"
    local routeState = state.route
    if routeState and routeState.firstMismatch == nil then routeState.firstMismatch = state.firstMismatch end
    return nil, state.firstMismatch
end

function runtime.status(state)
    local record = state.firstMismatch or state.firstFault or state.admissionError
    return {
        state = state.state, reason = state.reason,
        checkpoint = record and record.checkpoint,
    }
end

function runtime.mismatch(state, checkpoint, expected, observed)
    if type(checkpoint) == "table" and checkpoint.outcome == "fault" then
        return runtime.fault(state, checkpoint, expected, observed)
    end
    if state.firstFault ~= nil then return nil, state.firstFault end
    if state.state ~= "desynchronized" and state.room ~= nil then room.dispose(state) end
    return fail(state, checkpoint, expected, observed)
end

-- Faults are executor/host contract failures, never evidence that an admitted
-- run diverged.  They make enforcement passive just like a mismatch so hooks
-- can still call native code, but retain a separate reporting product.
function runtime.fault(state, errorValue, expected, observed)
    if state.firstMismatch ~= nil then return nil, state.firstMismatch end
    if state.firstFault == nil then
        state.firstFault = type(errorValue) == "table" and errorValue or {
            outcome = "fault", checkpoint = errorValue, expected = expected, observed = observed,
        }
        state.firstFault.outcome = "fault"
        state.firstFault.traceback = debug.traceback("", 2)
    end
    if state.room ~= nil then room.dispose(state) end
    state.state, state.reason = "faulted", "executor-fault"
    return nil, state.firstFault
end

-- No selected execution document was admitted, so this is intentionally not
-- the terminal run-mismatch transition.
function runtime.rejectAdmission(state, checkpoint, expected, observed)
    if state.admissionError == nil then
        state.admissionError = type(checkpoint) == "table" and checkpoint or {
            checkpoint = checkpoint, expected = expected, observed = observed,
        }
    end
    state.initialized = false
    state.state, state.reason = "inactive", "admission-rejected"
    return nil, state.admissionError
end

function runtime.canAttemptPostbossAdmission(state)
    return type(state) == "table" and state.admissionAttempted ~= true
end

local function reset(state, admissionAttempted)
    if state.room ~= nil then room.dispose(state) end
    state.initialized = false
    state.state = "inactive"
    state.plan = nil
    state.planSlot = nil
    state.route = nil
    state.room = nil
    state.firstMismatch = nil
    state.firstFault = nil
    state.loggedFault = nil
    state.admissionError = nil
    state.loggedMismatch = nil
    state.loggedAdmission = nil
    state.postbossAdmission = nil
    state.loggedPostbossAdmission = nil
    state.diagnostics = {}
    state.reason = "not-started"
    state.admissionAttempted = admissionAttempted == true
    return state
end

function runtime.beginNewRun(state)
    return reset(state, true)
end

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

local function selectedPostboss(plan, gameName)
    local selected = plan and plan.selectedOccurrenceIds or {}
    local matches, matchIndex
    for index, id in ipairs(selected) do
        local occurrence = plan.occurrencesById and plan.occurrencesById[id]
        if occurrence and occurrence.resumeBoundary == "postbossEntry"
            and occurrence.gameName == gameName then
            matches = (matches or 0) + 1
            matchIndex = index
        end
    end
    if matches == 1 then
        return plan.occurrencesById[selected[matchIndex]], matchIndex
    end
    return nil, matches or 0
end

local function nativeRunModeMatches(plan)
    local dream = _G.CurrentRun ~= nil and _G.CurrentRun.IsDreamRun == true
    return (plan.routeKey == "Dream") == dream
end

-- One fresh-process admission. Hades II already restored the native Postboss
-- room, so success constructs only fresh route and room coordinators. The
-- ordinary StartRoom path adopts and enters the existing native room.
function runtime.attemptPostbossAdmission(state, inbox, activeSlot, nativeRoom)
    if not runtime.canAttemptPostbossAdmission(state) then return nil end
    reset(state, true)
    state.initialized = true

    local loaded, plan = inbox.load(activeSlot)
    if not loaded or type(plan) ~= "table" or plan.kind ~= "ready" then
        local inboxStatus = inbox.status and inbox.status() or nil
        local observed = inboxStatus and inboxStatus.error or plan
        return runtime.rejectAdmission(state, "postboss-admission:active-plan",
            "ready execution plan", observed)
    end
    if not nativeRunModeMatches(plan) then
        return runtime.rejectAdmission(state, "postboss-admission:run-mode", plan.routeKey, {
            isDreamRun = _G.CurrentRun and _G.CurrentRun.IsDreamRun == true,
        })
    end

    local current = nativeRoom or (_G.CurrentRun and _G.CurrentRun.CurrentRoom)
    local gameName = roomName(current)
    local occurrence, indexOrCount = selectedPostboss(plan, gameName)
    if occurrence == nil then
        return runtime.mismatch(state, "postboss-admission:room",
            "exactly one selected Postboss entry", {
                gameName = gameName, matches = indexOrCount,
            })
    end

    local verified, mismatch = admission.verify(occurrence, plan.startingLoadout)
    if not verified then
        return runtime.mismatch(state, type(mismatch) == "table" and mismatch
            or "postboss-admission:state", "matching Postboss entry state", mismatch)
    end

    local routeState, routeError = route.newAt(plan, indexOrCount)
    if routeState == nil then
        return runtime.fault(state, routeError)
    end
    state.plan = plan
    state.planSlot = activeSlot
    state.route = routeState
    state.room = room.new(plan, function(errorValue, expected, observed)
        return runtime.mismatch(state, errorValue, expected, observed)
    end, {
        onFault = function(errorValue, expected, observed)
            return runtime.fault(state, errorValue, expected, observed)
        end,
        readConformance = function(kind, currentRun, gameState, expected)
            return conformance.read(kind, currentRun, gameState, expected)
        end,
    })
    state.state, state.reason = "synchronized", "ready"
    state.postbossAdmission = {
        occurrenceId = occurrence.id,
        gameName = occurrence.gameName,
        index = indexOrCount,
        slot = activeSlot,
    }
    return { occurrence = occurrence, index = indexOrCount }
end

function runtime.start(state, inbox, phase, activeSlot)
    reset(state, true)
    state.initialized = true
    local loaded, plan = inbox.load(activeSlot)
    if not loaded or type(plan) ~= "table" or plan.kind ~= "ready" then
        local inboxStatus = inbox.status and inbox.status() or nil
        local observed = inboxStatus and inboxStatus.error or plan
        return runtime.rejectAdmission(state, "run-start", "ready execution plan", observed)
    end
    if not nativeRunModeMatches(plan) then
        return runtime.rejectAdmission(state, "run-mode", plan.routeKey, {
            isDreamRun = _G.CurrentRun and _G.CurrentRun.IsDreamRun == true,
        })
    end
    for _, occurrence in ipairs(plan.occurrences) do
        for _, fact in ipairs((occurrence.roomExitConformance or {}).facts or {}) do
            if not conformance.supports(fact.kind) then
                return runtime.rejectAdmission(state, "room-exit-conformance",
                    "reachable conformance reader", fact.kind)
            end
        end
    end
    state.plan = plan
    state.planSlot = activeSlot
    state.route = route.new(plan)
    state.room = room.new(plan, function(errorValue, expected, observed)
        return runtime.mismatch(state, errorValue, expected, observed)
    end, {
        onFault = function(errorValue, expected, observed)
            return runtime.fault(state, errorValue, expected, observed)
        end,
        readConformance = function(kind, currentRun, gameState, expected)
            return conformance.read(kind, currentRun, gameState, expected)
        end,
    })
    state.state, state.reason = phase == "starting" and "starting" or "synchronized", "ready"
    return true
end

function runtime.complete(state, handle)
    return room.complete(state, handle)
end

function runtime.automatic(state, effect, phaseKey)
    local current = room.current(state)
    if current == nil then return nil end
    local handle = room.resolve(state, current, { kind = "automatic", effect = effect, phaseKey = phaseKey })
    if handle == nil then return room.incidental(state) end
    local payload = room.begin(state, handle)
    if payload == nil then return nil end
    return runtime.complete(state, handle)
end

function runtime.diagnostic(state, checkpoint, observed, occurrence)
    if state == nil or state.state ~= "synchronized" then return true end
    local current = room.current(state)
    occurrence = occurrence or current and current.occurrence
    if occurrence == nil then return true end
    local expected = occurrence.diagnostics and occurrence.diagnostics[checkpoint]
    local diagnostics = state.diagnostics or {}
    state.diagnostics = diagnostics
    if #diagnostics >= maxDiagnostics then table.remove(diagnostics, 1) end
    diagnostics[#diagnostics + 1] = {
        occurrenceId = occurrence.id, checkpoint = checkpoint,
        expected = expected, observed = observed,
    }
    return true
end

function runtime.readConformance(kind, currentRun, gameState, expected)
    return conformance.read(kind, currentRun, gameState, expected)
end

return runtime
