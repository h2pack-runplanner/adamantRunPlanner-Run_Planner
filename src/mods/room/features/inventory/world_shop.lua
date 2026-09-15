-- World Shop inventory, Travel Deal refill, and Infernal Contract inventory.
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local worldShop = {}

function worldShop.prepareRefill(storeData, args, scope)
    if scope == nil or scope.kind ~= "shop" or scope.refill == nil then return nil end
    local refill = primitives.copy(scope.refill.replacement)
    local group = storeData.GroupsOf and storeData.GroupsOf[refill.groupIndex + 1]
    if type(group) ~= "table" then
        return nil, { checkpoint = "shop-refill-group", expected = refill.groupIndex }
    end
    if group.OptionsData then
        group.OptionsData = primitives.retainRawOffers(group.OptionsData, { refill })
    end
    if group.Options then group.Options = primitives.retainRawOffers(group.Options, { refill }) end
    group.Offers = 1
    storeData.GroupsOf = { group }
    return { kind = "travelDealWorldShop", expected = { refill }, args = primitives.withStoreData(args, storeData) }
end

function worldShop.prepareContract(shop, storeData, args)
    if shop == nil or shop.infernalContract == nil then return nil end
    if type(storeData.GroupsOf) ~= "table" then return nil end
    local contract = primitives.copy(shop.infernalContract)
    local wanted = { [contract.rewardType] = true }
    local matchedCount = 0
    for _, group in ipairs(storeData.GroupsOf) do
        if type(group) == "table" then
            if group.OptionsData then
                local count
                group.OptionsData, count = primitives.retainAndCount(group.OptionsData, wanted)
                matchedCount = matchedCount + count
            end
            if group.Options then
                local count
                group.Options, count = primitives.retainAndCount(group.Options, wanted)
                matchedCount = matchedCount + count
            end
        end
    end
    if matchedCount == 0 then
        return nil, { checkpoint = "contract-inventory", expected = contract.rewardType, observed = nil }
    end
    return { kind = "contract", expected = { contract }, args = primitives.withStoreData(args, storeData) }
end

function worldShop.prepare(shop, storeData, args)
    if shop == nil then return nil end
    if type(storeData.GroupsOf) ~= "table" then return nil end
    local expectedOffers = {}
    for index, rawOffer in ipairs(shop.offers or {}) do
        expectedOffers[index] = primitives.copy(rawOffer)
    end
    -- Native GroupsOf order and Offers counts define the flattened shop slots.
    -- Narrow each slot inside its own group; a shop-wide item set lets choices
    -- bleed between groups (notably Q's mixed and premium boosted boons).
    local slotGroups = {}
    for _, group in ipairs(storeData.GroupsOf) do
        for _ = 1, group.Offers do
            local offer = expectedOffers[#slotGroups + 1]
            local slotGroup = primitives.copy(group)
            local matches = 0
            if offer and slotGroup.OptionsData then
                local count
                slotGroup.OptionsData, count = primitives.retainRawOffers(slotGroup.OptionsData, { offer })
                matches = matches + count
            end
            if offer and slotGroup.Options then
                local count
                slotGroup.Options, count = primitives.retainRawOffers(slotGroup.Options, { offer })
                matches = matches + count
            end
            if matches == 0 then
                return nil, {
                    checkpoint = "shop-inventory-offer", expected = offer and offer.optionKey,
                    observed = "no matching native slot option",
                }
            end
            slotGroup.Offers = 1
            slotGroups[#slotGroups + 1] = slotGroup
        end
    end
    if #slotGroups ~= #expectedOffers then
        return nil, {
            checkpoint = "shop-inventory-offer", expected = #expectedOffers, observed = #slotGroups,
        }
    end
    storeData.GroupsOf = slotGroups
    return { kind = "shop", expected = expectedOffers, args = primitives.withStoreData(args, storeData) }
end

return worldShop
