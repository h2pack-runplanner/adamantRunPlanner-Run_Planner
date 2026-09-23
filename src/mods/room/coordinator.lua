-- Inner-room coordinator. It owns exactly one active occurrence session and
-- aggregates room identity, encounter, feature, Timeline, and conformance
-- responsibilities. Incoming transition rewards remain navigation-owned.
local session = type(import) == "function" and import("mods/room/session.lua")
    or require("mods.room.session")
local timelineBindings = type(import) == "function" and import("mods/room/timeline/bindings.lua")
    or require("mods.room.timeline.bindings")
local overview = type(import) == "function" and import("mods/room/overview.lua")
    or require("mods.room.overview")
local features = type(import) == "function" and import("mods/room/features/structure.lua")
    or require("mods.room.features.structure")
local fieldFeatures = type(import) == "function" and import("mods/room/features/fields.lua")
    or require("mods.room.features.fields")
local conformance = type(import) == "function" and import("mods/room/conformance/proof.lua")
    or require("mods.room.conformance.proof")
local encounterPhaseFactory = type(import) == "function"
    and import("mods/room/timeline/encounters/phases.lua")
    or require("mods.room.timeline.encounters.phases")

local coordinator = {}
local function stateOf(state) return state and state.room end
local function encounterPhases(state)
    local roomState = stateOf(state)
    return roomState and roomState.encounterPhases or nil
end

local function fail(state, errorValue, expected, observed)
    local roomState = stateOf(state)
    if type(errorValue) == "table" and errorValue.outcome == "fault" then
        if roomState and type(roomState.onFault) == "function" then
            return roomState.onFault(errorValue, expected, observed)
        end
        return nil, errorValue
    end
    if roomState and type(roomState.onMismatch) == "function" then
        return roomState.onMismatch(errorValue, expected, observed)
    end
    return nil, errorValue
end

local function fault(state, checkpoint, expected, observed)
    return fail(state, {
        outcome = "fault", checkpoint = checkpoint, expected = expected, observed = observed,
    })
end

function coordinator.new(plan, onMismatch, capabilities)
    capabilities = capabilities or {}
    return {
        plan = plan, current = nil, prepared = nil,
        timelineIndex = capabilities.timelineIndex or timelineBindings.index,
        encounterPhases = encounterPhaseFactory.create(),
        readConformance = capabilities.readConformance,
        onMismatch = onMismatch,
        onFault = capabilities.onFault,
    }
end

function coordinator.current(state)
    if state == nil or state.state ~= "synchronized" then return nil end
    local roomState = stateOf(state)
    return roomState and roomState.current or nil
end

-- Narrow guide capability: callers receive the immutable occurrence and an
-- owner-completion query, never the Timeline session or its mutable maps.
function coordinator.guide(state)
    local active = coordinator.current(state)
    if active == nil then return nil end
    return {
        occurrence = active.occurrence,
        isCompleted = function(owner)
            return session.isCompleted(active, owner)
        end,
    }
end

function coordinator.prepare(state, occurrence)
    local roomState = stateOf(state)
    local active = coordinator.current(state)
    if active ~= nil and active.occurrence.id == occurrence.id then return active end
    if roomState.prepared ~= nil and roomState.prepared.occurrence.id == occurrence.id then
        return roomState.prepared
    end
    if type(roomState.timelineIndex) ~= "function" then
        return fault(state, "timeline-index", "timeline index capability", "missing")
    end
    local bindings, errorValue = roomState.timelineIndex(occurrence)
    if bindings == nil then
        return fault(state, errorValue and errorValue.checkpoint or "timeline-index",
            errorValue and errorValue.expected or "valid occurrence", errorValue and errorValue.observed)
    end
    if roomState.prepared ~= nil then session.dispose(roomState.prepared) end
    roomState.prepared = session.new(occurrence, bindings)
    return roomState.prepared
end

function coordinator.realize(state, occurrence, game, nativeRoom)
    local realized, errorValue = overview.realize(occurrence, game, nativeRoom)
    if realized == nil then return fail(state, errorValue) end
    coordinator.realizeFeatures(state, occurrence, realized)
    return realized
end

function coordinator.realizeFeatures(_, occurrence, nativeRoom)
    fieldFeatures.realize(nativeRoom, occurrence.overview and occurrence.overview.fields or nil)
    return nativeRoom
end

function coordinator.enter(state, occurrence, nativeRoom)
    if state.state ~= "synchronized" then return nil end
    local roomState = stateOf(state)
    if roomState.current ~= nil then
        return fault(state, "room-entry", "current room must exit", occurrence.id)
    end
    local prepared = roomState.prepared
    local active
    if prepared ~= nil and prepared.occurrence.id == occurrence.id then
        active = prepared
    else
        if prepared ~= nil then session.dispose(prepared) end
        if type(roomState.timelineIndex) ~= "function" then
            return fault(state, "timeline-index", "timeline index capability", "missing")
        end
        local bindings, errorValue = roomState.timelineIndex(occurrence)
        if bindings == nil then
            return fault(state, errorValue and errorValue.checkpoint or "timeline-index",
                errorValue and errorValue.expected or "valid occurrence", errorValue and errorValue.observed)
        end
        active = session.new(occurrence, bindings)
    end
    roomState.prepared = nil
    roomState.current = active
    if nativeRoom ~= nil then return coordinator.proveEntry(state, nativeRoom) end
    return active
end

function coordinator.proveEntry(state, nativeRoom, nativeContext)
    local active = coordinator.current(state)
    if active == nil then return nil end
    for _, proof in ipairs({
        function() return overview.prove(active.occurrence, nativeRoom) end,
        function() return coordinator.bindEntryEncounters(state, nativeRoom) end,
        function() return features.prove(active.occurrence, nativeRoom, nativeContext) end,
    }) do
        local ok, errorValue = proof()
        if not ok then return fail(state, errorValue) end
    end
    local ok, errorValue = session.checkpoint(active, "roomEntered")
    if not ok then return fail(state, errorValue) end
    return active
end

-- StartRoom owns the native encounter lifecycle and does not return until a
-- synchronous combat has ended. Bind its canonical encounter carriers before
-- entering that call; the complete room-content proof remains after setup.
function coordinator.bindEntryEncounters(state, nativeRoom)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = encounterPhases(state).prove(active.occurrence, nativeRoom)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.chooseEncounter(state, slotKey)
    local active = coordinator.current(state)
    return active and encounterPhases(state).choose(active.occurrence, slotKey) or nil
end

-- Native room generation can precede StartRoom for a selected destination or
-- an additional-exit room. Its stamp resolves immutable occurrence facts;
-- Timeline operations below still require an active or prepared room session.
local function occurrenceForNative(state, nativeRoom)
    local roomState = stateOf(state)
    if roomState == nil then return nil end
    local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
    local active = coordinator.current(state)
    if id == nil then return active and active.occurrence or nil end
    if active ~= nil and active.occurrence.id == id then return active.occurrence end
    local prepared = roomState.prepared
    if prepared ~= nil and prepared.occurrence.id == id then return prepared.occurrence end
    return state.plan and state.plan.occurrencesById[id] or nil
end

function coordinator.occurrence(state, nativeRoom)
    return occurrenceForNative(state, nativeRoom)
end

function coordinator.encounterAt(state, index, nativeRoom)
    local occurrence = occurrenceForNative(state, nativeRoom)
    return occurrence and encounterPhases(state).at(occurrence, index) or nil
end

function coordinator.bindEncounter(state, nativeEncounter, slotKey, nativeRoom)
    local occurrence = occurrenceForNative(state, nativeRoom)
    if occurrence == nil then return nil end
    local phase, errorValue = encounterPhases(state).bind(occurrence, nativeEncounter, slotKey)
    if phase == nil then
        return fault(state, errorValue and errorValue.checkpoint or "encounter-binding",
            errorValue and errorValue.expected, errorValue and errorValue.observed)
    end
    return phase
end

function coordinator.encounterPhase(state, nativeEncounter)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local binding = encounterPhases(state).forNative(nativeEncounter)
    if binding == nil or binding.occurrenceId ~= active.occurrence.id then return nil end
    return binding.phase
end

function coordinator.startEncounter(state, nativeEncounter)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local binding = encounterPhases(state).forNative(nativeEncounter)
    if binding == nil or binding.occurrenceId ~= active.occurrence.id then return nil end
    local ok, errorValue = session.startEncounter(active)
    if not ok then return fail(state, errorValue) end
    return binding.phase
end

function coordinator.encounterIsFinal(state, nativeEncounter)
    local active = coordinator.current(state)
    if active == nil then return false end
    local binding = encounterPhases(state).forNative(nativeEncounter)
    if binding == nil or binding.occurrenceId ~= active.occurrence.id then return false end
    return encounterPhases(state).isFinal(active.occurrence, binding.phase)
end

function coordinator.encounterHandle(state, source)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local nativeEncounter = nativeRoom and nativeRoom.Encounter
    local phase = coordinator.encounterPhase(state, nativeEncounter)
    if phase == nil then return nil end
    local handle = coordinator.resolve(state, active, {
        kind = "encounterInteraction", phaseKey = phase.slotKey,
    })
    return coordinator.bind(state, active, handle, source)
end

function coordinator.additional(state, kind)
    local active = coordinator.current(state)
    if active == nil then return nil end
    for _, additional in ipairs(active.occurrence.overview.additional or {}) do
        if additional.kind == kind then
            local occurrence = state.plan and state.plan.occurrencesById[additional.room.id]
            return additional, occurrence
        end
    end
    return nil
end

function coordinator.feature(state, key)
    local active = coordinator.current(state)
    return active and active.occurrence.overview[key] or nil
end

function coordinator.window(state, window)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.openWindow(active, window)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.activePhase(state, kind)
    local active = coordinator.current(state)
    return active and session.activePhase(active, kind) or nil
end

local function bindingContext(state, context)
    local roomState = stateOf(state)
    if roomState == nil then return nil end
    local active = coordinator.current(state)
    if context == nil then return active end
    if context == active or context == roomState.prepared then return context end
    return nil
end

local function occurrenceIdentity(occurrence)
    return occurrence and { id = occurrence.id, gameName = occurrence.gameName } or "none"
end

local function bindingFailure(state, errorValue, details)
    if type(errorValue) == "table" and errorValue.outcome == "fault" and errorValue.context == nil then
        local roomState = stateOf(state)
        local active = roomState and roomState.current
        local prepared = roomState and roomState.prepared
        local context = details.context or active
        local native = type(details.native) == "table" and details.native or nil
        local contact = {}
        for key, value in pairs(details.contact or {}) do
            if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
                contact[key] = value
            end
        end
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local route = state and state.route
        local plan = state and state.plan
        local expectedId = route and plan and plan.selectedOccurrenceIds and plan.selectedOccurrenceIds[route.index]
        -- Snapshot identities before the runtime fault disposes room sessions.
        -- A failed claim can precede transaction selection: do not attribute it
        -- to the first published owner or to the next room's reward.
        errorValue.context = {
            operation = details.operation,
            state = state and state.state,
            contact = contact,
            transaction = session.describeHandle(context, details.handle)
                or (details.handle == nil and "unclaimed" or "unknown handle"),
            sourceTransaction = session.describeHandle(context, details.contact and details.contact.source),
            native = native and {
                name = native.Name or native.ItemName or native.LootName,
                objectId = native.ObjectId,
                useFunction = native.UseFunctionName,
            } or "none",
            nativeRoom = nativeRoom and {
                gameName = nativeRoom.Name,
                occurrenceId = nativeRoom.__runPlannerExecutionRoomId,
                leaving = nativeRoom.Leaving,
            } or "none",
            requestedRoom = occurrenceIdentity(details.context and details.context.occurrence),
            activeRoom = occurrenceIdentity(active and active.occurrence),
            preparedRoom = occurrenceIdentity(prepared and prepared.occurrence),
            lastExitedRoom = occurrenceIdentity(route and route.lastExitedOccurrence),
            routeIndex = route and route.index,
            routeExpectedRoom = occurrenceIdentity(expectedId and plan.occurrencesById[expectedId]),
        }
    end
    return fail(state, errorValue)
end

local function unboundFailure(state, checkpoint, expected, observed, details)
    return bindingFailure(state, {
        outcome = "fault", checkpoint = checkpoint, expected = expected, observed = observed,
    }, details)
end

function coordinator.resolve(state, context, contact)
    local owner = bindingContext(state, context)
    -- A native producer can finish after its discovery context has expired.
    -- Without that context it cannot establish ownership in this or a later room.
    if owner == nil then return nil end
    local source = contact and contact.source
    local handle, errorValue = session.resolve(owner, timelineBindings.resolve, contact, source)
    if handle == nil and errorValue ~= nil then
        return bindingFailure(state, errorValue, { operation = "resolve", context = owner, contact = contact })
    end
    return handle
end

function coordinator.bind(state, context, handle, nativeObject)
    if handle == nil then return nil end
    local owner = bindingContext(state, context)
    if owner == nil then
        return unboundFailure(state, "timeline-binding", "active or prepared occurrence", "unbound",
            { operation = "bind", context = context, handle = handle, native = nativeObject })
    end
    local bound, errorValue = session.bind(owner, handle, nativeObject)
    if bound == nil then
        return bindingFailure(state, errorValue,
            { operation = "bind", context = owner, handle = handle, native = nativeObject })
    end
    return bound
end

function coordinator.bound(state, context, nativeObject)
    local owner = bindingContext(state, context)
    return owner and session.bound(owner, nativeObject) or nil
end

function coordinator.releaseCompletedBinding(state, context, handle, nativeObject)
    local owner = bindingContext(state, context)
    if owner == nil then return nil end
    local ok, errorValue = session.releaseCompletedBinding(owner, handle, nativeObject)
    if ok == nil and errorValue ~= nil then
        return bindingFailure(state, errorValue,
            { operation = "releaseCompletedBinding", context = owner, handle = handle, native = nativeObject })
    end
    return ok
end

function coordinator.sourceRole(state, context, handle, gameName)
    local owner = bindingContext(state, context)
    return owner and session.sourceRole(owner, handle, gameName) or nil
end

function coordinator.claimReady(state, context, contact, native, compatible)
    local owner = bindingContext(state, context)
    -- Discovery does not assert planner ownership. Native callbacks can run
    -- outside a room or outlive the room in which their use began.
    if owner == nil then return nil end
    local handle, payload, errorValue = session.claimReady(owner, contact, native, compatible)
    if handle == nil and errorValue ~= nil then
        return bindingFailure(state, errorValue,
            { operation = "claimReady", context = owner, contact = contact, native = native })
    end
    return handle, payload
end

function coordinator.begin(state, handle)
    local active = coordinator.current(state)
    if active == nil then
        return unboundFailure(state, "timeline-handle", "active occurrence", "none",
            { operation = "begin", handle = handle })
    end
    local payload, errorValue = session.begin(active, handle)
    if errorValue == "completed" then return nil, "completed" end
    if payload == nil then
        return bindingFailure(state, errorValue, { operation = "begin", context = active, handle = handle })
    end
    return payload
end

function coordinator.peek(state, handle)
    local active = coordinator.current(state)
    if active == nil then
        return unboundFailure(state, "timeline-handle", "active occurrence", "none",
            { operation = "peek", handle = handle })
    end
    local payload, errorValue = session.peek(active, handle)
    if payload == nil and errorValue ~= nil then
        return bindingFailure(state, errorValue, { operation = "peek", context = active, handle = handle })
    end
    return payload
end

function coordinator.complete(state, handle)
    if handle == nil then return coordinator.incidental(state) end
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.complete(active, handle)
    if not ok then
        return bindingFailure(state, errorValue, { operation = "complete", context = active, handle = handle })
    end
    return true
end

function coordinator.checkpoint(state, checkpoint)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.checkpoint(active, checkpoint)
    if not ok then return fail(state, errorValue) end
    return true
end


function coordinator.incidental(state)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.incidental(active)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.close(state, currentRun, gameState)
    local roomState = stateOf(state)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local reader = roomState.readConformance
    local ok, errorValue = session.close(active, function()
        return conformance.prove(active.occurrence, function(kind, expected)
            return type(reader) == "function" and reader(kind, currentRun, gameState, expected) or nil
        end)
    end)
    if not ok then return fail(state, errorValue) end
    roomState.current = nil
    return true
end

function coordinator.dispose(state)
    local roomState = stateOf(state)
    if roomState == nil then return end
    session.dispose(roomState.current)
    session.dispose(roomState.prepared)
    roomState.current = nil
    roomState.prepared = nil
end

return coordinator
