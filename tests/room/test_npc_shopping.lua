-- luacheck: globals TestNpcShopping
local lu = require("luaunit")
local json = require("mods.protocol.json")
local protocol = require("mods.protocol.decoder")
local occurrences = require("mods.protocol.occurrences")
local room = require("mods.room.coordinator")
local shopping = require("mods.room.features.npc_shopping")

TestNpcShopping = {}

local function fixture()
    local file = assert(io.open("fixtures/execution-plan/fg-npc-shopping-protection.execution.json", "rb"))
    local wire = assert(json.decode(file:read("*a")))
    file:close()
    return wire
end

function TestNpcShopping.testRealProducerProtectionSuppressesOnlyMatchingBoundCallback()
    local plan = assert(protocol.decode(fixture()))
    local protected
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.suppressedNpcShopping ~= nil then protected = occurrence; break end
    end
    lu.assertNotNil(protected)
    lu.assertEquals(protected.suppressedNpcShopping, { "Nemesis" })
    local callbacks, diagnostics = {}, {}
    local state = { state = "synchronized", plan = plan, room = room.new(plan) }
    local native = { __runPlannerExecutionRoomId = protected.id }
    local saved = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = native }
    shopping.attach({ hooks = { wrap = function(name, _, fn) callbacks[name] = fn end } }, {
        diagnostic = function(_, checkpoint, detail, occurrence)
            diagnostics[#diagnostics + 1] = { checkpoint, detail.family, occurrence.id }
        end,
    }, function() return state end, function() end, room)
    local function invoke(family, expectedSuppressed)
        local source, args, calls = {}, {}, 0
        local result = callbacks["Check" .. family .. "ShoppingEvent"](nil, {}, function(received, options)
            lu.assertIs(received, source)
            lu.assertIs(options, args)
            calls = calls + 1
            received[family .. "Shopping"] = true
            _G.CurrentRun[family .. "Shopped"] = true
            return "native-result"
        end, source, args)
        lu.assertEquals(calls, expectedSuppressed and 0 or 1)
        if expectedSuppressed then
            lu.assertNil(result)
            lu.assertNil(source[family .. "Shopping"])
            lu.assertNil(_G.CurrentRun[family .. "Shopped"])
        else
            lu.assertEquals(result, "native-result")
            lu.assertTrue(source[family .. "Shopping"])
            lu.assertTrue(_G.CurrentRun[family .. "Shopped"])
        end
        _G.CurrentRun[family .. "Shopped"] = nil
    end
    invoke("Nemesis", true)
    invoke("Heracles", false)
    lu.assertEquals(diagnostics, { { "npc-shopping-suppressed", "Nemesis", protected.id } })
    protected.suppressedNpcShopping = { "Heracles" }
    invoke("Heracles", true)
    invoke("Nemesis", false)
    protected.suppressedNpcShopping = { "Nemesis", "Heracles" }
    invoke("Nemesis", true)
    invoke("Heracles", true)
    state.room.current = { occurrence = protected } -- must never rescue an unbound native room
    native.__runPlannerExecutionRoomId = nil
    invoke("Nemesis", false)
    native.__runPlannerExecutionRoomId = "unknown"
    invoke("Heracles", false)
    native.__runPlannerExecutionRoomId = protected.id
    state.state = "desynchronized"
    invoke("Nemesis", false)
    state.state = "synchronized"
    protected.suppressedNpcShopping = nil
    invoke("Nemesis", false)
    protected.suppressedNpcShopping = {}
    invoke("Heracles", false)
    _G.CurrentRun = saved
end

function TestNpcShopping.testStrictOptionalUniqueFamilyArrayAndProtocolBoundary()
    for _, spelling in ipairs({ '[]', '["Nemesis"]', '["Heracles"]', '["Nemesis","Heracles"]' }) do
        local wire = fixture()
        wire.occurrences[1].suppressedNpcShopping = assert(json.decode(spelling))
        lu.assertNotNil(occurrences.decode(wire.occurrences, wire.selectedOccurrenceIds, "occurrences"))
    end
    for _, spelling in ipairs({ 'null', '"Nemesis"', '["Artemis"]', '["Nemesis","Nemesis"]', '[1]' }) do
        local wire = fixture()
        wire.occurrences[1].suppressedNpcShopping = assert(json.decode(spelling))
        lu.assertNil(occurrences.decode(wire.occurrences, wire.selectedOccurrenceIds, "occurrences"))
    end
    local wire = fixture()
    wire.protocolVersion = 47
    local value, err = protocol.decode(wire)
    lu.assertNil(value)
    lu.assertStrContains(err, "unsupported identity")
end
