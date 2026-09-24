local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")

local generated = {}

local function ordinal(value, label)
    return p.int(value, label, 1) and value <= 4
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
    local row, err = p.exact(value, { "decisionKey", "kind", "expectedBudget", "waveCount", "waves" },
        { "baseRoll", "highlight", "fangs", "menace" }, label)
    if not row then return nil, err end
    if row.kind ~= "generated" or not p.str(row.decisionKey, label .. ".decisionKey") then
        return p.fail(label .. " has invalid generated decision")
    end
    if not ordinal(row.waveCount, label .. ".waveCount") then
        return p.fail(label .. " has invalid wave count")
    end
    if not p.num(row.expectedBudget, label .. ".expectedBudget", 0) then
        return p.fail(label .. " has invalid expected budget")
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
    if row.menace ~= nil then
        local menace, menaceError = p.arr(row.menace, label .. ".menace", 4)
        if not menace then return nil, menaceError end
        local menaceWaves = {}
        for index, waveValue in ipairs(menace) do
            local wave, waveError = p.exact(waveValue, { "waveIndex", "conversions" }, {}, label .. ".menace[" .. index .. "]")
            if not wave then return nil, waveError end
            if not ordinal(wave.waveIndex, label .. ".menace[" .. index .. "].waveIndex") then return p.fail(label .. " has invalid Menace wave") end
            if menaceWaves[wave.waveIndex] then return p.fail(label .. " has duplicate Menace wave") end
            menaceWaves[wave.waveIndex] = true
            local conversions, conversionsError = p.arr(wave.conversions, label .. ".menace[" .. index .. "].conversions", 5)
            if not conversions then return nil, conversionsError end
            for conversionIndex, conversionValue in ipairs(conversions) do
                local conversionLabel = label .. ".menace[" .. index .. "].conversions[" .. conversionIndex .. "]"
                local conversion, conversionError = p.exact(conversionValue, { "source", "count" }, { "target" }, conversionLabel)
                if not conversion then return nil, conversionError end
                local source, sourceError = enemy(conversion.source, conversionLabel .. ".source")
                if not source then return nil, sourceError end
                if not p.int(conversion.count, conversionLabel .. ".count", 0) then return p.fail(label .. " has invalid Menace count") end
                if conversion.count > 0 and conversion.target == nil then return p.fail(label .. " positive Menace conversion requires target") end
                if conversion.target ~= nil then
                    local target, targetError = enemy(conversion.target, label .. ".menace[" .. index .. "].conversions[" .. conversionIndex .. "].target")
                    if not target then return nil, targetError end
                end
            end
        end
    end
    do
        local waves, wavesError = p.arr(row.waves, label .. ".waves", 4)
        if not waves then return nil, wavesError end
        if #waves ~= row.waveCount then return p.fail(label .. " waves must cover wave count") end
        for index, valueWave in ipairs(waves) do
            local path = label .. ".waves[" .. index .. "]"
            local wave, waveError = p.exact(valueWave, { "waveIndex", "types", "counts" }, {}, path)
            if not wave then return nil, waveError end
            if wave.waveIndex ~= index then
                return p.fail(path .. " must follow wave index order")
            end
            local types, typesError = p.arr(wave.types, path .. ".types", 5)
            if not types then return nil, typesError end
            if #types == 0 then return p.fail(path .. " requires generated types") end
            local keys, nativeIds = {}, {}
            for typeIndex, valueType in ipairs(types) do
                local spawn, shapeError = p.exact(valueType, { "choiceKey", "nativeId", "source" }, {}, path .. ".types")
                if not spawn then return nil, shapeError end
                if spawn.source ~= "fixed" and spawn.source ~= "template"
                    and spawn.source ~= "highlight" and spawn.source ~= "addition" then
                    return p.fail(path .. ".types has invalid source")
                end
                if not p.str(spawn.choiceKey, path .. ".types[" .. typeIndex .. "].choiceKey")
                    or not p.str(spawn.nativeId, path .. ".types[" .. typeIndex .. "].nativeId") then
                    return p.fail(path .. ".types has invalid enemy identity")
                end
                if keys[spawn.choiceKey] or nativeIds[spawn.nativeId] then
                    return p.fail(path .. " has duplicate generated types")
                end
                keys[spawn.choiceKey], nativeIds[spawn.nativeId] = true, true
            end
            local highlightCount = 0
            for _, entry in ipairs(types) do if entry.source == "highlight" then highlightCount = highlightCount + 1 end end
            if (row.highlight == nil and highlightCount ~= 0) or (row.highlight ~= nil
                and (highlightCount ~= 1 or types[1].source ~= "highlight"
                    or types[1].choiceKey ~= row.highlight.choiceKey
                    or types[1].nativeId ~= row.highlight.nativeId)) then
                return p.fail(path .. " must have exactly its declared highlight first")
            end
            if type(wave.counts) ~= "table" then return p.fail(path .. " counts must be an object") end
            local countNames = 0
            for name, count in pairs(wave.counts) do
                countNames = countNames + 1
                if type(name) ~= "string" or not p.int(count, path .. ".counts", 1) or nativeIds[name] == nil then
                    return p.fail(path .. " counts must exactly name generated types")
                end
            end
            if countNames ~= #types then return p.fail(path .. " counts must exactly name generated types") end
        end
    end
    if row.fangs ~= nil then
        local found = false
        for _, wave in ipairs(row.waves) do
            for _, entry in ipairs(wave.types) do
                if entry.choiceKey == row.fangs.type.choiceKey and entry.nativeId == row.fangs.type.nativeId then
                    found = true
                end
            end
        end
        if not found then return p.fail(label .. ".fangs.type must be in the published roster") end
    end
    for _, menaceWave in ipairs(row.menace or {}) do
        local wave = row.waves[menaceWave.waveIndex]
        if wave == nil then return p.fail(label .. " Menace wave is unavailable") end
        local sources = {}
        for _, conversion in ipairs(menaceWave.conversions) do
            if sources[conversion.source.nativeId] then return p.fail(label .. " has duplicate Menace source") end
            sources[conversion.source.nativeId] = true
            local found = false
            for _, entry in ipairs(wave.types) do
                if entry.choiceKey == conversion.source.choiceKey and entry.nativeId == conversion.source.nativeId
                    and conversion.count <= wave.counts[entry.nativeId] then found = true end
            end
            if not found then return p.fail(label .. " Menace conversion exceeds its source request") end
        end
    end
    return row
end

return generated
