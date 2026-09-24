-- luacheck: globals TestFangs EnemyData
local lu = require("luaunit")
local support = require("tests.harness.hook_composition")
local definition = require("mods.room.timeline.encounters.fangs")

TestFangs = {}

local function fixture()
    local module, _, callbacks = support.capture()
    local adapter = definition.create()
    adapter.attach(module)
    return adapter, callbacks
end

local function encounter(name)
    return { Name = name, SpawnWaves = { { Spawns = { { Name = "Elite" }, { Name = "Other" } } } } }
end

local function nativeEncounter(callbacks, observed, attributes)
    return function(native)
        local selected = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end,
            { "Other", "Elite" })
        observed.types[#observed.types + 1] = selected
        return callbacks.PickEliteAttributes(nil, {}, attributes, native, selected)
    end
end

function TestFangs.testSteersNativeTypeThenOrderedPerksAndLeavesNativeApplicationUntouched()
    local adapter, callbacks = fixture()
    local previous = EnemyData
    EnemyData = { Elite = { IsElite = true }, Other = { IsElite = true } }
    local observed = { types = {}, perks = {}, applications = 0, enemyType = nil }
    local attributes = function(_, enemyType)
        observed.perks[#observed.perks + 1] = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end,
            { "Blink", "Fog" })
        observed.perks[#observed.perks + 1] = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end,
            { "Blink" })
        observed.applications = observed.applications + 1
        observed.enemyType = enemyType
    end
    local native = encounter("same")
    adapter.bind(native, { type = { nativeId = "Elite" }, perks = { "Fog", "Blink" } }, {})
    callbacks.PickEncounterEliteAttributes(nil, {}, nativeEncounter(callbacks, observed, attributes), native)
    lu.assertEquals(observed.types, { "Elite" })
    lu.assertEquals(observed.perks, { "Fog", "Blink" })
    lu.assertEquals(observed.applications, 1)
    lu.assertEquals(observed.enemyType, "Elite")
    EnemyData = previous
end

function TestFangs.testSameNameCagesAreBoundByEncounterIdentityAndMissingTypeDelegatesWholeDecision()
    local adapter, callbacks = fixture()
    local previous = EnemyData
    EnemyData = { Elite = { IsElite = true }, Other = { IsElite = true } }
    local observed = { types = {}, perks = {} }
    local attributes = function(_, enemyType)
        observed.perks[#observed.perks + 1] = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end,
            { "Blink", "Fog" })
        return enemyType
    end
    local first, second, missing = encounter("same"), encounter("same"), encounter("same")
    adapter.bind(first, { type = { nativeId = "Elite" }, perks = { "Fog" } }, {})
    adapter.bind(second, { type = { nativeId = "Other" }, perks = { "Blink" } }, {})
    adapter.bind(missing, { type = { nativeId = "Missing" }, perks = { "Fog" } }, {})
    local base = nativeEncounter(callbacks, observed, attributes)
    callbacks.PickEncounterEliteAttributes(nil, {}, base, first)
    callbacks.PickEncounterEliteAttributes(nil, {}, base, second)
    callbacks.PickEncounterEliteAttributes(nil, {}, base, missing)
    lu.assertEquals(observed.types, { "Elite", "Other", "Other" })
    lu.assertEquals(observed.perks, { "Fog", "Blink", "Blink" })
    EnemyData = previous
end

function TestFangs.testNestedNativeAndErrorsRestoreNeutralScope()
    local adapter, callbacks = fixture()
    local previous = EnemyData
    EnemyData = { Elite = { IsElite = true }, Other = { IsElite = true } }
    local outer, inner = encounter("same"), encounter("same")
    adapter.bind(outer, { type = { nativeId = "Elite" }, perks = { "Fog" } }, {})
    local innerType, outerPerk = nil, nil
    local attributes = function(_, enemyType)
        outerPerk = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "Blink", "Fog" })
        return enemyType
    end
    local innerBase = function(native)
        innerType = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "Other", "Elite" })
        return native
    end
    local base = function(native)
        callbacks.PickEncounterEliteAttributes(nil, {}, innerBase, inner)
        local selected = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "Other", "Elite" })
        return callbacks.PickEliteAttributes(nil, {}, attributes, native, selected)
    end
    callbacks.PickEncounterEliteAttributes(nil, {}, base, outer)
    lu.assertEquals(innerType, "Other")
    lu.assertEquals(outerPerk, "Fog")
    local ok = pcall(function()
        callbacks.PickEncounterEliteAttributes(nil, {}, function() error("native failure") end, outer)
    end)
    lu.assertFalse(ok)
    local nativeType = nil
    callbacks.PickEncounterEliteAttributes(nil, {}, function()
        nativeType = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "Other", "Elite" })
    end, inner)
    lu.assertEquals(nativeType, "Other")
    EnemyData = previous
end
