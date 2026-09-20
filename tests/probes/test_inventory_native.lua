-- Manual only: lua tests/probes/test_inventory_native.lua /path/to/Scripts
-- Loads the local StoreLogic FillInShopOptions body without copying game code.
-- This probe is intentionally outside tests/all.lua. Its nil result for an
-- empty healing Options draw assumes the host's RNG(0) path yields nil; the
-- engine primitive itself is not available to this standalone Lua process.
-- luacheck: globals TestInventoryNative CurrentRun GameState TraitData ConsumableData LootData StoreData
-- luacheck: globals FillInShopOptions DeepCopyTable Contains IsTraitEligible StoreItemEligible
-- luacheck: globals StoreItemNameEligible TableLength GetRandomValueFromWeightedList GetRandomValue
-- luacheck: globals RandomInt RemoveRandomValue CollapseTable CombineTables GetEligibleInteractedGod
-- luacheck: globals GetProcessedValue IsGameStateEligible
local lu = require("luaunit")
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path

local support = require("tests.harness.hook_composition")
local nativeGame = require("tests.harness.native_game")
local capture, stub, opaque = support.capture, support.stub, support.opaque
local attachFeatureHooks = support.attachFeatureHooks

local function scriptsPath()
    local value = arg[1] or os.getenv("HADES2_SCRIPTS_PATH")
    assert(type(value) == "string" and value ~= "", "supply HADES2_SCRIPTS_PATH or a Scripts directory")
    return value:gsub("/$", "")
end

local nativeScriptsPath = scriptsPath()
if arg[1] then table.remove(arg, 1) end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function functionBody(source, name)
    local startAt = assert(source:find("function " .. name .. "%s*%(", 1),
        "native StoreLogic does not define " .. name)
    local nextAt = source:find("\nfunction ", startAt + 1)
    return source:sub(startAt, nextAt and nextAt - 1 or #source)
end

local function configured()
    local stubs = {
        FillInShopOptions = _G.FillInShopOptions,
        DeepCopyTable = copy,
        Contains = function(values, value)
            for _, item in pairs(values or {}) do if item == value then return true end end
            return false
        end,
        IsTraitEligible = function() return true end,
        StoreItemEligible = function() return true end,
        IsGameStateEligible = function(item) return item.Name ~= "Rejected" and item.Name ~= "ArmorBoost" end,
        StoreItemNameEligible = function(name) return name ~= "RejectedHeal" end,
        TableLength = function(values) local count = 0 for _ in pairs(values or {}) do count = count + 1 end return count end,
        GetRandomValueFromWeightedList = function(values) return next(values) end,
        GetRandomValue = function(values) return values and values[1] end,
        RandomInt = function(minimum) return minimum end,
        RemoveRandomValue = function(values) return table.remove(values) end,
        CollapseTable = function(values) return values end,
        CombineTables = function(left, right)
            local result = {}
            for _, value in pairs(left or {}) do result[#result + 1] = value end
            for _, value in pairs(right or {}) do result[#result + 1] = value end
            return result
        end,
        GetEligibleInteractedGod = function() return "NativeGod" end,
        GetProcessedValue = function(value) return value end,
        CurrentRun = {}, GameState = {}, TraitData = {}, LootData = {}, StoreData = {},
        ConsumableData = { RandomLoot = { ResourceCosts = {} } },
    }
    local restore = nativeGame.install(stubs)
    local path = nativeScriptsPath .. "/StoreLogic.lua"
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    assert(load(functionBody(source, "FillInShopOptions"), "@" .. path .. ":FillInShopOptions"))()
    return _G.FillInShopOptions, restore
end

TestInventoryNative = {}

function TestInventoryNative.testNativeWeightedUndersupplyAndNonweightedWellFallbackBoundary()
    local fill, restore = configured()
    local undersupplied = fill({ StoreData = { GroupsOf = { {
        Offers = 2, WeightedList = true, OptionsData = {
            { Name = "Rejected", ReplaceRequirements = {} },
            { Name = "Survivor", ReplaceRequirements = {} },
        },
    } } } })
    -- The native loop returns this malformed bare table after its exhaustion guard.
    lu.assertEquals(undersupplied, {})

    local survivor = fill({ StoreData = { GroupsOf = { {
        Offers = 2, WeightedList = false, OptionsData = {
            { Name = "Rejected", ReplaceRequirements = {} },
            { Name = "Survivor", ReplaceRequirements = {} },
        },
    } } } })
    lu.assertEquals(survivor.StoreOptions, { { Name = "Survivor", Type = "Consumable", Weight = 1 } })

    local well = fill({ StoreData = { HealingOffers = {
        Amount = 1, Options = { { Name = "RejectedHeal", Type = "Consumable" } },
    } } })
    lu.assertEquals(well.StoreOptions, {})
    restore()
end

function TestInventoryNative.testAdapterFallsBackThroughRealNativeBodyWithoutForcedGodLeak()
    local fill, restore = configured()
    local module, _, callbacks = capture()
    local diagnostics = {}
    local active = opaque({ occurrence = { overview = { hermesShrine = { offers = {
        { generationKey = "initial:first", optionKey = "RandomLoot", source = "ApolloUpgrade" },
        { generationKey = "initial:secondLeft", optionKey = "ArmorBoost" },
    } } } } }, function() return nil end)
    local session = stub()
    session.current = function() return active end
    session.diagnostic = function(_, checkpoint, values)
        diagnostics[#diagnostics + 1] = { checkpoint = checkpoint, values = values }
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local nativeGod = _G.GetEligibleInteractedGod
    _G.GetEligibleInteractedGod = function(ignored)
        return callbacks.GetEligibleInteractedGod(nil, {}, nativeGod, ignored)
    end
    local original = { StoreData = { GroupsOf = { {
        Offers = 2, WeightedList = true, OptionsData = {
            { Name = "RandomLoot", ReplaceRequirements = {} },
            { Name = "ArmorBoost", ReplaceRequirements = {} },
            { Name = "NativeOffer", ReplaceRequirements = {} },
        },
    } } } }
    local result = callbacks.FillInShopOptions(nil, {}, fill, original)
    lu.assertEquals(result.StoreOptions[1].Args.ForceLootName, "NativeGod")
    lu.assertEquals(result.StoreOptions[2].Name, "NativeOffer")
    lu.assertEquals(diagnostics[1].checkpoint, "inventory-generation")
    lu.assertEquals(diagnostics[1].values.expected, "ArmorBoost")
    _G.GetEligibleInteractedGod = nativeGod
    restore()
end

os.exit(lu.LuaUnit.run())
