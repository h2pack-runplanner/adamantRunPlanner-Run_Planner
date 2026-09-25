-- Fountain use and its Aromatic Phial extension.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local aromaticPhial = type(import) == "function" and import("mods/keepsakes/aromatic_phial.lua")
    or require("mods.keepsakes.aromatic_phial")
local ephyra = type(import) == "function" and import("mods/navigation/ephyra.lua")
    or require("mods.navigation.ephyra")
local fountain = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

local function currentRoomName()
    return roomName(_G.CurrentRun and _G.CurrentRun.CurrentRoom)
end

function fountain.attach(module, session, getState, report, room, route)
    local phial = aromaticPhial.attach(module, {
        session = session,
        getState = getState,
        report = report,
        phialTraitKey = nativeBindings.conformance.keepsakeTraits.phial,
    })

    -- The Hub fountain is a Hub-owned use; no room session is active there.
    local function hubBinding(state, source)
        if state == nil or state.state ~= "synchronized" or room.current(state) ~= nil then return nil end
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local hubRoom = roomName(nativeRoom)
        local objectId = ephyra.hubFountainObjectId(nativeRoom)
        if objectId == nil or type(source) ~= "table" or source.ObjectId ~= objectId then return nil end
        local routeState = state.route
        local used = ephyra.hubFountainUsed(nativeRoom)
        local hub = route.dueHubFountain(routeState, used)
        local claim = hub ~= nil and hub.room.gameName == hubRoom
            and route.claimHubFountain(routeState, used) or nil
        route.observeHubFountainUse(routeState)
        if claim == nil then return nil end
        return {
            transaction = hub.fountain,
            occurrence = claim.carrier,
            owns = function(current)
                return current.route == routeState and route.holdsHubFountain(routeState, claim)
                    and currentRoomName() == hubRoom
            end,
            complete = function() route.completeHubFountain(claim) end,
            release = function() route.releaseHubFountain(claim) end,
        }
    end

    local function roomBinding(state, source)
        local active = room.current(state)
        local handle = active and room.resolve(state, active,
            { kind = "interaction", interactionKey = "fountain" })
        handle = room.bind(state, active, handle, source)
        local payload = handle and room.begin(state, handle) or nil
        if payload == nil then return nil end
        return {
            transaction = payload.transaction,
            owns = function(current) return room.current(current) == active end,
            complete = function(current) session.complete(current, handle) end,
        }
    end

    module.hooks.wrap("UseHealthFountain", "run-planner-fountain", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local binding = hubBinding(state, source) or roomBinding(state, source)
        local transaction = binding and binding.transaction
        local phialScope = phial.begin(state, transaction and transaction.aromaticPhialTarget, binding)
        local ok, result = pcall(base, source, args)
        if not ok then
            phial.cancel(phialScope)
            if binding and binding.release then binding.release() end
            error(result, 0)
        end
        if binding ~= nil and phialScope == nil then binding.complete(state) end
        report(runtime)
        return result
    end)
end

return fountain
