-- Stygian Well inventory and carrier-specific Travel Deal refill construction.
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local wellInventory = {}

local function offersByGeneration(well)
    local result = {}
    for _, rawOffer in ipairs(well and well.offers or {}) do
        local offer = primitives.copy(rawOffer)
        result[offer.generationKey] = offer
    end
    return result
end

local function retainOffer(storeData, offer)
    if type(offer) ~= "table" then return false end
    local matched = false
    if storeData.HealingOffers and storeData.HealingOffers.WeightedList then
        local count = primitives.narrowHealingOffer(storeData.HealingOffers, offer)
        -- A non-healing refill must consume no healing carrier.
        storeData.HealingOffers.Amount = count > 0 and 1 or 0
        matched = matched or count > 0
    end
    local wanted = { [offer.offerKey] = true }
    local retained, count = primitives.retainAndCount(storeData.Traits, wanted)
    storeData.Traits = retained
    matched = matched or count > 0
    retained, count = primitives.retainAndCount(storeData.Consumables, wanted)
    storeData.Consumables = retained
    return matched or count > 0
end

function wellInventory.prepareRefill(storeData, args, scope)
    if scope == nil or scope.kind ~= "well" or scope.refill == nil then return nil end
    if scope.slotIndex == nil then
        return nil, { checkpoint = "well-refill-slot", expected = "native store slot", observed = nil }
    end
    local refill = primitives.copy(scope.refill.replacement)
    if not retainOffer(storeData, refill) then
        return nil, { checkpoint = "well-refill-inventory", expected = refill.offerKey, observed = nil }
    end
    storeData.MaxOffers = 1
    local expectedRefill = primitives.copy(refill)
    expectedRefill.slotIndex = scope.slotIndex
    return { kind = "travelDealStygianWell", expected = { expectedRefill },
        args = primitives.withStoreData(args, storeData) }
end

function wellInventory.prepare(well, storeData, args)
    if well == nil or not well.interacted then return nil end
    local byGeneration = offersByGeneration(well)
    local healing = byGeneration["initial:healing"]
    local left = byGeneration["initial:secondLeft"]
    local right = byGeneration["initial:secondRight"]
    if not healing or not left or not right then
        return nil, { checkpoint = "well-inventory", expected = "three initial offers" }
    end
    local healingMatches = 0
    if storeData.HealingOffers and storeData.HealingOffers.WeightedList then
        healingMatches = primitives.narrowHealingOffer(storeData.HealingOffers, healing)
    end
    if healingMatches == 0 then
        return nil, { checkpoint = "well-inventory", expected = healing.offerKey, observed = nil }
    end
    local wanted = { [left.offerKey] = true, [right.offerKey] = true }
    storeData.Traits = primitives.retain(storeData.Traits, wanted)
    storeData.Consumables = primitives.retain(storeData.Consumables, wanted)
    return { kind = "well", expected = { healing, left, right },
        args = primitives.withStoreData(args, storeData) }
end

return wellInventory
