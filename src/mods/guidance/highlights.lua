local world = type(import) == "function" and import("mods/guidance/world.lua") or require("mods.guidance.world")
local screen = type(import) == "function" and import("mods/guidance/choice_screen.lua") or require("mods.guidance.choice_screen")
local highlights = {}

function highlights.create(route)
    local doors, choices = world.create(route), screen.create()
    local instance = {
        doors = doors.doors,
        hub = doors.hub,
        wheel = doors.wheel,
        clearWorld = doors.clear,
        retireWorld = doors.retire,
        screen = choices.present,
        bindSource = choices.bindSource,
    }
    function instance.refresh(runtime, state)
        doors.refresh(runtime, state)
        choices.refresh(runtime, state)
    end
    function instance.attach(module, getState)
        choices.attach(module, getState)
        module.hooks.wrap("RemoveRoomRewardPreviews", "run-planner-highlight-previews-remove", function(_, _, base, ...)
            doors.clear()
            return base(...)
        end)
        module.hooks.wrap("LeaveRoom", "run-planner-highlight-world-leave", function(_, _, base, ...)
            doors.clear()
            return base(...)
        end)
        module.hooks.wrap("StartRoom", "run-planner-highlight-room-start", function(_, _, base, ...)
            doors.clear()
            choices.clear()
            return base(...)
        end)
    end
    return instance
end

return highlights
