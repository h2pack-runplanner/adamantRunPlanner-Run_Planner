-- Published Fangs maps bypass native draws but leave native later application.
local lu = require("luaunit")
local definition = require("mods.room.timeline.encounters.fangs")
local support = require("tests.harness.hook_composition")

TestFangs = {}

function TestFangs.testInstallsOnlyTheExactOwnedEncounterMap()
    local module, _, callbacks = support.capture()
    local first, second = {}, {}
    local owned = { [first] = { fangs = { type = { nativeId = "Elite" }, perks = { "Blink", "Fog" } } } }
    definition.attach(module, function(_, encounter) return owned[encounter] end)
    local nativeCalls = 0
    callbacks.PickEncounterEliteAttributes(nil, {}, function() nativeCalls = nativeCalls + 1 end, first)
    lu.assertEquals(first.EliteAttributes, { Elite = { "Blink", "Fog" } })
    callbacks.PickEncounterEliteAttributes(nil, {}, function() nativeCalls = nativeCalls + 1 end, second)
    lu.assertEquals(nativeCalls, 1)
    lu.assertNil(second.EliteAttributes)
end

function TestFangs.testInstallsAnEmptyMapForAnOwnedEncounterWithoutAFangsAssignment()
    local module, _, callbacks = support.capture()
    local encounter = {}
    definition.attach(module, function(_, candidate)
        return candidate == encounter and { fangs = nil } or nil
    end)
    callbacks.PickEncounterEliteAttributes(nil, {}, function() error("owned Fangs must not redraw") end, encounter)
    lu.assertEquals(encounter.EliteAttributes, {})
end

function TestFangs.testEmptyPublishedPerksSuppressOwnDrawWithoutMaskingRoomFallback()
    local module, _, callbacks = support.capture()
    local encounter = {}
    definition.attach(module, function(_, candidate)
        return candidate == encounter and { fangs = { type = { nativeId = "Elite" }, perks = {} } } or nil
    end)
    callbacks.PickEncounterEliteAttributes(nil, {}, function() error("owned Fangs must not redraw") end, encounter)
    lu.assertEquals(encounter.EliteAttributes, {})
    -- RoomLogic only replaces its fallback when this map has a key for the
    -- source type; an empty published perk pool must leave that native path.
    local roomFallback = { Elite = { "RoomFallback" } }
    lu.assertEquals(encounter.EliteAttributes.Elite or roomFallback.Elite, { "RoomFallback" })
end
