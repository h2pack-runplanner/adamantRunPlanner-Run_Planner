-- Published windows guide unbound action discovery. A phase's pickup
-- availability outlives its automatic-effect callback contact.
local lifecycle = {}

local checkpoints = {
    roomEntered = true,
    outgoingGeneration = true,
    exitUsable = true,
    roomExit = true,
}

local function capabilityFor(window)
    if type(window) ~= "table" then return nil end
    if window.kind == "standard" then
        return window.phase == "beforeCombat" and "roomEntered" or "afterCombat"
    end
    if window.kind == "postOutgoing" then return "postOutgoing" end
    if (window.kind == "shipPreCombat" or window.kind == "shipPostCombat")
        and type(window.wheelKey) == "string" then
        return window.kind .. ":" .. window.wheelKey
    end
    if (window.kind == "encounterEnd" or window.kind == "bossDefeated") and type(window.phaseKey) == "string" then
        return window.kind .. ":" .. window.phaseKey
    end
    return nil
end

function lifecycle.new()
    return { roomEntered = true }
end

function lifecycle.open(capabilities, window)
    if type(window) ~= "string" then
        return nil, { checkpoint = "lifecycle-window", expected = "published lifecycle window", observed = window }
    end
    if window == "roomEntered" or window == "afterCombat" or window == "postOutgoing" then
        if window == "afterCombat" then
            capabilities.roomEntered = nil
            capabilities.activePhaseContact = nil
        end
        capabilities[window] = true
        return true
    end
    if window:match("^shipPreCombat:.+") or window:match("^shipPostCombat:.+") then
        for key in pairs(capabilities) do
            if key:match("^shipPreCombat:") or key:match("^shipPostCombat:") then capabilities[key] = nil end
        end
        capabilities[window] = true
        return true
    end
    if window:match("^encounterEnd:.+") or window:match("^bossDefeated:.+") then
        -- New phases replace prior discovery windows. Closing the final
        -- callback ends its active contact without hiding the spawned pickups.
        for key in pairs(capabilities) do
            if key:match("^encounterEnd:") or key:match("^bossDefeated:") then capabilities[key] = nil end
        end
        capabilities[window] = true
        capabilities.activePhaseContact = window
        return true
    end
    return nil, { checkpoint = "lifecycle-window", expected = "published lifecycle window", observed = window }
end

function lifecycle.startEncounter(capabilities)
    capabilities.activePhaseContact = nil
    for key in pairs(capabilities) do
        if key:match("^encounterEnd:") or key:match("^bossDefeated:") then capabilities[key] = nil end
    end
    return true
end

function lifecycle.accepts(capabilities, window)
    local capability = capabilityFor(window)
    return capability ~= nil and capabilities[capability] == true, capability
end

function lifecycle.activePhase(capabilities, kind)
    local prefix = kind .. ":"
    local contact = capabilities and capabilities.activePhaseContact
    if contact ~= nil and contact:sub(1, #prefix) == prefix then return contact:sub(#prefix + 1) end
    return nil
end

function lifecycle.isCheckpoint(name) return checkpoints[name] == true end

return lifecycle
