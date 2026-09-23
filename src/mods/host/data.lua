local data = {}

function data.buildStorage()
    return {
        {
            type = "int",
            alias = "ActivePlanSlot",
            label = "Active plan slot",
            tooltip = "Run Planner uses this slot for the next run.",
            default = 1,
            min = 1,
            max = 6,
        },
        {
            type = "bool",
            alias = "ShowRoomGuide",
            label = "Show room guide",
            tooltip = "Show read-only planned room instructions on the HUD.",
            default = false,
        },
        {
            type = "bool",
            alias = "HighlightPlannedChoices",
            label = "Highlight planned choices",
            tooltip = "Mark the next planned door or choice when it is available.",
            default = false,
        },
    }
end

function data.buildStatus()
    return {
        ExecutionSessionStatus = {
            type = "string",
            default = "inactive: not-started",
            maxLen = 1024,
            persist = false,
        },
    }
end

return data
