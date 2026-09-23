-- Read-only room-guide projection. It presents the frozen execution guide and
-- existing completion hints; it never starts, claims, or completes timeline work.
local guide = {}

local MAX_ROWS = 6

-- Display-only names matching the catalog; native map IDs are not text keys.
local roomOccupants = {
    F_Story01 = "Arachne", G_Story01 = "Narcissus", H_Bridge01 = "Echo", I_Story01 = "Hades",
    N_Story01 = "Medea", O_Story01 = "Circe", P_Story01 = "Dionysus",
    F_MiniBoss01 = "Root-Stalker", F_MiniBoss02 = "Shadow-Spiller", F_MiniBoss03 = "Master-Slicer",
    G_MiniBoss01 = "Deep Serpent", G_MiniBoss02 = "King Vermin", G_MiniBoss03 = "Hellifish",
    H_MiniBoss01 = "Phantom", H_MiniBoss02 = "Queen Lamia",
    I_MiniBoss01 = "The Verminancer", I_MiniBoss02 = "Goldwrath",
    N_MiniBoss01 = "Satyr Champion", N_MiniBoss02 = "Erymanthian Boar",
    O_MiniBoss01 = "Charybdis", O_MiniBoss02 = "The Yargonaut",
    P_MiniBoss01 = "Talos", P_MiniBoss02 = "Mega-Dracon",
    Q_MiniBoss02 = "Brute", Q_MiniBoss03 = "Tail", Q_MiniBoss04 = "Eye", Q_MiniBoss05 = "Stalker",
}

local function displayName(key, fallback)
    if type(key) ~= "string" or key == "" then return fallback end
    local ok, label = pcall(function()
        return _G.GetDisplayName and _G.GetDisplayName({ Text = key }) or nil
    end)
    if ok and type(label) == "string" and label ~= "" and label ~= key then
        -- Native names may contain resource icons and formatting commands.
        -- The compact guide deliberately renders plain text only.
        label = label:gsub("{[!#][^}]*}", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
        if label ~= "" then return label end
    end
    return fallback
end

local function roomName(gameName)
    local localized = displayName(gameName, nil)
    if localized then return localized end
    local chaos = tostring(gameName):match("^Chaos_(%d+)$")
    if chaos then return "Chaos · " .. chaos end
    local dream = tostring(gameName):match("^Dream_PostBoss(%d+)$")
    if dream then return "Dream · Postboss " .. dream end
    local biome, kind, number = tostring(gameName):match("^(%u)_([%a]+)(%d*)$")
    local biomes = { F = "Erebus", G = "Oceanus", H = "Fields", I = "Tartarus",
        N = "Ephyra", O = "Thessaly", P = "Olympus", Q = "Summit", B = "Anomaly", C = "Zagreus" }
    if biomes[biome] and roomOccupants[gameName] then
        return biomes[biome] .. " · " .. roomOccupants[gameName]
    end
    local rooms = { Combat = "Combat", MiniBoss = "Miniboss", Boss = "Boss", Opening = "Opening",
        Intro = "Intro", PreHub = "Hub entrance", Hub = "Hub", PreBoss = "Preboss",
        PostBoss = "Postboss", Shop = "Shop", Story = "Story", Reprieve = "Fountain",
        Devotion = "Trial", Sub = "Side room" }
    if biomes[biome] and rooms[kind] then
        local suffix = (kind == "Combat" or kind == "Sub" or kind == "MiniBoss" or kind == "Opening")
            and number ~= "" and (" " .. number) or ""
        return biomes[biome] .. " · " .. rooms[kind] .. suffix
    end
    return "Current room"
end

local function sourceName(source)
    if type(source) ~= "string" then return nil end
    local god = source:match("^(.-)Upgrade$")
    local gods = { Aphrodite = true, Apollo = true, Ares = true, Demeter = true,
        Hephaestus = true, Hera = true, Hestia = true, Poseidon = true, Zeus = true, Hermes = true }
    return gods[god] and god or nil
end

local function rewardName(reward, boosted)
    if type(reward) ~= "table" then return "reward" end
    local common = {
        StackUpgrade = "Pom", StackUpgradeBig = "Double Pom", StackUpgradeTriple = "Triple Pom",
        StoreRewardRandomStack = "Pom Slice", WeaponUpgrade = "Hammer", WeaponUpgradeDrop = "Hammer",
        SpellDrop = "Hex", TalentDrop = "Path of Stars", ChaosWeaponUpgrade = "Anvil of Fates",
        MetaCurrencyDrop = "Bones", MetaCardPointsCommonDrop = "Ashes", MemPointsCommonDrop = "Psyche",
        MaxHealthDrop = "Max Health", MaxManaDrop = "Max Magick", RoomMoneyDrop = "Gold",
        MaxHealthDropSmall = "Max Health", MaxManaDropSmall = "Max Magick",
        GiftDrop = "Nectar", HealDrop = "Health", ManaDrop = "Magick",
    }
    local god = sourceName(reward.source) or sourceName(reward.rewardType)
    local mystery = reward.rewardType == "BlindBoxLoot" or reward.rewardType == "RandomLootGiftItem"
    if mystery or god or reward.rewardType == "RandomLoot" or reward.rewardType == "Boon" then
        local label = mystery and "Mystery Boon" or boosted and "Boosted Boon" or "Boon"
        if god and not mystery and not boosted then return god .. " boon" end
        return god and (label .. " — " .. god) or label
    end
    if common[reward.rewardType] ~= nil then return common[reward.rewardType] end
    return displayName(reward.rewardType, "reward")
end

local function shopOffer(occurrence, offerKey)
    for _, offer in ipairs(occurrence and occurrence.overview and occurrence.overview.shop
        and occurrence.overview.shop.offers or {}) do
        if offer.offerKey == offerKey then return offer end
    end
end

local function cageName(phaseKey)
    local index = type(phaseKey) == "string" and phaseKey:match("^Cage0*(%d+)$") or nil
    return index and "Cage " .. index or "Cage"
end

local function instruction(description, occurrence, transaction)
    if type(description) ~= "table" then return "Complete planned action" end
    local kind = description.kind
    local reward = description.reward or (transaction and transaction.reward)
    if transaction and transaction.kind == "acquisition" then
        for _, role in ipairs(transaction.roles or {}) do
            if role.disposition == "artificer" then return "Use Artificer on " .. rewardName(reward) end
        end
    end
    if kind == "collectRequiredReward" then return "Collect boss reward" end
    if kind == "completeFieldsCage" then
        local label = "Clear " .. cageName(description.phaseKey)
        if reward ~= nil then
            local name = sourceName(reward.source) or sourceName(reward.rewardType) or rewardName(reward)
            return label .. " — " .. name
        end
        return label
    end
    if kind == "interactIncomingReward" or kind == "interactLocalReward" then
        if description.conversion == "timePiece" then return "Use Time Piece on " .. rewardName(reward) end
        return "Collect " .. rewardName(reward)
    end
    if kind == "chooseRewardWheel" then
        for _, wheel in ipairs(occurrence.overview and occurrence.overview.rewardWheels or {}) do
            if wheel.wheelKey == description.wheelKey then
                for _, offer in ipairs(wheel.offers or {}) do
                    if offer.offerKey == wheel.pickedOfferKey then
                        return "Wheel: " .. rewardName(offer.reward)
                    end
                end
            end
        end
        return "Choose wheel reward"
    end
    if kind == "interactWheelReward" then
        if description.conversion == "timePiece" then return "Use Time Piece on " .. rewardName(reward) end
        return "Collect " .. rewardName(reward)
    end
    if kind == "interactShopOffer" then
        if description.conversion == "anvilOfFates" then return "Use Anvil of Fates" end
        local offer = shopOffer(occurrence, description.offerKey)
        -- The acquisition owns the resolved Mystery Boon god; the inventory
        -- can still describe only its box carrier.
        local label = rewardName(reward or offer or { rewardType = description.rewardType },
            offer and offer.optionKey == "BoostedRandomLoot")
        if description.conversion == "timePiece" then return "Use Time Piece on " .. label end
        return "Buy " .. label
    end
    if kind == "purchaseStygianWellOffer" then
        return "Buy " .. displayName(description.itemKey, "Well item")
    end
    if kind == "sellPurgingPoolTrait" then
        return "Sell " .. displayName(description.traitKey, "trait")
    end
    if kind == "interactGorgon" then return "Talk to Athena" end
    if kind == "interactEncounter" then
        local resolution = transaction and transaction.resolution
        local giver = resolution and resolution.offer and resolution.offer.giver
        local names = { "Arachne", "Narcissus", "Echo", "Hades", "Medea", "Circe",
            "Dionysus", "Icarus", "Artemis", "Athena", "Nemesis", "Heracles" }
        for _, name in ipairs(names) do
            if giver == name or (resolution and resolution.kind == "nemesisRandomEvent" and name == "Nemesis")
                or (type(description.encounterKey) == "string"
                    and (description.encounterKey:match("^" .. name)
                        or description.encounterKey:match("^Story_" .. name .. "_"))) then
                return "Talk to " .. name
            end
        end
        return "Complete encounter"
    end
    if kind == "interactAcquisitionEntry" then
        if description.conversion == "timePiece" then return "Use Time Piece on " .. rewardName(reward) end
        if description.conversion == "anvilOfFates" then return "Use Anvil of Fates" end
        return "Collect " .. rewardName(reward)
    end
    if kind == "useFountain" then
        local target = description.aromaticPhialTarget
        if target ~= nil then
            return "Use fountain — Phial: " .. displayName(target, "planned trait")
        end
        return "Use fountain"
    end
    if kind == "interactKeepsakeRack" then
        return "Equip " .. displayName(description.keepsakeKey, "planned keepsake")
    end
    return "Complete planned action"
end

local function navigationFooter(navigation)
    if type(navigation) ~= "table" then return nil end
    if navigation.kind == "return" and navigation.gameName ~= nil then
        return navigation.gameName == "N_Hub" and "Return to Hub" or ("Return to " .. roomName(navigation.gameName))
    end
    local nextOccurrence = navigation.occurrence
    if navigation.kind ~= "next" or type(nextOccurrence) ~= "table" then return nil end
    local gameName = nextOccurrence.gameName or ""
    local overview = nextOccurrence.overview
    local reward = navigation.reward
    if navigation.hubVisit and not gameName:match("_MiniBoss%d+$") then
        local number = gameName:match("^N_Combat(%d+)$")
        local label = number and ("Room " .. number) or roomName(gameName)
        return "Next visit: " .. label .. (reward and (" — " .. rewardName(reward)) or "")
    end
    if gameName:match("^Chaos_") then return "Next: Chaos" end
    if gameName:match("^C_Boss") then return "Next: Zagreus" end
    if overview and overview.shop then return "Next: Shop" end
    if gameName:match("_Reprieve") then return "Next: Fountain" end
    if reward ~= nil then return "Next door: " .. rewardName(reward) end
    if navigation.cageRewards and #navigation.cageRewards > 0 then
        local labels = {}
        for _, cageReward in ipairs(navigation.cageRewards) do labels[#labels + 1] = rewardName(cageReward) end
        return "Next door: " .. table.concat(labels, " / ")
    end
    return "Next: " .. roomName(gameName)
end

local function visibleRows(snapshot)
    local rows = {}
    for _, row in ipairs(snapshot.occurrence.roomGuide or {}) do
        local completed = row.transactionOwner ~= nil and snapshot.isCompleted(row.transactionOwner) == true
        if not completed then rows[#rows + 1] = row end
    end
    return rows
end

local function window(rows)
    if #rows <= MAX_ROWS then return rows, 0 end
    local anchor = nil
    for index, row in ipairs(rows) do
        if row.transactionOwner ~= nil then anchor = index; break end
    end
    if anchor == nil then anchor = 1 end
    -- Keep one immediately preceding informational reminder adjacent to the
    -- first still-pending transaction without letting old reminders pin it.
    local start = anchor
    if start > 1 and rows[start - 1].transactionOwner == nil then start = start - 1 end
    local displayed = {}
    for index = start, math.min(#rows, start + MAX_ROWS - 1) do
        displayed[#displayed + 1] = rows[index]
    end
    return displayed, #rows - #displayed
end

function guide.project(snapshot)
    if type(snapshot) ~= "table" then return nil end
    if snapshot.kind == "navigation" then
        return {
            header = roomName(snapshot.nativeRoomName),
            rows = {},
            footer = navigationFooter(snapshot.navigation),
        }
    end
    if snapshot.kind ~= "room" or type(snapshot.occurrence) ~= "table"
        or type(snapshot.isCompleted) ~= "function" then return nil end
    local rows = visibleRows(snapshot)
    local displayed, omitted = window(rows)
    local projected = {}
    for _, row in ipairs(displayed) do
        projected[#projected + 1] = {
            instruction = instruction(row.description, snapshot.occurrence,
                snapshot.occurrence.transactionsByOwner
                    and snapshot.occurrence.transactionsByOwner[row.transactionOwner]),
        }
    end
    local footer = navigationFooter(snapshot.navigation)
    if omitted > 0 then
        local reminders = tostring(omitted) .. " hidden reminder" .. (omitted == 1 and "" or "s")
        footer = footer and (reminders .. " | " .. footer) or reminders
    end
    return {
        header = roomName(snapshot.occurrence.gameName),
        rows = projected,
        footer = footer,
    }
end

local function fingerprint(projection)
    if projection == nil then return "hidden" end
    local values = { projection.header or "", projection.footer or "" }
    for _, row in ipairs(projection.rows or {}) do
        values[#values + 1] = row.instruction
    end
    return table.concat(values, "\30")
end

function guide.attach(module, inspect)
    assert(type(module) == "table" and type(module.overlays) == "table", "guide overlay module is required")
    assert(type(inspect) == "function", "guide inspection is required")
    local visible = { guide = false, footer = false }
    local lastFingerprint = nil
    module.overlays.createLine("room-guide-header", {
        hudVisibility = "independent",
        region = "middleRightStack", order = module.overlays.order.module,
        columns = { { key = "text", minWidth = 240 } },
        visible = function() return visible.guide end,
    })
    module.overlays.createTable("room-guide-rows", {
        hudVisibility = "independent",
        region = "middleRightStack", order = module.overlays.order.module + 1,
        maxRows = MAX_ROWS,
        columns = { { key = "instruction", minWidth = 240 } },
        visible = function() return visible.guide end,
    })
    module.overlays.createLine("room-guide-footer", {
        hudVisibility = "independent",
        region = "middleRightStack", order = module.overlays.order.module + MAX_ROWS + 1,
        columns = { { key = "text", minWidth = 240 } },
        visible = function() return visible.footer end,
    })

    local function refresh(_, runtime, overlay)
        local projection = nil
        if runtime.data.read("ShowRoomGuide") == true then
            local ok, value = pcall(function() return guide.project(inspect()) end)
            if ok then projection = value end
        end
        local value = fingerprint(projection)
        if value == lastFingerprint then return end
        lastFingerprint = value
        visible.guide = projection ~= nil
        visible.footer = projection ~= nil and projection.footer ~= nil
        overlay.setLine("room-guide-header", { text = projection and projection.header or "" })
        overlay.setTable("room-guide-rows", projection and projection.rows or {})
        overlay.setLine("room-guide-footer", { text = projection and projection.footer or "" })
        overlay.refreshOwned()
    end

    module.overlays.onCommit(refresh)
    module.overlays.onInterval("room-guide-refresh", 0.25, refresh)
end

return guide
