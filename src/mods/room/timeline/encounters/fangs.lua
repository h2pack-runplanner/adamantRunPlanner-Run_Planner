-- Selection is published; native SetupUnit/ApplyEliteAttribute still own actual
-- name lookup, room fallback and per-room application caps.
local fangs = {}

-- Native PickEliteAttributes draws in order from options not banned by the
-- encounter and passing IsEliteAttributeEligible; each pick removes its BlockAttributes.
function fangs.admit(decision, encounter, enemies, eligible)
    local selected = decision.fangs
    if selected == nil or #selected.perks == 0 then return nil end
    local name = selected.type.nativeId
    local enemy = enemies[name]
    if type(eligible) ~= "function" then return "missing-elite-attribute-eligibility" end
    local banned, options = {}, {}
    for _, perk in pairs(encounter.BannedEliteAttributes or {}) do banned[perk] = true end
    for _, perk in pairs(enemy.EliteAttributeOptions or {}) do
        if not banned[perk] then
            local ok, verdict = pcall(eligible, enemy, perk)
            if not ok then return "native-perk-check-error", { enemy = name, perk = perk, observed = tostring(verdict) } end
            if verdict then options[perk] = true end
        end
    end
    for position, perk in ipairs(selected.perks) do
        if not options[perk] then return "fangs-perk-unavailable", { enemy = name, perk = perk, position = position } end
        options[perk] = nil
        for _, blocked in pairs(((enemy.EliteAttributeData or {})[perk] or {}).BlockAttributes or {}) do
            options[blocked] = nil
        end
    end
end

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
