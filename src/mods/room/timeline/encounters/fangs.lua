-- Selection is published; native SetupUnit/ApplyEliteAttribute still own actual
-- name lookup, room fallback and per-room application caps.
local fangs = {}
function fangs.attach(module, owned)
    module.hooks.wrap("PickEncounterEliteAttributes", "run-planner-fangs-install", function(_, runtime, base,
        encounter, ...)
        local decision = owned(runtime, encounter)
        if decision == nil then return base(encounter, ...) end
        local attributes, selected = {}, decision.fangs
        if selected and #selected.perks > 0 then
            local perks = {}
            for index, perk in ipairs(selected.perks) do perks[index] = perk end
            attributes[selected.type.nativeId] = perks
        end
        encounter.EliteAttributes = attributes
    end)
end
return fangs
