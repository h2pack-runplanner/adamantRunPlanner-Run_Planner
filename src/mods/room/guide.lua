-- Read-only room-guide projection. It presents the frozen execution guide and
-- existing completion hints; it never starts, claims, or completes timeline work.
local guide = {}

local MAX_ROWS = 6

local function displayName(key, fallback)
    if type(key) ~= "string" or key == "" then return fallback end
    local ok, label = pcall(function()
        return _G.GetDisplayName and _G.GetDisplayName({ Text = key }) or nil
    end)
    if ok and type(label) == "string" and label ~= "" and label ~= key then return label end
    return fallback
end

local function readableKey(key, fallback)
    local label = displayName(key, nil)
    if label ~= nil then return label end
    if type(key) ~= "string" or key == "" then return fallback end
    local words = key:gsub("([a-z])([A-Z])", "%1 %2"):gsub("(%a)(%d)", "%1 %2")
    return words ~= "" and words or fallback
end

local function roomName(gameName)
    return displayName(gameName, type(gameName) == "string" and gameName or "room")
end

local function rewardName(reward)
    if type(reward) ~= "table" then return "reward" end
    local common = {
        RandomLoot = "boon", MaxHealthDrop = "health", MaxManaDrop = "mana",
        HealBigDrop = "healing", ArmorDrop = "armor", RoomMoneyDrop = "gold",
    }
    if common[reward.rewardType] ~= nil then return common[reward.rewardType] end
    if reward.source ~= nil then return displayName(reward.source, "reward") end
    return displayName(reward.rewardType, "reward")
end

local function sourceName(source)
    local label = displayName(source, nil)
    if label ~= nil then return label end
    if type(source) == "string" then
        local god = source:match("^(.-)Upgrade$")
        if god and god ~= "" then return god end
    end
    return nil
end

local function shopOffer(occurrence, offerKey)
    for _, offer in ipairs(occurrence and occurrence.overview and occurrence.overview.shop
        and occurrence.overview.shop.offers or {}) do
        if offer.offerKey == offerKey then return offer end
    end
end

local function cageName(phaseKey)
    local index = type(phaseKey) == "string" and phaseKey:match("^Cage0*(%d+)$") or nil
    return index and "cage " .. index or "cage"
end

local function instruction(description, occurrence)
    if type(description) ~= "table" then return "Complete planned action" end
    local kind = description.kind
    if kind == "collectRequiredReward" then return "Collect required reward" end
    if kind == "completeFieldsCage" then return "Clear " .. cageName(description.phaseKey) end
    if kind == "interactIncomingReward" or kind == "interactLocalReward" then
        if description.conversion == "timePiece" then return "Destroy reward with Time Piece" end
        return "Collect " .. rewardName(description.reward)
    end
    if kind == "chooseRewardWheel" then return "Choose " .. readableKey(description.wheelKey, "reward wheel") end
    if kind == "interactWheelReward" then
        if description.conversion == "timePiece" then return "Destroy wheel reward with Time Piece" end
        return "Collect " .. readableKey(description.wheelKey, "wheel") .. " " .. rewardName(description.reward)
    end
    if kind == "interactShopOffer" then
        if description.conversion == "timePiece" then return "Destroy Shop reward with Time Piece" end
        if description.conversion == "anvilOfFates" then return "Use Anvil of Fates" end
        local offer = shopOffer(occurrence, description.offerKey)
        local prefix = offer and offer.optionKey == "BoostedRandomLoot" and "boosted " or ""
        local source = offer and sourceName(offer.source) or nil
        local reward = offer and rewardName(offer) or rewardName({ rewardType = description.rewardType })
        if source ~= nil then return "Buy " .. prefix .. source .. " " .. reward end
        return "Buy " .. readableKey(description.offerKey, "Shop offer") .. " " .. reward
    end
    if kind == "purchaseStygianWellOffer" then
        return "Buy " .. readableKey(description.itemKey or description.twistResultKey, "Well item")
    end
    if kind == "sellPurgingPoolTrait" then
        return "Sell " .. displayName(description.traitKey, "trait") .. " at Pool"
    end
    if kind == "interactEncounter" or kind == "interactGorgon" then
        return "Complete " .. readableKey(description.encounterKey, "encounter")
    end
    if kind == "interactAcquisitionEntry" then
        if description.conversion == "timePiece" then return "Destroy reward with Time Piece" end
        if description.conversion == "anvilOfFates" then return "Use Anvil of Fates" end
        return "Collect " .. rewardName(description.reward)
    end
    if kind == "useFountain" then return "Use fountain" end
    if kind == "interactKeepsakeRack" then
        return "Use " .. readableKey(description.keepsakeKey, "keepsake rack")
    end
    return "Complete planned action"
end

local function navigationFooter(navigation)
    if type(navigation) ~= "table" then return nil end
    if navigation.kind == "return" and navigation.gameName ~= nil then
        return "Go to " .. roomName(navigation.gameName)
    end
    local nextOccurrence = navigation.occurrence
    if navigation.kind ~= "next" or type(nextOccurrence) ~= "table" then return nil end
    local room = roomName(nextOccurrence.gameName)
    local overview = nextOccurrence.overview
    local reward = overview and overview.incomingReward
    if reward ~= nil then return "Next: " .. room .. " — " .. rewardName(reward) end
    return "Next: " .. room
end

local function visibleRows(snapshot)
    local rows = {}
    for index, row in ipairs(snapshot.occurrence.roomGuide or {}) do
        local completed = row.transactionOwner ~= nil and snapshot.isCompleted(row.transactionOwner) == true
        if not completed then rows[#rows + 1] = { ordinal = index, row = row } end
    end
    return rows
end

local function window(rows)
    if #rows <= MAX_ROWS then return rows, 0 end
    local anchor = nil
    for index, item in ipairs(rows) do
        if item.row.transactionOwner ~= nil then anchor = index; break end
    end
    if anchor == nil then anchor = 1 end
    -- Keep one immediately preceding informational reminder adjacent to the
    -- first still-pending transaction without letting old reminders pin it.
    local start = anchor
    if start > 1 and rows[start - 1].row.transactionOwner == nil then start = start - 1 end
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
            header = "Room guide: " .. roomName(snapshot.nativeRoomName),
            rows = {},
            footer = navigationFooter(snapshot.navigation),
        }
    end
    if snapshot.kind ~= "room" or type(snapshot.occurrence) ~= "table"
        or type(snapshot.isCompleted) ~= "function" then return nil end
    local rows = visibleRows(snapshot)
    local displayed, omitted = window(rows)
    local projected = {}
    for _, item in ipairs(displayed) do
        projected[#projected + 1] = {
            number = tostring(item.ordinal) .. ".",
            instruction = instruction(item.row.description, snapshot.occurrence),
        }
    end
    local footer = navigationFooter(snapshot.navigation)
    if omitted > 0 then
        local reminders = tostring(omitted) .. " additional reminder" .. (omitted == 1 and "" or "s")
        footer = footer and (reminders .. " | " .. footer) or reminders
    end
    return {
        header = "Room guide: " .. roomName(snapshot.occurrence.gameName),
        rows = projected,
        footer = footer,
    }
end

local function fingerprint(projection)
    if projection == nil then return "hidden" end
    local values = { projection.header or "", projection.footer or "" }
    for _, row in ipairs(projection.rows or {}) do
        values[#values + 1] = row.number .. "\31" .. row.instruction
    end
    return table.concat(values, "\30")
end

function guide.attach(module, inspect)
    assert(type(module) == "table" and type(module.overlays) == "table", "guide overlay module is required")
    assert(type(inspect) == "function", "guide inspection is required")
    local visible = { guide = false, footer = false }
    local lastFingerprint = nil
    module.overlays.createLine("room-guide-header", {
        region = "middleRightStack", order = module.overlays.order.module,
        columns = { { key = "text", minWidth = 240 } },
        visible = function() return visible.guide end,
    })
    module.overlays.createTable("room-guide-rows", {
        region = "middleRightStack", order = module.overlays.order.module + 1,
        maxRows = MAX_ROWS,
        columns = { { key = "number", minWidth = 24 }, { key = "instruction", minWidth = 216 } },
        visible = function() return visible.guide end,
    })
    module.overlays.createLine("room-guide-footer", {
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
