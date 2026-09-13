-- luacheck: globals TestMysteryAcquisitions
local lu = require("luaunit")
local mystery = require("mods.room.timeline.acquisitions.mystery.hooks")

TestMysteryAcquisitions = {}

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    return module, callbacks
end

local function nativeCreateLoot(args)
    return { Name = args.Name }
end

local function harness()
    local module, callbacks = capture()
    local state, item, provider = {}, { Name = "BlindBoxLoot" }, { Name = "HeraUpgrade" }
    local boxHandle = {}
    local node = {
        owner = "mystery", kind = "acquisition",
        roles = {
            { role = "box", lifecyclePoint = "roomRewardPickup", kind = "consumable",
                gameName = item.Name, disposition = "normal" },
            { role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                gameName = provider.Name, disposition = "normal" },
        },
    }
    local boxPayload = { transaction = node, detail = node.roles[1] }
    local bound, payloads = {}, { [boxHandle] = boxPayload }
    local active = { occurrence = { overview = {} } }
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return bound[native] end,
        peek = function(_, handle) return payloads[handle] end,
        begin = function(_, handle) return payloads[handle] end,
        claimReady = function(_, _, contact, native, compatible)
            local role = compatible(node, contact)
            if role == nil then return nil end
            bound[native] = boxHandle
            return boxHandle, boxPayload
        end,
        bind = function(_, _, handle, native) bound[native] = handle; return handle end,
    }
    local session = { complete = function() error("Mystery box must not complete at unwrap") end }
    mystery.attach(module, session, function() return state end, function() end, room)
    return callbacks, state, item, provider, boxHandle, bound
end

function TestMysteryAcquisitions.testMysteryBoxClaimsAndBindsForcedProviderAtNativeUnwrap()
    local callbacks, _, item, provider, boxHandle, bound = harness()
    lu.assertNil(bound[item])
    callbacks.UnwrapRandomLoot(nil, {}, function()
        callbacks.GiveLoot(nil, {}, function(args)
            lu.assertEquals(args.ForceLootName, provider.Name)
            return provider
        end, {})
    end, item)
    lu.assertEquals(bound[item], boxHandle)
    lu.assertEquals(bound[provider], boxHandle)
end

function TestMysteryAcquisitions.testMysteryUnwrapRetiresConstructionScopeBeforeNativePresentationWait()
    local callbacks, _, item, provider, boxHandle, bound = harness()
    local native = coroutine.create(function()
        callbacks.UnwrapRandomLoot(nil, {}, function()
            local result = callbacks.GiveLoot(nil, {}, function(args)
                lu.assertEquals(args.ForceLootName, provider.Name)
                return provider
            end, {})
            lu.assertEquals(result, provider)
            coroutine.yield("unwrap-presentation")
        end, item)
    end)
    local resumed, yielded = coroutine.resume(native)
    lu.assertTrue(resumed)
    lu.assertEquals(yielded, "unwrap-presentation")
    lu.assertEquals(bound[provider], boxHandle)

    local unrelated = { Name = "ZeusUpgrade" }
    callbacks.GiveLoot(nil, {}, function(args)
        lu.assertNil(args.ForceLootName)
        return unrelated
    end, {})
    local sameName = nativeCreateLoot({ Name = provider.Name })
    lu.assertNil(bound[unrelated])
    lu.assertNil(bound[sameName])

    resumed = coroutine.resume(native)
    lu.assertTrue(resumed)
    lu.assertEquals(coroutine.status(native), "dead")
    lu.assertEquals(bound[provider], boxHandle)
end

function TestMysteryAcquisitions.testMysteryUnwrapErrorDoesNotLeakConstructionScope()
    local callbacks, _, item, provider, _, bound = harness()
    local ok = pcall(callbacks.UnwrapRandomLoot, nil, {}, function()
        callbacks.GiveLoot(nil, {}, function()
            error("native provider failure")
        end, {})
    end, item)
    lu.assertFalse(ok)

    local sameName = { Name = provider.Name }
    callbacks.GiveLoot(nil, {}, function(args)
        lu.assertNil(args.ForceLootName)
        return sameName
    end, {})
    lu.assertNil(bound[sameName])
end
