-- The inner room envelope owns its Timeline session directly. Timeline
-- ordering stays local; Overview and conformance remain coordinated by room/.
local timeline = type(import) == "function" and import("mods/room/timeline/session.lua")
    or require("mods.room.timeline.session")

local room = {}

local function mismatch(session, checkpoint, expected, observed)
    if session.firstMismatch == nil then
        session.firstMismatch = { checkpoint = checkpoint, expected = expected, observed = observed }
    end
    return nil, session.firstMismatch
end

local function fault(session, checkpoint, expected, observed)
    if session.firstFault == nil then
        session.firstFault = {
            outcome = "fault", checkpoint = checkpoint, expected = expected, observed = observed,
        }
    end
    return nil, session.firstFault
end

local function failure(session, errorValue)
    if type(errorValue) == "table" and errorValue.outcome == "fault" then
        if session.firstFault == nil then session.firstFault = errorValue end
        return nil, session.firstFault
    end
    return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
end

function room.new(occurrence, bindings)
    local inner = timeline.new(occurrence, bindings)
    local outer = {
        occurrence = occurrence,
        _timeline = inner,
        firstMismatch = nil, firstFault = nil,
        closed = false,
    }
    return outer
end

local function innerFor(session) return session and session._timeline or nil end

local function delegate(session, method, ...)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local inner = innerFor(session)
    if inner == nil then return fault(session, "room-session", "active timeline", "missing") end
    local ok, errorValue = timeline[method](inner, ...)
    if not ok then return failure(session, errorValue) end
    return true
end

function room.openWindow(session, window) return delegate(session, "open", window) end
function room.startEncounter(session) return delegate(session, "startEncounter") end
function room.resolve(session, resolver, contact, source)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local inner = innerFor(session)
    if inner == nil then return fault(session, "room-session", "active timeline", "missing") end
    local handle, errorValue = timeline.resolve(inner, resolver, contact, source)
    if handle == nil and errorValue ~= nil then
        return failure(session, errorValue)
    end
    return handle
end
function room.bind(session, handle, native)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local inner = innerFor(session)
    if inner == nil then return fault(session, "room-session", "active timeline", "missing") end
    local bound, errorValue = timeline.bind(inner, handle, native)
    if bound == nil and errorValue ~= nil then
        return failure(session, errorValue)
    end
    return bound
end
function room.bound(session, native)
    local inner = innerFor(session)
    return inner and timeline.bound(inner, native) or nil
end
function room.releaseCompletedBinding(session, handle, native)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local inner = innerFor(session)
    if inner == nil then return fault(session, "room-session", "active timeline", "missing") end
    local ok, errorValue = timeline.releaseCompletedBinding(inner, handle, native)
    if ok == nil and errorValue ~= nil then
        return failure(session, errorValue)
    end
    return ok
end
function room.sourceRole(session, handle, gameName)
    local inner = innerFor(session)
    return inner and timeline.sourceRole(inner, handle, gameName) or nil
end
function room.begin(session, handle)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local payload, errorValue = timeline.begin(innerFor(session), handle)
    if errorValue == "completed" then return nil, "completed" end
    if payload == nil then return failure(session, errorValue) end
    return payload
end
function room.peek(session, handle)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local inner = innerFor(session)
    if inner == nil then return fault(session, "room-session", "active timeline", "missing") end
    local payload, errorValue = timeline.peek(inner, handle)
    if payload == nil and errorValue ~= nil then
        return failure(session, errorValue)
    end
    return payload
end
function room.claimReady(session, contact, native, compatible)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if session.firstFault ~= nil then return nil, session.firstFault end
    local handle, payload, errorValue = timeline.claimReady(
        innerFor(session), contact, native, compatible)
    if handle == nil and errorValue ~= nil then
        return failure(session, errorValue)
    end
    return handle, payload
end
function room.complete(session, handle)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    return delegate(session, "complete", handle)
end
function room.incidental(session) return delegate(session, "incidental") end
function room.checkpoint(session, checkpoint) return delegate(session, "checkpoint", checkpoint) end
function room.activePhase(session, kind) return timeline.activePhase(innerFor(session), kind) end

function room.dispose(session)
    if session == nil then return end
    session._timeline = nil
    session.closed = true
end

function room.close(session, proveConformance)
    if session.closed then return fault(session, "room-session", "open session", "closed") end
    local ok, errorValue = room.checkpoint(session, "roomExit")
    if not ok then return nil, errorValue end
    if proveConformance ~= nil then
        local conformed, conformanceError = proveConformance()
        if not conformed then
            return failure(session, conformanceError)
        end
    end
    local inner = innerFor(session)
    local closed, closeError = timeline.close(inner)
    if not closed then return failure(session, closeError) end
    session.closed = true
    session._timeline = nil
    return true
end

return room
