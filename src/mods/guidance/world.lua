-- Exact native-object markers for published exits and ship-wheel offers.
local world = {}
local MARKER_KEY = "RunPlannerPlannedChoice"

function world.create(route)
    local instance, markers = {}, setmetatable({}, { __mode = "k" })
    local desired = { route = nil, doors = {} }
    local function enabled(runtime, state)
        return state and state.state == "synchronized" and runtime and runtime.data
            and runtime.data.read("HighlightPlannedChoices") == true
    end
    local function retire(door)
        local marker = markers[door]
        if marker and _G.Destroy then pcall(_G.Destroy, { Ids = { marker } }) end
        if type(door) == "table" and type(door.AdditionalIcons) == "table" then door.AdditionalIcons[MARKER_KEY] = nil end
        markers[door] = nil
    end
    local function clearMarkers()
        for door in pairs(markers) do retire(door) end
    end
    function instance.clear()
        clearMarkers()
        desired.route, desired.doors = nil, {}
    end
    function instance.retire(door)
        if door == nil then return end
        retire(door)
        for index = #desired.doors, 1, -1 do
            if desired.doors[index] == door then table.remove(desired.doors, index) end
        end
    end
    local function mark(door)
        if type(door) ~= "table" or markers[door] then return end
        local icons, icon = door.RewardPreviewIconIds, nil
        if type(icons) == "table" then icon = icons[#icons] end
        if icon == nil or type(_G.AddDoorInfoIcon) ~= "function" then return end
        door.AdditionalIcons = door.AdditionalIcons or {}
        local nativeIcons = 0
        for key in pairs(door.AdditionalIcons) do
            if key ~= MARKER_KEY then nativeIcons = nativeIcons + 1 end
        end
        -- Native subicons use 60-unit spacing centered on the preview. Keep
        -- guidance beyond that strip without moving any native pin or icon.
        local offset = nativeIcons == 0 and 0 or 30 * (nativeIcons + 1)
        local ok = pcall(_G.AddDoorInfoIcon, { Door = door, DoorIconId = icon, Group = "Combat_UI_World",
            IsoOffset = offset, Name = MARKER_KEY, Animation = "RoomRewardSubIcon_ForgetMeNot" })
        if ok then markers[door] = door.AdditionalIcons[MARKER_KEY] end
    end
    function instance.doors(runtime, state, nativeDoors, target, source)
        clearMarkers()
        desired.route, desired.doors = state and state.route or nil, {}
        if type(target) ~= "table" or type(target.gameName) ~= "string" or type(source) ~= "table"
            or type(source.gameName) ~= "string" then return end
        -- Navigation already supplies only ordinary doors, including exits
        -- from shared rooms such as Chaos. Only N's separate Hub-only scope
        -- needs a source-room exclusion here.
        if source.gameName:match("^N_") then return end
        local matches = {}
        for _, door in ipairs(nativeDoors or {}) do
            local room = door and (door.Room or door.RoomData)
            local id = door and door.__runPlannerExecutionDoorTarget
                or type(room) == "table" and room.__runPlannerExecutionRoomId
            if id == target.id then
                matches[#matches + 1] = door
            end
        end
        if #matches ~= 1 then return end
        desired.doors = matches
        if enabled(runtime, state) then mark(matches[1]) end
    end
    function instance.hub(runtime, state, nativeDoors, hub)
        local target = state and route.next(state.route) or nil
        if type(hub) ~= "table" or type(target) ~= "table" then instance.clear(); return end
        for _, slot in ipairs(hub.slots or {}) do
            if slot.room and slot.room.id == target.id then
                for _, door in ipairs(nativeDoors or {}) do
                    if door.ObjectId == slot.physicalDoorId then
                        clearMarkers()
                        desired.route, desired.doors = state and state.route or nil, { door }
                        if enabled(runtime, state) then mark(door) end
                        return
                    end
                end
            end
        end
        instance.clear()
    end
    function instance.wheel(runtime, state, wheel, pickedOfferKey)
        if type(wheel) == "table" and wheel.__runPlannerOfferKey == pickedOfferKey then
            if desired.route ~= (state and state.route) then instance.clear() end
            desired.route = state and state.route or nil
            local present = false
            for _, existing in ipairs(desired.doors) do
                if existing == wheel then present = true end
            end
            if not present then desired.doors[#desired.doors + 1] = wheel end
            if enabled(runtime, state) then mark(wheel) end
        end
    end
    function instance.refresh(runtime, state)
        if not state or state.state ~= "synchronized" or desired.route ~= state.route then
            instance.clear()
            return
        end
        if not enabled(runtime, state) then clearMarkers(); return end
        for _, door in ipairs(desired.doors) do mark(door) end
    end
    function instance.mapIcons(runtime, state, door, icons)
        if not enabled(runtime, state) or desired.route ~= state.route then return icons end
        for _, target in ipairs(desired.doors) do
            if target == door then
                local result = {}
                for index, icon in ipairs(icons or {}) do result[index] = icon end
                result[#result + 1] = { Name = MARKER_KEY, Animation = "RoomRewardSubIcon_ForgetMeNot" }
                return result
            end
        end
        return icons
    end
    return instance
end
return world
