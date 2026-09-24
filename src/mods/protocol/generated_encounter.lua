local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")

local generated = {}

local function ordinal(value, label)
    return p.int(value, label, 1) and value <= 5
end

local function enemy(value, label)
    local row, err = p.exact(value, { "choiceKey", "nativeId" }, {}, label)
    if not row then return nil, err end
    if not p.str(row.choiceKey, label .. ".choiceKey") or not p.str(row.nativeId, label .. ".nativeId") then
        return p.fail(label .. " has invalid enemy identity")
    end
    return row
end

function generated.decode(value, label)
    local row, err = p.exact(value, { "decisionKey", "kind" }, { "baseRoll", "waveCount", "highlight", "fangs", "waves" }, label)
    if not row then return nil, err end
    if row.kind ~= "generated" or not p.str(row.decisionKey, label .. ".decisionKey") then
        return p.fail(label .. " has invalid generated decision")
    end
    if row.waveCount ~= nil and not ordinal(row.waveCount, label .. ".waveCount") then
        return p.fail(label .. " has invalid wave count")
    end
    if row.baseRoll ~= nil and (not p.int(row.baseRoll, label .. ".baseRoll", 0) or row.baseRoll > 10000) then
        return p.fail(label .. " has invalid base roll")
    end
    if row.highlight ~= nil then
        local highlight, highlightError = enemy(row.highlight, label .. ".highlight")
        if not highlight then return nil, highlightError end
        if row.waveCount == 1 then return p.fail(label .. " cannot highlight a single wave") end
    end
    if row.fangs ~= nil then
        local fangs, fangsError = p.exact(row.fangs, { "type", "perks" }, {}, label .. ".fangs")
        if not fangs then return nil, fangsError end
        local selected, selectedError = enemy(fangs.type, label .. ".fangs.type")
        if not selected then return nil, selectedError end
        local perks, perksError = p.arr(fangs.perks, label .. ".fangs.perks", 2)
        if not perks then return nil, perksError end
        local seen = {}
        for index, perk in ipairs(perks) do
            if not p.str(perk, label .. ".fangs.perks[" .. index .. "]") or seen[perk] then
                return p.fail(label .. " has invalid Fangs perks")
            end
            seen[perk] = true
        end
    end
    if row.waves ~= nil then
        local waves, wavesError = p.arr(row.waves, label .. ".waves", 5)
        if not waves then return nil, wavesError end
        if #waves == 0 then return p.fail(label .. " has no waves") end
        local seen = {}
        for index, valueWave in ipairs(waves) do
            local path = label .. ".waves[" .. index .. "]"
            local wave, waveError = p.exact(valueWave, { "waveIndex", "types" }, { "allocations" }, path)
            if not wave then return nil, waveError end
            if not ordinal(wave.waveIndex, path .. ".waveIndex") or seen[wave.waveIndex]
                or (row.waveCount ~= nil and wave.waveIndex > row.waveCount) then
                return p.fail(path .. " has duplicate or out-of-range wave index")
            end
            seen[wave.waveIndex] = true
            local types, typesError = p.arr(wave.types, path .. ".types", 5)
            if not types then return nil, typesError end
            if #types == 0 then return p.fail(path .. " requires generated types") end
            local keys, nativeIds = {}, {}
            for typeIndex, valueType in ipairs(types) do
                local entry, entryError = enemy(valueType, path .. ".types[" .. typeIndex .. "]")
                if not entry then return nil, entryError end
                if keys[entry.choiceKey] or nativeIds[entry.nativeId] then
                    return p.fail(path .. " has duplicate generated types")
                end
                keys[entry.choiceKey], nativeIds[entry.nativeId] = true, true
            end
            if row.highlight ~= nil and (types[1].choiceKey ~= row.highlight.choiceKey
                or types[1].nativeId ~= row.highlight.nativeId) then
                return p.fail(path .. " must seed its declared highlight first")
            end
            if wave.allocations ~= nil then
                if type(wave.allocations) ~= "table" then return p.fail(path .. " allocations must be an object") end
                for name, allocation in pairs(wave.allocations) do
                    if type(name) ~= "string" or not p.num(allocation, path .. ".allocations") or allocation < 0
                        or nativeIds[name] == nil then
                        return p.fail(path .. " allocations must name generated types with nonnegative values")
                    end
                end
            end
        end
    end
    if row.baseRoll == nil and row.waveCount == nil and row.highlight == nil and row.fangs == nil and row.waves == nil then
        return p.fail(label .. " has no active override")
    end
    return row
end

return generated
