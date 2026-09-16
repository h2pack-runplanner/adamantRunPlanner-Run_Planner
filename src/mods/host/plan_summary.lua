-- Presentation of decoded facts only; no native loadout reads or revalidation.
local summary = {}
local ARCANA_RANKS = { Common = 1, Rare = 2, Epic = 3, Heroic = 4 }

function summary.build(plan, displayName)
    local loadout = plan.startingLoadout
    local result = {
        route = plan.routeKey .. " | " .. table.concat(plan.extent.biomeKeys, " / ")
            .. " | " .. #plan.selectedOccurrenceIds .. " planned rooms",
        weapon = displayName(loadout.weaponKey),
        aspect = displayName(loadout.aspectKey),
        keepsake = displayName(plan.startingKeepsake.keepsakeKey),
        keepsakeChanges = {},
        arcana = {},
        fear = {},
    }
    for _, id in ipairs(plan.selectedOccurrenceIds) do
        local occurrence = plan.occurrencesById[id]
        for _, transaction in ipairs(occurrence.timeline.transactions) do
            if transaction.kind == "keepsakeChange" or transaction.kind == "keepsakeReplay" then
                result.keepsakeChanges[#result.keepsakeChanges + 1] = occurrence.gameName .. ": "
                    .. displayName(transaction.keepsakeKey)
                    .. (transaction.kind == "keepsakeReplay" and " (Gift replay)" or "")
            end
        end
    end
    for _, card in ipairs(loadout.arcana) do
        result.arcana[#result.arcana + 1] = displayName(card.key) .. " - Rank "
            .. ARCANA_RANKS[card.rarity] .. " (" .. card.rarity .. ", " .. card.origin .. ")"
    end
    local keys, seen = {}, {}
    for _, ranks in ipairs({ loadout.fear.configuredRanks, loadout.fear.effectiveRanks }) do
        for key in pairs(ranks) do
            if not seen[key] then keys[#keys + 1] = key; seen[key] = true end
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local configured = loadout.fear.configuredRanks[key] or 0
        local effective = loadout.fear.effectiveRanks[key] or 0
        if configured > 0 or effective > 0 then
            result.fear[#result.fear + 1] = displayName(key) .. ": "
                .. (configured == effective and "Rank " .. configured
                    or "Configured " .. configured .. " / Effective " .. effective)
        end
    end
    return result
end

return summary
