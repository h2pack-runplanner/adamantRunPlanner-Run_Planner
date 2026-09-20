-- Shared test doubles for required Hades II contacts. Production adapters call
-- these contacts directly; suites install only the native surface they use.
local nativeGame = {}

function nativeGame.install(bindings)
    local prior = {}
    for key, value in pairs(bindings) do
        prior[key] = _G[key]
        _G[key] = value
    end
    return function()
        for key in pairs(bindings) do _G[key] = prior[key] end
    end
end

function nativeGame.anyTraitDeclarations()
    return setmetatable({}, {
        __index = function(declarations, key)
            local declaration = { Name = key }
            rawset(declarations, key, declaration)
            return declaration
        end,
    })
end

function nativeGame.alwaysEligible()
    return true
end

function nativeGame.currentUpgradeableTraits()
    local result = {}
    for _, trait in ipairs(_G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.Traits or {}) do
        result[trait.Name] = true
    end
    return result
end

function nativeGame.noShrineUpgrades()
    return 0
end

-- StoreLogic.FillInShopOptions' Well pool/count contract. All supplied items
-- are eligible and the first available option is drawn deterministically.
-- Fail on an exhausted required pool instead of reproducing the native hang.
function nativeGame.fillWellInventory(args)
    local data, options, healingOptions = args.StoreData, {}, {}
    for _, name in ipairs(data.Traits or {}) do
        options[#options + 1] = { Name = name, Type = "Trait" }
    end
    for _, name in ipairs(data.Consumables or {}) do
        options[#options + 1] = { Name = name, Type = "Consumable" }
    end
    local healing = data.HealingOffers
    local healingCount = healing and (healing.Amount or healing.Min) or 0
    local healingPool = healing and (healing.Options or healing.WeightedList) or {}
    for index = 1, healingCount do
        local option = assert(healingPool[index], "native Well healing draw has no candidate")
        healingOptions[#healingOptions + 1] = { Name = option.Name, Type = option.Type }
    end
    local ordinaryCount = data.MaxOffers - healingCount
    assert(ordinaryCount >= 0, "native Well count cannot satisfy its required healing offers")
    while #options > ordinaryCount do table.remove(options) end
    for _, option in ipairs(options) do healingOptions[#healingOptions + 1] = option end
    return { StoreOptions = healingOptions }
end

function nativeGame.randomChance(roll, observed)
    return function(chance)
        if observed ~= nil then observed[#observed + 1] = chance end
        return roll <= chance
    end
end

return nativeGame
