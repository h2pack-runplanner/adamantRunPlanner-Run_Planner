-- Sole outer cursor for the configured route. Room exit advances the cursor;
-- the next room entry proves the next published occurrence identity.
local routeSession = {}

local function fault(route, checkpoint, expected, observed)
    if route.firstFault == nil then
        route.firstFault = {
            outcome = "fault", checkpoint = checkpoint, expected = expected, observed = observed,
        }
    end
    return nil, route.firstFault
end

function routeSession.new(plan)
    return {
        plan = plan, index = 1, currentOccurrence = nil,
        firstMismatch = nil, diagnostics = {},
    }
end

-- Recovery starts at one exact selected occurrence.  The cursor remains
-- otherwise identical to an ordinary new-run cursor: only exit advances it,
-- and entry still proves the occurrence identity at that index.
function routeSession.newAt(plan, index)
    local selected = plan and plan.selectedOccurrenceIds
    if type(selected) ~= "table"
        or type(index) ~= "number" or index ~= math.floor(index)
        or index < 1 or index > #selected then
        return nil, {
            outcome = "fault", checkpoint = "route-index",
            expected = "valid selected occurrence index",
            observed = index,
        }
    end
    local route = routeSession.new(plan)
    route.index = index
    return route
end

function routeSession.expected(route)
    local id = route and route.plan.selectedOccurrenceIds[route.index]
    return id and route.plan.occurrencesById[id] or nil
end

function routeSession.current(route)
    return route and route.currentOccurrence or nil
end

-- Dream chooses its next native biome before the current Postboss leaves.
-- Keep that cursor-relative lookup alongside route state so both the native
-- selector and later starting-room realization use the same occurrence.
function routeSession.next(route)
    if route == nil then return nil end
    local index = route.index
    if route.currentOccurrence ~= nil then index = index + 1 end
    local id = route.plan.selectedOccurrenceIds[index]
    return id and route.plan.occurrencesById[id] or nil
end

local function parentForSide(route, occurrenceId)
    for _, parent in pairs(route and route.plan.occurrencesById or {}) do
        for _, slot in ipairs(parent.overview and parent.overview.localSlots or {}) do
            if slot.room and slot.room.id == occurrenceId then return parent end
        end
    end
    return nil
end

local function hubForRoom(route, occurrenceId)
    for _, occurrence in pairs(route and route.plan.occurrencesById or {}) do
        local hub = occurrence.overview and occurrence.overview.hub
        if hub and hub.room and hub.room.gameName then
            if occurrence.id == occurrenceId then return hub end
            for _, slot in ipairs(hub.slots or {}) do
                if slot.room and slot.room.id == occurrenceId then return hub end
            end
        end
    end
    return nil
end

-- The cursor waits in the Hub for its next visit or final handoff, identified
-- by the number of completed main-room visits (not side-room excursions).
local function hubDeparturePosition(route)
    if route == nil or route.currentOccurrence ~= nil then return nil end
    local expected = routeSession.expected(route)
    if expected == nil then return nil end
    for _, carrier in pairs(route.plan.occurrencesById or {}) do
        local hub = carrier.overview and carrier.overview.hub
        if hub and hub.fountain then
            local slotIds = {}
            for _, slot in ipairs(hub.slots or {}) do slotIds[slot.room.id] = true end
            if not slotIds[expected.id] and expected.id ~= hub.finalHandoff.id then return nil end
            local visits = 0
            for index = 1, route.index - 1 do
                if slotIds[route.plan.selectedOccurrenceIds[index]] then visits = visits + 1 end
            end
            return hub, carrier, visits
        end
    end
    return nil
end

function routeSession.hubDeparture(route)
    local hub, carrier, visits = hubDeparturePosition(route)
    if hub == nil then return nil end
    return hub.departures[visits + 1], carrier
end

local function hubFountainPosition(route)
    local hub, carrier, visits = hubDeparturePosition(route)
    if hub == nil or visits ~= hub.fountain.precedingVisitCount then return nil end
    return hub, carrier
end

-- Due at its position while unclaimed and the native fountain is still unused.
local function dueHubFountain(route, nativeUsed)
    if route == nil or route.hubFountainClaim ~= nil or nativeUsed then return nil end
    return hubFountainPosition(route)
end

routeSession.dueHubFountain = dueHubFountain

-- One claim per route cursor; a released claim returns the use to due.
function routeSession.claimHubFountain(route, nativeUsed)
    local hub, carrier = dueHubFountain(route, nativeUsed)
    if hub == nil then return nil end
    local claim = { route = route, index = route.index, hub = hub, carrier = carrier, completed = false }
    route.hubFountainClaim = claim
    return claim
end

-- Any Hub fountain use this route saw, including one outside its position.
function routeSession.observeHubFountainUse(route)
    if route ~= nil then route.hubFountainObserved = true end
end

function routeSession.releaseHubFountain(claim)
    if claim and claim.route.hubFountainClaim == claim and not claim.completed then
        claim.route.hubFountainClaim = nil
    end
end

function routeSession.completeHubFountain(claim)
    if claim and claim.route.hubFountainClaim == claim then claim.completed = true end
end

-- The claim stays owned only while its route waits at the same Hub position.
function routeSession.holdsHubFountain(route, claim)
    return claim ~= nil and route == claim.route and route.hubFountainClaim == claim
        and route.currentOccurrence == nil and route.index == claim.index
end

-- Leaving the Hub from the fountain's position: "fulfilled", "incomplete" (claimed,
-- unfinished), "missed" (skipped or used elsewhere), or "unobserved" (already spent).
function routeSession.hubFountainDeparture(route, nativeUsed)
    local hub, carrier = hubFountainPosition(route)
    if hub == nil then return nil end
    local claim = route.hubFountainClaim
    if claim ~= nil then return claim.completed and "fulfilled" or "incomplete", hub, carrier end
    if nativeUsed and not route.hubFountainObserved then return "unobserved", hub, carrier end
    return "missed", hub, carrier
end

local function guideNext(current, target)
    local result = { kind = "next", occurrence = target }
    for _, door in ipairs(current and current.doors and current.doors.targets or {}) do
        if target and door.room and door.room.id == target.id then
            result.reward, result.cageRewards = door.reward, door.cageRewards
            break
        end
    end
    return result
end

-- The guide consumes this bounded navigation projection rather than inferring
-- a new cursor from room names. Side rooms return to their native parent;
-- after a transparent parent restore N returns to its Hub before another visit.
function routeSession.guideNavigation(route, hubFountainUsed)
    if route == nil then return nil end
    local current = route.currentOccurrence
    if current ~= nil then
        local parent = parentForSide(route, current.id)
        if parent ~= nil then return { kind = "return", gameName = parent.gameName } end
        local nextOccurrence = routeSession.next(route)
        if nextOccurrence ~= nil and parentForSide(route, nextOccurrence.id) == current then
            return { kind = "next", occurrence = nextOccurrence }
        end
        local hub = hubForRoom(route, current.id)
        if hub ~= nil then return { kind = "return", gameName = hub.room.gameName } end
        return guideNext(current, nextOccurrence)
    end
    local native = route.transparentNativeRoom
    if native == nil then return nil end
    if native == "N_Hub" then
        local target = routeSession.next(route)
        local result = guideNext(nil, target)
        local hub = target and hubForRoom(route, target.id)
        for _, slot in ipairs(hub and hub.slots or {}) do
            if slot.room and slot.room.id == target.id then
                result.hubVisit, result.reward = true, slot.reward
                break
            end
        end
        local dueHub = dueHubFountain(route, hubFountainUsed)
        if dueHub ~= nil then result.hubFountain = dueHub.fountain end
        return result
    end
    local parent = route.lastExitedOccurrence and parentForSide(route, route.lastExitedOccurrence.id)
    if parent ~= nil and parent.gameName == native then
        local nextOccurrence = routeSession.next(route)
        if nextOccurrence ~= nil and parentForSide(route, nextOccurrence.id) == parent then
            return { kind = "next", occurrence = nextOccurrence }
        end
        local hub = hubForRoom(route, parent.id)
        return hub ~= nil and { kind = "return", gameName = hub.room.gameName } or { kind = "none" }
    end
    return { kind = "none" }
end

function routeSession.enter(route, occurrenceId, gameName)
    if route.firstFault then return nil, route.firstFault end
    if route.firstMismatch then return nil, route.firstMismatch end
    if route.currentOccurrence ~= nil then
        return fault(route, "route-entry", "current room must exit", occurrenceId)
    end
    local occurrence = routeSession.expected(route)
    if occurrence == nil then return true end -- configured prefix already completed
    if gameName ~= occurrence.gameName then
        route.firstMismatch = {
            checkpoint = "room-entry",
            expected = occurrence,
            observed = { id = occurrenceId, gameName = gameName },
        }
        return nil, route.firstMismatch
    end
    if occurrenceId ~= occurrence.id then
        return fault(route, "route-occurrence-stamp", occurrence.id, occurrenceId)
    end
    route.currentOccurrence = occurrence
    return occurrence
end

function routeSession.exit(route)
    if route.currentOccurrence == nil then
        return fault(route, "route-exit", "active room", nil)
    end
    route.index = route.index + 1
    route.lastExitedOccurrence = route.currentOccurrence
    route.currentOccurrence = nil
    return true
end

-- N Hub and completed-parent reloads are native restoration transitions, not
-- execution rooms. They must not consume the single fresh-occurrence cursor.
function routeSession.transparent(route, gameName)
    if route == nil or route.currentOccurrence ~= nil then return false end
    -- Dream_Intro is entered before the first published occurrence. Its native
    -- LeaveRoom follows ChooseStartingRoom, so it must neither close nor
    -- advance the still-unentered first cursor position.
    if route.plan.routeKey == "Dream" and route.index == 1 and gameName == "Dream_Intro" then return true end
    if route.lastExitedOccurrence == nil then return false end
    if gameName == "N_Hub" then
        for _, occurrence in pairs(route.plan.occurrencesById or {}) do
            local hub = occurrence.overview and occurrence.overview.hub
            if hub and hub.room and hub.room.gameName == gameName then return true end
        end
        return false
    end
    -- A generated side reloads its declared main parent. Derive that relation
    -- from the published local slots instead of equating parent and side names.
    for _, parent in pairs(route.plan.occurrencesById or {}) do
        for _, slot in ipairs(parent.overview and parent.overview.localSlots or {}) do
            if slot.room and slot.room.id == route.lastExitedOccurrence.id
                and parent.gameName == gameName then return true end
        end
    end
    return false
end

function routeSession.enterTransparent(route, gameName)
    if routeSession.transparent(route, gameName) then
        route.transparentNativeRoom = gameName
        return true
    end
    return false
end

function routeSession.leaveTransparent(route, gameName)
    if route and route.transparentNativeRoom ~= nil then
        route.transparentNativeRoom = nil
        return true
    end
    -- Persistent N restores do not consistently re-enter through StartRoom.
    -- Recognize the same planner-transparent room at LeaveRoom without
    -- advancing or otherwise validating a native transition.
    if routeSession.transparent(route, gameName) then return true end
    return false
end

return routeSession
