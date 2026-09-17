-- luacheck: globals TestScylla
local lu = require("luaunit")
local scylla = require("mods.room.timeline.encounters.scylla")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestScylla = {}

local function capture()
    local callbacks = {}
    return { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }, callbacks
end

local function attach(phase, encounter, state)
    local module, callbacks = capture()
    scylla.attach(module, {}, function() return state end, function() end, {
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
    })
    return callbacks
end

local function decision(nativeId)
    return { decisionKey = "featuredPerformer", kind = "single", choiceKey = "chosen", nativeId = nativeId }
end

local function restoreGlobals(values)
    local prior = {}
    for key, value in pairs(values) do
        prior[key] = _G[key]
        _G[key] = value
    end
    return function()
        for key in pairs(values) do _G[key] = prior[key] end
    end
end

local function scyllaFlags()
    local flags = {}
    for _, nativeId in ipairs({ "Scylla", "Drummer", "Keytarist", "Charybdis" }) do
        flags[nativeId] = {
            Name = nativeId, ApplyEffect = { EffectName = nativeId .. "Boost", DataProperties = {} },
        }
    end
    return flags
end

local function nativeScyllaApplication(source, args)
    if _G.CurrentRun.CurrentRoom.Name ~= "G_Boss02" then args.Flags.Charybdis = nil end
    local _, flagData = next(args.Flags)
    if _G.GameState.EncountersOccurredCache.BossScylla01 == 1 then flagData = args.Flags.Keytarist end
    if _G.CurrentRun.CurrentRoom.Name == "G_Boss02" and _G.GameState.EncountersOccurredCache.BossScylla02 == 1 then
        flagData = args.Flags.Charybdis
    end
    flagData.Id = 99
    flagData.ApplyEffect.Id = source.ObjectId
    flagData.ApplyEffect.DestinationId = flagData.Id
    return flagData
end

function TestScylla.testEveryPublishedPerformerSurvivesNativeFirstFightOverridesOnce()
    local domains = {
        { encounterKey = "BossScylla01", roomName = "G_Boss01", choices = { "Scylla", "Drummer", "Keytarist" } },
        { encounterKey = "BossScylla02", roomName = "G_Boss02", choices = { "Scylla", "Drummer", "Keytarist", "Charybdis" } },
    }
    for _, domain in ipairs(domains) do
        for _, nativeId in ipairs(domain.choices) do
            for _, firstFight in ipairs({ false, true }) do
                local encounter = {}
                local callbacks = attach({ encounterKey = domain.encounterKey,
                    customization = { decision(nativeId) } }, encounter, { state = "synchronized" })
                local flags = scyllaFlags()
                local args = { Flags = flags }
                local restore = restoreGlobals({
                    CurrentRun = { CurrentRoom = { Name = domain.roomName, Encounter = encounter } },
                    GameState = { EncountersOccurredCache = {
                        BossScylla01 = domain.roomName == "G_Boss01" and firstFight and 1 or 0,
                        BossScylla02 = domain.roomName == "G_Boss02" and firstFight and 1 or 0,
                    } },
                })
                local applications = 0
                local result = callbacks.ApplyScyllaFightSpotlight(nil, {}, function(source, nativeArgs)
                    applications = applications + 1
                    return nativeScyllaApplication(source, nativeArgs)
                end, { ObjectId = 7 }, args)
                restore()

                lu.assertEquals(applications, 1)
                lu.assertEquals(result.Name, nativeId)
                lu.assertNil(flags[nativeId].Id)
                lu.assertNil(flags[nativeId].ApplyEffect.Id)
                lu.assertNil(flags[nativeId].ApplyEffect.DestinationId)
            end
        end
    end
end

function TestScylla.testDefaultNoPlanDesyncUnboundAndWrongEncounterPassThrough()
    local cases = {
        { state = nil, phase = { encounterKey = "BossScylla01", customization = { decision("Scylla") } } },
        { state = { state = "desynchronized" }, phase = { encounterKey = "BossScylla01",
            customization = { decision("Scylla") } } },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossScylla01" } },
        { state = { state = "synchronized" }, phase = { encounterKey = "Other",
            customization = { decision("Scylla") } } },
        { state = { state = "synchronized" }, phase = { encounterKey = "BossScylla01",
            customization = { decision("Scylla") } }, unbound = true },
    }
    for _, case in ipairs(cases) do
        local encounter, args = {}, { Flags = scyllaFlags() }
        local callbacks = attach(case.phase, encounter, case.state)
        local restore = restoreGlobals({
            CurrentRun = { CurrentRoom = { Name = "G_Boss01", Encounter = case.unbound and {} or encounter } },
        })
        local observed = callbacks.ApplyScyllaFightSpotlight(nil, {}, function(_, nativeArgs) return nativeArgs end,
            {}, args)
        restore()
        lu.assertEquals(observed, args)
    end
end

function TestScylla.testNativeErrorPropagates()
    local encounter = {}
    local callbacks = attach({ encounterKey = "BossScylla01", customization = { decision("Scylla") } },
        encounter, { state = "synchronized" })
    local restore = restoreGlobals({ CurrentRun = { CurrentRoom = { Name = "G_Boss01", Encounter = encounter } } })
    local ok, message = pcall(callbacks.ApplyScyllaFightSpotlight, nil, {}, function() error("native failure") end,
        {}, { Flags = scyllaFlags() })
    restore()
    lu.assertFalse(ok)
    lu.assertStrContains(message, "native failure")
end

function TestScylla.testEncounterHooksRegisterScyllaContact()
    local module, registered = capture()
    encounterHooks.attach(module, {}, function() return { state = "desynchronized" } end, function() end, {
        encounterPhase = function() return nil end,
    })
    lu.assertNotNil(registered.ApplyScyllaFightSpotlight)
end
