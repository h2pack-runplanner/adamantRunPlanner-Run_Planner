-- Native lifecycle contacts identify exact encounter-owned automatic effects.
-- Pickup discovery is governed by native availability and the local DAG.
local lifecycle = {}

local checkpoints = {
    roomEntered = true,
    outgoingGeneration = true,
    exitUsable = true,
    roomExit = true,
}

function lifecycle.new()
    return {}
end

function lifecycle.open(capabilities, window)
    if type(window) ~= "string" then
        return nil, { checkpoint = "lifecycle-window", expected = "published lifecycle window", observed = window }
    end
    if window == "roomEntered" or window == "afterCombat" or window == "postOutgoing" then
        if window == "afterCombat" then
            capabilities.activePhaseContact = nil
        end
        return true
    end
    if window:match("^shipPreCombat:.+") or window:match("^shipPostCombat:.+") then
        return true
    end
    if window:match("^encounterEnd:.+") or window:match("^bossDefeated:.+") then
        capabilities.activePhaseContact = window
        return true
    end
    return nil, { checkpoint = "lifecycle-window", expected = "published lifecycle window", observed = window }
end

function lifecycle.startEncounter(capabilities)
    capabilities.activePhaseContact = nil
    return true
end

function lifecycle.activePhase(capabilities, kind)
    local prefix = kind .. ":"
    local contact = capabilities and capabilities.activePhaseContact
    if contact ~= nil and contact:sub(1, #prefix) == prefix then return contact:sub(#prefix + 1) end
    return nil
end

function lifecycle.isCheckpoint(name) return checkpoints[name] == true end

return lifecycle
